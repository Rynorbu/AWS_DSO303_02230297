#!/bin/bash
# USMS data tier bootstrap. Runs ONCE, as root, at first boot, via cloud-init.
# Idempotent: if the marker file exists, a previous run finished, so exit and change nothing.
MARKER=/var/log/usms-db-bootstrap.done
if [ -f "$MARKER" ]; then echo "USMS db bootstrap already done: $(cat "$MARKER")"; exit 0; fi

set -x
exec >> /var/log/usms-db-bootstrap.log 2>&1

echo "USMS db bootstrap starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

dnf -y install postgresql15-server

# initdb only if the data directory has not been initialised yet.
[ -f /var/lib/pgsql/data/PG_VERSION ] || postgresql-setup --initdb
systemctl enable --now postgresql

# Create the usms database only if it does not already exist.
runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='usms'" | grep -q 1 \
  || runuser -u postgres -- createdb usms

# Ask the instance for its ID, using IMDSv2 (token-based, the secure default).
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  "http://169.254.169.254/latest/meta-data/instance-id")

# Written LAST, so a run that failed halfway can safely run again.
printf '%s %s\n' "$INSTANCE_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"
echo "USMS db bootstrap complete"
