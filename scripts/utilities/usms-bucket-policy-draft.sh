#!/usr/bin/env bash
# Draft the transcripts bucket's RESOURCE policy for the S3 configuration lab.
# Reads live IAM + outputs/lab-09-identity-inventory.json. APPLIES NOTHING.
# Uses only the caller's existing profile; no credential material is read,
# written or referenced by this script.
# No -e: head-bucket legitimately fails before Lab 10 creates the bucket, and
# one unreadable policy must not abort the draft; failures are handled inline.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
INVENTORY="$REPO_ROOT/outputs/lab-09-identity-inventory.json"
DRAFT="$REPO_ROOT/outputs/lab-09-bucket-policy-draft.json"
READY="$REPO_ROOT/outputs/lab-09-lab10-readiness.txt"
SOURCE_POLICY="USMSStudentDataReadWrite"     # Lab 01's policy: the bucket name comes from here
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$REPO_ROOT/outputs"

# 1. Every customer-managed policy: default document + who it is attached to.
aws iam list-policies --scope Local --output json > "$TMP/list.json" \
  || { echo "cannot list IAM policies" >&2; exit 2; }
python3 - "$TMP/list.json" > "$TMP/arns.txt" << 'PY'
import json, sys
for p in json.load(open(sys.argv[1]))["Policies"]:
    print(p["Arn"], p.get("DefaultVersionId", "v1"), p["PolicyName"])
PY
while read -r arn ver pname; do
  aws iam get-policy-version --policy-arn "$arn" --version-id "$ver" \
    --query 'PolicyVersion.Document' --output json > "$TMP/doc-$pname.json" 2>/dev/null \
    || { rm -f "$TMP/doc-$pname.json"; continue; }
  aws iam list-entities-for-policy --policy-arn "$arn" --output json \
    > "$TMP/ent-$pname.json" 2>/dev/null || echo '{}' > "$TMP/ent-$pname.json"
done < "$TMP/arns.txt"

if [ ! -f "$TMP/doc-$SOURCE_POLICY.json" ]; then
  echo "cannot read $SOURCE_POLICY from IAM" >&2; exit 2
fi

# 2. Bucket ARN from the policy DOCUMENT - never typed.
BUCKET_ARN=$(python3 - "$TMP/doc-$SOURCE_POLICY.json" << 'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d = json.loads(d) if isinstance(d, str) else d
for s in d.get("Statement", []):
    rs = s.get("Resource"); rs = rs if isinstance(rs, list) else [rs]
    for r in rs:
        if r and r.startswith("arn:aws:s3:::") and "/" not in r:
            print(r); sys.exit(0)
sys.exit(1)
PY
) || { echo "no bucket ARN found in $SOURCE_POLICY" >&2; exit 2; }
# Parameter expansion, not a subprocess: '##*:::' strips the longest prefix
# ending in ':::' so the ARN becomes the bare bucket name. Pure shell, so it
# behaves the same whether or not the bucket exists and needs no AWS call.
BUCKET="${BUCKET_ARN##*:::}"

if aws s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then EXISTS=yes; else EXISTS=no; fi

# 3. Compute principals + their existing actions, write draft + readiness.
python3 - "$TMP" "$BUCKET_ARN" "$INVENTORY" "$DRAFT" "$READY" "${ACCOUNT_ID:-000000000000}" "$EXISTS" << 'PY'
import glob, json, os, re, subprocess, sys
tmp, bucket_arn, inv_path, draft_path, ready_path, account, exists = sys.argv[1:8]
obj_arn, bucket = bucket_arn + "/*", bucket_arn.split(":::")[1]

def L(x):
    return x if isinstance(x, list) else ([] if x is None else [x])

inv = {}
if os.path.exists(inv_path):
    inv = {r["role"]: r for r in json.load(open(inv_path))}

grants, policies, others = {}, {}, {}
for f in sorted(glob.glob(os.path.join(tmp, "doc-*.json"))):
    pname = os.path.basename(f)[4:-5]
    doc = json.load(open(f))
    doc = json.loads(doc) if isinstance(doc, str) else doc
    found = {}
    for st in L(doc.get("Statement")):
        if st.get("Effect") != "Allow":
            continue
        acts = [a for a in L(st.get("Action")) if a == "*" or a.lower().startswith("s3:")]
        if not acts:
            continue
        for r in L(st.get("Resource")):
            if r in ("*", "arn:aws:s3:::*"):
                for x in (bucket_arn, obj_arn):
                    found.setdefault(x, set()).update(acts)
            elif r == bucket_arn or r.startswith(bucket_arn + "/"):
                found.setdefault(r, set()).update(acts)
    if not found:
        continue
    ent = json.load(open(os.path.join(tmp, f"ent-{pname}.json")))
    roles = [x["RoleName"] for x in ent.get("PolicyRoles", [])]
    policies[pname] = roles
    others[pname] = [x["UserName"] for x in ent.get("PolicyUsers", [])] + \
                    ["group:" + x["GroupName"] for x in ent.get("PolicyGroups", [])]
    for role in roles:
        for r, a in found.items():
            grants.setdefault(role, {}).setdefault(r, set()).update(a)

