#!/bin/bash

# common configurations:

OPENSHIFT_NAMESPACE=3scale-upgrade
OPENSHIFT_USERNAME=admin
OPENSHIFT_PASSWORD=admin

FAIL_ON_ERROR=false
DELETE_SECRET=true

SECRET_ITEMS=()




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

createGenericSecret()
{
    local secretName=$1
    local appName=$2
    local threescale_component=$3
    shift 3
    local literals=("${@}")
    local literalList="";
    for literal in "${literals[@]}"; do
        literalList=$(echo "${literalList} --from-literal=${literal}")
    done

    #### check if secret is present
    log INFO 0 "check if the secret already exists"
    
    oc get secret ${secretName} -n ${OPENSHIFT_NAMESPACE} >/dev/null 2>&1

    if [ $? -eq 0 ] ; then
        if [ ${DELETE_SECRET} == true ] ; then
            log WARN 0 "deleting existing secret...."
            local out=$(oc delete secret  ${secretName} -n ${OPENSHIFT_NAMESPACE} )
            log WARN 0 "${out}"
        else
            cmdOut="secret  ${secretName} already exists!"
            return 3
        fi
    fi
    cmdOut=$(oc create secret generic ${secretName} ${literalList} -n ${OPENSHIFT_NAMESPACE} 2>&1)
    cmdRet=$?
    if [ $cmdRet -eq 0 ] ; then
        log INFO 0 "${cmdOut}"
        log INFO 0 "applying labels:"
        log INFO 0 "app: ${appName}"
        log INFO 0 "3scale.component: ${threescale_component}"
        cmdOut=$(oc label secret ${secretName} -n ${OPENSHIFT_NAMESPACE} app=${appName} 3scale.component=${threescale_component}  2>&1)
        cmdRet=$?
    fi
    return $cmdRet
}

#
# input: an item list mapped this way
# "<deploymentConfig env variable>:<secret item name>:<deploymentConfig name>"
#

getSecretItems()
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
    SECRET_ITEMS=("${literals[@]}")
}

log INFO 0 "login"

cmdOut=$(oc login -u ${OPENSHIFT_USERNAME} -p ${OPENSHIFT_PASSWORD})

if [ $? -ne 0 ] ; then
    log ERROR 0 "login FAILED"
    log ERROR 0 "${cmdOut}"
    exit 4
fi

DEPLOYED_APP_LABEL=$(oc get dc backend-listener -o json | jq .spec.template.metadata.labels.app -r)

if [ $? -ne 0 ] || [ "${DEPLOYED_APP_LABEL}" == "" ]; then
    log ERROR 0 "cannot retrieve app label!"
    exit 5
fi

# apicast-redis

# retrieve the actual configuration from APICasts

DEST_SECRET=apicast-redis

mapping=(
    "REDIS_URL:PRODUCTION_URL:apicast-production"
    "REDIS_URL:STAGING_URL:apicast-staging"
)

getSecretItems ${mapping[@]}

log INFO 0 "creating ${DEST_SECRET} secret..."

createGenericSecret ${DEST_SECRET} ${DEPLOYED_APP_LABEL} apicast ${SECRET_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_SECRET} secret: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_SECRET} secret created: "
    log INFO 0 "${cmdOut}"
fi

# backend-internal-api

DEST_SECRET=backend-internal-api

mapping=(
    "CONFIG_INTERNAL_API_USER:username:backend-listener"
    "CONFIG_INTERNAL_API_PASSWORD:password:backend-listener"
)

getSecretItems ${mapping[@]}


log INFO 0 "creating ${DEST_SECRET} secret..."

createGenericSecret ${DEST_SECRET} ${DEPLOYED_APP_LABEL} backend ${SECRET_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_SECRET} secret: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_SECRET} secret created: "
    log INFO 0 "${cmdOut}"
fi

#####

# backend-redis

DEST_SECRET=backend-redis

