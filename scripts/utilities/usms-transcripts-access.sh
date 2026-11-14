#!/usr/bin/env bash
# Who can read / write the transcripts bucket?  (Lab 09 Exercise 4)
#
# Derived ONLY from outputs/lab-09-identity-inventory.json (every role, its trust
# policy and every attached/inline policy document) and the policies/ folder
# (to name the committed document that grants the access).
# Read-only. Writes outputs/lab-09-transcripts-access.md.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
INVENTORY="outputs/lab-09-identity-inventory.json"
[ -f "$INVENTORY" ] || { echo "no $INVENTORY - rebuild it first (Exercise 2)" >&2; exit 2; }

python3 - "$INVENTORY" << 'PY'
import glob, json, sys

def L(x):
    return x if isinstance(x, list) else ([] if x is None else [x])

def doc_of(d):
    return json.loads(d) if isinstance(d, str) else (d or {})

# Bucket ARN from Lab 01's committed policy document, never typed.
rw = json.load(open("policies/usms-student-data-rw-policy.json"))
bucket = next(r for s in rw["Statement"] for r in L(s.get("Resource"))
              if r.startswith("arn:aws:s3:::") and "/" not in r)

# Map each committed policy document to its file, by content.
files = {}
for f in sorted(glob.glob("policies/*.json")):
    try:
        # first match wins, so the live document beats a later *-draft copy
        files.setdefault(json.dumps(json.load(open(f)), sort_keys=True), f)
    except Exception:
        pass

def mode(actions):
    a = [x.lower() for x in actions]
    w = any(x in ("*", "s3:*") or x.startswith(("s3:put", "s3:delete")) for x in a)
    r = any(x in ("*", "s3:*") or x.startswith(("s3:get", "s3:list")) for x in a)
    obj = any(x in ("*", "s3:*") or x.startswith("s3:get") and x != "s3:getbucketlocation" for x in a)
    if w and r:
        return "read+write"
    if w:
        return "write"
    return "read" if obj else "list only (no object read)"

def who_assumes(trust):
    out = []
    for st in L(doc_of(trust).get("Statement")):
        p = st.get("Principal") or {}
        if p == "*":
            out.append("ANYONE")
            continue
        out += L(p.get("Service")) + L(p.get("AWS"))
    return ", ".join(out) or "?"

rows = []
for role in json.load(open(sys.argv[1])):
    pols = [(p["name"], p.get("document")) for p in role.get("attachedPolicies", [])]
    pols += [(p["name"] + " (inline)", p.get("document")) for p in role.get("inlinePolicies", [])]
    for pname, d in pols:
        d = doc_of(d)
        acts, prefixes, denies = set(), set(), set()
        for st in L(d.get("Statement")):
            s3 = [a for a in L(st.get("Action")) if a == "*" or a.lower().startswith("s3:")]
            hit = [r for r in L(st.get("Resource"))
                   if r in ("*", "arn:aws:s3:::*") or r == bucket or r.startswith(bucket + "/")]
            if not s3 or not hit:
                continue
            if st.get("Effect") == "Allow":
                acts.update(s3)
                prefixes.update(r.replace(bucket, "") or "(bucket)" for r in hit)
            else:
                denies.update(s3)
        if not acts:
            continue
        rows.append({
            "principal": role["role"],
            "how": f"role assumed by {who_assumes(role.get('trustPolicy'))}; policy {pname}",
            "access": mode(acts),
            "scope": ", ".join(sorted(prefixes)),
            "actions": ", ".join(sorted(acts)),
            "denies": ", ".join(sorted(denies)) or "-",
            "document": files.get(json.dumps(d, sort_keys=True), f"(IAM only: {pname})"),
        })

rows.sort(key=lambda r: (r["access"] != "read+write", r["principal"]))
out = ["| Principal | How it gets access | Read / write | Scope | Allowed actions | Explicit denies | Granting document |",
       "|---|---|---|---|---|---|---|"]
for r in rows:
    out.append(f"| `{r['principal']}` | {r['how']} | **{r['access']}** | {r['scope']} | "
               f"{r['actions']} | {r['denies']} | `{r['document']}` |")
text = f"Bucket: `{bucket}` (from policies/usms-student-data-rw-policy.json)\n\n" + "\n".join(out)
text += f"\n\nRoles scanned: {len(json.load(open(sys.argv[1])))}   Roles with access: {len(rows)}\n"
open("outputs/lab-09-transcripts-access.md", "w").write(text)
print(text)
print("written: outputs/lab-09-transcripts-access.md")
PY
