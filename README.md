# Distributed System Load Analysis

A **capacity engineering lab**: take one small Kubernetes cluster, apply a
**real** web service to it, and find out *where* it breaks and *why* — one
single-variable change at a time, with a number and a trace to back up every
claim.

Everything is reproducible: the infra is rebuilt with Terraform + Ansible, the
load is generated **from inside the cluster** (so results measure the service,
not your laptop's Wi‑Fi), and one script tears the whole thing down so nothing
keeps billing.

```mermaid
flowchart LR
    Q["❓ How many users<br/>can this serve?"] --> M["📈 Measure"] --> A["🔍 Analyse"] --> F["🔧 Fix one thing"] --> M
    classDef default stroke:#57606a;
```

---

## TL;DR

> Headline numbers are from the **FastAPI demo-shop** live run
> (`RESULTS_PHASES.md`). One small cluster, one change at a time.

| Phase | Reliable throughput | p50 | p95 | Errors |
|---|---|---|---|---|
| 0 · 1 pod, no HPA (SQLite) | ~16.69 RPS @20 VU | 83 ms | 272 ms | 0 % |
| 1 · HPA 2→6 @ 50 % CPU | ~53.49 RPS @60 VU | 84 ms | 271 ms | 0 % |
| 2 · + PostgreSQL | ~16.23 RPS @20 VU | 105 ms | 289 ms | 0 % |
| 3 · + Redis cache | ~15.85 RPS @20 VU | 54 ms | 284 ms | 0 % |

\* Real users with ~5–10 s think time: `users ≈ RPS × (response + think)`.

**Three lessons worth the whole exercise:**

1. **HPA scales the app cleanly** — 2→6 pods take throughput from ~16.69 RPS
   to ~53.49 RPS with 0 % errors; p95 stays flat.
2. **The data tier is the next ceiling** — per-pod SQLite is inconsistent across
   replicas; Postgres fixes correctness, Redis removes the read hotspot.
3. **Measure the hop, don't assume it** — Postgres adds ~20 ms p50; cache cuts
   p50 ~48 % with a 97.8 % hit ratio.

---

## What's in here

A single **real** FastAPI shop (`apps/demo-shop/`) exercised through a phased
capacity ladder (SQLite → Postgres → Redis → observability), on one small
Kubernetes cluster.

```mermaid
flowchart TB
    ROOT(["Distributed-system-load-analysis"])

    ROOT --> LAB["apps/demo-shop/<br/><b>FastAPI shop</b> · PHASED LADDER"]
    ROOT --> OPS["infra/ + monitoring/ + scripts/<br/><b>rebuild · observe · teardown</b>"]

    LAB --> L1["main.py · Dockerfile · requirements"]
    LAB --> L2["k8s/ + phases/ (SQLite→Postgres→Redis)"]
    LAB --> L3["bench/ (pgbench DB sweep)"]
    OPS --> O1["Terraform · Ansible"]
    OPS --> O2["Prometheus · Grafana · Jaeger"]
    OPS --> O3["build-push · run-load · db-bench · destroy"]
    classDef default stroke:#57606a;
```

---

## Architecture

A minimal single-AZ kubeadm cluster. Every workload lives in the `demo`
namespace; monitoring is optional so it can be tagged in/out.

```mermaid
flowchart TB
    subgraph LAB["kubeadm cluster · 1 control-plane + 2 workers · t3.small · ap-south-1a"]
        direction TB

        subgraph NS["namespace: demo"]
            K6["k6 Job<br/>in-cluster load generator"]

            SVC["Service: demo-shop :80"]

            subgraph APPS["demo-shop · HPA 2→6"]
                A1["pod demo-shop<br/>FastAPI :80"]
                A2["pod demo-shop<br/>FastAPI :80"]
            end

            PG[("Postgres<br/>StatefulSet")]
            RD[("Redis<br/>Deployment<br/>128 MB LRU")]

            subgraph OBS["monitoring · optional"]
                PROM["Prometheus :9090"]
                GRAF["Grafana :3000"]
                JAEG["Jaeger :16686 / OTLP :4318"]
            end
        end
    end

    K6 -->|"HTTP"| SVC
    SVC --> A1
    SVC --> A2
    A1 -->|"SQL"| PG
    A1 -->|"GET / SETEX"| RD
    A1 -.->|"OTLP spans"| JAEG
    PROM -.->|"scrape /metrics"| A1
    GRAF -.->|"datasource"| PROM
    classDef default stroke:#57606a;
```

**Simple setup** (no Postgres, no Redis, lightweight monitoring):

```mermaid
flowchart TB
    subgraph LAB["kubeadm cluster · 1 control-plane + 2 workers · t3.small · ap-south-1a"]
        direction TB

        subgraph NS["namespace: demo"]
            K6["k6 Job<br/>in-cluster load generator"]

            SVC["Service: demo-shop :80"]

            subgraph APPS["demo-shop · HPA 2→6"]
                A1["pod demo-shop<br/>FastAPI :80<br/><i>SQLite in-pod</i>"]
                A2["pod demo-shop<br/>FastAPI :80<br/><i>SQLite in-pod</i>"]
            end

            subgraph OBS["monitoring · optional"]
                PROM["Prometheus :9090"]
                GRAF["Grafana :3000"]
            end
        end
    end

    K6 -->|"HTTP"| SVC
    SVC --> A1
    SVC --> A2
    PROM -.->|"scrape /metrics"| A1
    GRAF -.->|"datasource"| PROM
    classDef default stroke:#57606a;
```

Whole-node picture: [CLUSTER.md](CLUSTER.md) · Terraform: `infra/terraform/`.

---

## What happens on one request

Every request gets a **request id**, a latency histogram sample, a JSON log
line, and (when tracing is on) a server span with `k8s.pod`. `/products` is the
hot read path and the first thing the cache phase targets.

```mermaid
sequenceDiagram
    autonumber
    participant U as k6 VU
    participant M as HTTP middleware
    participant H as Route handler
    participant C as Redis
    participant D as DB (SQLite / Postgres)

    U->>M: GET /products?limit&offset
    M->>M: assign request id · start timer + span
    M->>H: call_next()
    H->>C: GET products:limit:offset
    alt cache hit
        C-->>H: cached JSON
    else cache miss
        H->>D: SELECT ... ORDER BY id LIMIT/OFFSET
        D-->>H: rows
        H->>C: SETEX key 10s
    end
    H-->>M: 200 JSON
    M->>M: record metrics · JSON log · span attrs (k8s.pod, http.status)
    M-->>U: response + x-request-id
```

App code: [`apps/demo-shop/main.py`](apps/demo-shop/main.py).

---

## The capacity ladder

Each phase changes **exactly one thing**; hardware, HPA config, k6 script and VU
levels stay fixed so deltas are attributable.

```mermaid
flowchart LR
    P0["<b>Phase 0</b><br/>1 replica, no HPA<br/><i>~16.69 RPS</i>"]
    P1["<b>Phase 1</b><br/>HPA 2→6 @50%<br/><i>~53.49 RPS</i>"]
    P2["<b>Phase 2</b><br/>SQLite → Postgres"]
    P3["<b>Phase 3</b><br/>+ Redis cache"]
    P4["<b>Phase 4</b><br/>+ monitoring cost"]
    P5["<b>Phase 5</b><br/>vertical scale<br/><i>regression ⚠️</i>"]

    P0 --> P1 --> P2 --> P3 --> P4 --> P5

    style P0 fill:#ffe3e3,stroke:#cc0000,color:#7a0000
    style P1 fill:#dcf5dc,stroke:#0a7d0a,color:#0a4d0a
    style P5 fill:#ffe3e3,stroke:#cc0000,color:#7a0000
    classDef default stroke:#57606a;
```

| Phase | Change | Problem it fixes | Tradeoff |
|---|---|---|---|
| 0 · baseline | 1 replica, no HPA | — (the floor) | one pod = one CPU budget |
| 1 · scale out | HPA 2→6, 500m limits | single-pod CPU ceiling | node CPU becomes the limit |
| 2 · external DB | SQLite → PostgreSQL | per-pod DB inconsistency, single writer | network hop, shared node CPU |
| 3 · cache | Redis in front of `/products` | DB read hotspot | staleness ≤ TTL, warm-up cost |
| 4 · observe cost | Prometheus + Grafana + Jaeger | proves monitoring isn't free | steals CPU from a small node |
| 5 · counter-example | limits 1000m, 8 replicas | *(intentionally fails)* | node contention + T3 credits |

Run any phase with one command — see [PHASE_COMMANDS.md](apps/demo-shop/PHASE_COMMANDS.md),
full write-up in [RESULTS_PHASES.md](RESULTS_PHASES.md) and the narrative in
[SHOWCASE.md](SHOWCASE.md).

### Data tier evolution

```mermaid
flowchart LR
    S0["<b>SQLite on pod</b><br/>one DB <i>per replica</i><br/>zero infra · inconsistent across pods"]
    S1["<b>PostgreSQL primary</b><br/>durable · concurrent<br/>network hop · single writer"]
    S2["<b>+ Redis + read replicas</b><br/>read scaling · low tail latency<br/>staleness · invalidation"]
    S3["<b>Sharding</b><br/>write scaling<br/>only if you truly need it"]

    S0 -->|"correctness"| S1
    S1 -->|"read load"| S2
    S2 -->|"write ceiling"| S3
    classDef default stroke:#57606a;
```

Reasoning and cost/benefit per step: [DB_EVOLUTION.md](apps/demo-shop/DB_EVOLUTION.md).

---

## Observability & tracing

Three signals, all optional at runtime so headline throughput numbers never
depend on a collector being up.

```mermaid
flowchart LR
    APP["demo-shop pods"] -->|"/metrics (text)"| PROM["Prometheus"]
    APP -->|"JSON logs → stdout"| LOGS["kubectl logs"]
    APP -->|"OTLP spans"| JAEG["Jaeger"]
    K6["k6 Job"] -.->|"client spans<br/>(--traces-output)"| JAEG
    PROM --> GRAF["Grafana dashboard"]
    classDef default stroke:#57606a;
```

| Signal | Endpoint / source | Enabled by |
|---|---|---|
| Health / readiness | `GET /health` (reports active db + cache) | always |
| Request metrics | `GET /metrics` | always |
| Request logs | stdout JSON (`rid`, `path`, `status`, `latency_ms`, `pod`) | always |
| DB query timing | `shop_db_query_seconds` histogram | always |
| Cache hit ratio | `shop_cache_events_total{result}` | `REDIS_URL` set |
| Distributed traces | OTLP → Jaeger | `OTEL_EXPORTER_OTLP_ENDPOINT` set |
| App scrape | Prometheus job for pods `app=demo-shop` | monitoring playbook |

UIs (port-forward): Prometheus `:9090`, Grafana `:3000` (`admin/admin`),
Jaeger `:16686`, app `:8080`.

> **Tracing caveat:** k6's built-in `--traces-output` emits k6's *own* spans but
> does **not** propagate `traceparent` to the request, so the k6 span and the
> app span are two separate traces by default. The app-side waterfall
> (route → `db.*` → `work.*`) is complete either way — which is what the phase
> analysis uses. Details: [TRACING.md](apps/demo-shop/TRACING.md).

Deep dives: [OBSERVABILITY.md](apps/demo-shop/OBSERVABILITY.md) ·
[TRACING.md](apps/demo-shop/TRACING.md).

---

## Quick start

### Lifecycle at a glance

```mermaid
flowchart LR
    TF["terraform apply<br/>VPC + 3 EC2 nodes"] --> INV["edit inventory.yml"]
    INV --> ANS["ansible-playbook site.yml"]
    ANS --> IMG["build-push.sh<br/>demo-shop image"]
    IMG --> DEP["kubectl apply<br/>SQLite → Postgres → Redis"]
    DEP --> LOAD["run-load.sh<br/>db-bench.sh"]
    LOAD --> OBS["port-forward Grafana / Jaeger"]
    OBS --> DEST["destroy.sh<br/>delete everything"]
    classDef default stroke:#57606a;
```

### 0 · Local check (no AWS needed)
Prove the app works before touching any cloud infra:
```bash
./scripts/smoke-test.sh        # builds the image, exercises SQLite AND Postgres+Redis
docker compose up --build      # or run the full local stack on http://localhost:8080
```

### 1 · Prerequisites
Terraform, Ansible, `kubectl`, Docker, Python 3 (for the tracing patch), AWS creds.

### 2 · Rebuild the lab
```bash
cd infra/terraform && terraform init && terraform apply   # prints node IPs
cd ../ansible && cp inventory.example.yml inventory.yml    # set the 3 IPs
ansible-playbook -i inventory.yml site.yml                 # kubeadm + Calico + metrics
# optional: add monitoring
ansible-playbook -i inventory.yml site.yml --tags monitoring

export KUBECONFIG=$PWD/../../kubeconfig                    # ansible fetches this for you
kubectl get nodes                                          # should list 3 Ready nodes
```
Full guide: [infra/REBUILD.md](infra/REBUILD.md).
> The kubeconfig points at the control plane's **public** IP on `:6443`, which the
> security group opens to `allowed_ssh_cidr` (default `0.0.0.0/0`). Set that to
> your own IP before applying so the API and SSH aren't world-open.

### 3 · Build & deploy the app
`build-push.sh` works with **any** registry (derived from `IMAGE`) and
`deploy-app.sh` renders that image into the manifests, so nothing is hardcoded.
```bash
# Docker Hub (public repo)
IMAGE=<user>/demo-shop:latest \
  DOCKERHUB_USERNAME=<user> DOCKERHUB_TOKEN=<pat> ./scripts/build-push.sh

# ...or GitHub Container Registry (username defaults to the image owner)
IMAGE=ghcr.io/<owner>/demo-shop:latest \
  GHCR_TOKEN=<pat-with-write:packages> ./scripts/build-push.sh

The default image (`anshdhanani/demo-shop:latest`) is published **and public**, so
the commands below work with no `IMAGE` set and no login:
```bash
./scripts/deploy-app.sh 1                                 # uses the published default
IMAGE=<user>/demo-shop:latest ./scripts/deploy-app.sh 1   # SQLite in-pod (creates `demo` ns)
IMAGE=<user>/demo-shop:latest ./scripts/deploy-app.sh 2   # + Postgres
IMAGE=<user>/demo-shop:latest ./scripts/deploy-app.sh 3   # + Redis
```
```
A **private** registry (ghcr packages are private by default) needs a pull secret
the script can create for you:
```bash
IMAGE=ghcr.io/<owner>/demo-shop:latest \
  PULL_SECRET_USER=<owner> PULL_SECRET_TOKEN=<pat> ./scripts/deploy-app.sh 3
```
`kubectl apply -f apps/demo-shop/k8s/deployment.yaml` still works if you keep the
default image. Verify: `kubectl -n demo port-forward svc/demo-shop 8080:80` → open
`http://localhost:8080` (UI) or `curl localhost:8080/health`.

### 4 · Generate load
```bash
./scripts/run-load.sh                 # app-level capacity, prints a summary
TRACE=true ./scripts/run-load.sh      # + client→app→DB traces into Jaeger
./scripts/db-bench.sh                 # DB-only sweep (rows × clients) via pgbench
```
`run-load.sh` runs k6 **as an in-cluster Job** so the runner is never the
bottleneck. Watch scaling live: `kubectl -n demo get hpa demo-shop --watch`.
`TARGET_URL=http://...` overrides the target.

### 5 · Observe
```bash
kubectl -n demo port-forward svc/grafana 3000:3000     # dashboard (admin/admin)
kubectl -n demo port-forward svc/jaeger  16686:16686   # traces
kubectl -n demo port-forward svc/prometheus 9090:9090  # raw PromQL
```

### 6 · Destroy everything (no leftover charges)
```bash
./scripts/destroy.sh   # namespaces + cluster-scoped RBAC + terraform destroy + local artefacts
```

---

## Results

For the **demo-shop** phases, record per run: RPS, p50/p95/p99, error %,
replicas, CPU/mem, **p99 DB query time**, **cache hit ratio**, and a Jaeger trace
id for the slowest request. Table to fill: [RESULTS_PHASES.md](RESULTS_PHASES.md).
Measured numbers and analysis: [RESULTS_PHASES.md](RESULTS_PHASES.md).

---

## Repository map

```
Distributed-system-load-analysis/
├── README.md                     ← you are here
├── CLUSTER.md                    infrastructure spec (nodes, versions, limits)
├── RESULTS_PHASES.md             phased ladder + results table to fill
├── SHOWCASE.md                   narrative version of the ladder
├── docker-compose.yml            local stack (app + Postgres + Redis)
│
├── apps/demo-shop/               ← the REAL app (FastAPI)
│   ├── main.py                   API, metrics, JSON logs, optional OTLP tracing
│   ├── Dockerfile · requirements.txt
│   ├── k8s/deployment.yaml       Phase 1: SQLite in-pod (+ namespace, svc, HPA)
│   ├── phases/phase2-postgres.yaml   Phase 2: Postgres StatefulSet
│   ├── phases/phase3-cache.yaml      Phase 3: + Redis
│   ├── load/k6-realistic.js      browse → cart → checkout flow
│   ├── bench/                    pgbench DB-only sweep (schema, script, job)
│   ├── DB_EVOLUTION.md · PHASE_COMMANDS.md
│   └── OBSERVABILITY.md · TRACING.md
│
├── load-test/                    k6 Job manifest
├── monitoring/                   prometheus.yaml · grafana.yaml · jaeger.yaml
│
├── infra/
│   ├── REBUILD.md
│   ├── terraform/                VPC + 3× t3.small (standard CPU credits)
│   └── ansible/                  site.yml + playbooks 00/10/20/30
│
└── scripts/
    ├── build-push.sh             build + push the demo-shop image (IMAGE=...)
    ├── deploy-app.sh             deploy a phase with the chosen IMAGE
    ├── smoke-test.sh             local end-to-end check (SQLite + Postgres/Redis)
    ├── run-load.sh               run k6 in-cluster (TRACE=true for Jaeger)
    ├── db-bench.sh               pgbench sweep across rows × clients
    └── destroy.sh                tear down EVERYTHING
```

---

## Key findings

1. **HPA scales the FastAPI app cleanly** — 2→6 pods take it from ~16.69 RPS
   (1 pod) to ~53.49 RPS @60 VU with 0 % errors; p95 stays ~271 ms.
2. **Postgres adds a network hop** but fixes correctness (per-pod SQLite was
   inconsistent across replicas); p50 rises ~20 ms, RPS ~16.23 @20 VU.
3. **Redis cache cuts p50 ~48 %** (105 → 54 ms) on `/products` with a 97.8 %
   hit ratio; cart/checkout are unaffected (no cache).
4. **The data tier is the ceiling.** SQLite is per-pod and single-writer;
   Postgres fixes correctness, Redis removes the read hotspot.
5. **Reliability held**: 0 pod restarts, HPA scaled every run, monitoring never
   dropped.

---

## Design decisions & guardrails

- **k6 runs in-cluster** so the generator is never the bottleneck (kept < 15 m CPU).
- **One change per phase**, same hardware and VU levels, for attributable deltas.
- **Prometheus/Grafana/Jaeger are optional** (`--tags monitoring`) so you can
  measure their cost (Phase 4) *and* exclude them from headline runs.
- **Tracing is off by default** — zero overhead unless `OTEL_EXPORTER_OTLP_ENDPOINT` is set.
- **Postgres uses `emptyDir`** in the lab (no StorageClass/provisioner on this
  cluster); a real deployment would use a PVC.
- **`cpu_credits = standard`** on the T3 nodes, so the documented credit-burn
  behaviour is reproducible.

## Known limitations

- Single AZ, single control-plane, no NAT/LB — a cheap lab, not production.
- Demo-shop phases 0–3 have **measured** data; phases 4–5 are a ready-to-run
  framework (see `RESULTS_PHASES.md`).
- App opens **one DB connection per request** (no pool) — this is deliberate; it
  is the reason PgBouncer is the first Phase-2 recommendation.
- k6 doesn't propagate trace context into requests by default (see caveat above).

---

## Credits & teardown

Built with Terraform + Ansible (`k8s-aws-lab`). **Always run `./scripts/destroy.sh`
when finished** — it removes in-cluster resources, the AWS VPC/nodes, and local
artefacts, then verifies nothing is left.