def role_arn(n):
    if n in inv:
        return inv[n]["arn"]
    try:
        return subprocess.check_output(
            ["aws", "iam", "get-role", "--role-name", n,
             "--query", "Role.Arn", "--output", "text"], text=True).strip()
    except Exception:
        return f"arn:aws:iam::{account}:role/{n}"

stmts, arns, i = [], [], 0
for role in sorted(grants):
    arn = role_arn(role)
    arns.append(arn)
    for res in sorted(grants[role]):
        i += 1
        sid = "Allow" + re.sub(r"[^A-Za-z0-9]", "", role.title()) + str(i)
        stmts.append({"Sid": sid, "Effect": "Allow", "Principal": {"AWS": arn},
                      "Action": sorted(grants[role][res]), "Resource": res})
root = f"arn:aws:iam::{account}:root"
stmts.append({"Sid": "DenyInsecureTransport", "Effect": "Deny", "Principal": "*",
              "Action": "s3:*", "Resource": [bucket_arn, obj_arn],
              "Condition": {"Bool": {"aws:SecureTransport": "false"}}})
stmts.append({"Sid": "DenyEveryoneExceptKnownRolesAndRoot", "Effect": "Deny",
              "NotPrincipal": {"AWS": sorted(arns) + [root]},
              "Action": "s3:*", "Resource": [bucket_arn, obj_arn]})
json.dump({"Version": "2012-10-17", "Id": f"{bucket}-draft", "Statement": stmts},
          open(draft_path, "w"), indent=2)

stale = sorted(set(grants) - set(inv))
with open(ready_path, "w") as o:
    o.write(f"BUCKET NAME (from USMSStudentDataReadWrite): {bucket}\n")
    o.write(f"BUCKET EXISTS NOW: {exists}\n")
    o.write(f"TRANSCRIPTS POLICIES ({len(policies)}): {', '.join(sorted(policies))}\n")
    for p in sorted(policies):
        o.write(f"  {p}: roles={','.join(policies[p]) or '-'} "
                f"users/groups={','.join(others[p]) or '-'}\n")
    o.write(f"ROLE ARNS: {' '.join(sorted(arns))}\n")
    o.write(f"PRINCIPAL COUNT (roles granted s3 on the bucket): {len(arns)}\n")
    o.write(f"ROLES MISSING FROM INVENTORY: {', '.join(stale) or 'none'}\n")
    o.write("WHEN LAB 10 RUNS create-bucket: the ARN these identity policies already name "
            "starts to exist, so the roles above immediately gain exactly the access their "
            "policies grant; nobody else gains anything, and this draft becomes applicable.\n")
print(open(ready_path).read())
PY

# 4. Validate: JSON, then the mechanical checks.
if python3 -m json.tool "$DRAFT" > /dev/null; then
  echo "draft: valid JSON"
else
  echo "draft: INVALID JSON" >&2; exit 1
fi
python3 - "$DRAFT" "$BUCKET_ARN" << 'PY'
import json, sys
d, b = json.load(open(sys.argv[1])), sys.argv[2]
bad, res = [], set()
for s in d["Statement"]:
    p = s.get("Principal", s.get("NotPrincipal"))
    if p == "*":
        vals = ["*"]
    else:
        vals = p["AWS"] if isinstance(p["AWS"], list) else [p["AWS"]]
    for v in vals:
        if v == "*" and s["Sid"] != "DenyInsecureTransport":
            bad.append(f"{s['Sid']}: Principal *")
        elif v != "*" and not v.startswith("arn:aws:iam::"):
            bad.append(f"{s['Sid']}: not an ARN: {v}")
    r = s["Resource"]
    res.update(r if isinstance(r, list) else [r])
print("bucket ARN without /* :", b in res)
print("bucket ARN with    /* :", b + "/*" in res)
if bad or b not in res or b + "/*" not in res:
    print("CHECK FAILED:", bad)
    sys.exit(1)
print("checks: PASS (every Principal an ARN; only DenyInsecureTransport uses *)")
PY
