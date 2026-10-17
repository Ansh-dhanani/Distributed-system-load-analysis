# Building This Kind of Capacity-Lab Infrastructure From Scratch

> A conceptual guide — no code. It explains *what* to build, *why*, the
> trade-offs between the common options, how much each step matters, and the
> pitfalls to avoid. Pair it with `infra/REBUILD.md` (the runnable steps) and
> `CLUSTER.md` (the exact spec of this lab).

---

## 1. Goal and mindset

**Goal:** take one small, cheap Kubernetes cluster, put a *real* web service on
it, and answer **"how many users can this serve, and where does it break?"**
with a number and a trace for every claim.

**Mindset that makes it work:**

- **One change per experiment.** If you change HPA limits *and* add a cache in
  the same run, you cannot attribute the delta. Hold hardware, VU levels, and
  the k6 script constant.
- **Measure, don't assume.** "Postgres adds 20 ms" is a hypothesis until
  `shop_db_query_seconds` shows it.
- **Make the failure the finding.** The most useful result here is that naive
  vertical scaling *regressed*. Don't hide regressions.
- **Cheap and disposable.** Single AZ, no NAT, no LB, standard CPU credits.
  Everything tears down in one command. If it can't be rebuilt in an hour,
  it's too complex for a lab.
- **Reproducible.** Terraform + Ansible + a pinned AMI + a committed lock file.
  "It worked on my cluster" is not a result.

**What this is NOT:** production. No HA control plane, no multi-AZ, no SLA.
The lessons transfer; the topology does not.

---

## 2. What you are building

```
1 VPC  →  3 EC2 (1 control-plane + 2 workers, t3.small)
        →  kubeadm cluster + Calico CNI + metrics-server
        →  namespace "demo" with the app, HPA, optional Postgres/Redis
        →  optional monitoring namespace (Prometheus, Grafana, Jaeger)
        →  in-cluster k6 Job generating load
```

The **whole-node picture** and exact versions live in `CLUSTER.md`. The
principle: every component earns its place by being necessary to measure
something.

---

## 3. The big decisions (and why)

### 3.1 Kubernetes vs. "just run it on a VM"

| Option | Pros | Cons | When to pick |
|---|---|---|---|
| **kubeadm on EC2** (this lab) | Full control, real K8s semantics, HPA/PDB/rollouts, cheap, reproducible | You own upgrades, CNI, cert rotation | Learning capacity + scaling behaviour |
| **Managed (EKS/GKE/AKS)** | Less ops, HA control plane, cloud integrations | Costly control plane, slower iteration, vendor lock-in | Production or when you need managed add-ons |
| **kind / minikube on a laptop** | Free, instant | No real node limits, no HPA realism, no node-level contention | Dev loop, unit-ish tests only |

**Impact:** High. The whole point of the lab is to observe *node-level* CPU
contention and HPA behaviour. A laptop cluster hides both. Pick managed only if
ops time > money; pick kubeadm when the lesson is the mechanism.

### 3.2 Node size and CPU credits

- **t3.small** (2 vCPU, 2 GB) is the sweet spot for "small but real": cheap,
  enough to run 6 pods at 500m, small enough that you *hit* the ceiling.
- **CPU credits = standard** (not unlimited). This is deliberate: it makes
  T3 credit burn reproducible and observable (Phase 5).
- **Do not** start with t3.medium+ "to be safe" — you will never see the
  collapse. The constraint *is* the experiment.

**Impact:** Very high. Wrong sizing invalidates every number.

### 3.3 Storage

| Option | Use here | Why |
|---|---|---|
| `emptyDir` (Postgres in this lab) | Lab only | No StorageClass/provisioner on a bare kubeadm cluster; simple, disposable |
| PVC + EBS | Production | Durable, survives pod rescheduling |
| hostPath | Never | Ties data to a node; breaks rescheduling |

**Tip:** state clearly in docs that `emptyDir` is a lab shortcut. A reviewer
will otherwise assume you don't know about PVCs.

### 3.4 Networking / exposure

- **No NAT gateway, no load balancer.** SSH + `kubectl` via the public IP of
  the control plane. Saves ~$30-50/mo.
- **Security group:** open 6443 and 22 to *your* IP, not `0.0.0.0/0`. The
  default in this repo is open for convenience — change it.
- **Port-forwards** for UIs (Grafana/Jaeger/Prometheus) instead of Ingress.
  Zero extra infra, fine for a lab.

**Trade-off:** you can't hand a URL to a stakeholder. Acceptable for a lab;
not for a demo to customers.

### 3.5 Container registry

| Option | Pros | Cons |
|---|---|---|
| Docker Hub (public) | Zero config, free pulls | Rate limits, slow from clusters |
| GHCR | Ties to the repo, fine-grained tokens | Private by default → need pull secret |
| ECR | Fast in-region pulls, IAM auth | AWS-specific, extra cost |