mapping=(
    "CONFIG_REDIS_PROXY:REDIS_STORAGE_URL:backend-listener"
    "CONFIG_REDIS_SENTINEL_HOSTS:REDIS_STORAGE_SENTINEL_HOSTS:backend-listener"
    "CONFIG_REDIS_SENTINEL_ROLE:REDIS_STORAGE_SENTINEL_ROLE:backend-listener"
    "CONFIG_QUEUES_MASTER_NAME:REDIS_QUEUES_URL:backend-listener"
    "CONFIG_QUEUES_SENTINEL_HOSTS:REDIS_QUEUES_SENTINEL_HOSTS:backend-listener"
    "CONFIG_QUEUES_SENTINEL_ROLE:REDIS_QUEUES_SENTINEL_ROLE:backend-listener"
)
getSecretItems ${mapping[@]}


log INFO 0 "creating ${DEST_SECRET} secret..."

createGenericSecret ${DEST_SECRET} ${DEPLOYED_APP_LABEL} backend ${SECRET_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_SECRET} secret: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_SECRET} secret created: "
    log INFO 0 "${cmdOut}"
fi

# backend-listener


DEST_SECRET=backend-listener
mapping=(
    "BACKEND_ROUTE:route_endpoint:system-app"
    "BACKEND_ENDPOINT_OVERRIDE:service_endpoint:apicast-production"
)

getSecretItems ${mapping[@]}


log INFO 0 "creating ${DEST_SECRET} secret..."

createGenericSecret ${DEST_SECRET} ${DEPLOYED_APP_LABEL} backend ${SECRET_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_SECRET} secret: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_SECRET} secret created: "
    log INFO 0 "${cmdOut}"
fi

#####

# system-app

#SECRET_KEY_BASE maps SECRET_KEY_BASE from system-app dc
DEST_SECRET=system-app
mapping=(
    "SECRET_KEY_BASE:SECRET_KEY_BASE:system-app"
)

getSecretItems ${mapping[@]}


log INFO 0 "creating ${DEST_SECRET} secret..."

createGenericSecret ${DEST_SECRET} ${DEPLOYED_APP_LABEL} system ${SECRET_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_SECRET} secret: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_SECRET} secret created: "
    log INFO 0 "${cmdOut}"
fi

####

# system-events-hook


# URL maps CONFIG_EVENTS_HOOK from backend-worker dc
# PASSWORD CONFIG_EVENTS_HOOK_SHARED_SECRET  from backend-worker dc

DEST_SECRET=system-events-hook

mapping=(
    "CONFIG_EVENTS_HOOK:URL:backend-worker"
    "CONFIG_EVENTS_HOOK_SHARED_SECRET:PASSWORD:backend-worker"
)

getSecretItems ${mapping[@]}


log INFO 0 "creating ${DEST_SECRET} secret..."

createGenericSecret ${DEST_SECRET} ${DEPLOYED_APP_LABEL} system ${SECRET_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_SECRET} secret: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_SECRET} secret created: "
    log INFO 0 "${cmdOut}"
fi

# system-master-apicast

#ACCESS_TOKEN maps APICAST_ACCESS_TOKEN from system-app dc
#BASE_URL maps API_HOST from apicast-wildcard-router dc
#PROXY_CONFIGS_ENDPOINT maps THREESCALE_PORTAL_ENDPOINT from apicast-production dc

DEST_SECRET=system-master-apicast

mapping=(
    "APICAST_ACCESS_TOKEN:ACCESS_TOKEN:system-app"
    "API_HOST:BASE_URL:apicast-wildcard-router"
    "THREESCALE_PORTAL_ENDPOINT:PROXY_CONFIGS_ENDPOINT:apicast-production"
)

getSecretItems ${mapping[@]}


log INFO 0 "creating ${DEST_SECRET} secret..."

createGenericSecret ${DEST_SECRET} ${DEPLOYED_APP_LABEL} system ${SECRET_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_SECRET} secret: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_SECRET} secret created: "
    log INFO 0 "${cmdOut}"
