#!/usr/bin/env bash
# Validate the Lab 09 bucket-policy draft against what actually exists.
# Reports only - never fixes. Usage: usms-validate-bucket-policy.sh [draft.json]
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
DRAFT="${1:-$REPO_ROOT/outputs/lab-09-bucket-policy-draft.json}"

python3 - "$DRAFT" <<'PY'
import json, subprocess, sys

BUCKET = "usms-student-data"
ACCOUNT = "000000000000"
doc = json.load(open(sys.argv[1]))

def as_list(x):
    return [x] if isinstance(x, str) else (x or [])

resources, principals, getobject = set(), set(), set()
for s in doc["Statement"]:
    res = as_list(s.get("Resource"))
    resources.update(res)
    for key in ("Principal", "NotPrincipal"):
        p = s.get(key)
        if isinstance(p, dict):
            principals.update(as_list(p.get("AWS")))
    if (s.get("Effect") == "Allow"
            and "s3:GetObject" in as_list(s.get("Action"))
            and f"arn:aws:s3:::{BUCKET}/*" in res):
        getobject.update(as_list((s.get("Principal") or {}).get("AWS")))

bad = 0
print(f"draft: {sys.argv[1]}")
print("-- resources")
for r in sorted(resources):
    ok = r == f"arn:aws:s3:::{BUCKET}" or r.startswith(f"arn:aws:s3:::{BUCKET}/")
    bad += not ok
    print(f"{'OK      ' if ok else 'MISMATCH'} {r}")

print("-- principals")
for p in sorted(principals):
    if p.endswith(":root"):
        print(f"OK       {p}  (account root)")
        continue
    name = p.split("/")[-1]
    ok = subprocess.run(["aws", "iam", "get-role", "--role-name", name],
                        capture_output=True).returncode == 0
    bad += not ok
    print(f"{'OK      ' if ok else 'MISMATCH'} {p}{'' if ok else '  (role does not exist)'}")

print("-- roles carrying USMSStudentDataReadWrite must have s3:GetObject on the bucket")
out = subprocess.run(["aws", "iam", "list-entities-for-policy", "--policy-arn",
                      f"arn:aws:iam::{ACCOUNT}:policy/USMSStudentDataReadWrite",
                      "--query", "PolicyRoles[].RoleName", "--output", "json"],
                     capture_output=True, text=True).stdout
rw = json.loads(out) if out.strip() else []
print(f"   carriers: {', '.join(rw) if rw else '(none found)'}")
for name in rw:
    arn = f"arn:aws:iam::{ACCOUNT}:role/{name}"
    ok = arn in getobject
    bad += not ok
    print(f"{'OK      ' if ok else 'MISMATCH'} {name} {'is granted' if ok else 'is NOT granted'} s3:GetObject on {BUCKET}/*")

print(f"VALIDATION RESULT: {'PASS' if bad == 0 else 'FAIL'} - {bad} mismatch(es)")
PY
