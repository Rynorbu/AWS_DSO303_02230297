#!/usr/bin/env bash
# Lab 13 Exercise 3 - are these thresholds defensible?
# For every alarm whose name starts with "usms-", print one JSON object with the
# alarm's definition and what its metric actually did over the last 24 hours.
# stdout: valid JSON only.  stderr: diagnostics.  Safe under set -u.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env >/dev/null 2>&1 || true
PREFIX="${1:-usms-}"

ALARMS_JSON=$(aws cloudwatch describe-alarms --alarm-name-prefix "$PREFIX" \
                --alarm-types MetricAlarm CompositeAlarm --output json)
echo "threshold-report: read alarms with prefix '$PREFIX'" >&2

python3 - "$ALARMS_JSON" << 'PY'
import datetime, json, subprocess, sys

doc = json.loads(sys.argv[1] or "{}")
end = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)
start = end - datetime.timedelta(hours=24)
iso = lambda t: t.strftime("%Y-%m-%dT%H:%M:%SZ")

OPS = {
    "GreaterThanThreshold":          lambda v, t: v >  t,
    "GreaterThanOrEqualToThreshold": lambda v, t: v >= t,
    "LessThanThreshold":             lambda v, t: v <  t,
    "LessThanOrEqualToThreshold":    lambda v, t: v <= t,
}

def log(msg):
    print("threshold-report: " + msg, file=sys.stderr)

def stats(alarm):
    """Datapoints for the alarm's exact metric + dimension set, last 24 h."""
    period = int(alarm.get("Period") or 60)
    while 86400 // period > 1440:          # API limit: 1440 datapoints per call
        period *= 2
    cmd = ["aws", "cloudwatch", "get-metric-statistics",
           "--namespace", alarm["Namespace"], "--metric-name", alarm["MetricName"],
           "--start-time", iso(start), "--end-time", iso(end),
           "--period", str(period),
           "--statistics", "Minimum", "Maximum", "Average", "Sum", "SampleCount",
           "--output", "json"]
    dims = alarm.get("Dimensions") or []
    if dims:
        cmd += ["--dimensions"] + ["Name=%s,Value=%s" % (d["Name"], d["Value"]) for d in dims]
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        log("%s: get-metric-statistics failed: %s" % (alarm["AlarmName"], r.stderr.strip()))
        return []
    return json.loads(r.stdout).get("Datapoints", [])

out = []
for a in doc.get("MetricAlarms", []) or []:
    if "MetricName" not in a:                       # metric-math alarm: no single metric
        log("%s: metric-math alarm, skipped stats" % a["AlarmName"])
        pts = []
    else:
        pts = stats(a)
    stat = a.get("Statistic")
    count = sum(p.get("SampleCount", 0) for p in pts)
    op = OPS.get(a.get("ComparisonOperator"))
    breached = (any(op(p[stat], a["Threshold"]) for p in pts if stat in p)
                if op and stat and pts else False)
    if not pts:
        log("%s: no datapoints in the last 24 h" % a["AlarmName"])
    out.append({
        "alarm": a["AlarmName"],
        "type": "metric",
        "namespace": a.get("Namespace"),
        "metric": a.get("MetricName"),
        "dimensions": {d["Name"]: d["Value"] for d in a.get("Dimensions") or []},
        "statistic": stat,
        "period": a.get("Period"),
        "evaluation_periods": a.get("EvaluationPeriods"),
        "datapoints_to_alarm": a.get("DatapointsToAlarm"),
        "threshold": a.get("Threshold"),
        "comparison": a.get("ComparisonOperator"),
        "missing_data": a.get("TreatMissingData"),
        "state": a.get("StateValue"),
        "observed_24h": {
            "min": min((p["Minimum"] for p in pts), default=None),
            "avg": (round(sum(p["Sum"] for p in pts) / count, 4) if count else None),
            "max": max((p["Maximum"] for p in pts), default=None),
            "sample_count": count,
        },
        "threshold_ever_breached": breached,
    })

for c in doc.get("CompositeAlarms", []) or []:
    out.append({
        "alarm": c["AlarmName"], "type": "composite",
        "namespace": None, "metric": None, "dimensions": None, "statistic": None,
        "period": None, "evaluation_periods": None, "datapoints_to_alarm": None,
        "threshold": None, "comparison": None, "missing_data": None,
        "rule": c.get("AlarmRule"), "state": c.get("StateValue"),
        "observed_24h": None, "threshold_ever_breached": None,
    })

log("%d alarm(s) reported" % len(out))
print(json.dumps(out, indent=2))
PY
