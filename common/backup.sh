#!/bin/bash

BACKUP_BASE_DIR=$PWD

BACKUP_DIR=${BACKUP_BASE_DIR}/backup

# Creating directories

mkdir ${BACKUP_DIR}

cd ${BACKUP_DIR}

mkdir ${BACKUP_DIR}/system-database ${BACKUP_DIR}/zync-database ${BACKUP_DIR}/system-redis ${BACKUP_DIR}/backend-redis ${BACKUP_DIR}/system-app ${BACKUP_DIR}/openshift

mkdir ${BACKUP_DIR}/openshift/configmaps/ ${BACKUP_DIR}/openshift/deploymentConfigs ${BACKUP_DIR}/openshift/imageStreams ${BACKUP_DIR}/openshift/other/ ${BACKUP_DIR}/openshift/routes/ ${BACKUP_DIR}/openshift/secrets/ ${BACKUP_DIR}/openshift/services/ 

# Backup system-database (MySQL)

oc rsh $(oc get pods -l 'deploymentConfig=system-mysql' -o json | jq -r '.items[0].metadata.name') bash -c 'export MYSQL_PWD=${MYSQL_ROOT_PASSWORD}; mysqldump --single-transaction -hsystem-mysql -uroot system' | gzip > ${BACKUP_DIR}/system-database/system-mysql-backup.gz

# Backup zync-database

oc rsh $(oc get pods -l 'deploymentConfig=zync-database' -o json | jq '.items[0].metadata.name' -r) bash -c 'pg_dumpall -c --if-exists' | gzip > ${BACKUP_DIR}/zync-database/zync-database-backup.gz

# Backup system-redis

oc cp $(oc get pods -l 'deploymentConfig=system-redis' -o json | jq '.items[0].metadata.name' -r):/var/lib/redis/data/dump.rdb ${BACKUP_DIR}/system-redis/system-redis-dump.rdb

# Backup backend-redis

oc cp $(oc get pods -l 'deploymentConfig=backend-redis' -o json | jq '.items[0].metadata.name' -r):/var/lib/redis/data/dump.rdb ${BACKUP_DIR}/backend-redis/backend-redis-dump.rdb

# Backup system-app persistent data

oc rsync $(oc get pods -l 'deploymentConfig=system-app' -o json | jq '.items[0].metadata.name' -r):/opt/system/public/system ${BACKUP_DIR}/system-app/

# Backup Openshift objects

#configMaps

for object in `oc get cm | awk '{print $1}' | grep -v NAME`; do oc get -o yaml --export cm ${object} > ${BACKUP_DIR}/openshift/configmaps/${object}_cm.yaml; done
 
#secrets
# backing up everything except tokens and secrets default - builder - deployer

for object in `oc get secret | awk '{print $1}' | grep -v NAME | grep -v default | grep -v builder | grep -v deployer`; do oc get -o yaml --export secret ${object} > ${BACKUP_DIR}/openshift/secrets/${object}_secret.yaml; done

#imagestreams

for object in `oc get is | awk '{print $1}' | grep -v NAME`; do oc get -o yaml --export is ${object} > ${BACKUP_DIR}/openshift/imageStreams/${object}_is.yaml; done

#deploymentconfigs

for object in `oc get dc | awk '{print $1}' | grep -v NAME`; do oc get -o yaml --export dc ${object} > ${BACKUP_DIR}/openshift/deploymentConfigs/${object}_dc.yaml; done

#routes

for object in `oc get routes | awk '{print $1}' | grep -v NAME`; do oc get -o yaml --export route ${object} > ${BACKUP_DIR}/openshift/routes/${object}_route.yaml; done

#services

for object in `oc get svc | awk '{print $1}' | grep -v NAME`; do oc get -o yaml --export svc ${object} > ${BACKUP_DIR}/openshift/services/${object}_svc.yaml; done

# a second backup, to deal with other custom not backed-up objects

oc get -o yaml --export all > ${BACKUP_DIR}/openshift/other/threescale-project-elements.yaml

for object in rolebindings serviceaccounts secrets imagestreamtags cm rolebindingrestrictions limitranges resourcequotas pvc templates cronjobs statefulsets hpa deployments replicasets poddisruptionbudget endpoints; do
   oc get -o yaml --export $object > ${BACKUP_DIR}/openshift/other/$object.yaml
done

