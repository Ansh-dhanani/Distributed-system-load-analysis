# Rebuilding the lab

## 1. AWS infrastructure (Terraform)
```bash
cd infra/terraform
terraform init
terraform apply          # prints control-plane + worker IPs
```

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

Optional monitoring (Prometheus + Grafana + Jaeger):
```bash
ansible-playbook -i inventory.yml site.yml --tags monitoring
```

## 4. App image
```bash
cd ../..
DOCKERHUB_USERNAME=anshdhanani DOCKERHUB_TOKEN=<pat> ./scripts/build-push.sh
```

## 5. Deploy the real app
```bash
# Phase 1: SQLite in-pod (the manifest also creates the `demo` namespace)
kubectl apply -f apps/demo-shop/k8s/deployment.yaml
# Phase 2/3: Postgres (+ Redis) — see apps/demo-shop/PHASE_COMMANDS.md
```

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
