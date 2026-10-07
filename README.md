# Distributed System Load Analysis

Capacity study of a CPU-bound web service (`registry.k8s.io/hpa-example`,
a.k.a. php-apache) on a 3-node kubeadm cluster (1 control-plane + 2 workers,
all `t3.small`, `ap-south-1`). Load generated with **k6 running inside the
cluster** so results reflect service capacity, not laptop bandwidth.

## TL;DR

| Setup | Reliable throughput | Concurrent users* | p95 | Errors |
|-------|--------------------|-------------------|-----|--------|
| Single replica, no scaling | ~4 RPS (~340k req/day theory, mostly errors) | <10 | 5–15s | 26–33% |
| HPA 1->6 @ 50% CPU (final) | **~12 RPS (~1M req/day)** | **~70–100** | ~2.3s | <1% |
| Past ceiling (80–150 VU) | stalls at 9–14 RPS | — | 13–19s | 1–11% |

\* Real users with ~5–10s think time: `users ~= RPS x (response + think)`.

## Contents

- `results/results.md` — full numbers for every run (5 runs + 1 tuning experiment)
- `load-test/` — the k6 capacity profile + Job manifest used for every run
- `manifests/` — final tuned manifests (`deployment.yaml`, `hpa.yaml`, `pdb.yaml`)
- `CLUSTER.md` — infrastructure spec

## Key findings

1. **One unoptimized pod caps at ~4 RPS** and errors from ~20 concurrent users.
   The pod sits pinned at its `500m` CPU limit; more concurrency only queues.
2. **HPA 1->6 triples goodput** to ~12.5 RPS at 30 concurrent users with 0.4%
   errors — the reliable operating envelope (p95 < 3s).
3. **Past saturation the system collapses, not degrades gracefully**: at 80 VUs
   throughput *fell* to 8.8 RPS; at 150 VUs errors hit 11% with 48s max latency.
4. **Naive vertical scaling regressed**: raising limits to 1000m and replicas to
   8 *lowered* throughput (12.5 -> 8.7 RPS, errors 0.4% -> 4.4%) — 8000m burst
   demand vs ~3600m allocatable plus T3 CPU-credit burn. Reverted; node capacity
   must grow before pod limits do.
5. **Reliability was solid**: 0 pod restarts, HPA scaled out/in every run,
   monitoring never dropped. Known gaps: single AZ, no PDB (fixed — see
   `manifests/pdb.yaml`), weak Grafana password, IP-allowlisted SG.

## How to reproduce

```bash
# on the control plane (or any host with cluster access):
# 1. bake the VU level into load-test/k6-capacity.js (RAMP_VU / HOLD_VU)
kubectl -n demo create configmap k6-script \
  --from-file=k6.js=k6-capacity.js --dry-run=client -o yaml | kubectl apply -f -
kubectl -n demo delete job k6 --ignore-not-found --wait=true
kubectl apply -f load-test/k6-job.yaml
kubectl -n demo wait --for=condition=complete job/k6 --timeout=600s
kubectl -n demo logs job/k6 | tail -25
# watch scaling live in another terminal:
kubectl -n demo get hpa php-apache --watch
```

## Infra changes shipped from this study

- `manifests/pdb.yaml` (new): `minAvailable: 1` for php-apache — free
  protection during drains/upgrades.
- `deployment.yaml` / `hpa.yaml`: documented comments pinning `500m` /
  `maxReplicas: 6` as the load-tested sweet spot for 2x `t3.small`, with the
  reasoning so the next person doesn't repeat the failed experiment.
