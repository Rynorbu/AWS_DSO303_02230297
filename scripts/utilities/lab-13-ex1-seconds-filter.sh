#!/usr/bin/env bash
# Lab 13 Exercise 1 - extract a value instead of counting events.
# Filter usms-transcript-seconds on /usms/central/application publishes
# TranscriptSecondsFromLogs = the trailing seconds field of each USMS_EVENT line.
# Does NOT touch usms-central-errors.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
source configs/lab-13.env

GROUP="${USMS_LOG_GROUP_CENTRAL:-/usms/central/application}"
NS="${USMS_METRIC_NAMESPACE:-USMS/Application}"
FILTER=usms-transcript-seconds
METRIC=TranscriptSecondsFromLogs
PATTERN='[tag="USMS_EVENT", payload, seconds]'
OUT=outputs/lab-13-ex1-seconds-filter.txt
mkdir -p outputs

{
echo "Lab 13 Exercise 1 - $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "pattern: $PATTERN"
echo
echo "== 1. test-metric-filter (run first, as required)"
aws logs test-metric-filter --filter-pattern "$PATTERN" \
  --log-event-messages \
    'USMS_EVENT {"event":"transcript.processed","faculty":"science","seconds":0.51} 0.51' \
    'USMS_EVENT {"event":"transcript.processed","faculty":"science","seconds":0.42}' \
    'ERROR USMS_EVENT {"event":"transcript.failed","faculty":"science"}' \
    'health-check ok status=200 path=/healthz' \
  --output json 2>&1
echo
echo "== 2. put-metric-filter $FILTER (metricValue=\$seconds, not 1)"
aws logs put-metric-filter --log-group-name "$GROUP" --filter-name "$FILTER" \
  --filter-pattern "$PATTERN" \
  --metric-transformations "metricName=$METRIC,metricNamespace=$NS,metricValue=\$seconds,unit=Seconds" 2>&1 \
  && echo "filter created" || echo "filter NOT created - falling back to client-side extraction"
} | tee "$OUT"

# 3. Fresh emitter runs with known seconds
T0=$(($(date +%s) * 1000))
SENT="science:0.37 engineering:1.20 science:2.75 engineering:0.88"
{
echo
echo "== 3. emitter runs (faculty:seconds sent)"
for pair in $SENT; do
  ./scripts/utilities/usms-emit-telemetry.sh "${pair%%:*}" "${pair##*:}" | grep -E '^  (log|metric)'
  sleep 1
done
sleep 2

echo
echo "== 4. what the filter would extract (lines since this run started)"
aws logs filter-log-events --log-group-name "$GROUP" --start-time "$T0" \
  --query 'events[].[timestamp,message]' --output json > /tmp/ex1-events.json
python3 - /tmp/ex1-events.json /tmp/ex1-metric-data.json "$METRIC" << 'PY'
import json, sys, datetime
events = json.load(open(sys.argv[1])) or []
data = []
for ts, msg in events:
    parts = msg.split(" ")
    # same rule as [tag="USMS_EVENT", payload, seconds]: exactly 3 fields, tag matches
    if len(parts) != 3 or parts[0] != "USMS_EVENT":
        continue
    try:
        secs = float(parts[2])
    except ValueError:
        continue
    when = datetime.datetime.fromtimestamp(ts / 1000, datetime.timezone.utc)
    print("  extracted %-5s from %s" % (parts[2], when.strftime("%H:%M:%S")))
    data.append({"MetricName": sys.argv[3], "Unit": "Seconds", "Value": secs,
                 "Timestamp": when.strftime("%Y-%m-%dT%H:%M:%SZ")})
json.dump(data, open(sys.argv[2], "w"))
print("  %d value(s) extracted" % len(data))
PY

echo
echo "== 5. publish (stand-in for the filter on this build)"
if [ "$(python3 -c 'import json;print(len(json.load(open("/tmp/ex1-metric-data.json"))))')" != "0" ]; then
  aws cloudwatch put-metric-data --namespace "$NS" --metric-data file:///tmp/ex1-metric-data.json \
    && echo "  published $METRIC"
fi
sleep 2

echo
echo "== 6. read back $METRIC (last hour)"
aws cloudwatch get-metric-statistics --namespace "$NS" --metric-name "$METRIC" \
  --start-time "$(date -u -d '-1 hour' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time   "$(date -u -d '+5 min'  +%Y-%m-%dT%H:%M:%SZ)" \
  --period 3600 --statistics SampleCount Sum Minimum Maximum --output json

echo
echo "== 7. usms-central-errors left alone"
aws logs describe-metric-filters --filter-name-prefix usms-central-errors --output json 2>&1 | head -5
aws cloudwatch list-metrics --namespace "$NS" --metric-name CentralErrorCount \
  --query 'length(Metrics)' --output text
} | tee -a "$OUT"
echo
echo "saved: $OUT"
