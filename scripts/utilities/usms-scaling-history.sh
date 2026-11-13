#!/usr/bin/env bash
# usms-scaling-history.sh - export the enrolment service's full scaling configuration
# and history as ONE JSON document: outputs/lab-06-scaling-history.json # Every identifier is discovered from the service ARN; nothing is typed.
# No `set -e`: optional calls (activities) may be unimplemented and must not abort the export.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/lab-04.env"
mkdir -p "$REPO_ROOT/outputs"
OUT="$REPO_ROOT/outputs/lab-06-scaling-history.json"

python3 - "$USMS_ECS_CLUSTER" "$USMS_ENROLMENT_SERVICE" "$OUT" <<'PY'
import json, subprocess, sys
from datetime import datetime, timezone

cluster, service, out = sys.argv[1:4]

def aws(*args):
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        return {"error": (r.stderr or "").strip()[:300]}
    return json.loads(r.stdout or "null")

svc = aws("ecs", "describe-services", "--cluster", cluster, "--services",
service)["services"][0]
svc_arn = svc["serviceArn"]
rid = "service/" + svc_arn.split(":service/", 1)[1]

target   = aws("application-autoscaling", "describe-scalable-targets",
"--service-namespace", "ecs", "--resource-ids", rid)
policies = aws("application-autoscaling", "describe-scaling-policies",
"--service-namespace", "ecs", "--resource-id", rid)
sched    = aws("application-autoscaling", "describe-scheduled-actions",
"--service-namespace", "ecs", "--resource-id", rid)

acts = aws("application-autoscaling", "describe-scaling-activities",
"--service-namespace", "ecs",
           "--resource-id", rid, "--include-not-scaled-activities")
if "error" in acts:
    acts = aws("application-autoscaling", "describe-scaling-activities",
"--service-namespace", "ecs", "--resource-id", rid)

pols = policies.get("ScalingPolicies", []) if isinstance(policies, dict) else []
pol_arns = {p["PolicyARN"] for p in pols}
names = {a["AlarmName"] for p in pols for a in (p.get("Alarms") or [])}
every = aws("cloudwatch", "describe-alarms").get("MetricAlarms", [])
alarms = [a for a in every if a["AlarmName"] in names or pol_arns &
set(a.get("AlarmActions", []))]

doc = {
    "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
    "serviceArn": svc_arn,
    "resourceId": rid,
    "service": {"desiredCount": svc.get("desiredCount"), "runningCount":
svc.get("runningCount")},
    "scalableTarget": (target.get("ScalableTargets") or [None])[0] if
isinstance(target, dict) else target,
    "policies": pols,
    "scheduledActions": sched.get("ScheduledActions", []) if isinstance(sched, dict)
else sched,
    "alarms": [{"AlarmName": a["AlarmName"], "StateValue": a.get("StateValue"),
                "MetricName": a.get("MetricName"), "Namespace": a.get("Namespace"),
                "Threshold": a.get("Threshold"), "ComparisonOperator": a.get("ComparisonOperator"),
                "AlarmActions": a.get("AlarmActions", [])} for a in alarms],
    "scalingActivities": acts.get("ScalingActivities", acts) if isinstance(acts, dict) else acts,
}
with open(out, "w") as f:
    json.dump(doc, f, indent=2, default=str)
print(f"wrote {out}: {len(pols)} policies, {len(doc['scheduledActions'])} scheduled actions, {len(alarms)} alarms")
PY
