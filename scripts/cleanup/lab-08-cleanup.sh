#!/usr/bin/env bash
# Remove everything Lab 08 added. Run ONLY at the end of the course,
# and BEFORE lab-07-cleanup.sh (Lab 07 owns the cluster and the Deployments).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
NS=usms
CLUSTER="${USMS_EKS_CLUSTER:-usms-eks-cluster}"
NODEGROUP="${USMS_EKS_NODEGROUP:-usms-eks-nodes}"

cat <<WARN
This will remove the Lab 08 objects from namespace '$NS':
  - Ingress            usms-portal-ingress
  - Service            usms-gateway  -> patched back to ClusterIP
  - Service            usms-results-np (NodePort 30080)
  - HPA                usms-enrolment-hpa
  - PDBs               usms-gateway-pdb, usms-enrolment-pdb
  - Deployment         usms-loadgen
  - Node group         $NODEGROUP scaling reset to min 2 / max 4 / desired 2
The Lab 07 Deployments, Services, ConfigMaps and the cluster are NOT touched.
WARN
read -r -p "Type DELETE-LAB-08 to continue: " ANSWER
[ "$ANSWER" = "DELETE-LAB-08" ] || { echo "Aborted - nothing deleted."; exit 1; }

echo "== 1. Ingress"
kubectl delete ingress usms-portal-ingress -n "$NS" --ignore-not-found

echo "== 2. Services"
kubectl patch svc usms-gateway -n "$NS" --type=json \
  -p='[{"op":"replace","path":"/spec/type","value":"ClusterIP"},{"op":"remove","path":"/spec/ports/0/nodePort"}]' \
  2>/dev/null || echo "  usms-gateway already ClusterIP (or missing)"
kubectl delete svc usms-results-np -n "$NS" --ignore-not-found

echo "== 3. HPA and PDBs"
kubectl delete hpa usms-enrolment-hpa -n "$NS" --ignore-not-found
kubectl delete pdb usms-gateway-pdb usms-enrolment-pdb -n "$NS" --ignore-not-found

echo "== 4. Load generator"
kubectl delete deployment usms-loadgen -n "$NS" --ignore-not-found

echo "== 5. Node group scaling back to 2/4/2"
aws eks update-nodegroup-config \
  --cluster-name "$CLUSTER" --nodegroup-name "$NODEGROUP" \
  --scaling-config minSize=2,maxSize=4,desiredSize=2 \
  --query 'update.status' --output text 2>/dev/null \
  || echo "  update-nodegroup-config unsupported on this Floci build - node group left as it is"

echo; echo "Lab 08 cleanup finished. Remaining in $NS:"
kubectl get deploy,svc,hpa,pdb,ingress -n "$NS"