**Tip:** make the image public if you can. Private registries need a pull secret
wired into every pod spec — a common source of "ImagePullBackOff" pain.

### 3.6 Database

| Option | When |
|---|---|
| SQLite in-pod | Phase 0 only — per-pod, single writer, inconsistent across replicas |
| PostgreSQL in-cluster (StatefulSet, emptyDir) | Phases 2+ lab — real SQL, real concurrency, still disposable |
| Managed RDS | Production — durability, backups, failover |

**Key insight:** SQLite is not "wrong" for a lab; it is the *baseline* that
makes Postgres's value measurable. Start simple, then upgrade one tier at a time.

### 3.7 Cache

- Redis with LRU eviction (`allkeys-lru`, 128 MB) in front of the hot read path.
- **TTL is a product decision, not just a perf one** (staleness window).
- Measure hit ratio (`shop_cache_events_total`) — a cache with 10% hits is
  worse than no cache (extra hop).

### 3.8 Observability

Three signals, each optional so headline numbers never depend on a collector:

- **Metrics** (Prometheus) — always on in the app (`/metrics`), scrape optional.
- **Logs** (stdout JSON) — always on, zero overhead.
- **Traces** (OTLP → Jaeger) — off unless `OTEL_EXPORTER_OTLP_ENDPOINT` is set.

**Impact:** Tracing libraries add real overhead if always on. Gate them behind
env vars. Also: k6's `--traces-output` does *not* propagate `traceparent`, so
client and server spans are separate traces by default — know this before you
spend an afternoon chasing a "broken" trace.

---

## 4. Step-by-step build, with impact ratings

Rating scale: **[Critical]** must be right or everything downstream is wrong;
**[High]** shapes the result; **[Medium]** matters for fidelity; **[Low]** nice-to-have.

### Step 1 — Cloud account, IAM, budget alert  [Critical]
- Create a dedicated AWS account or at least a dedicated IAM user with a
  billing alarm.
- **Set a budget alert before anything else.** A forgotten cluster bills forever.
- **Tip:** tag every resource with `Project=load-lab` so cleanup is auditable.

