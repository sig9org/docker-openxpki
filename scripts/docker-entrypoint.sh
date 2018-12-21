#!/bin/bash

function fixPermissions {

  chown openxpki:openxpki /etc/openxpki -R
  if [ -f "/etc/openxpki/customconfig.sh" ]; then
    chmod 0700 /etc/openxpki/customconfig.sh
    chown root:root /etc/openxpki/customconfig.sh
  fi
  
  mkdir -p /var/log/apache2 && chown -R www-data:www-data /var/log/apache2 && chmod 0775 /var/log/apache2 && chmod 0664 /var/log/apache2/*
  mkdir -p /var/log/openxpki && chown -R openxpki:www-data /var/log/openxpki && chmod 0775 /var/log/openxpki && chmod 0664 /var/log/openxpki/*

}

function checkDbVariables {
  if [ -z "${APP_DB_NAME}" ]; then echo "Missing APP_DB_NAME, set this variable or link a mysql server with the name mysql."; exit 101; fi
  if [ -z "${APP_DB_HOST}" ]; then echo "Missing APP_DB_HOST, set this variable or link a mysql server with the name mysql."; exit 102; fi
  if [ -z "${APP_DB_PORT}" ]; then echo "Missing APP_DB_PORT, set this variable or link a mysql server with the name mysql."; exit 103; fi
  if [ -z "${APP_DB_USER}" ]; then echo "Missing APP_DB_USER, set this variable or link a mysql server with the name mysql."; exit 104; fi
  if [ -z "${APP_DB_PASS}" ]; then echo "Missing APP_DB_PASS, set this variable or link a mysql server with the name mysql."; exit 105; fi
}

function waitForDbConnection {

  connectionAttempt=1
  while ! echo "SHOW GRANTS FOR CURRENT_USER;" | mysql -u ${APP_DB_USER} -p${APP_DB_PASS} -D ${APP_DB_NAME} -h ${APP_DB_HOST} -P ${APP_DB_PORT}; do
    if [ $connectionAttempt -gt 30 ]; then
      echo "Maximum amounts of attempts reached, stopping now."
      exit 1
    fi
    echo "Connection to MySql server failed, waiting 5s before trying again. [${connectionAttempt}/30]"
    sleep 5
    connectionAttempt=$[$connectionAttempt +1]
  done
  echo "Connection to MySql server was successful."

}

function waitForRootDbConnection {

  if [ -z "${APP_DB_ROOT_PASS}" ]; then
    echo "No root password set, cannot wait for root db connection"
    exit 1
  fi

  connectionAttempt=1
  while ! echo "show databases;" | mysql -u root -p${APP_DB_ROOT_PASS} -h ${APP_DB_HOST} -P ${APP_DB_PORT}; do
    if [ $connectionAttempt -gt 30 ]; then
      echo "Maximum amounts of attempts reached, stopping now."; exit 1
    fi
    echo "Connection to MySql server failed, waiting 5s before trying again. [${connectionAttempt}/30]"
    sleep 5
    connectionAttempt=$[$connectionAttempt +1]
  done
  echo "Connection to MySql server as root was successful."

}

function create_config {

  # Use custom configuration if available - otherwise the default
  if [ -f "/etc/openxpki/customconfig.sh" ]; then
     echo "Found custom configuration, securing and executing it."
     chown root:root /etc/openxpki/customconfig.sh
     chmod 700 /etc/openxpki/customconfig.sh
     /etc/openxpki/customconfig.sh
  elif [ -f "/usr/share/doc/libopenxpki-perl/examples/sampleconfig.sh" ]; then
    echo "Found no custom customconfig.sh - using default sampleconfig.sh from /usr/share/doc/libopenxpki-perl/examples/sampleconfig.sh"
    sh /usr/share/doc/libopenxpki-perl/examples/sampleconfig.sh
  elif [ -f "/usr/share/doc/libopenxpki-perl/examples/sampleconfig.sh.gz" ]; then
    echo "Found no custom customconfig.sh - using default compressed sampleconfig.sh.gz from /usr/share/doc/libopenxpki-perl/examples/sampleconfig.sh.gz"
    gunzip < /usr/share/doc/libopenxpki-perl/examples/sampleconfig.sh.gz > /usr/share/doc/libopenxpki-perl/examples/sampleconfig.sh
    sh /usr/share/doc/libopenxpki-perl/examples/sampleconfig.sh
  else
    echo "Found no sampleconfig.sh and no customconfig.sh"
    exit 1
  fi
  
}

function create_db {

  if [ -z "${APP_DB_ROOT_PASS}" ]; then
    echo "No root password set, cannot create new database"
    exit 1
  fi

  APP_DB_NAME=${APP_DB_NAME:-openxpki}
  APP_DB_USER=${APP_DB_USER:-openxpki}
  APP_DB_PASS=${APP_DB_PASS:-openxpki}
 
  echo "CREATE DATABASE ${APP_DB_NAME} CHARSET utf8;" > /tmp/create_db.sh
  echo "CREATE USER '${APP_DB_USER}'@'%' IDENTIFIED BY '${APP_DB_PASS}';" >> /tmp/create_db.sh
  echo "GRANT ALL ON ${APP_DB_NAME}.* TO '${APP_DB_NAME}'@'%';" >> /tmp/create_db.sh
  echo "flush privileges;" >> /tmp/create_db.sh

  cat /tmp/create_db.sh | mysql -u root -p${APP_DB_ROOT_PASS} -h ${APP_DB_HOST} -P ${APP_DB_PORT}

  rm /tmp/create_db.sh
  
}

function init_db {
  # Extract sql file and install database shema
  zcat /usr/share/doc/libopenxpki-perl/examples/schema-mysql.sql.gz | \
    mysql -u ${APP_DB_USER} -p${APP_DB_PASS} -D ${APP_DB_NAME} -h ${APP_DB_HOST} -P ${APP_DB_PORT}

}

function update_db {
  local DB_NUM=0
  if [ -f "/etc/openxpki/.db_num" ]; then
    DB_NUM=$(cat /etc/openxpki/.db_num)
  else
    echo "Found no db_num, running all updates anyway"
  fi

  #Upate DB from 1.x to 2.x
  if [ $DB_NUM -lt 1 ]; then
    mysql -u ${APP_DB_USER} -p${APP_DB_PASS} -D ${APP_DB_NAME} -h ${APP_DB_HOST} -P ${APP_DB_PORT} << EOF
    ALTER TABLE certificate
      ADD revocation_time int(10) unsigned DEFAULT NULL,
      ADD invalidity_time int(10) unsigned DEFAULT NULL,
      ADD reason_code varchar(50) DEFAULT NULL,
      ADD hold_instruction_code varchar(50) DEFAULT NULL;
EOF

    mysql -u ${APP_DB_USER} -p${APP_DB_PASS} -D ${APP_DB_NAME} -h ${APP_DB_HOST} -P ${APP_DB_PORT} << EOF
    UPDATE crr crr LEFT JOIN certificate crt USING (identifier)
    SET crt.reason_code = crr.reason_code,
        crt.revocation_time = crr.revocation_time,
        crt.invalidity_time = crr.invalidity_time,
        crt.hold_instruction_code = crr.hold_code;
EOF

    mysql -u ${APP_DB_USER} -p${APP_DB_PASS} -D ${APP_DB_NAME} -h ${APP_DB_HOST} -P ${APP_DB_PORT} << EOF
    ALTER TABLE workflow_history
    ADD workflow_node varchar(64) DEFAULT NULL;
EOF

    mysql -u ${APP_DB_USER} -p${APP_DB_PASS} -D ${APP_DB_NAME} -h ${APP_DB_HOST} -P ${APP_DB_PORT} << EOF
    ALTER TABLE crl
    ADD crl_number decimal(49,0) DEFAULT NULL,
    ADD items int(10) DEFAULT 0,
    ADD KEY crl_number (issuer_identifier,crl_number);
EOF

    mysql -u ${APP_DB_USER} -p${APP_DB_PASS} -D ${APP_DB_NAME} -h ${APP_DB_HOST} -P ${APP_DB_PORT} << EOF
    CREATE TABLE `backend_session` (
      `session_id` varchar(255) NOT NULL,
      `data` longtext,
      `created` int(10) UNSIGNED NOT NULL,
      `modified` int(10) UNSIGNED NOT NULL,
      `ip_address` varchar(45) DEFAULT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8;
    CREATE TABLE `frontend_session` (
      `session_id` varchar(255) NOT NULL,
      `data` longtext,
      `created` int(10) UNSIGNED NOT NULL,
      `modified` int(10) UNSIGNED NOT NULL,
      `ip_address` varchar(45) DEFAULT NULL
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8;
    CREATE TABLE `ocsp_responses` (
      `identifier` varchar(64) DEFAULT NULL,
      `serial_number` varbinary(128) NOT NULL,
      `authority_key_identifier` varbinary(128) NOT NULL,
      `body` varbinary(4096) NOT NULL,
      `expiry` timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP
    ) ENGINE=InnoDB DEFAULT CHARSET=utf8;
    ALTER TABLE `workflow_history` CHANGE `workflow_node` `workflow_node` VARCHAR(64) NULL DEFAULT NULL;
    ALTER TABLE `openxpki`.`certificate` DROP INDEX `identifier`, ADD UNIQUE `identifier` (`identifier`) USING BTREE;
    ALTER TABLE `frontend_session`
      ADD PRIMARY KEY (`session_id`),
      ADD KEY `modified` (`modified`);
    ALTER TABLE `ocsp_responses`
      ADD PRIMARY KEY (`serial_number`,`authority_key_identifier`),
      ADD KEY `identifier` (`identifier`);
EOF
  fi

  #Update db_num
  echo "1" > "/etc/openxpki/.db_num"
}

function run_server {

  unset APP_DB_ROOT_PASS APP_DB_PASS

  # openxpkictl start --foreground is not working
  openxpkictl start

  apache2ctl -DFOREGROUND

}

# Check for linked MYSQL container
if [ -n "${MYSQL_NAME}" ]; then
  echo "Found linked MySql container, updating variables."
  MYSQL_DB_HOST="mysql"
  MYSQL_DB_NAME=${MYSQL_ENV_MYSQL_DATABASE}
  MYSQL_DB_PORT=${MYSQL_PORT_3306_TCP_PORT}
  MYSQL_DB_USER=${MYSQL_ENV_MYSQL_USER}
  MYSQL_DB_PASS=${MYSQL_ENV_MYSQL_PASSWORD}
  MYSQL_DB_ROOT_PASS=${MYSQL_ENV_MYSQL_ROOT_PASSWORD}

  # Unset the original variables to prevent leakage
  unset MYSQL_ENV_MYSQL_PASSWORD MYSQL_ENV_MYSQL_ROOT_PASSWORD
fi

# Using environment variables that may have been set
APP_DB_NAME=${APP_DB_NAME:-$MYSQL_DB_NAME}
APP_DB_HOST=${APP_DB_HOST:-$MYSQL_DB_HOST}
APP_DB_PORT=${APP_DB_PORT:-$MYSQL_DB_PORT}
APP_DB_USER=${APP_DB_USER:-$MYSQL_DB_USER}
APP_DB_PASS=${APP_DB_PASS:-$MYSQL_DB_PASS}
APP_DB_ROOT_PASS=${APP_DB_ROOT_PASS:-$MYSQL_DB_ROOT_PASS}

# Create default config files if missing - because of volume
if [ ! -d /etc/openxpki/config.d ]; then
  echo "Found no config.d folder in /etc/openxpki - extracting example configuration."
  tar xzf /usr/share/doc/libopenxpki-perl/examples/openxpki-etc.tgz -C /etc
fi

echo "Updating database.yml"
if [ -n "${APP_DB_NAME}" ]; then echo "Replacing DB_NAME with given APP_DB_NAME: ${APP_DB_NAME}"; sed -i "s/name: .*/name: ${APP_DB_NAME}/" /etc/openxpki/config.d/system/database.yaml; fi
if [ -n "${APP_DB_HOST}" ]; then echo "Replacing DB_HOST with given APP_DB_HOST: ${APP_DB_HOST}"; sed -i "s/host: .*/host: ${APP_DB_HOST}/" /etc/openxpki/config.d/system/database.yaml; fi
if [ -n "${APP_DB_PORT}" ]; then echo "Replacing DB_PORT with given APP_DB_PORT: ${APP_DB_PORT}"; sed -i "s/port: .*/port: ${APP_DB_PORT}/" /etc/openxpki/config.d/system/database.yaml; fi
if [ -n "${APP_DB_USER}" ]; then echo "Replacing DB_USER with given APP_DB_USER: ${APP_DB_USER}"; sed -i "s/user: .*/user: ${APP_DB_USER}/" /etc/openxpki/config.d/system/database.yaml; fi
if [ -n "${APP_DB_PASS}" ]; then echo "Replacing DB_PASS with given APP_DB_PASS: ${APP_DB_PASS}"; sed -i "s/passwd: .*/passwd: ${APP_DB_PASS}/" /etc/openxpki/config.d/system/database.yaml; fi

fixPermissions

# Start depending on parameters
if [ "$1" == "create_db" ]; then
  echo "================================================"
  echo "Received createdb parameter, creating database."
  echo "================================================"
  checkDbVariables
  waitForRootDbConnection
  create_db
elif [ "$1" == "init_db" ]; then
  echo "================================================"
  echo "Received initdb parameter, initiating database."
  echo "================================================"
  checkDbVariables
  waitForDbConnection
  init_db
elif [ "$1" == "update_db" ]; then
  echo "================================================"
  echo "Received updatedb parameter, updating database."
  echo "================================================"
  checkDbVariables
  waitForDbConnection
  update_db
elif [ "$1" == "create_certs" ]; then
  echo "================================================"
  echo "Received create_certs parameter, creating certificates."
  echo "================================================"
  create_config
elif [ "$1" == "wait_for_db" ]; then
  echo "================================================"
  echo "Received wait_for_db parameter, Waiting for successful database connection."
  echo "================================================"
  checkDbVariables
  waitForDbConnection
elif [ "$1" == "version" ]; then
  echo "================================================"
  echo "Versions:"
  echo "================================================"
  perl -v
  apache2 -v
  openxpkiadm version
elif [ "$1" == "run" ]; then
  echo "================================================"
  echo "Starting Servers"
  echo "================================================"
  run_server
elif [ -z "$1" ]; then
  if [ ! -f "/etc/openxpki/.initiated" ]; then
    echo "================================================"
    echo "No parameters given and /etc/openxpki/.initiated does not exist."
    echo "Waiting for DB connection before initiating database and creating configs."
    echo "================================================"
    checkDbVariables
    if [ -n "${APP_DB_ROOT_PASS}" ]; then
      waitForRootDbConnection
      echo "================================================"
      echo "Creating database."
      echo "================================================"
      create_db
    fi
    echo >/etc/openxpki/.initiated
    echo "================================================"
    echo "Initiating database."
    echo "================================================"
    init_db
    echo "================================================"
    echo "Creating configuration files."
    echo "================================================"
    create_config
    echo "================================================"
    echo "Starting Servers"
    echo "================================================"
    run_server
  else
    echo "================================================"
    echo "No parameters given and /etc/openxpki/.initiated exist."
    echo "================================================"
    echo "================================================"
    echo "Updating database"
    echo "================================================"
    update_db
    echo "================================================"
    echo "Starting Servers"
    echo "================================================"
    run_server
  fi
else
  echo "================================================"
  echo "Starting: $@"
  echo "================================================"
  apache2ctl start
  openxpkictl start
  exec "$@"
fi
