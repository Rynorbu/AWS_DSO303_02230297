#!/usr/bin/env bash
# Run post_build.finally from a buildspec - the Step 14 runner does not implement finally.
APP_DIR="$1"
python3 - "$APP_DIR/buildspec.yml" > /tmp/usms-finally.sh << 'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
print('export ARTIFACT_DIR="${ARTIFACT_DIR:-%s}"' % doc["env"]["variables"]["ARTIFACT_DIR"])
for c in doc["phases"]["post_build"].get("finally", []):
    print(c)
PY
echo "=== finally (run separately) ==="
( cd "$APP_DIR" && bash /tmp/usms-finally.sh )