### Step 2 — Terraform: VPC + 3 EC2  [Critical]
- VPC with public subnets (no NAT), internet gateway, route table.
- 3 instances: 1 control-plane, 2 workers. Same AZ (latency + cost).
- User-data installs containerd + kubeadm prerequisites.
- **Pin the AMI** (don't use "latest" — reproducibility).
- **Commit the provider lock file** (`.terraform.lock.hcl`).
- **Impact:** this is the foundation; a flaky AMI wastes hours.

### Step 3 — Ansible: kubeadm bootstrap  [Critical]
- Common: packages, containerd, kubeadm/kubelet/kubectl, disable swap.
- Control plane: `kubeadm init`, install CNI (Calico), fetch kubeconfig.
- Workers: `kubeadm join` with the token.
- Addons: metrics-server (patched for insecure TLS in lab).
- **Tip:** make it idempotent — re-running must not break a working cluster.
  Use `creates=` / `changed_when=false` and `kubectl apply` (not `create`).
- **Pitfall:** forgetting to disable swap → kubelet won't start.

### Step 4 — Verify the cluster  [High]
- `kubectl get nodes` → 3 Ready.
- `kubectl top nodes` works (metrics-server).
- A test pod schedules and reaches the internet.
- **Do not proceed to app work until this is green.** Debugging app issues on a
  broken cluster is miserable.

### Step 5 — Package the app  [High]
- Minimal `Dockerfile`: slim base, install deps, copy code, run uvicorn.
- Pin dependency versions (`requirements.txt`).
- Health endpoint (`/health`) and `/metrics` from day one.
- **Tip:** keep the image small; large images slow deploys and pulls in-cluster.

### Step 6 — Write manifests  [High]
- Deployment with resource `requests`/`limits` (this is what HPA and scheduling
  key off — get them right).
- Service (ClusterIP is enough for in-cluster load).
- HPA (min/max replicas, target CPU %).
- PDB (so voluntary disruptions don't kill all pods).
- Readiness/liveness probes pointing at `/health`.
- **Impact:** limits define your ceiling. 500m → ~4 RPS per pod is the whole
  story of this lab.

### Step 7 — Deploy data tier (when ready)  [Medium]
- Postgres StatefulSet (emptyDir in lab, PVC in prod).
- Redis Deployment with LRU + memory cap.
- Wait-for-DB logic in the app (retry init) so pods don't CrashLoop.

### Step 8 — In-cluster load generation  [High]
- Run k6 as a **Job inside the cluster** so the generator is never the
  bottleneck (keep k6 under ~15 m CPU).
- Env-driven VU levels (no file edits per run) → reproducible ladders.
- Export a `SUMMARY` line (p50/p90/p95/p99/RPS/ERR) for easy comparison.
- **Pitfall:** running k6 on your laptop measures your Wi-Fi, not the service.

### Step 9 — Observability  [Medium]
- Scrape `/metrics` with Prometheus; dashboard in Grafana.
- JSON logs to stdout (collected by `kubectl logs`).
- Tracing gated behind an env var.
- **Tip:** keep monitoring optional (`--tags monitoring`) so you can measure its
  cost (Phase 4) and exclude it from headline runs.

### Step 10 — Run the ladder and record  [Critical for the result]
- Same hardware, same script, same VU levels, one change per phase.
- Record: RPS, p50/p95/p99, error %, replicas, CPU/mem, p99 DB time, cache
  hit ratio, and a Jaeger trace ID for the slowest request.
- **Tip:** a run without a recorded trace ID is not a result — you can't defend
  it later.

### Step 11 — Teardown  [Critical for your wallet]
- One script deletes namespaces, cluster-scoped RBAC, terraform destroy, and
  local artefacts, then verifies nothing remains.
- **Never skip this.** A forgotten 3-node cluster bills ~$0.10/hr forever.

---

## 5. Things to keep in mind (guardrails)

1. **One change per phase.** This is the single most important rule.
2. **k6 CPU < ~15 m.** Otherwise the runner is the bottleneck and your
   "capacity" number is a lie.
3. **Tracing off by default.** Zero overhead unless the env var is set.
4. **Resource limits are the experiment.** Don't "fix" them to make numbers
   look good — the regression *is* the lesson.
5. **Standard CPU credits.** Unlimited credits hide contention.
6. **Don't mix experiments.** A CPU-bound app (hpa-example) and a
   latency-bound app (FastAPI) produce incomparable RPS. Label which is which.
7. **State your assumptions.** "emptyDir is a lab shortcut" belongs in the docs.
8. **Reproducibility > cleverness.** Pin AMIs, lock files, and dependency versions.
9. **Budget alert first.** Before `terraform apply`.
10. **Document the non-result.** Phase 5 "did not reproduce" is still a result —
    report it as such, not as evidence either way.

---

## 6. Common pitfalls

| Symptom | Likely cause | Fix |
|---|---|---|
| Pods stuck `Pending` | No schedulable node capacity / wrong limits | `kubectl describe pod`; check allocatable vs requests |
| `ImagePullBackOff` | Private registry without pull secret, or wrong image name | Add pull secret or make image public |
| HPA shows `<unknown>` metrics | metrics-server missing/broken | Patch for insecure TLS; wait for apiservice |
| App CrashLoop on Postgres | DB not ready at boot | Add retry loop in startup (`DB_INIT_RETRIES`) |
| k6 "connection refused" | Service name wrong or app not ready | Check `kubectl get svc`; readiness probe |
| Numbers wildly different run-to-run | Node contention / CPU credits / noisy neighbour | Run at consistent times; note credit balance |
| Traces missing in Jaeger | OTLP wiring or startup ordering | Check exporter env; accept HTTP histograms as fallback |
| Bill shock | Forgot teardown | Automate teardown; set budget alarm |

---

## 7. Cost ballpark (lab, ap-south-1)

- 3 × t3.small on-demand: ~$0.02/hr each → ~$0.06/hr, ~$1.50/day.
- EBS 16 GB × 3: ~$2/mo.
- No NAT, no LB, no EIP beyond control plane: ~$0.
- **Total:** a full day of experimenting costs a few dollars. A forgotten
  cluster costs ~$45/mo. Teardown is not optional.

---

## 8. Recommended reading order for a newcomer

1. `README.md` (TL;DR + architecture)
2. This file (concepts + decisions)
3. `CLUSTER.md` (exact spec)
4. `infra/REBUILD.md` (runnable steps)
5. `apps/demo-shop/PHASE_COMMANDS.md` (how to switch phases)
6. `RESULTS_PHASES.md` (what a finished run looks like)
7. `apps/demo-shop/OBSERVABILITY.md` + `TRACING.md` (signals)
8. `apps/demo-shop/DB_EVOLUTION.md` (data-tier reasoning)
9. `BUSINESS_CAPACITY.md` (translating RPS → users → cost)

---

## 9. Checklist before you call it "done"

- [ ] `terraform apply` → 3 Ready nodes, reproducible.
- [ ] Ansible site.yml runs clean twice (idempotent).
- [ ] `smoke-test.sh` passes locally (SQLite + Postgres/Redis).
- [ ] App deploys via `deploy-app.sh` for phases 1–3.
- [ ] k6 runs in-cluster and prints a `SUMMARY` line.
- [ ] HPA scales up and back down.
- [ ] At least one full ladder recorded with trace IDs.
- [ ] `destroy.sh` leaves zero resources (verify in console).
- [ ] Budget alarm configured.
- [ ] README updated with *your* numbers, not the example's.