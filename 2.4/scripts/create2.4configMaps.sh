#!/bin/bash

# common configurations:

# OpenShift namespace where 3Scale resides
OPENSHIFT_NAMESPACE=3scale-upgrade

# OpenShift credentials (used only if LOGIN_ENABLED is true)
OPENSHIFT_USERNAME=admin
OPENSHIFT_PASSWORD=admin

# Enables / disables login
LOGIN_ENABLED=false

# Fail on error, if true any error stops the procedure (even if a ConfigMap already exists and DELETE_CONFIG_MAP is false)
FAIL_ON_ERROR=false

# If true and the config map to be created already exists, it will be deleted before creating the new one. If false the configmap creation will fail.
DELETE_CONFIGMAP=false

CONFIGMAP_ITEMS=()




log()
{
    #color constants
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    NC='\033[0m' # No Color
    
    # local variables
    local level=$1
    local exitCode=$2
    shift 2
    local message=$@
    local colorCode=${GREEN}

    case ${level} in
        ERROR)
            colorCode=${RED}
            ;;
        WARN)
            colorCode=${YELLOW}
            ;;
        *)
            colorCode=${GREEN}
            ;;
    esac

    echo -e "${colorCode}${level}: ${message}${NC}" 
    if [[ ${exitCode} -ne 0 ]] ; then
        if [[ ${FAIL_ON_ERROR} == true ]] ; then
            exit ${exitCode}
        fi
    fi

}

getConfigFromDC()
{
    local dcName=$1
    local environmentName=$2
    oc get dc ${dcName} -o json -n ${OPENSHIFT_NAMESPACE} | jq -r '.spec.template.spec.containers[0].env[] | select(.name == "'${environmentName}'").value'
    return $?
}

createConfigMap()
{
    local configMapName=$1
    local appName=$2
    local threescale_component=$3
    shift 3
    local literals=("${@}")
    local literalList="";
    for literal in "${literals[@]}"; do
        literalList=$(echo "${literalList} --from-literal=${literal}")
    done

    #### check if the configMap is present
    log INFO 0 "check if the configMap already exists"
    
    oc get cm ${configMapName} -n ${OPENSHIFT_NAMESPACE} >/dev/null 2>&1

    if [ $? -eq 0 ] ; then
        if [ ${DELETE_CONFIGMAP} == true ] ; then
            log WARN 0 "deleting existing configMap...."
            local out=$(oc delete cm  ${configMapName} -n ${OPENSHIFT_NAMESPACE} )
            log WARN 0 "${out}"
        else
            cmdOut="configMap  ${configMapName} already exists!"
            return 3
        fi
    fi
    cmdOut=$(oc create cm ${configMapName} ${literalList} -n ${OPENSHIFT_NAMESPACE} 2>&1)
    cmdRet=$?
    if [ $cmdRet -eq 0 ] ; then
        log INFO 0 "${cmdOut}"
        log INFO 0 "applying labels:"
        log INFO 0 "app: ${appName}"
        log INFO 0 "3scale.component: ${threescale_component}"
        cmdOut=$(oc label cm ${configMapName} -n ${OPENSHIFT_NAMESPACE} app=${appName} 3scale.component=${threescale_component}  2>&1)
        cmdRet=$?
    fi
    return $cmdRet
}

#
# input: an item list mapped this way
# "<deploymentConfig env variable>:<cm item name>:<deploymentConfig name>"
#

getConfigMapItems()
{
    local mapping=("${@}")
    local literals=()
    for element in ${mapping[@]} ; do
   
        src_element=$(echo ${element} | awk -F ":" '{print $1}')
        dest_element=$(echo ${element} | awk -F ":" '{print $2}')
        src_deploymentConfig=$(echo ${element} | awk -F ":" '{print $3}')
        value=$(getConfigFromDC ${src_deploymentConfig} ${src_element})


        if [ "${value}" == "null" ] ; then
            log WARN 0 "an empty value returned from getting ${src_element} from ${src_deploymentConfig} dc"
            value=""
        elif [ "${value}" == "" ] ; then
            log ERROR 2 "the ${src_element} is missing from ${src_deploymentConfig} dc"
        else
            log INFO 0 "${src_element} from ${src_deploymentConfig} -> ${value}"
        fi
        literals+=("${dest_element}=${value}")      
    done
    CONFIGMAP_ITEMS=("${literals[@]}")
}

