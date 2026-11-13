#!/usr/bin/env bash
# lab-04-ecs-inventory.sh - one line per ECS service in the cluster:
#   desired/running counts, task definition, role separation, public-IP exposure.
# Also writes the same data as JSON to outputs/lab-04-ecs-inventory.json.
#
# Why no `set -e`: this is a report. If one describe call fails for one service,
# the report should mark that service and carry on, not die halfway with a
# partial file. Every AWS call is checked explicitly instead.
# -u catches misspelled variables; pipefail surfaces failures inside pipelines.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-04.env"

CLUSTER="${1:-$USMS_ECS_CLUSTER}"
OUT_DIR="$REPO_ROOT/outputs"
OUT_JSON="$OUT_DIR/lab-04-ecs-inventory.json"
mkdir -p "$OUT_DIR"

if ! SERVICE_ARNS=$(aws ecs list-services --cluster "$CLUSTER" \
      --query 'serviceArns[]' --output text | tr -d '\r'); then
  echo "ERROR: cannot list services in cluster $CLUSTER" >&2
  exit 1
fi

rows=()
printf '%-22s %-8s %-8s %-22s %-9s %s\n' SERVICE DESIRED RUNNING TASKDEF ROLES PUBLICIP
for arn in $SERVICE_ARNS; do
  if ! line=$(aws ecs describe-services --cluster "$CLUSTER" --services "$arn" \
      --query 'services[0].[serviceName,desiredCount,runningCount,taskDefinition,networkConfiguration.awsvpcConfiguration.assignPublicIp]' \
      --output text | tr -d '\r'); then
    echo "WARN: describe-services failed for $arn" >&2; continue
  fi
  read -r name desired running taskdef pub <<<"$line"

  # publicip verdict is computed from assignPublicIp, never from names or tags
  case "$pub" in
    ENABLED)  publicip=RISK ;;
    DISABLED) publicip=OK ;;
    *)        publicip=N/A ;;      # no awsvpc network configuration
  esac

  # roles verdict is computed by comparing the two ARNs on the task definition
  if roles_line=$(aws ecs describe-task-definition --task-definition "$taskdef" \
        --query 'taskDefinition.[executionRoleArn,taskRoleArn]' --output text | tr -d '\r'); then
    read -r exec_role task_role <<<"$roles_line"
    if [ "$exec_role" = "None" ] || [ "$task_role" = "None" ]; then roles=MISSING
    elif [ "$exec_role" = "$task_role" ]; then roles=SAME
    else roles=SEPARATE; fi
  else
    roles=UNKNOWN; exec_role=None; task_role=None
  fi

  td_short="${taskdef##*/}"
  printf '%-22s %-8s %-8s %-22s %-9s %s\n' \
    "$name" "$desired" "$running" "$td_short" "roles=$roles" "publicip=$publicip"
  rows+=("{\"service\":\"$name\",\"desired\":$desired,\"running\":$running,\"taskDefinition\":\"$td_short\",\"executionRoleArn\":\"$exec_role\",\"taskRoleArn\":\"$task_role\",\"roles\":\"$roles\",\"assignPublicIp\":\"$pub\",\"publicip\":\"$publicip\"}")
done

{
  printf '{"cluster":"%s","generated":"%s","services":[' "$CLUSTER" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ( IFS=,; printf '%s' "${rows[*]-}" )
  printf ']}\n'
} | python3 -m json.tool > "$OUT_JSON" || { echo "ERROR: JSON output invalid" >&2; exit 1; }

echo "JSON written to $OUT_JSON"
