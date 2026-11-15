#!/usr/bin/env bash
# Remove everything Lab 10 added. Run ONLY at the end of the course.
# DO NOT RUN NOW - the S3 lab builds on usms-student-data and these functions.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-10.env" 2>/dev/null || true

# Git Bash on Windows rewrites arguments that start with /aws/ into Windows paths.
export MSYS2_ARG_CONV_EXCL="/aws/"

BUCKET="${USMS_BUCKET:-usms-student-data}"
VIEWER="${USMS_EDGE_VIEWER_FN:-usms-edge-viewer-request}"
ORIGIN="${USMS_EDGE_ORIGIN_FN:-usms-edge-origin-response}"
NOTIFIER="${USMS_LAMBDA_NOTIFIER_FN:-usms-transcript-notifier}"
ALIAS="${USMS_LAMBDA_NOTIFIER_ALIAS:-live}"
STATEMENT_ID="usms-s3-transcript-upload"
DIST_ID="${USMS_CLOUDFRONT_DIST_ID:-}"

cat <<WARN
This will permanently delete the Lab 10 resources:
  - Bucket notification on      $BUCKET
  - CloudFront distribution     ${DIST_ID:-<none recorded>}
  - Resource-policy statement   $STATEMENT_ID on $NOTIFIER:$ALIAS
  - Alias                       $NOTIFIER:$ALIAS
  - Functions (all versions)    $VIEWER, $ORIGIN, $NOTIFIER
  - Bucket and every object in  $BUCKET
WARN
read -r -p "Type DELETE USMS EDGE FUNCTIONS to continue: " ANSWER
[ "$ANSWER" = "DELETE USMS EDGE FUNCTIONS" ] || { echo "Aborted - nothing deleted."; exit 1; }

echo "== 1. Bucket notification (stop new invocations first)"
aws s3api put-bucket-notification-configuration --bucket "$BUCKET" \
  --notification-configuration '{}' || true

echo "== 2. CloudFront distribution"
if [ -n "$DIST_ID" ] && aws cloudfront get-distribution --id "$DIST_ID" >/dev/null 2>&1; then
  ETAG=$(aws cloudfront get-distribution-config --id "$DIST_ID" --query ETag --output text)
  aws cloudfront get-distribution-config --id "$DIST_ID" --query DistributionConfig --output json \
    | python -c 'import json,sys; c=json.load(sys.stdin); c["Enabled"]=False; print(json.dumps(c))' \
    > "$REPO_ROOT/outputs/lab-10-dist-disable.json"
  aws cloudfront update-distribution --id "$DIST_ID" --if-match "$ETAG" \
    --distribution-config "file://outputs/lab-10-dist-disable.json" >/dev/null || true
  # On real AWS this blocks until the disabled config has deployed everywhere.
  aws cloudfront wait distribution-deployed --id "$DIST_ID" 2>/dev/null || true
  ETAG=$(aws cloudfront get-distribution --id "$DIST_ID" --query ETag --output text)
  aws cloudfront delete-distribution --id "$DIST_ID" --if-match "$ETAG" || true
else
  echo "   no distribution to delete"
fi

echo "== 3. Resource-policy statement on the notifier"
aws lambda remove-permission --function-name "$NOTIFIER" --qualifier "$ALIAS" \
  --statement-id "$STATEMENT_ID" || true

echo "== 4. Alias, then functions (deleting a function removes all its versions)"
aws lambda delete-alias --function-name "$NOTIFIER" --name "$ALIAS" || true
for fn in "$VIEWER" "$ORIGIN" "$NOTIFIER"; do
  aws lambda delete-function --function-name "$fn" && echo "   deleted $fn" || true
  aws logs delete-log-group --log-group-name "/aws/lambda/$fn" 2>/dev/null || true
done

echo "== 5. Empty and delete the bucket"
aws s3 rm "s3://$BUCKET" --recursive || true
aws s3api delete-bucket --bucket "$BUCKET" || true

echo
echo "Done. usms-lambda-exec-role and USMSLambdaBasic belong to Lab 01 and were NOT deleted."
