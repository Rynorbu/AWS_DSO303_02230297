#!/usr/bin/env bash
# usms-scaling-report.sh - read-only decision table for every usms-* ECS scalable target.
# Usage: ./scripts/utilities/usms-scaling-report.sh   (no arguments)
# Writes: outputs/lab-06-scaling-report.json
#
# No `set -e`: this is a report. Some calls are optional or unimplemented in some
# environments (e.g. describe-scaling-activities on Floci). One failing call must
# show as "n/a" in its row, not abort the whole report. Each call's failure is
# handled explicitly in the Python part instead.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
mkdir -p "$REPO_ROOT/outputs"

python3 - "$REPO_ROOT/outputs/lab-06-scaling-report.json" <<'PY'
import json, subprocess, sys

def aws(*args):
    """Run an AWS CLI call and return parsed JSON, or None if it failed."""
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    try:
        return json.loads(r.stdout or "null")
    except ValueError:
        return None

def signed(n):
    n = int(n)
    return f"{n:+d}"

targets = (aws("application-autoscaling", "describe-scalable-targets",
               "--service-namespace", "ecs") or {}).get("ScalableTargets", [])
# resource id = service/<cluster>/<service>; keep clusters starting with usms-
targets = [t for t in targets
           if len(t["ResourceId"].split("/")) == 3 and t["ResourceId"].split("/")[1].startswith("usms-")]

report = []
if not targets:
    print("No usms-* scalable targets found in the ecs namespace.")

for t in targets:
    rid = t["ResourceId"]
    _, cluster, service = rid.split("/")
    mn, mx = t["MinCapacity"], t["MaxCapacity"]
    susp = t.get("SuspendedState") or {}
    frozen = any(bool(v) for v in susp.values())

    svc = (aws("ecs", "describe-services", "--cluster", cluster, "--services", service) or {}).get("services") or [{}]
    desired = svc[0].get("desiredCount", "n/a")
    running = svc[0].get("runningCount", "n/a")

    pols = (aws("application-autoscaling", "describe-scaling-policies",
                "--service-namespace", "ecs", "--resource-id", rid) or {}).get("ScalingPolicies", [])
    sched = (aws("application-autoscaling", "describe-scheduled-actions",
                 "--service-namespace", "ecs", "--resource-id", rid) or {}).get("ScheduledActions", [])
    acts = aws("application-autoscaling", "describe-scaling-activities",
               "--service-namespace", "ecs", "--resource-id", rid, "--max-results", "1")

    # Batch every alarm name into ONE describe-alarms call
    alarm_names = sorted({a["AlarmName"] for p in pols for a in (p.get("Alarms") or [])})
    states = {}
    if alarm_names:
        res = aws("cloudwatch", "describe-alarms", "--alarm-names", *alarm_names) or {}
        states = {a["AlarmName"]: a.get("StateValue", "?") for a in res.get("MetricAlarms", [])}

    # Verdict, evaluated top to bottom. Order matters:
    # PINNED first: if min == max nothing can move, whatever else is true.
    # FROZEN before AT-CEILING: a suspended target that happens to sit at max is NOT
    #   "at ceiling because of demand". The switch is the real reason it can't move,
    #   and it is the thing an operator must fix first.
    # AT-CEILING before AT-FLOOR: hitting max means users may be unserved (urgent);
    #   sitting at the floor is the normal quiet state.
    if mn == mx:
        verdict = "PINNED"
    elif frozen:
        verdict = "FROZEN"
    elif desired == mx:
        verdict = "AT-CEILING"
    elif desired == mn and len(pols) > 1:
        verdict = "AT-FLOOR"
    else:
        verdict = "ELASTIC"

    print("=" * 78)
    print(f"Target      : {rid}")
    print(f"Verdict     : {verdict}")
    print(f"Bounds      : min={mn} max={mx}   desired={desired} running={running}")
    print("Suspended   : " + ", ".join(f"{k}={v}" for k, v in susp.items()) if susp else "Suspended   : (no suspension state reported)")

    rows = []
    print("Policies    :" + ("" if pols else " (none)"))
    for p in pols:
        alarms = [a["AlarmName"] for a in (p.get("Alarms") or [])]
        alarm_txt = ", ".join(f"{a.split('-')[-1] if a.startswith('TargetTracking-') else a}={states.get(a,'?')}"
                              for a in alarms) or "(no alarms listed)"
        if p["PolicyType"] == "TargetTrackingScaling":
            c = p.get("TargetTrackingScalingPolicyConfiguration", {})
            metric = (c.get("PredefinedMetricSpecification") or {}).get("PredefinedMetricType") \
                     or (c.get("CustomizedMetricSpecification") or {}).get("MetricName", "custom")
            line = (f"  TT   {p['PolicyName']}: {metric} target={c.get('TargetValue')} "
                    f"out={c.get('ScaleOutCooldown','-')}s in={c.get('ScaleInCooldown','-')}s "
                    f"scale-in={'OFF' if c.get('DisableScaleIn') else 'on'} | alarms: {alarm_txt}")
            rows.append({"name": p["PolicyName"], "type": "TargetTracking", "metric": metric,
                         "target": c.get("TargetValue"), "alarms": {a: states.get(a, "?") for a in alarms}})
        else:
            c = p.get("StepScalingPolicyConfiguration", {})
            steps = " / ".join(signed(s["ScalingAdjustment"]) for s in c.get("StepAdjustments", [])) or "(no steps)"
            line = (f"  STEP {p['PolicyName']}: {c.get('AdjustmentType')} steps {steps} "
                    f"cooldown={c.get('Cooldown','-')}s | alarms: {alarm_txt}")
            rows.append({"name": p["PolicyName"], "type": "StepScaling", "steps": steps,
                         "alarms": {a: states.get(a, "?") for a in alarms}})
        print(line)

    print("Scheduled   :" + ("" if sched else " (none)"))
    for s in sched:
        a = s.get("ScalableTargetAction", {})
        print(f"  {s['ScheduledActionName']}: {s.get('Schedule')} tz={s.get('Timezone','UTC')} "
              f"min={a.get('MinCapacity','-')} max={a.get('MaxCapacity','-')}")

    if acts is None:
        last = "n/a (describe-scaling-activities not available)"
    elif not acts.get("ScalingActivities"):
        last = "(no activities recorded)"
    else:
        x = acts["ScalingActivities"][0]
        last = f"{x.get('StartTime')} {x.get('StatusCode')} - {x.get('Description','')}"
    print(f"Last activity: {last}")

    report.append({"resourceId": rid, "verdict": verdict, "min": mn, "max": mx,
                   "desired": desired, "running": running, "suspended": susp,
                   "policies": rows,
                   "scheduledActions": [s["ScheduledActionName"] for s in sched],
                   "lastActivity": last})

with open(sys.argv[1], "w") as f:
    json.dump({"targets": report}, f, indent=2, default=str)
print("=" * 78)
print(f"JSON written to outputs/{sys.argv[1].split('/outputs/')[-1]}")
PY
