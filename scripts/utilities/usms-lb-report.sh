#!/usr/bin/env bash
# Print the decision table of every Application Load Balancer whose name starts with usms-:
# load balancer -> listeners -> rules (evaluation order, default last) -> target health.
# Also writes outputs/lab-05-lb-report.json. Read-only; takes no arguments.
#
# No -e on purpose: one listener or target group that fails to describe should print a
# readable "(error)" row and let the rest of the report finish, not abort it silently.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

# Four levels of nested calls and string sorting are easier to get right in python3 than
# in nested shell loops; python only formats - every value still comes from the aws CLI.
python3 - "$REPO_ROOT/outputs/lab-05-lb-report.json" << 'PY'
import json
import subprocess
import sys

out_json = sys.argv[1]


def aws(*args):
    """Run one aws call and return parsed JSON, or None if the call failed."""
    r = subprocess.run(["aws", *args, "--output", "json"], capture_output=True, text=True)
    if r.returncode != 0:
        return None
    return json.loads(r.stdout or "null")


def priority_key(rule):
    # Priority is a STRING: "10", "20" ... and "default" for the default action.
    # Sort numbers as numbers (so "5" comes before "10"), and put "default" last.
    p = rule.get("Priority", "default")
    return (1, 0) if p == "default" else (0, int(p))


def tg_name(arn):
    return arn.split(":targetgroup/")[1].split("/")[0] if arn and ":targetgroup/" in arn else "-"


def tg_health(arn):
    d = aws("elbv2", "describe-target-health", "--target-group-arn", arn)
    if d is None:
        return "(error reading target health)", None
    descs = d.get("TargetHealthDescriptions") or []
    healthy = sum(1 for t in descs if (t.get("TargetHealth") or {}).get("State") == "healthy")
    return f"({len(descs)} targets, {healthy} healthy)", {"targets": len(descs), "healthy": healthy}


def describe_action(action):
    """One-line summary of a rule's first action, whatever its type."""
    kind = action.get("Type", "?")
    if kind == "forward":
        arn = action.get("TargetGroupArn") or (
            ((action.get("ForwardConfig") or {}).get("TargetGroups") or [{}])[0].get("TargetGroupArn"))
        text, counts = tg_health(arn) if arn else ("(no target group)", None)
        return f"-> {tg_name(arn):<18} {text}", {"type": kind, "targetGroup": tg_name(arn), **(counts or {})}
    if kind == "fixed-response":
        code = (action.get("FixedResponseConfig") or {}).get("StatusCode", "?")
        return f"-> fixed-response {code}", {"type": kind, "statusCode": code}
    if kind == "redirect":
        cfg = action.get("RedirectConfig") or {}
        return (f"-> redirect {cfg.get('StatusCode', '?')} to {cfg.get('Protocol', '#{protocol}')}:{cfg.get('Port', '#{port}')}",
                {"type": kind, **cfg})
    return f"-> {kind}", {"type": kind}


def describe_condition(rule):
    conds = rule.get("Conditions") or []
    if not conds:
        return "-", "-"
    c = conds[0]
    field = c.get("Field", "?")
    values = (c.get("PathPatternConfig") or c.get("HostHeaderConfig") or {}).get("Values") or c.get("Values") or []
    return field, ",".join(values) or "-"


lbs = aws("elbv2", "describe-load-balancers",
          "--query", "LoadBalancers[?starts_with(LoadBalancerName, 'usms-')]") or []
report = []
if not lbs:
    print("No load balancers whose name starts with usms- were found.")

for lb in sorted(lbs, key=lambda x: x["LoadBalancerName"]):
    print(f"{lb['LoadBalancerName']:<20} {lb.get('Scheme', '?'):<16} {lb.get('Type', '?'):<12} "
          f"{(lb.get('State') or {}).get('Code', '?'):<7} AZs={len(lb.get('AvailabilityZones') or [])}  "
          f"SGs={len(lb.get('SecurityGroups') or [])}")
    lb_entry = {"name": lb["LoadBalancerName"], "scheme": lb.get("Scheme"), "type": lb.get("Type"),
                "state": (lb.get("State") or {}).get("Code"), "listeners": []}

    listeners = (aws("elbv2", "describe-listeners", "--load-balancer-arn", lb["LoadBalancerArn"]) or {}).get("Listeners") or []
    if not listeners:
        print("  (no listeners - this load balancer answers nothing)")
    for lis in sorted(listeners, key=lambda x: x.get("Port", 0)):
        print(f"  {lis.get('Protocol', '?')}:{lis.get('Port', '?')}")
        lis_entry = {"protocol": lis.get("Protocol"), "port": lis.get("Port"), "rules": []}

        rules = (aws("elbv2", "describe-rules", "--listener-arn", lis["ListenerArn"]) or {}).get("Rules")
        if rules is None:
            print("    (error reading rules)")
            rules = []
        # Some builds omit the default rule from describe-rules; fall back to the listener's own.
        if not any(r.get("IsDefault") or r.get("Priority") == "default" for r in rules):
            rules.append({"Priority": "default", "IsDefault": True, "Conditions": [],
                          "Actions": lis.get("DefaultActions") or []})
        if all(r.get("Priority") == "default" for r in rules):
            print("    (no non-default rules)")

        for rule in sorted(rules, key=priority_key):
            field, values = describe_condition(rule)
            actions = rule.get("Actions") or [{}]
            summary, detail = describe_action(actions[0])
            print(f"    prio  {rule.get('Priority', 'default'):<8} {field:<13} {values:<28} {summary}")
            lis_entry["rules"].append({"priority": rule.get("Priority", "default"), "field": field,
                                       "values": values, "action": detail})
        lb_entry["listeners"].append(lis_entry)
    report.append(lb_entry)

with open(out_json, "w", encoding="utf-8") as f:
    json.dump(report, f, indent=2)
print(f"\n(report also written to outputs/lab-05-lb-report.json)")
PY
