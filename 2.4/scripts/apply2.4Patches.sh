#!/bin/bash

# Parent directory for the patch files

PATCH_BASE=${PWD}

PATCH_DIR=${PATCH_BASE}/patches
BACKUP_DIR=${PATCH_BASE}/backup

# OpenShift namespace where 3Scale resides
OPENSHIFT_NAMESPACE=3scale-upgrade
# OpenShift credentials (used only if LOGIN_ENABLED is true)
OPENSHIFT_USERNAME=admin
OPENSHIFT_PASSWORD=admin
# Enables / disables login
LOGIN_ENABLED=false

mkdir -p ${BACKUP_DIR}

if [ "${LOGIN_ENABLED}" == "true" ] ; then
    oc login -u ${OPENSHIFT_USERNAME} -p ${OPENSHIFT_PASSWORD}
fi

for patch in $(ls ${PATCH_DIR}) ; do
    deploymentConfig=$(echo ${patch} | awk -F "." '{print $1}')
    oc get dc ${deploymentConfig} -o yaml -n ${OPENSHIFT_NAMESPACE} > ${BACKUP_DIR}/${deploymentConfig}-orig.yaml;
    oc patch dc ${deploymentConfig}  -n ${OPENSHIFT_NAMESPACE} -p "$(cat ${PATCH_DIR}/${deploymentConfig}.patch)"
done