fi
####

# system-seed

DEST_SECRET=system-seed
# ADMIN_ACCESS_TOKEN maps ADMIN_ACCESS_TOKEN from system-app dc
# ADMIN_PASSWORD maps USER_PASSWORD from system-app dc
# ADMIN_USER maps USER_LOGIN from system-app dc
# MASTER_DOMAIN maps MASTER_DOMAIN from system-app dc
# MASTER_PASSWORD maps MASTER_PASSWORD from system-app dc
# MASTER_USER maps MASTER_USER from system-app dc
# TENANT_NAME maps TENANT_NAME from system-app dc


mapping=(
    "ADMIN_ACCESS_TOKEN:ADMIN_ACCESS_TOKEN:system-app"
    "USER_PASSWORD:ADMIN_PASSWORD:system-app"
    "USER_LOGIN:ADMIN_USER:system-app"
    "MASTER_DOMAIN:MASTER_DOMAIN:system-app"
    "MASTER_PASSWORD:MASTER_PASSWORD:system-app"
    "MASTER_USER:MASTER_USER:system-app"
    "TENANT_NAME:TENANT_NAME:system-app"
)

getSecretItems ${mapping[@]}


log INFO 0 "creating ${DEST_SECRET} secret..."

createGenericSecret ${DEST_SECRET} ${DEPLOYED_APP_LABEL} system ${SECRET_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_SECRET} secret: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_SECRET} secret created: "
    log INFO 0 "${cmdOut}"
fi

####

# system-recaptcha
# IN 2.3 doesn't exist at all. it will be created empty
#
#

DEST_SECRET=system-recaptcha


SECRET_ITEMS=(
    "PRIVATE_KEY="
    "PUBLIC_KEY="
)

log INFO 0 "creating ${DEST_SECRET} secret..."

createGenericSecret ${DEST_SECRET} ${DEPLOYED_APP_LABEL} system ${SECRET_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_SECRET} secret: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_SECRET} secret created: "
    log INFO 0 "${cmdOut}"
fi
####

# system-memcache
# IN 2.3 doesn't exist at all. it will be created with a default value system-memcache:11211
#
#
DEST_SECRET=system-memcache

SECRET_ITEMS=(
    "SERVERS=system-memcache:11211"
)

log INFO 0 "creating ${DEST_SECRET} secret..."

createGenericSecret ${DEST_SECRET} ${DEPLOYED_APP_LABEL} system ${SECRET_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_SECRET} secret: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_SECRET} secret created: "
    log INFO 0 "${cmdOut}"
fi

####

# system-database
DEST_SECRET=system-database
#
# URL maps DATABASE_URL from system-app dc
#

mapping=(
    "DATABASE_URL:URL:system-app"
)

getSecretItems ${mapping[@]}


log INFO 0 "creating ${DEST_SECRET} secret..."

createGenericSecret ${DEST_SECRET} ${DEPLOYED_APP_LABEL} system ${SECRET_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_SECRET} secret: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_SECRET} secret created: "
    log INFO 0 "${cmdOut}"
fi

####

# system-redis
DEST_SECRET=system-redis
#
# URL maps PRODUCTION_URL from apicast-production dc
#
mapping=(
    "REDIS_URL:URL:apicast-production"
)

getSecretItems ${mapping[@]}


log INFO 0 "creating ${DEST_SECRET} secret..."

createGenericSecret ${DEST_SECRET} ${DEPLOYED_APP_LABEL} system ${SECRET_ITEMS[@]}


if [[ $? -ne 0 ]] ; then
    log ERROR 0 "unable to create the ${DEST_SECRET} secret: "
    log ERROR 2 "${cmdOut}"
    
else
    log INFO 0 "${DEST_SECRET} secret created: "
    log INFO 0 "${cmdOut}"
fi

####

log INFO 0 "operation success!"