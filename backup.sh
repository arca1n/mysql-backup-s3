#!/bin/sh

set -e

if [ "${S3_ACCESS_KEY_ID}" = "**None**" ]; then
  echo "Warning: You did not set the S3_ACCESS_KEY_ID environment variable."
fi

if [ "${S3_SECRET_ACCESS_KEY}" = "**None**" ]; then
  echo "Warning: You did not set the S3_SECRET_ACCESS_KEY environment variable."
fi

if [ "${S3_BUCKET}" = "**None**" ]; then
  echo "You need to set the S3_BUCKET environment variable."
  exit 1
fi

if [ "${MYSQLDUMP_DATABASE}" = "**None**" ]; then
  echo "You need to set the MYSQLDUMP_DATABASE environment variable (database name OR --all-databases)."
  exit 1
fi

if [ "${MYSQL_HOST}" = "**None**" ]; then
  echo "You need to set the MYSQL_HOST environment variable."
  exit 1
fi

if [ "${MYSQL_USER}" = "**None**" ]; then
  echo "You need to set the MYSQL_USER environment variable."
  exit 1
fi

if [ "${MYSQL_PASSWORD}" = "**None**" ]; then
  echo "You need to set the MYSQL_PASSWORD environment variable or link to a container named MYSQL."
  exit 1
fi

if [ "${S3_IAMROLE}" != "true" ]; then
  # env vars needed for aws tools - only if an IAM role is not used
  export AWS_ACCESS_KEY_ID=$S3_ACCESS_KEY_ID
  export AWS_SECRET_ACCESS_KEY=$S3_SECRET_ACCESS_KEY
  export AWS_DEFAULT_REGION=$S3_REGION
fi

MYSQL_HOST_OPTS="-h $MYSQL_HOST -P $MYSQL_PORT -u$MYSQL_USER -p$MYSQL_PASSWORD"
DUMP_START_TIME=$(date +"%Y-%m-%dT%H%M%SZ")

mysqldump --version

copy_s3 () {
  SRC_FILE=$1
  DEST_FILE=$2

  if [ "${S3_ENDPOINT}" = "**None**" ]; then
    AWS_ARGS=""
  else
    AWS_ARGS="--endpoint-url ${S3_ENDPOINT}"
  fi

  echo "Uploading ${DEST_FILE} on S3..."

  # Create a temporary rclone config using provided credentials (or env auth when using IAM role)
  RCLONE_CONF=/tmp/rclone.conf
  echo "[s3]" > $RCLONE_CONF
  echo "type = s3" >> $RCLONE_CONF
  # If using IAM role, let rclone use env auth
  if [ "${S3_IAMROLE}" = "true" ]; then
    echo "env_auth = true" >> $RCLONE_CONF
  else
    echo "access_key_id = ${S3_ACCESS_KEY_ID}" >> $RCLONE_CONF
    echo "secret_access_key = ${S3_SECRET_ACCESS_KEY}" >> $RCLONE_CONF
  fi
  if [ "${S3_REGION}" != "" ]; then
    echo "region = ${S3_REGION}" >> $RCLONE_CONF
  fi
  if [ "${S3_ENDPOINT}" != "**None**" ]; then
    # For non-AWS endpoints, use provider = Other and set the endpoint
    echo "provider = Other" >> $RCLONE_CONF
    echo "endpoint = ${S3_ENDPOINT}" >> $RCLONE_CONF
  else
    # Default provider is AWS
    echo "provider = AWS" >> $RCLONE_CONF
  fi

  # Use rclone rcat to stream the file to the remote path
  # rclone will read from stdin and write to s3:<bucket>/<prefix>/<dest>
  rclone rcat --config $RCLONE_CONF "s3:$S3_BUCKET/$S3_PREFIX/$DEST_FILE" < "$SRC_FILE"

  if [ $? != 0 ]; then
    >&2 echo "Error uploading ${DEST_FILE} on S3 via rclone"
  fi

  rm -f $SRC_FILE $RCLONE_CONF
}

# Multi databases: yes
if [ ! -z "$(echo $MULTI_DATABASES | grep -i -E "(yes|true|1)")" ]; then
  if [ "${MYSQLDUMP_DATABASE}" = "--all-databases" ]; then
    DATABASES=`mysql $MYSQL_HOST_OPTS -e "SHOW DATABASES;" | grep -Ev "(Database|information_schema|performance_schema|mysql|sys|innodb)"`
  else
    DATABASES=$MYSQLDUMP_DATABASE
  fi

  for DB in $DATABASES; do
    echo "Creating individual dump of ${DB} from ${MYSQL_HOST}..."

    DUMP_FILE="/tmp/${DB}.sql.gz"

    mysqldump $MYSQL_HOST_OPTS $MYSQLDUMP_OPTIONS $DB | gzip > $DUMP_FILE

    if [ $? = 0 ]; then
      if [ "${S3_FILENAME}" = "**None**" ]; then
        S3_FILE="${DUMP_START_TIME}.${DB}.sql.gz"
      else
        S3_FILE="${S3_FILENAME}.${DB}.sql.gz"
      fi

      copy_s3 $DUMP_FILE $S3_FILE
    else
      >&2 echo "Error creating dump of ${DB}"
    fi
  done
# Multi databases: no
else
  echo "Creating dump for ${MYSQLDUMP_DATABASE} from ${MYSQL_HOST}..."
  DB=$MYSQLDUMP_DATABASE

  DUMP_FILE="/tmp/${DB}.sql.gz"
  mysqldump $MYSQL_HOST_OPTS $MYSQLDUMP_OPTIONS $DB | gzip > $DUMP_FILE

  if [ $? = 0 ]; then
    if [ "${S3_FILENAME}" = "**None**" ]; then
      S3_FILE="${DUMP_START_TIME}.${DB}.sql.gz"
    else
      S3_FILE="${S3_FILENAME}.${DB}.sql.gz"
    fi

    copy_s3 $DUMP_FILE $S3_FILE
  else
    >&2 echo "Error creating dump of ${DB}"
  fi
fi

echo "SQL backup finished"
