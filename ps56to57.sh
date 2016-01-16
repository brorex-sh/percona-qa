#!/bin/bash 
# Created by Ramesh Sivaraman, Percona LLC

# User Configurable Variables
SBENCH="sysbench"
PORT=$[50000 + ( $RANDOM % ( 9999 ) ) ]
WORKDIR=$1
ROOT_FS=$WORKDIR
SCRIPT_PWD=$(cd `dirname $0` && pwd)
LPATH="/usr/share/doc/sysbench/tests/db"

if [ -z ${BUILD_NUMBER} ]; then
  BUILD_NUMBER=1001
fi

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"

if [ -z ${SDURATION} ]; then
  SDURATION=100
fi

if [ -z ${TSIZE} ]; then
  TSIZE=500
fi

if [ -z ${NUMT} ]; then
  NUMT=16
fi

if [ -z ${TCOUNT} ]; then
  TCOUNT=10
fi

cleanup(){
  tar cvzf $ROOT_FS/results-${BUILD_NUMBER}.tar.gz $WORKDIR/logs || true
}

echoit(){
  echo "[$(date +'%T')] $1"
  if [ "${WORKDIR}" != "" ]; then echo "[$(date +'%T')] $1" >> ${WORKDIR}/upgrade_testing.log; fi
}

trap cleanup EXIT KILL

cd $ROOT_FS

if [ ! -d $ROOT_FS/test_db ]; then
  git clone https://github.com/datacharmer/test_db.git
fi

PS56_TAR=`ls -1td ?ercona-?erver-5.6* | grep ".tar" | head -n1`
PS57_TAR=`ls -1td ?ercona-?erver-5.7* | grep ".tar" | head -n1`

