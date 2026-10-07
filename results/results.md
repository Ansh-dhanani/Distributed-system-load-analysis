# Load-test results (k6, run inside the cluster as a Job in namespace `demo`)

App: `registry.k8s.io/hpa-example` (burns CPU per request by design).
Requests `200m`, limits `500m CPU / 128Mi`, HPA `1->6 @ 50% CPU`.
k6 profile: ramp + hold + ramp-down, `sleep(0.1)` between requests (aggressive users).
0 pod restarts in every run. k6 runner never exceeded ~15m CPU (not the bottleneck).

## A. Unoptimized: HPA pinned to 1 replica (no scale-out)

| VUs | Duration | RPS | p50 | p90 | p95 | max | Errors |
|-----|----------|-----|-----|-----|-----|-----|--------|
| 20 | 3m00s | 3.72 | 2.98s | 5.13s | 5.50s | 6.8s | 25.97% (174/670) |
| 50 | 3m00s | 3.95 | 6.57s | 13.99s | 15.14s | 18.07s | 32.81% (234/713) |

Pod sat pinned at its 500m CPU limit (`kubectl top` showed exactly 500m).
RPS ceiling per pod: ~4 RPS. Extra concurrency only queues.

## B. Scalable: HPA 1->6 enabled

| VUs | Duration | RPS | p50 | p90 | p95 | max | Errors | Replicas/CPU |
|-----|----------|-----|-----|-----|-----|-----|--------|--------------|
| 30 (standard 1m/3m/1m) | 5m00s | 12.52 | 1.14s | 2.03s | 2.31s | 4.64s | 0.39% (15/3758) | scaled out |
| 80 | 3m02s | 8.82 | 5.34s | 16.42s | 18.88s | 21.56s | 0.74% (12/1609) | 6/6 @ 130% |
| 150 | 3m17s | 14.20 | 5.05s | 11.80s | 12.69s | 48.50s | 11.25% (315/2798, +8 interrupted) | 6/6 @ 150% |

## C. Tuning experiment (reverted): limits 500m->1000m, maxReplicas 6->8

| VUs | Duration | RPS | p50 | p90 | p95 | max | Errors | Replicas/CPU |
|-----|----------|-----|-----|-----|-----|-----|--------|--------------|
| 30 (standard) | 5m00s | 8.72 | 0.88s | 3.68s | 6.64s | 21.59s | 4.43% (116/2616) | 8/8 @ 202% |

WORSE than the untuned 30VU run (12.52 RPS, 0.39%). 8 pods x 1000m = 8000m
burst demand vs ~3600m allocatable on 2x t3.small -> CPU contention, plus
T3 `standard` CPU-credit burn after ~25 min of sustained load across the
session. Reverted to 500m / max 6 (commit history in k8s-aws-lab), kept the
new PodDisruptionBudget. Lesson: raise node capacity before pod limits.

## D. Cluster state after runs

- Nodes (t3.small): never saturated at the moment of sampling (workers 3-19%
  CPU post-run); the binding constraint was pod CPU limits, then node
  contention at 8 replicas.
- Monitoring (Prometheus 15 targets, Grafana) healthy throughout.
- HPA scaled 1->N on every run and back to 1 afterwards (60s scale-down window).
