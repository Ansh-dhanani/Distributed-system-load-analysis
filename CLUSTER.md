# Cluster under test

- Kubernetes v1.36.5 (kubeadm), Ubuntu 24.04, containerd 2.2.1, Calico 3.32.2
- 1 control-plane + 2 workers, all `t3.small` (2 vCPU, 2 GB), `ap-south-1a`
- `cpu_credits = standard`, 16 GB gp3 root volumes, no NAT / no LB (cheap lab)
- metrics-server; Prometheus + Grafana + Jaeger are optional (see below)
- Demo app: `apps/demo-shop` (FastAPI + Postgres/Redis), HPA `2->6 @ 50% CPU`
  (limits `500m/128Mi`, 60s scale-down window)
- Observability: metrics-server always; Prometheus + Grafana + Jaeger optional
  (`ansible-playbook ... --tags monitoring`)

Built with Terraform + Ansible (`k8s-aws-lab`); torn down afterwards with
`./scripts/destroy.sh` so no AWS charges accrue.
