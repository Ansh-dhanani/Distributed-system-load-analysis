#!/usr/bin/env bash
# Tear down EVERYTHING created for this study:
#   1. in-cluster resources (namespaces, app, DB, cache, load jobs)
#   2. the AWS nodes/VPC/network (terraform destroy) -> cluster goes with it
#   3. local artefacts (ssh key, terraform state kept for audit, docker images)
# Safe to re-run; every step is idempotent.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TF_DIR="$REPO_ROOT/infra/terraform"
ANSIBLE_DIR="$REPO_ROOT/infra/ansible"

echo "==> 1/4 deleting in-cluster resources"
if command -v kubectl >/dev/null 2>&1; then
  # only lab namespaces; the control plane itself disappears with the EC2 nodes
  kubectl delete namespace demo --ignore-not-found --wait=true 2>/dev/null || true
  kubectl delete pvc --all -n demo --ignore-not-found 2>/dev/null || true
  # cluster-scoped RBAC added by the monitoring stack is NOT removed with the namespace
  kubectl delete clusterrole demo-prometheus --ignore-not-found 2>/dev/null || true
  kubectl delete clusterrolebinding demo-prometheus --ignore-not-found 2>/dev/null || true
else
  echo "    kubectl not found, skipping"
fi

echo "==> 2/4 destroying AWS infrastructure (VPC, subnets, SG, EC2 nodes)"
cd "$TF_DIR"
terraform init -input=false >/dev/null
terraform destroy -auto-approve

echo "==> 3/4 removing local secrets and artefacts"
rm -f "$ANSIBLE_DIR/keys/id_rsa"
rm -f /tmp/kubeadm_join.sh
rm -rf /tmp/dbbench
# optional: drop local images built for this study
docker image rm -f anshdhanani/demo-shop:latest >/dev/null 2>&1 || true

echo "==> 4/4 verifying nothing is left"
terraform plan -no-color | tail -5
echo "Done. Terraform state retained in $TF_DIR for audit; delete it with:"
echo "  rm -rf $TF_DIR/.terraform $TF_DIR/terraform.tfstate*"