if [ "${LOGIN_ENABLED}" == "true" ] ; then
    log INFO 0 "login"

    cmdOut=$(oc login -u ${OPENSHIFT_USERNAME} -p ${OPENSHIFT_PASSWORD})

    if [ $? -ne 0 ] ; then
        log ERROR 0 "login FAILED"
        log ERROR 0 "${cmdOut}"
        exit 4
    fi
else
    log INFO 0 "login skipped"
fi

DEPLOYED_APP_LABEL=$(oc get dc backend-listener -o json | jq .spec.template.metadata.labels.app -r)

if [ $? -ne 0 ] || [ "${DEPLOYED_APP_LABEL}" == "" ]; then
    log ERROR 0 "cannot retrieve app label!"
    exit 5
fi

# apicast-environment

# retrieve the actual configuration from APICasts

DEST_CM=apicast-environment

mapping=(
    "APICAST_MANAGEMENT_API:APICAST_MANAGEMENT_API:apicast-production"
    "APICAST_RESPONSE_CODES:APICAST_RESPONSE_CODES:apicast-production"
    "OPENSSL_VERIFY:OPENSSL_VERIFY:apicast-production"
)

getConfigMapItems ${mapping[@]}

log INFO 0 "creating ${DEST_CM} configMap..."

createConfigMap ${DEST_CM} ${DEPLOYED_APP_LABEL} apicast ${CONFIGMAP_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "${cmdOut}"
    log ERROR 2 "unable to create the ${DEST_CM} configMap: "
    
    
else
    log INFO 0 "${cmdOut}"
    log INFO 0 "${DEST_CM} configMap created "
fi

# backend-environment


DEST_CM=backend-environment

mapping=(
    "RACK_ENV:RACK_ENV:backend-listener"
)

getConfigMapItems ${mapping[@]}


log INFO 0 "creating ${DEST_CM} configMap..."

createConfigMap ${DEST_CM} ${DEPLOYED_APP_LABEL} backend ${CONFIGMAP_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_CM} configMap: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_CM} configMap created: "
    log INFO 0 "${cmdOut}"
fi

#####

# system-environment

#SECRET_KEY_BASE maps SECRET_KEY_BASE from system-app dc
DEST_CM=system-environment
mapping=(
      "AMP_RELEASE:AMP_RELEASE:system-app"
      "APICAST_REGISTRY_URL:APICAST_REGISTRY_URL:system-app"
      "FORCE_SSL:FORCE_SSL:system-app"
      "PROVIDER_PLAN:PROVIDER_PLAN:system-app"
      "RAILS_ENV:RAILS_ENV:system-app"
      "RAILS_LOG_LEVEL:RAILS_LOG_LEVEL:system-app"
      "RAILS_LOG_TO_STDOUT:RAILS_LOG_TO_STDOUT:system-app"
      "SSL_CERT_DIR:SSL_CERT_DIR:system-app"
      "THINKING_SPHINX_PORT:THINKING_SPHINX_PORT:system-app"
      "THREESCALE_SANDBOX_PROXY_OPENSSL_VERIFY_MODE:THREESCALE_SANDBOX_PROXY_OPENSSL_VERIFY_MODE:system-app"
      "THREESCALE_SUPERDOMAIN:THREESCALE_SUPERDOMAIN:system-app"
)

getConfigMapItems ${mapping[@]}


log INFO 0 "creating ${DEST_CM} configMap..."

createConfigMap ${DEST_CM} ${DEPLOYED_APP_LABEL} system ${CONFIGMAP_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_CM} configMap: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_CM} configMap created: "
    log INFO 0 "${cmdOut}"
fi

####

log INFO 0 "operation success!"
