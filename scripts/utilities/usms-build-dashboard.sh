#!/usr/bin/env bash
# Lab 13 Exercise 2 - generate templates/lab-13-dashboard.json from the
# environment (no literal account id or region in this file), add a sixth
# widget, put it, and check it. Re-runnable.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source configs/course.env
ACCOUNT=$(grep -E '^export USMS_ACCOUNT_ID=' configs/lab-01.env | cut -d= -f2)
source configs/lab-13.env

: "${ACCOUNT:?USMS_ACCOUNT_ID missing from configs/lab-01.env}"
: "${AWS_REGION_COURSE:?AWS_REGION_COURSE missing from configs/course.env}"
R="$AWS_REGION_COURSE"
NS="${USMS_METRIC_NAMESPACE:-USMS/Application}"
DASH="${USMS_DASHBOARD:-usms-overview}"
ALARM_ARN="arn:aws:cloudwatch:$R:$ACCOUNT:alarm"
OUT=templates/lab-13-dashboard.json

cat > "$OUT" << EOF
{
  "widgets": [
    {
      "type": "text",
      "x": 0, "y": 0, "width": 24, "height": 2,
      "properties": {
        "markdown": "# USMS - transcript delivery\nOwner: platform team · Runbook: notes/lab-13-runbook.md · Alarms page the composite alarm only."
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 2, "width": 12, "height": 6,
      "properties": {
        "title": "Transcripts processed, by faculty",
        "region": "$R",
        "stat": "Sum",
        "period": 300,
        "view": "timeSeries",
        "stacked": false,
        "metrics": [
          [ "$NS", "TranscriptsProcessed", "Faculty", "science", "Stage", "notify" ],
          [ "$NS", "TranscriptsProcessed", "Faculty", "engineering", "Stage", "notify" ]
        ]
      }
    },
    {
      "type": "metric",
      "x": 12, "y": 2, "width": 12, "height": 6,
      "properties": {
        "title": "Notification latency - max and average",
        "region": "$R",
        "period": 60,
        "view": "timeSeries",
        "metrics": [
          [ "$NS", "TranscriptLagSeconds", "Stage", "notify", { "stat": "Maximum", "label": "max" } ],
          [ "$NS", "TranscriptLagSeconds", "Stage", "notify", { "stat": "Average", "label": "avg" } ]
        ],
        "annotations": {
          "horizontal": [ { "label": "alarm threshold", "value": 2 } ]
        }
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 8, "width": 8, "height": 4,
      "properties": {
        "title": "Notifications in the last 5 minutes",
        "region": "$R",
        "stat": "Sum",
        "period": 300,
        "view": "singleValue",
        "metrics": [
          [ "$NS", "NotifyCount" ],
          [ "$NS", "CentralErrorCount" ]
        ]
      }
    },
    {
      "type": "alarm",
      "x": 8, "y": 8, "width": 16, "height": 4,
      "properties": {
        "title": "Pipeline alarms",
        "alarms": [
          "$ALARM_ARN:${USMS_ALARM_COMPOSITE:-usms-transcript-pipeline-down}",
          "$ALARM_ARN:${USMS_ALARM_LAG_HIGH:-usms-transcript-lag-high}",
          "$ALARM_ARN:${USMS_ALARM_NOTIFY_SILENCE:-usms-notify-silence}"
        ]
      }
    },
    {
      "type": "metric",
      "x": 0, "y": 12, "width": 24, "height": 6,
      "properties": {
        "title": "Central errors - last 3 hours",
        "region": "$R",
        "stat": "Sum",
        "period": 300,
        "start": "-PT3H",
        "end": "P0D",
        "view": "timeSeries",
        "metrics": [
          [ "$NS", "CentralErrorCount", { "label": "errors per 5 min" } ]
        ],
        "annotations": {
          "horizontal": [ { "label": "proposed error alarm threshold (no alarm yet)", "value": 1 } ]
        }
      }
    }
  ]
}
EOF

echo "== generated $OUT"
python3 -m json.tool "$OUT" > /dev/null && echo "valid JSON" || { echo "INVALID JSON" >&2; exit 1; }
grep -c '\$' "$OUT" | sed 's/^/unexpanded \$ signs: /'
grep -nE '[0-9]{12}' "$0" | grep -v 'grep -nE' && echo "LITERAL ACCOUNT ID IN GENERATOR" >&2 \
  || echo "no literal account id in the generator"

echo "== put-dashboard $DASH"
aws cloudwatch put-dashboard --dashboard-name "$DASH" --dashboard-body "file://$OUT" \
  --query 'DashboardValidationMessages' --output json

echo "== read back"
aws cloudwatch get-dashboard --dashboard-name "$DASH" --query 'DashboardBody' --output text \
| python3 -c '
import json, sys
w = json.load(sys.stdin)["widgets"]
print("widgets      :", len(w))
print("grid width   :", max(x["x"] + x["width"] for x in w))
def hit(a, b):
    return (a["x"] < b["x"] + b["width"] and b["x"] < a["x"] + a["width"] and
            a["y"] < b["y"] + b["height"] and b["y"] < a["y"] + a["height"])
pairs = [(i, j) for i in range(len(w)) for j in range(i + 1, len(w)) if hit(w[i], w[j])]
print("overlapping  :", bool(pairs), pairs if pairs else "")
print("widget 6     :", w[-1]["properties"]["title"])
'
