#!/usr/bin/env bash

set -eu
set -o pipefail

# Define loggers
function now() {
    date +'%Y-%m-%d %H:%M:%S %z'
}
function __log() {
    local -u -r level="${1:-unknown}"
    local -r message="${2:-}"
    echo "$(now) [$level] $message"
}
function __info_log() {
    __log info "${1:-}"
}
function __warn_log() {
    __log warn "${1:-}"
}
function __error_log() {
    __log error "${1:-}" 1>&2
}

__info_log "This script polls ecs-agent logs to detect the ecs container instance stale state. When the state is detected, this script can do some actions to the instance."
__info_log "See https://github.com/civitaspo/ecs-stale-ec2-rescaler for more information."

# Declare variables
declare -r  APP_NAME=ecs-stale-ec2-rescaler
declare -ir POLLING_MAX_ATTEMPTS=${POLLING_MAX_ATTEMPTS:-60}
declare -ir POLLING_INTERVAL=${POLLING_INTERVAL:-1}
declare -ir DUPLICATE_ENI_ATTACHMENT_PER_HOUR_THRESHOLD=${DUPLICATE_ENI_ATTACHMENT_PER_HOUR_THRESHOLD:-50}

declare -r INSTANCE_IDENTITY_URL=${INSTANCE_IDENTITY_URL:-http://169.254.169.254/latest/dynamic/instance-identity/document}
declare -i num_attempts=0
while [[ -z "$(curl -s ${INSTANCE_IDENTITY_URL} | jq -r .instanceId)" ]]; do
    if ((num_attempts == POLLING_MAX_ATTEMPTS)); then
        __error_log "Max attempts(=$POLLING_MAX_ATTEMPTS) is exceeded because $INSTANCE_IDENTITY_URL did not become available."
        exit 1
    fi
    __info_log "Wait until $INSTANCE_IDENTITY_URL become available. (attempts: $((num_attempts++))/$POLLING_MAX_ATTEMPTS)"
    sleep ${POLLING_INTERVAL}
done
unset num_attempts

declare -r INSTANCE_ID=$(curl -s ${INSTANCE_IDENTITY_URL} | jq -r .instanceId)
declare -r REGION=$(curl -s ${INSTANCE_IDENTITY_URL} | jq -r .region)
declare -r AUTOSCALING_GROUP_NAME=$(
    aws ec2 describe-tags \
        --region ${REGION} \
        --filters "Name=resource-id,Values=$INSTANCE_ID" \
                  "Name=key,Values=aws:autoscaling:groupName" \
        | jq -r '.Tags[0].Value'
    )
if [[ -z "$AUTOSCALING_GROUP_NAME" ]]; then
    __error_log "Unable to fetch the autoscaling group that ec2:$INSTANCE_ID joins in."
    exit 1
fi

declare -r  TERMINATE_STALE_EC2=${TERMINATE_STALE_EC2:-true}
if [[ "$TERMINATE_STALE_EC2" = true ]]; then
    __info_log "Set TERMINATE_STALE_EC2=true"
else
    __info_log "Set TERMINATE_STALE_EC2=false"
fi

declare -r  ENTER_STANDBY_STALE_EC2=${ENTER_STANDBY_STALE_EC2:-false}
if [[ "$ENTER_STANDBY_STALE_EC2" = true ]]; then
    if [[ "$TERMINATE_STALE_EC2" = true ]]; then
        __warn_log "Ignore ENTER_STANDBY_STALE_EC2 setting because of TERMINATE_STALE_EC2=true."
    else
        __info_log "Set ENTER_STANDBY_STALE_EC2=true"
    fi
else
    __info_log "Set ENTER_STANDBY_STALE_EC2=false"
fi

declare -r  DETACH_STALE_EC2=${DETACH_STALE_EC2:-false}
if [[ "$DETACH_STALE_EC2" = true ]]; then
    if [[ "$TERMINATE_STALE_EC2" = true ]]; then
        __warn_log "Ignore DETACH_STALE_EC2 setting because of TERMINATE_STALE_EC2=true."
    else
        __info_log "Set DETACH_STALE_EC2=true"
    fi
else
    __info_log "Set TERMINATE_STALE_EC2=false"
fi

declare -r  ECS_CLUSTER="$(curl -s ${ECS_CONTAINER_METADATA_URI}/task | jq -r .Cluster)"
if [[ -z "$ECS_CLUSTER" ]]; then
    __error_log "Unable to fetch the name of the cluster."
    exit 1
fi
declare -r  ATTRIBUTES_FOR_STALE_EC2="${ATTRIBUTES_FOR_STALE_EC2:-}"
declare -ir MAX_ATTRIBUTES=${MAX_ATTRIBUTES:-10}  # AWS Restriction
declare -a  ATTRIBUTES_FOR_AWSCLI=()
if [[ -n "$ATTRIBUTES_FOR_STALE_EC2" ]]; then
    declare -r container_instance_arn=$(
        aws ecs list-container-instances \
            --region ${REGION} \
            --cluster ${ECS_CLUSTER} \
            --filter "ec2InstanceId==$INSTANCE_ID" \
            | jq -r '.containerInstanceArns[0]'
        )
    if [[ -z "container_instance_arn" ]]; then
        __error_log "Unable to fetch the arn of the container instance(ec2 id: $INSTANCE_ID)."
        exit 1
    fi
    __info_log "Container Instance ARN: $container_instance_arn"

    declare -i num_attrs=0
    for attr_kv in ${ATTRIBUTES_FOR_STALE_EC2}; do
        if [[ "$((++num_attrs))" -gt ${MAX_ATTRIBUTES} ]]; then
            __error_log "You can specify up to $MAX_ATTRIBUTES attributes in a single call."
            exit 1
        fi
        if [[ ! "$attr_kv" =~ '=' ]]; then
            __error_log "ATTRIBUTES_FOR_STALE_EC2 must be a list of 'key=value' string"
            exit 1
        fi
        IFS='=' read -ra kv <<< "$attr_kv"
        declare -r attr="name=${kv[0]},value=${kv[1]},targetType=container-instance,targetId=${container_instance_arn##*/}"
        ATTRIBUTES_FOR_AWSCLI+=("$attr")
        unset attr
    done

    unset container_instance_arn
    unset num_attrs
fi
declare -ar ATTRIBUTES_FOR_AWSCLI=("${ATTRIBUTES_FOR_AWSCLI[@]}")

declare -r SLACK_URL=${SLACK_URL:-}
declare -r SLACK_ADDITIONAL_MESSAGE=${SLACK_ADDITIONAL_MESSAGE:-}
declare -r SLACK_CHANNEL=${SLACK_CHANNEL:-}
declare -r SLACK_ICON_EMOJI=${SLACK_ICON_EMOJI:-}

__info_log "Polling until errors are catched."
declare STALE_STATE_CAUSE=""
while true; do
    if ls /var/log/ecs/ecs-agent.log* | sort -n | tail -n1 | xargs -I{} grep -r "Error getting message from ws backend" {} >/dev/null; then
        STALE_STATE_CAUSE="'Error getting message from ws backend' is occurred"
        break
    fi
    if ls /var/log/ecs/ecs-agent.log* | sort -n | tail -n1 | xargs -I{} grep -r "Error response from daemon: conflict: unable to delete" {} >/dev/null; then
        STALE_STATE_CAUSE="'Error response from daemon: conflict: unable to delete' is occurred"
        break
    fi
    for n in $(grep 'Duplicate ENI attachment message' /var/log/ecs/ecs-agent.log* | cut -f2 -d: | sort -n | uniq -c |  xargs -n2 echo | cut -f1 -d' '); do
        if ((n > DUPLICATE_ENI_ATTACHMENT_PER_HOUR_THRESHOLD)); then
            STALE_STATE_CAUSE="'Duplicate ENI attachment message' count exceeds $DUPLICATE_ENI_ATTACHMENT_PER_HOUR_THRESHOLD/h"
            break 2
        fi
    done
    sleep ${POLLING_INTERVAL}
done

declare -a actions=()
if [[ "${#ATTRIBUTES_FOR_AWSCLI[@]}" != 0 ]]; then
    actions+=("put attributes($ATTRIBUTES_FOR_STALE_EC2)")
fi
if [[ "$TERMINATE_STALE_EC2" = true ]]; then
    actions+=("terminate")
else
    if [[ "$ENTER_STANDBY_STALE_EC2" = true ]]; then
        actions+=("enter standby")
    fi
    if [[ "$DETACH_STALE_EC2" = true ]]; then
        actions+=("detach")
    fi
fi
if [[ "${#actions[@]}" == 0 ]]; then
    declare -r MESSAGE="Detect stale state:[$STALE_STATE_CAUSE], so do nothing to targets:[ec2:$INSTANCE_ID, asg:$AUTOSCALING_GROUP_NAME]"
else
    declare -r MESSAGE="Detect stale state:[$STALE_STATE_CAUSE], so do actions:[$(IFS=,; echo "${actions[*]}")] to targets:[ec2:$INSTANCE_ID, asg:$AUTOSCALING_GROUP_NAME]"
fi
unset actions
declare -r SLACK_MESSAGE=":hammer_and_wrench: $MESSAGE $SLACK_ADDITIONAL_MESSAGE"
__warn_log "$MESSAGE"

if [[ ! -z "$SLACK_URL" ]]; then
    curl -X POST \
         -H 'Content-type: application/json' \
         --data "
             {
                 \"text\": \"$SLACK_MESSAGE\",
                 \"channel\":\"$SLACK_CHANNEL\",
                 \"icon_emoji\":\"$SLACK_ICON_EMOJI\",
                 \"username\":\"$APP_NAME\"
             }
             " \
         ${SLACK_URL}
fi

# Put attributes
if [[ "${#ATTRIBUTES_FOR_AWSCLI[@]}" -ne 0 ]]; then
    aws ecs put-attributes \
        --cluster ${ECS_CLUSTER} \
        --attributes ${ATTRIBUTES_FOR_AWSCLI[@]} \
        --region ${REGION}
fi

# Do actions to the container instance.
if [[ "$TERMINATE_STALE_EC2" = true ]]; then
    aws autoscaling terminate-instance-in-auto-scaling-group \
        --instance-id ${INSTANCE_ID} \
        --no-should-decrement-desired-capacity \
        --region ${REGION}
else
    if [[ "$ENTER_STANDBY_STALE_EC2" = true ]]; then
        aws autoscaling enter-standby \
            --instance-ids ${INSTANCE_ID} \
            --auto-scaling-group-name ${AUTOSCALING_GROUP_NAME} \
            --no-should-decrement-desired-capacity \
            --region ${REGION}
    fi
    if [[ "$DETACH_STALE_EC2" = true ]]; then
        aws autoscaling detach-instances \
            --instance-ids ${INSTANCE_ID} \
            --auto-scaling-group-name ${AUTOSCALING_GROUP_NAME} \
            --no-should-decrement-desired-capacity \
            --region ${REGION}
    fi
fi

# Sleep for 200 seconds to prevent this script from looping.
# The instance should be terminated by the end of the sleep.
sleep 200
