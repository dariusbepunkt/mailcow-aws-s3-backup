#!/bin/bash

##
## Cronjob:
## 7 4 * * * /home/path/to/backup.sh > /home/path/to/backup/log/mailcow_sys_$(date +\%Y-\%m-\%d-\%H-\%M-\%S).log 2>&1
##

#
# Functions
#
getDate() { echo $(date +'%d.%m.%Y %H:%M:%S'); }
info() { printf "\n- %s %s\n\n" "$( getDate )" "$*" >&2; }
trap "echo $( getDate ) Backup interrupted >&2; exit 2" INT TERM


#
# Settings
#

# System vars
workDirectory='/opt/mailcow-dockerized'		# path to docker-compose.yml
logDirectory='/home/path/to/backup/log'		# path top log archive (keep in mind to change path in cron also)
logKeepAmount='10'							# how many logfiles should be kept



# autocatch vars
source "${workDirectory}/mailcow.conf"
CMPS_PRJ=$(echo $COMPOSE_PROJECT_NAME | tr -cd "[A-Za-z-_]")

volumeVMail=$(docker volume inspect -f '{{ .Mountpoint }}' ${CMPS_PRJ}_vmail-vol-1)
volumeCrypt=$(docker volume inspect -f '{{ .Mountpoint }}' ${CMPS_PRJ}_crypt-vol-1)
volumeRedis=$(docker volume inspect -f '{{ .Mountpoint }}' ${CMPS_PRJ}_redis-vol-1)
volumeRSpamd=$(docker volume inspect -f '{{ .Mountpoint }}' ${CMPS_PRJ}_rspamd-vol-1)
volumePostfix=$(docker volume inspect -f '{{ .Mountpoint }}' ${CMPS_PRJ}_postfix-vol-1)
volumeMySQL=$(docker volume inspect -f '{{ .Mountpoint }}' ${CMPS_PRJ}_mysql-vol-1)



#
# Prerequisites
#

# check for root
if [[ "$(id -u)" != "0" ]] ; then
  info "ERROR: no root!"
  exit 1
fi

# check project name
if [[ -z "${CMPS_PRJ}" ]] ; then
  info "ERROR: empty docker-project-name"
  exit 1
fi

# create directories if not already done
if [[ ! -d "${logDirectory}" ]] ; then
  if ! mkdir -p "${logDirectory}" ; then
    info "ERROR: could not create logDirectory ($logDirectory)"
    exit 1
  fi
fi

if [[ ! -f "${workDirectory}/.env.aws" ]] ; then
    echo "ERROR: AWS Environment Variables not found. Copy .env.aws.dist to ${workDirectory}/.env.aws and adust it to your needs"
    exit 1
fi
export $(grep -v '^#' .env.aws | xargs)


#
# Pre-BackupProcess
#
startTime=$(date +%s)

echo
echo "=================================================="
info "start backup"


