#!/usr/bin/env bash
set -uo pipefail
# Deliberately NOT using -e: a subnet with no default route is an
# expected, valid outcome (ISOLATED), not a script failure, and -e
# would abort the whole run the first time that happens.

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"

SUBNETS=$(aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$USMS_VPC_ID" \
  --query 'Subnets[*].{Id:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone,Name:Tags[?Key==`Name`]|[0].Value}' \
  --output json)

echo "$SUBNETS" | jq -c '.[]' | while read -r row; do
  SUBNET_ID=$(echo "$row" | jq -r '.Id')
  CIDR=$(echo "$row" | jq -r '.CIDR')
  AZ=$(echo "$row" | jq -r '.AZ')
  NAME=$(echo "$row" | jq -r '.Name')

  RT_ID=$(aws ec2 describe-route-tables \
    --filters "Name=association.subnet-id,Values=$SUBNET_ID" \
    --query 'RouteTables[0].RouteTableId' --output text)

  IGW=$(aws ec2 describe-route-tables --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].GatewayId | [0]' --output text)
  NAT=$(aws ec2 describe-route-tables --route-table-ids "$RT_ID" \
    --query 'RouteTables[0].Routes[?DestinationCidrBlock==`0.0.0.0/0`].NatGatewayId | [0]' --output text)

  if [[ "$IGW" == igw-* ]]; then
    printf "%-24s%-16s%-14s%-9s via %s\n" "$NAME" "$CIDR" "$AZ" "PUBLIC" "$IGW"
  elif [[ "$NAT" == nat-* ]]; then
    printf "%-24s%-16s%-14s%-9s via %s\n" "$NAME" "$CIDR" "$AZ" "PRIVATE" "$NAT"
  else
    printf "%-24s%-16s%-14s%-9s no default route\n" "$NAME" "$CIDR" "$AZ" "ISOLATED"
  fi
done