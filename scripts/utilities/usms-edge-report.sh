#!/usr/bin/env bash
# Print a JSON edge-eligibility report for every usms- Lambda function.
# JSON goes to stdout; diagnostics go to stderr. Runs from any directory.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1091
source "$REPO_ROOT/configs/course.env"
echo "usms-edge-report: scanning usms- functions..." >&2

python3 - <<'PY'
import json, subprocess, sys

def aws(*args):
    out = subprocess.run(["aws", *args, "--output", "json"],
                         check=True, capture_output=True, text=True).stdout
    return json.loads(out) if out.strip() else None

fns = aws("lambda", "list-functions",
          "--query", "Functions[?starts_with(FunctionName, 'usms-')]") or []
report = []
for f in sorted(fns, key=lambda x: x["FunctionName"]):
    name    = f["FunctionName"]
    runtime = f.get("Runtime") or ""
    memory  = f.get("MemorySize", 0)
    timeout = f.get("Timeout", 0)
    # .get() chains: safe when Environment / VpcConfig keys are absent
    env     = (f.get("Environment") or {}).get("Variables") or {}
    vpc     = (f.get("VpcConfig") or {}).get("SubnetIds") or []
    versions = [v for v in (aws("lambda", "list-versions-by-function",
                                "--function-name", name,
                                "--query", "Versions[].Version") or [])
                if v != "$LATEST"]
    aliases  = aws("lambda", "list-aliases", "--function-name", name,
                   "--query", "Aliases[].Name") or []

    mem_cap, to_cap = (128, 5) if "viewer" in name else (10240, 30)
    reasons = []
    if not runtime.startswith(("nodejs", "python")):
        reasons.append(f"runtime {runtime}")
    if env:
        reasons.append(f"{len(env)} environment variable(s)")
    if vpc:
        reasons.append("VPC configuration")
    if not versions:
        reasons.append("no published version")
    if memory > mem_cap:
        reasons.append(f"memory {memory} > {mem_cap}")
    if timeout > to_cap:
        reasons.append(f"timeout {timeout} > {to_cap}")
    print(f"  {name}: " + ("eligible" if not reasons
                           else "NOT eligible - " + "; ".join(reasons)),
          file=sys.stderr)

    report.append({"name": name, "runtime": runtime, "memory": memory,
                   "timeout": timeout, "versions": len(versions),
                   "aliases": len(aliases), "env_vars": bool(env),
                   "edge_eligible": not reasons})

print(json.dumps(report, indent=2))
PY