# clean old stuff
echo "-- clean up temp/log"
countLogs=$(ls -l ${logDirectory}/*.log 2>/dev/null | wc -l)
echo "--- found $countLogs old log files"
if (( "$countLogs" > "$logKeepAmount" )) ; then
  echo "--- delete old logfiles up to the last $logKeepAmount .."
  ls -dt ${logDirectory}/*.log | tail -n "+$((logKeepAmount+1))" | xargs rm -v
fi

echo
echo "-- pre backup stuff"

# ensure no more changes are made (e.g. send/receive mails, WebUI changes)
echo "--- mailcow: stop services"
echo "---- stop dovecot"
dovecot_id=$(docker stop "$(docker ps -qf name=dovecot-mailcow)")
if [[ "$(docker inspect -f '{{ .State.ExitCode }}' "$dovecot_id")" == "0" && "$(docker inspect -f '{{ .State.Running }}' "$dovecot_id")" == "false" ]] ; then
  echo "----- success"
else
  echo "----- FAILED"
fi
echo "---- stop postfix"
postfix_id=$(docker stop "$(docker ps -qf name=postfix-mailcow)")
if [[ "$(docker inspect -f '{{ .State.ExitCode }}' "$postfix_id")" == "0" && "$(docker inspect -f '{{ .State.Running }}' "$postfix_id")" == "false" ]] ; then
  echo "----- success"
else
  echo "----- FAILED"
fi

# show error on webstuff
echo "--- nginx return service unavailable"
echo "return 503;" > "${workDirectory}/data/conf/nginx/site.backup.custom"
nginx_id=$(docker restart "$(docker ps -qf name=nginx-mailcow)")
if [[ "$(docker inspect -f '{{ .State.Running }}' "$nginx_id")" == "true" ]] ; then
  echo "---- success"
else
  echo "---- FAILED"
fi

# backup database: mysql
echo "--- mysql-dump"
if [[ -d "${volumeMySQL}/tmp_backup" ]] ; then
  echo "---- WARN: tmp backup dir already exists"
  rm -r "${volumeMySQL}/tmp_backup"
  if [[ -d "${volumeMySQL}/tmp_backup" ]] ; then
    echo "---- FAILED: could not delete"
  fi
fi
mysql_id=$(docker ps -qf 'name=mysql-mailcow')
docker exec ${mysql_id} /bin/sh -c "mariabackup --host mysql --user root --password ${DBROOT} \
                                        --backup --rsync --target-dir=/var/lib/mysql/tmp_backup ; \
									mariabackup --prepare --target-dir=/var/lib/mysql/tmp_backup ; \
									chown -R 999:999 /var/lib/mysql/tmp_backup ;" > /dev/null 2>&1
if [[ -d "${volumeMySQL}/tmp_backup" ]] ; then
  echo "---- success"
else
  echo "---- FAILED: could not create backup"
fi

# backup database: redis
echo "--- redis-dump"
redis_id=$(docker ps -qf name=redis-mailcow)
redis_dump=$(docker exec $redis_id redis-cli save)
if [[ "$redis_dump" == "OK" ]]; then
  echo "---- success"
else
  echo "---- FAILED: $redisdump"
fi



#
# BackupProcess
#

# starting aws sync
echo
echo "-- start syncing files"
echo

thisDir="$( cd $( dirname ${BASH_SOURCE[0]} ) >/dev/null 2>&1 && pwd )"
thisFile="$(basename ${0})"

docker run --rm -it \
  -v ${workDirectory}/.env:/aws${workDirectory}/.env \
  -v ${workDirectory}/docker-compose.yml:/aws${workDirectory}/docker-compose.yml \
  -v ${workDirectory}/docker-compose.override.yml:/aws${workDirectory}/docker-compose.override.yml \
  -v ${workDirectory}/.nonexitentTest:/aws${workDirectory}/.nonexitentTest \
  -v ${workDirectory}/mailcow.conf:/aws${workDirectory}/mailcow.conf \
  -v ${volumeVMail}:/aws${volumeVMail} \
  -v ${volumeCrypt}:/aws${volumeVvolumeCryptMail} \
  -v ${volumeRedis}:/aws${volumeRedis} \
  -v ${volumeRSpamd}:/aws${volumeRSpamd} \
  -v ${volumePostfix}:/aws${volumePostfix} \
  -v ${volumeMySQL}/tmp_backup:/aws${volumeMySQL}/tmp_backup \
  -v ${thisDir}/${thisFile}:/aws${thisDir}/${thisFile} \
  -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY -e AWS_S3_BUCKET amazon/aws-cli s3 sync --delete . s3://$AWS_S3_BUCKET

docker_exit=$?

# check state
echo
echo "-- sync finished"
if [[ "${docker_exit}" == "0" ]] ; then
  echo "--- success"
elif [[ "${docker_exit}" == "1" ]] ; then
  echo "--- WARN: 1"
else
  echo "--- FAILED: ${docker_exit}"
fi



#
# Post-BackupProcess
#

echo
echo "-- post backup stuff"

echo "--- mailcow: re/start services"
echo "---- start dovecot"
dovecot_id=$(docker start "$(docker ps -aqf name=dovecot-mailcow)")
if [[ "$(docker inspect -f '{{ .State.Running }}' "$dovecot_id")" == "true" ]] ; then
  echo "----- success"
else
  echo "----- FAILED"
fi
echo "---- start postfix"
postfix_id=$(docker start "$(docker ps -aqf name=postfix-mailcow)")
if [[ "$(docker inspect -f '{{ .State.Running }}' "$postfix_id")" == "true" ]] ; then
  echo "----- success"
else
  echo "----- FAILED"
fi

# show error on webstuff
echo "--- nginx normal mode"
if [[ -f "${workDirectory}/data/conf/nginx/site.backup.custom" ]] ; then
  rm "${workDirectory}/data/conf/nginx/site.backup.custom"
fi
nginx_id=$(docker restart "$(docker ps -qf name=nginx-mailcow)")
if [[ "$(docker inspect -f '{{ .State.Running }}' "$nginx_id")" == "true" ]] ; then
  echo "---- success"
else
  echo "---- FAILED"
fi

# clean tmp stuff
echo "--- clean up"

if [[ -d "${volumeMySQL}/tmp_backup" ]] ; then
  rm -r "${volumeMySQL}/tmp_backup"
  echo "---- removed MySQL tmp_backup dir"
fi


# calc backup duration
endTime=$(date +%s)
duration=$((endTime-startTime))
echo
echo "-- backup duration: $(printf '%02d hours %02d minutes %02d seconds' $((duration / 3600)) $(((duration / 60) % 60)) $((duration % 60)))"
info "-> everything done: exit"

exit ${docker_exit}
