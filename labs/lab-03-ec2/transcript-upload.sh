#!/usr/bin/env bash
# Upload a student transcript to S3. Runs ON usms-web-01.
# Credentials come only from the instance profile (usms-ec2-app-profile),
# which the AWS CLI picks up automatically from instance metadata.
#
# Usage: transcript-upload.sh <student-id> <file-path>
# Uploads to s3://usms-student-data/transcripts/<student-id>/<filename>
set -euo pipefail

BUCKET="${USMS_BUCKET_NAME:-usms-student-data}"

usage() {
  echo "Usage: $(basename "$0") <student-id> <file-path>" >&2
  echo "Example: $(basename "$0") S2024001 ./transcript.pdf" >&2
  exit 2
}

[ $# -eq 2 ] || { echo "Error: expected 2 arguments, got $#." >&2; usage; }

STUDENT_ID=$1
FILE=$2

[ -n "$STUDENT_ID" ] || { echo "Error: student ID is empty." >&2; usage; }
[[ "$STUDENT_ID" =~ ^[A-Za-z0-9_-]+$ ]] \
  || { echo "Error: student ID '$STUDENT_ID' may only contain letters, digits, _ and -." >&2; exit 2; }
[ -f "$FILE" ] || { echo "Error: file '$FILE' does not exist." >&2; exit 2; }
[ -r "$FILE" ] || { echo "Error: file '$FILE' is not readable." >&2; exit 2; }

KEY="transcripts/${STUDENT_ID}/$(basename "$FILE")"

echo "Uploading $FILE to s3://${BUCKET}/${KEY}"
aws s3 cp "$FILE" "s3://${BUCKET}/${KEY}" --region "${AWS_REGION:-us-east-1}"
echo "Upload complete."
