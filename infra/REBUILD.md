# Rebuilding the lab

## 1. AWS infrastructure (Terraform)
```bash
cd infra/terraform
terraform init
terraform apply          # prints control-plane + worker IPs
```
The AMI is looked up automatically (latest Ubuntu 24.04 amd64). Pin a specific
image with `terraform apply -var ami_id=ami-xxxxxxxx`.

## 2. Inventory
```bash
cd ../ansible
cp inventory.example.yml inventory.yml
# edit: cp ansible_host = CP_IP, w1 = W1_IP, w2 = W2_IP
```

## 3. Cluster + addons (Ansible)
```bash
ansible-playbook -i inventory.yml site.yml
```
This installs: containerd, kubeadm/kubelet/kubectl v1.36, control plane +
workers, Calico, metrics-server, and the original `manifests/` study workload.

Re-running on **already-used nodes** (the guards normally make this a no-op)?
Force a clean rebuild:
```bash
ansible-playbook -i inventory.yml site.yml -e reset_cluster=true   # runs kubeadm reset + cleans state
```

Optional monitoring (Prometheus + Grafana + Jaeger):
```bash
ansible-playbook -i inventory.yml site.yml --tags monitoring
```

## 4. App image
```bash
cd ../..
# Docker Hub, GHCR, or any registry — build-push.sh derives it from IMAGE.
IMAGE=<user>/demo-shop:latest \
  DOCKERHUB_USERNAME=<user> DOCKERHUB_TOKEN=<pat> ./scripts/build-push.sh
```

## 5. Deploy the real app
```bash
# Build+push once, then deploy any phase with the same IMAGE (no manifest edits):
IMAGE=<user>/demo-shop:latest ./scripts/deploy-app.sh 1   # Phase 1: SQLite in-pod
# Phase 2/3: Postgres (+ Redis) — see apps/demo-shop/PHASE_COMMANDS.md

# Private registry (e.g. a private ghcr package): let deploy-app.sh add the pull secret
IMAGE=ghcr.io/<owner>/demo-shop:latest \
  PULL_SECRET_USER=<owner> PULL_SECRET_TOKEN=<pat> ./scripts/deploy-app.sh 3
```
`kubectl apply -f apps/demo-shop/k8s/deployment.yaml` also works with the default image.

## 6. Load test + observability
```bash
./scripts/run-load.sh                 # summary printed
TRACE=true ./scripts/run-load.sh      # + client spans into Jaeger
kubectl -n demo port-forward svc/grafana 3000:3000     # admin/admin
kubectl -n demo port-forward svc/jaeger 16686:16686
```

## 7. Tear down (everything)
```bash
./scripts/destroy.sh
```
