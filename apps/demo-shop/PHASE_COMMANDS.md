# One-command phase switches

Only the data tier changes between phases — infra, HPA, and the k6 script stay identical
so the numbers are comparable.

## Phase 1 — SQLite inside the pod
```bash
kubectl apply -f apps/demo-shop/k8s/deployment.yaml
```

## Phase 2 — PostgreSQL primary (external to the app pods)
```bash
kubectl apply -f apps/demo-shop/phases/phase2-postgres.yaml
```

## Phase 3 — PostgreSQL + Redis cache
```bash
kubectl apply -f apps/demo-shop/phases/phase2-postgres.yaml   # includes Postgres
kubectl apply -f apps/demo-shop/phases/phase3-cache.yaml      # adds Redis + env
```

## Verify what is active
```bash
kubectl -n demo port-forward svc/demo-shop 8080:80 && curl localhost:8080/health
# {"ok":true,"db":"postgres","cache":true}
```

## Revert to Phase 1
```bash
kubectl -n demo delete statefulset postgres svc postgres secret postgres-auth
kubectl -n demo delete deploy redis svc redis
kubectl apply -f apps/demo-shop/k8s/deployment.yaml
```

Notes:
- The image must be rebuilt with `psycopg` (`apps/demo-shop/requirements.txt`) for Phase 2/3.
- Seed size is controlled with `SEED_N` (default 2000); Postgres seeds via `generate_series`,
  so `SEED_N=1000000` is feasible.
- `/products` is paginated (`?limit=&offset=`, max 200) to avoid unbounded payloads.
