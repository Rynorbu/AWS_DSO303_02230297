#!/usr/bin/env bash
# Regenerate outputs/lab-10-s3-readiness.txt for the S3 lab. Safe to re-run.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1091
source configs/course.env
# shellcheck disable=SC1091
source configs/lab-10.env
B=usms-student-data
OUT=outputs/lab-10-s3-readiness.txt

{
  echo "# Lab 10 -> S3 lab readiness"
  echo "# generated $(date -u +%FT%TZ) by scripts/utilities/usms-s3-readiness.sh"
  echo
  echo "bucket:      $B"
  echo "bucket_arn:  arn:aws:s3:::$B"
  COUNT=$(aws s3api list-objects-v2 --bucket "$B" --prefix transcripts/ \
            --query 'length(Contents)' --output text)
  echo "objects under transcripts/: $COUNT"

  echo
  echo "## notification (id, target, events)"
  aws s3api get-bucket-notification-configuration --bucket "$B" \
    --query 'LambdaFunctionConfigurations[].[Id,LambdaFunctionArn,join(`,`,Events)]' \
    --output text
  echo "filter:"
  aws s3api get-bucket-notification-configuration --bucket "$B" \
    --query 'LambdaFunctionConfigurations[].Filter.Key.FilterRules[].[Name,Value]' \
    --output text

  echo
  echo "## functions and published versions"
  for fn in usms-edge-viewer-request usms-edge-origin-response usms-transcript-notifier; do
    V=$(aws lambda list-versions-by-function --function-name "$fn" \
          --query "Versions[?Version!='\$LATEST'].Version" --output text | tr '\t' ' ')
    echo "$fn: $V"
  done

  echo
  echo "## cloudfront"
  echo "supported on this build: ${USMS_CLOUDFRONT_SUPPORTED:-unknown} (distribution ${USMS_CLOUDFRONT_DIST_ID:-none})"

  echo
  echo "## bucket policy (must be absent - the S3 lab applies it)"
  if aws s3api get-bucket-policy --bucket "$B" >/dev/null 2>&1; then
    echo "APPLIED - unexpected!"
  else
    echo "none applied - correct"
  fi

  echo
  echo "## point 2: validation of outputs/lab-09-bucket-policy-draft.json"
  ./scripts/utilities/usms-validate-bucket-policy.sh
} > "$OUT" 2>&1

echo "wrote $OUT"
