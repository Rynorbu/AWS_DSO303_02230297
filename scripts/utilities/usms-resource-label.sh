#!/usr/bin/env bash
# Print the ResourceLabel that ALBRequestCountPerTarget needs:
#   app/<lb-name>/<lb-id>/targetgroup/<tg-name>/<tg-id>
# Usage: usms-resource-label.sh [load-balancer-name] [target-group-name]
# Both ARNs are looked up from the API every time - never read from configs/lab-05.env.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

LB_NAME="${1:-usms-enrolment-alb}"
TG_NAME="${2:-usms-enrolment-tg}"

LB_ARN=$(aws elbv2 describe-load-balancers --names "$LB_NAME" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null) || LB_ARN=""
TG_ARN=$(aws elbv2 describe-target-groups --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null) || TG_ARN=""

case "$LB_ARN" in arn:aws:elasticloadbalancing:*:loadbalancer/*) ;; *)
  echo "ERROR: load balancer '$LB_NAME' not found" >&2; exit 1 ;; esac
case "$TG_ARN" in arn:aws:elasticloadbalancing:*:targetgroup/*) ;; *)
  echo "ERROR: target group '$TG_NAME' not found" >&2; exit 1 ;; esac

# The two suffixes are cut differently:
# - the load balancer suffix DROPS its "loadbalancer/" resource type
#   (…:loadbalancer/app/usms-enrolment-alb/<id>  ->  app/usms-enrolment-alb/<id>)
# - the target group suffix KEEPS its "targetgroup/" resource type
#   (…:targetgroup/usms-enrolment-tg/<id>        ->  targetgroup/usms-enrolment-tg/<id>)
LB_SUFFIX="${LB_ARN#*:loadbalancer/}"
TG_SUFFIX="${TG_ARN##*:}"
LABEL="$LB_SUFFIX/$TG_SUFFIX"

# Plausibility checks before printing anything.
IFS='/' read -r -a SEG <<< "$LABEL"
if [ "${#SEG[@]}" -ne 6 ] || [ "${SEG[0]}" != app ] || [ "${SEG[3]}" != targetgroup ] \
   || [ "${SEG[1]}" != "$LB_NAME" ] || [ "${SEG[4]}" != "$TG_NAME" ]; then
  echo "ERROR: implausible ResourceLabel: $LABEL" >&2
  exit 1
fi

echo "$LABEL"
