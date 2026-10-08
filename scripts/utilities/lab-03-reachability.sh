#!/usr/bin/env bash
# Lab 03 reachability report. For every running instance tagged Project=USMS,
# print: name, private IP, public IP, verdict, reason.
# The verdict comes from the subnet's route table, the public address and the
# security groups - never from the instance's name or tags.
# Read-only; safe to run at any time, from any directory.
#
# No -e on purpose: one failed or empty lookup (for example a subnet with no
# explicit route table association) must produce a line for that instance,
# not abort the whole report. Every lookup below handles its own failure.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

# Treat empty, None and Floci's loopback placeholder as "no public address".
is_blank() { case "${1:-}" in ""|None|null|127.0.0.1) return 0;; *) return 1;; esac; }

# Default-route targets for a subnet: its own route table, else the VPC main table.
default_route_targets() {
  local subnet=$1 vpc=$2 rt
  rt=$(aws ec2 describe-route-tables \
         --filters "Name=association.subnet-id,Values=$subnet" \
         --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
  if is_blank "$rt"; then
    rt=$(aws ec2 describe-route-tables \
           --filters "Name=vpc-id,Values=$vpc" "Name=association.main,Values=true" \
           --query 'RouteTables[0].RouteTableId' --output text 2>/dev/null)
  fi
  is_blank "$rt" && return 0
  aws ec2 describe-route-tables --route-table-ids "$rt" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId' \
    --output text 2>/dev/null
}

# Does any of these security groups admit TCP 80 from 0.0.0.0/0?
sg_allows_80() {
  [ -n "${1:-}" ] || return 1
  # shellcheck disable=SC2086  # word splitting of the group list is intended
  aws ec2 describe-security-groups --group-ids $1 \
    --query 'SecurityGroups[].IpPermissions[] | [?IpProtocol==`-1` || (IpProtocol==`tcp` && FromPort<=`80` && ToPort>=`80`)].IpRanges[].CidrIp' \
    --output text 2>/dev/null | tr '\t' '\n' | grep -qx '0.0.0.0/0'
}

IDS=$(aws ec2 describe-instances \
        --filters "Name=tag:Project,Values=USMS" "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)

if is_blank "$IDS"; then
  echo "No running instances tagged Project=USMS."
  exit 0
fi

for ID in $IDS; do
  IFS=$'\t' read -r NAME PRIVATE PUBLIC SUBNET VPC SGS < <(
    aws ec2 describe-instances --instance-ids "$ID" \
      --query 'Reservations[0].Instances[0].[Tags[?Key==`Name`]|[0].Value, PrivateIpAddress, PublicIpAddress, SubnetId, VpcId, join(`" "`, SecurityGroups[].GroupId)]' \
      --output text 2>/dev/null)

  is_blank "${NAME:-}"    && NAME="$ID"
  is_blank "${PRIVATE:-}" && PRIVATE="-"

  # An associated Elastic IP is always a real public address, even when Floci
  # reports its IP as the 127.0.0.1 placeholder, so test the allocation, not the IP.
  read -r EIP_ALLOC EIP_IP < <(aws ec2 describe-addresses --filters "Name=instance-id,Values=$ID" \
          --query 'Addresses[0].[AllocationId, PublicIp]' --output text 2>/dev/null)
  if ! is_blank "${EIP_ALLOC:-}"; then PUBLIC="${EIP_IP:-$EIP_ALLOC} (eip)"
  elif is_blank "${PUBLIC:-}"; then PUBLIC="-"
  fi

  TARGETS=$(default_route_targets "${SUBNET:-}" "${VPC:-}")

  if ! grep -q 'igw-' <<<"$TARGETS"; then
    VERDICT="UNREACHABLE"; REASON="no igw route on subnet"
  elif [ "$PUBLIC" = "-" ]; then
    VERDICT="NO-ADDRESS";  REASON="igw route present but no public address"
  elif ! sg_allows_80 "${SGS:-}"; then
    VERDICT="BLOCKED";     REASON="igw route + public address but sg does not allow 80/tcp from 0.0.0.0/0"
  else
    VERDICT="REACHABLE";   REASON="igw route + sg allows 80/tcp from 0.0.0.0/0"
  fi

  printf '%-20s %-15s %-16s %-12s %s\n' "$NAME" "$PRIVATE" "$PUBLIC" "$VERDICT" "$REASON"
done | sort