if [ ! -z $PS56_TAR ];then
  tar -xzf $PS56_TAR
  PS56_BASE=`ls -1td ?ercona-?erver-5.6* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PS56_BASE/bin:$PATH"
fi

if [ ! -z $PS57_TAR ];then
  tar -xzf $PS57_TAR
  PS57_BASE=`ls -1td ?ercona-?erver-5.7* | grep -v ".tar" | head -n1`
  export PATH="$ROOT_FS/$PS57_BASE/bin:$PATH"
fi

WORKDIR="${ROOT_FS}/$BUILD_NUMBER"
PS56_BASEDIR="${ROOT_FS}/$PS56_BASE"
PS57_BASEDIR="${ROOT_FS}/$PS57_BASE"

export MYSQL_VARDIR="$WORKDIR/mysqldir"
mkdir -p $MYSQL_VARDIR
mkdir -p $WORKDIR/logs

psdatadir="${MYSQL_VARDIR}/psdata"
mkdir -p $psdatadir

function create_emp_db()
{
  DB_NAME=$1
  SE_NAME=$2
  SQL_FILE=$3
  pushd $ROOT_FS/test_db
  cat $ROOT_FS/test_db/$SQL_FILE \
   | sed -e "s|DROP DATABASE IF EXISTS employees|DROP DATABASE IF EXISTS ${DB_NAME}|" \
   | sed -e "s|CREATE DATABASE IF NOT EXISTS employees|CREATE DATABASE IF NOT EXISTS ${DB_NAME}|" \
   | sed -e "s|USE employees|USE ${DB_NAME}|" \
   | sed -e "s|set default_storage_engine = InnoDB|set default_storage_engine = ${SE_NAME}|" \
   > $ROOT_FS/test_db/${DB_NAME}_${SE_NAME}.sql
   $PS56_BASEDIR/bin/mysql --socket=${WORKDIR}/ps56.sock -u root < ${ROOT_FS}/test_db/${DB_NAME}_${SE_NAME}.sql || true
   popd
}

#Load jemalloc lib
if [ -r `find /usr/*lib*/ -name libjemalloc.so.1 | head -n1` ]; then 
  export LD_PRELOAD=`find /usr/*lib*/ -name libjemalloc.so.1 | head -n1`
elif [ -r /sda/workdir/PS-mysql-5.7.10-1rc1-linux-x86_64-debug/lib/mysql/libjemalloc.so.1 ]; then 
  export LD_PRELOAD=/sda/workdir/PS-mysql-5.7.10-1rc1-linux-x86_64-debug/lib/mysql/libjemalloc.so.1
else 
  echoit "Error: jemalloc not found, please install it first" 
  exit 1; 
fi


pushd ${PS56_BASEDIR}/mysql-test/

set +e 
perl mysql-test-run.pl \
  --start-and-exit \
  --vardir=$psdatadir \
  --mysqld=--port=$PORT \
  --mysqld=--innodb_file_per_table \
  --mysqld=--default-storage-engine=InnoDB \
  --mysqld=--binlog-format=ROW \
  --mysqld=--log-bin=mysql-bin \
  --mysqld=--server-id=101 \
  --mysqld=--gtid-mode=ON  \
  --mysqld=--log-slave-updates \
  --mysqld=--enforce-gtid-consistency \
  --mysqld=--innodb_flush_method=O_DIRECT \
  --mysqld=--core-file \
  --mysqld=--secure-file-priv= \
  --mysqld=--skip-name-resolve \
  --mysqld=--log-error=$WORKDIR/logs/ps56.err \
  --mysqld=--socket=$WORKDIR/ps56.sock \
  --mysqld=--log-output=none \
1st  
set -e
popd

#Install TokuDB plugin
echo "INSTALL PLUGIN tokudb SONAME 'ha_tokudb.so'" | $PS56_BASEDIR/bin/mysql -uroot  --socket=$WORKDIR/ps56.sock 
$PS56_BASEDIR/bin/mysql -uroot  --socket=$WORKDIR/ps56.sock < ${SCRIPT_PWD}/TokuDB.sql
echoit "Sysbench Run: Prepare stage"

$SBENCH --test=$LPATH/parallel_prepare.lua --report-interval=10 --mysql-engine-trx=yes --mysql-table-engine=innodb --oltp-table-size=$TSIZE --oltp_tables_count=$TCOUNT --mysql-db=test --mysql-user=root  --num-threads=$NUMT --db-driver=mysql --mysql-socket=$WORKDIR/ps56.sock prepare  2>&1 | tee $WORKDIR/logs/sysbench_prepare.txt

echoit "Loading sakila test database"
$PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root < ${SCRIPT_PWD}/sample_db/sakila.sql

echoit "Loading world test database"
$PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root < ${SCRIPT_PWD}/sample_db/world.sql

echoit "Loading employees database with innodb engine.."
create_emp_db employee_1 innodb employees.sql

echoit "Loading employees partitioned database with innodb engine.."
create_emp_db employee_2 innodb employees_partitioned.sql

echoit "Loading employees database with myisam engine.."
create_emp_db employee_3 myisam employees.sql

echoit "Loading employees partitioned database with myisam engine.."
create_emp_db employee_4 myisam employees_partitioned.sql

echoit "Drop foreign keys for changing storage engine"
$PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root -Bse "SELECT CONCAT('ALTER TABlE ',TABLE_SCHEMA,'.',TABLE_NAME,' DROP FOREIGN KEY ',CONSTRAINT_NAME) as a FROM INFORMATION_SCHEMA.TABLE_CONSTRAINTS WHERE CONSTRAINT_TYPE='FOREIGN KEY' AND TABLE_SCHEMA NOT IN('mysql','information_schema','performance_schema','sys')" | while read drop_key ; do
  echoit "Executing : $drop_key"
  echo "$drop_key" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root
done

echoit "Altering tables to TokuDB.."

$PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root -Bse "select concat('ALTER TABLE ',table_schema,'.',table_name,' ENGINE=TokuDB') as a from information_schema.tables where table_schema not in('mysql','information_schema','performance_schema','sys') and table_type='BASE TABLE'" | while read alter_tbl ; do
  echoit "Executing : $alter_tbl"
  echo "$alter_tbl" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root || true  
done

echoit "Loading employees database with tokudb engine for upgrade testing.."
create_emp_db employee_5 tokudb employees.sql

echoit "Loading employees partitioned database with tokudb engine for upgrade testing.."
create_emp_db employee_6 tokudb employees_partitioned.sql

echoit "Loading employees database with innodb engine for upgrade testing.."
create_emp_db employee_7 innodb employees.sql

echoit "Loading employees partitioned database with innodb engine for upgrade testing.."
create_emp_db employee_8 innodb employees_partitioned.sql

echoit "Loading employees database with myisam engine for upgrade testing.."
create_emp_db employee_9 myisam employees.sql

echoit "Loading employees partitioned database with myisam engine for upgrade testing.."
create_emp_db employee_10 myisam employees_partitioned.sql

#Partition testing with sysbench data
echo "ALTER TABLE test.sbtest1 PARTITION BY HASH(id) PARTITIONS 8;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root || true
echo "ALTER TABLE test.sbtest2 PARTITION BY LINEAR KEY ALGORITHM=2 (id) PARTITIONS 32;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root || true
echo "ALTER TABLE test.sbtest3 PARTITION BY HASH(id) PARTITIONS 8;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root || true
echo "ALTER TABLE test.sbtest4 PARTITION BY LINEAR KEY ALGORITHM=2 (id) PARTITIONS 32;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps56.sock -u root || true

$PS56_BASEDIR/bin/mysqladmin  --socket=$WORKDIR/ps56.sock -u root shutdown


pushd ${PS57_BASEDIR}/mysql-test/

set +e 
perl mysql-test-run.pl \
  --start-and-exit \
  --start-dirty \
  --vardir=$psdatadir \
  --mysqld=--port=$PORT \
  --mysqld=--innodb_file_per_table \
  --mysqld=--default-storage-engine=InnoDB \
  --mysqld=--binlog-format=ROW \
  --mysqld=--log-bin=mysql-bin \
  --mysqld=--server-id=101 \
  --mysqld=--gtid-mode=ON  \
  --mysqld=--log-slave-updates \
  --mysqld=--enforce-gtid-consistency \
  --mysqld=--innodb_flush_method=O_DIRECT \
  --mysqld=--core-file \
  --mysqld=--secure-file-priv= \
  --mysqld=--skip-name-resolve \
  --mysqld=--log-error=$WORKDIR/logs/ps57.err \
  --mysqld=--socket=$WORKDIR/ps57.sock \
  --mysqld=--log-output=none \
1st  
set -e
popd

$PS57_BASEDIR/bin/mysql_upgrade -S $WORKDIR/ps57.sock -u root 2>&1 | tee $WORKDIR/logs/mysql_upgrade.log

echo "ALTER TABLE test.sbtest1 COALESCE PARTITION 2;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -u root || true
echo "ALTER TABLE test.sbtest2 REORGANIZE PARTITION;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -u root || true
echo "ALTER TABLE test.sbtest3 ANALYZE PARTITION p1;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -u root || true
echo "ALTER TABLE test.sbtest4 CHECK PARTITION p2;" | $PS56_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -u root || true

$PS57_BASEDIR/bin/mysql -S $WORKDIR/ps57.sock  -u root -e "show global variables like 'version';"

echoit "Downgrade testing with mysqlddump and reload.."
$PS57_BASEDIR/bin/mysqldump --set-gtid-purged=OFF  --triggers --routines --socket=$WORKDIR/ps57.sock -uroot --databases `$PS57_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -uroot -Bse "SELECT GROUP_CONCAT(schema_name SEPARATOR ' ') FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','performance_schema','information_schema','sys','mtr');"` > $WORKDIR/dbdump.sql 2>&1

psdatadir="${MYSQL_VARDIR}/ps56_down"
PORT1=$[50000 + ( $RANDOM % ( 9999 ) ) ]

pushd ${PS56_BASEDIR}/mysql-test/

set +e 
perl mysql-test-run.pl \
  --start-and-exit \
  --vardir=$psdatadir \
  --mysqld=--port=$PORT1 \
  --mysqld=--innodb_file_per_table \
  --mysqld=--default-storage-engine=InnoDB \
  --mysqld=--binlog-format=ROW \
  --mysqld=--log-bin=mysql-bin \
  --mysqld=--server-id=101 \
  --mysqld=--gtid-mode=ON  \
  --mysqld=--log-slave-updates \
  --mysqld=--enforce-gtid-consistency \
  --mysqld=--innodb_flush_method=O_DIRECT \
  --mysqld=--core-file \
  --mysqld=--secure-file-priv= \
  --mysqld=--skip-name-resolve \
  --mysqld=--log-error=$WORKDIR/logs/ps56_down.err \
  --mysqld=--socket=$WORKDIR/ps56_down.sock \
  --mysqld=--log-output=none \
1st
set -e
popd

${PS56_BASEDIR}/bin/mysql --socket=$WORKDIR/ps56_down.sock -uroot < $WORKDIR/dbdump.sql 2>&1

CHECK_DBS=`$PS57_BASEDIR/bin/mysql --socket=$WORKDIR/ps57.sock -uroot -Bse "SELECT GROUP_CONCAT(schema_name SEPARATOR ' ') FROM information_schema.schemata WHERE schema_name NOT IN ('mysql','performance_schema','information_schema','sys','mtr');"`

echoit "Checking table status..."
${PS56_BASEDIR}/bin/mysqlcheck -uroot --socket=$WORKDIR/ps56_down.sock --check-upgrade --databases $CHECK_DBS 2>&1

