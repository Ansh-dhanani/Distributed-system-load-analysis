# Cluster under test

- Kubernetes v1.36.5 (kubeadm), Ubuntu 24.04, containerd 2.2.1, Calico 3.32.2
- 1 control-plane + 2 workers, all `t3.small` (2 vCPU, 2 GB), `ap-south-1a`
- `cpu_credits = standard`, 16 GB gp3 root volumes, no NAT / no LB (cheap lab)
- metrics-server 0.8.1, Prometheus + Grafana + node-exporter + kube-state-metrics
- Demo app: `registry.k8s.io/hpa-example`, requests `200m/64Mi`,
  limits `500m/128Mi`, HPA `1->6 @ 50% CPU` (60s scale-down window)

Built with Terraform + Ansible (`k8s-aws-lab`); torn down afterwards with
`./scripts/destroy.sh` so no AWS charges accrue.
