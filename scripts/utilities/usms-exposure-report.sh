#!/usr/bin/env bash
# USMS exposure report - one line per network interface in usms-vpc.
#
# The verdict is COMPUTED from three facts only:
#   1. route   - does the interface's subnet route to an internet gateway?
#                (explicit association, else the VPC's main route table)
#   2. address - does it have a public IP? (or is it requester-managed, e.g. an
#                ALB/NAT node, whose public address AWS owns and Floci may hide)
#   3. ingress - do its security groups allow 0.0.0.0/0 or ::/0, and on what?
# Names, tags and descriptions are DISPLAYED only, never used for the verdict.
#
#   ISOLATED  no IGW route: the internet has no path to it
#   INTERNAL  IGW route, but no public address: nothing outside can address it
#   EXPOSED   IGW route + public address. The reason says whether ingress is
#             open, group-only, or absent. A public address with no ingress
#             rule is still EXPOSED: it is discoverable, it is one
#             AuthorizeSecurityGroupIngress away from open, and stateful
#             return traffic flows to anything it initiates.
#   REVIEW    IGW route + public, but a group could not be read: fail safe,
#             never guess "safe".
#
# Read-only. No arguments. No hard-coded IDs. Works from any directory.
#
# Why no -e: one failed describe (an uncached group, a vanished instance) must
# not kill the whole report. Each aws call handles its own failure below and
# the verdict degrades to REVIEW instead of the script silently exiting.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true

VPC="${USMS_VPC_ID:-}"
if [ -z "$VPC" ] || [ "$VPC" = "None" ]; then
  echo "cannot resolve usms-vpc from configs/lab-02.env" >&2
  exit 2
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
F="Name=vpc-id,Values=$VPC"

aws ec2 describe-network-interfaces --filters "$F" --output json > "$TMP/eni.json" \
  || { echo "cannot read network interfaces" >&2; exit 2; }
aws ec2 describe-route-tables --filters "$F" --output json > "$TMP/rtb.json" 2>/dev/null \
  || echo '{}' > "$TMP/rtb.json"
aws ec2 describe-security-groups --filters "$F" --output json > "$TMP/sg.json" 2>/dev/null \
  || echo '{}' > "$TMP/sg.json"
aws ec2 describe-instances --filters "$F" --output json > "$TMP/ec2.json" 2>/dev/null \
  || echo '{}' > "$TMP/ec2.json"

mkdir -p "$REPO_ROOT/outputs"
# Switch to python3 here: joining four JSON documents is not a job for jq/awk.
python3 - "$TMP" "$REPO_ROOT/outputs/lab-09-exposure.json" "$VPC" << 'PY'
import ipaddress, json, os, sys
tmp, out_path, vpc = sys.argv[1:4]

def load(f, key):
    try:
        return json.load(open(os.path.join(tmp, f))).get(key, [])
    except Exception:
        return []

enis = load("eni.json", "NetworkInterfaces")
rtbs = load("rtb.json", "RouteTables")
sgs = {g["GroupId"]: g for g in load("sg.json", "SecurityGroups")}
inst = {}
for r in load("ec2.json", "Reservations"):
    for i in r.get("Instances", []):
        name = next((t["Value"] for t in i.get("Tags", []) if t["Key"] == "Name"), "")
        inst[i["InstanceId"]] = (i.get("State", {}).get("Name", "?"), name)

main_rtb, by_subnet = None, {}
for t in rtbs:
    for a in t.get("Associations", []):
        if a.get("Main"):
            main_rtb = t
        elif a.get("SubnetId"):
            by_subnet[a["SubnetId"]] = t

def igw_route(t):
    if not t:
        return False
    return any((r.get("GatewayId") or "").startswith("igw-")
               and r.get("State", "active") == "active"
               for r in t.get("Routes", []))

def world_ports(g):
    out = []
    for p in g.get("IpPermissions", []):
        world = any(x.get("CidrIp") == "0.0.0.0/0" for x in p.get("IpRanges", [])) or \
                any(x.get("CidrIpv6") == "::/0" for x in p.get("Ipv6Ranges", []))
        if not world:
            continue
        lo, hi = p.get("FromPort"), p.get("ToPort")
        if p.get("IpProtocol") == "-1" or lo in (None, -1):
            out.append("all ports")
        else:
            out.append(str(lo) if lo == hi else f"{lo}-{hi}")
    return out

rows = []
for e in enis:
    eid = e["NetworkInterfaceId"]
    att = e.get("Attachment") or {}
    iid = att.get("InstanceId")
    state, iname = inst.get(iid, (None, "")) if iid else (None, "")
    label = (iname or iid) if iid else f"{e.get('InterfaceType') or 'interface'} {eid}"
    priv = e.get("PrivateIpAddress") or "-"
    pub = (e.get("Association") or {}).get("PublicIp")
    notes = []
    if not e.get("Description"):
        notes.append("no description")
    if e.get("Status") == "available":
        notes.append("unattached leftover")
    elif iid and state in (None, "terminated", "shutting-down"):
        notes.append(f"instance {state or 'gone'}")

    subnet = e.get("SubnetId")
    if subnet in by_subnet:
        rtb = by_subnet[subnet]
    else:
        rtb = main_rtb
        notes.append("main route table (no explicit association)")

    groups = [g["GroupId"] for g in e.get("Groups", [])]
    missing = [g for g in groups if g not in sgs]
    if missing:
        notes.append("SG not cached: " + ",".join(missing))
    world = sorted({p for g in groups if g in sgs for p in world_ports(sgs[g])})
    nrules = sum(len(sgs[g].get("IpPermissions", [])) for g in groups if g in sgs)
    addressable = bool(pub) or bool(e.get("RequesterManaged"))

    if not igw_route(rtb):
        v, why = "ISOLATED", "No IGW route on the subnet"
    elif not addressable:
        v, why = "INTERNAL", "IGW route, but no public address"
    elif missing:
        v, why = "REVIEW", "IGW route + public, but a SG is unreadable"
    elif world:
        v, why = "EXPOSED", "IGW route, and the SG allows " + " and ".join(world) + " from 0.0.0.0/0"
    elif nrules == 0:
        v, why = "EXPOSED", "IGW route, but no ingress rule at all"
    else:
        v, why = "EXPOSED", "IGW route + public; ingress only from groups/private CIDRs"

    rows.append({"interface": label, "eni": eid, "privateIp": priv,
                 "publicIp": pub or "none", "verdict": v, "reason": why,
                 "subnet": subnet, "securityGroups": groups, "notes": notes})

def ipkey(r):
    try:
        return int(ipaddress.ip_address(r["privateIp"]))
    except ValueError:
        return 0

rows.sort(key=ipkey)

fmt = "{:<26} {:<13} {:<15} {:<9} {}"
print("== USMS exposure report ==")
print()
print(fmt.format("INTERFACE", "PRIVATE IP", "PUBLIC IP", "VERDICT", "REASON"))
for r in rows:
    extra = f"  [{'; '.join(r['notes'])}]" if r["notes"] else ""
    print(fmt.format(r["interface"][:26], r["privateIp"], r["publicIp"],
                     r["verdict"], r["reason"] + extra))
counts = {}
for r in rows:
    counts[r["verdict"]] = counts.get(r["verdict"], 0) + 1
print()
print("  ".join(f"{k}={counts[k]}" for k in sorted(counts)) + f"  interfaces={len(rows)}")
json.dump({"vpc": vpc, "counts": counts, "interfaces": rows},
          open(out_path, "w"), indent=2, sort_keys=True)
print("written: outputs/lab-09-exposure.json")
PY
