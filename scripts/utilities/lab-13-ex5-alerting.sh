#!/usr/bin/env bash
# Lab 13 Exercise 5 - leave alarms the next alerting lab can attach to.
# Writes a DRAFT of alarm actions (never applied), validates it, records a
# latency baseline, and writes a reproducible readiness report.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-13.env
ACCOUNT=$(grep -E '^export USMS_ACCOUNT_ID=' configs/lab-01.env | cut -d= -f2)
: "${ACCOUNT:?USMS_ACCOUNT_ID missing from configs/lab-01.env}"
R="${AWS_REGION_COURSE:-us-east-1}"
NS="$USMS_METRIC_NAMESPACE"
ALARMS=("$USMS_ALARM_LAG_HIGH" "$USMS_ALARM_NOTIFY_SILENCE" "$USMS_ALARM_COMPOSITE")
mkdir -p outputs

# ---- 1. the draft ---------------------------------------------------------
DRAFT=outputs/lab-13-alarm-actions-draft.json
python3 - "$DRAFT" "$R" "$ACCOUNT" "${ALARMS[@]}" << 'PY'
import json, sys
path, region, account, lag, silence, composite = sys.argv[1:7]
arn = lambda topic: "arn:aws:sns:%s:%s:usms-%s" % (region, account, topic)
draft = {
  "status": "DRAFT - NOT APPLIED. put-metric-alarm --alarm-actions replaces the whole alarm definition.",
  "alarms": [
    {"alarm": composite, "meaning": "transcript pipeline is down: lagging OR silent",
     "urgency": "page",   "alarm_actions": [arn("oncall-page")]},
    {"alarm": lag,       "meaning": "a transcript notification took longer than 2 s (max, 2 of 3 minutes)",
     "urgency": "ticket", "alarm_actions": [arn("platform-tickets")]},
    {"alarm": silence,   "meaning": "no transcript notifications for 15 minutes",
     "urgency": "ticket", "alarm_actions": [arn("platform-tickets")]},
  ],
}
json.dump(draft, open(path, "w"), indent=2)
PY
echo "== draft written: $DRAFT"

# ---- 2. validate it (report, never fix) -----------------------------------
EXISTING=$(aws cloudwatch describe-alarms --alarm-names "${ALARMS[@]}" \
             --alarm-types MetricAlarm CompositeAlarm \
             --query '[MetricAlarms[].AlarmName, CompositeAlarms[].AlarmName][]' --output json)
VALIDATION=$(python3 - "$DRAFT" "$EXISTING" "$ACCOUNT" << 'PY'
import json, re, sys
draft = json.load(open(sys.argv[1])); existing = set(json.loads(sys.argv[2]) or [])
pat = re.compile(r"^arn:aws:sns:[a-z]{2}-[a-z]+-\d:\d{12}:[A-Za-z0-9_-]{1,256}$")
problems = []
for a in draft["alarms"]:
    if a["alarm"] not in existing:
        problems.append("alarm does not exist: %s" % a["alarm"])
    for arn in a["alarm_actions"]:
        if arn.count(":") != 5 or not pat.match(arn):
            problems.append("malformed ARN: %s" % arn)
        elif arn.split(":")[4] != sys.argv[3]:
            problems.append("ARN account differs from lab-01.env: %s" % arn)
print("PASS - 0 mismatch(es)" if not problems else
      "FAIL - %d mismatch(es): %s" % (len(problems), "; ".join(problems)))
PY
)
echo "== validation: $VALIDATION"

# ---- 3. prove it was NOT applied ------------------------------------------
echo "== AlarmActions on each metric alarm (must be empty)"
aws cloudwatch describe-alarms --alarm-names "${ALARMS[@]}" \
  --query 'MetricAlarms[].[AlarmName, length(AlarmActions)]' --output text

# ---- 4. latency baseline ---------------------------------------------------
echo "== emitter runs"
for pair in science:0.44 engineering:1.35 science:0.92 engineering:2.60 science:1.71 engineering:0.58; do
  ./scripts/utilities/usms-emit-telemetry.sh "${pair%%:*}" "${pair##*:}" | grep -E '^  (log|metric)'
  sleep 1
done
sleep 3
BASE=outputs/lab-13-latency-baseline.json
aws cloudwatch get-metric-statistics --namespace "$NS" --metric-name TranscriptLagSeconds \
  --dimensions Name=Stage,Value=notify \
  --start-time "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time   "$(date -u -d '+5 min'  +%Y-%m-%dT%H:%M:%SZ)" \
  --period 3600 --statistics SampleCount Minimum Average Maximum --output json > "$BASE"
echo "== baseline written: $BASE"
MAXLAT=$(python3 -c "import json;d=json.load(open('$BASE'))['Datapoints'];print(max((p['Maximum'] for p in d),default='none'))")

# ---- 5. readiness report (generated, never typed) --------------------------
READY=outputs/lab-13-alerting-readiness.txt
{
echo "USMS alerting readiness - generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by $0"
echo
echo "== alarms and missing-data policy"
aws cloudwatch describe-alarms --alarm-names "${ALARMS[@]}" \
  --query 'MetricAlarms[].[AlarmName, TreatMissingData, StateValue]' --output text
echo
echo "== composite rule"
RULE=$(aws cloudwatch describe-alarms --alarm-names "$USMS_ALARM_COMPOSITE" --alarm-types CompositeAlarm \
         --query 'CompositeAlarms[0].AlarmRule' --output text)
echo "$USMS_ALARM_COMPOSITE: ${RULE:-None}"
echo
echo "== namespace and metrics"
echo "namespace: $NS"
aws cloudwatch list-metrics --namespace "$NS" --query 'Metrics[].MetricName' --output text \
  | tr '\t' '\n' | sort -u
echo
echo "== notifier"
aws lambda get-function-configuration --function-name "${USMS_LAMBDA_NOTIFIER_FN:-usms-transcript-notifier}" \
  --qualifier live --query '[Version, TracingConfig.Mode]' --output text \
  | awk '{print "live alias version: "$1"   tracing: "$2}'
echo
echo "== capabilities on this build"
echo "X-Ray supported:   $USMS_XRAY_SUPPORTED"
echo "Insights supported: $USMS_INSIGHTS_SUPPORTED"
echo
echo "== draft validation (point 2)"
echo "$VALIDATION"
echo
echo "== observed maximum TranscriptLagSeconds (last hour)"
echo "$MAXLAT s"
} > "$READY"
cat "$READY"

echo
echo "== git: outputs must be ignored"
git check-ignore -v "$READY" "$DRAFT" "$BASE" || echo "WARNING: not ignored" >&2
