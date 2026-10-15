# One-command phase switches

Only the data tier changes between phases — infra, HPA, and the k6 script stay identical
so the numbers are comparable.

The app image is **not hardcoded** in the manifests any more: `scripts/deploy-app.sh`
renders it from the `IMAGE` variable, so you build+push **one** image and point at it.

```bash
IMAGE=myuser/demo-shop:v2 ./scripts/deploy-app.sh <phase>
```

## Phase 1 — SQLite inside the pod
```bash
./scripts/deploy-app.sh 1
```

## Phase 2 — PostgreSQL primary (external to the app pods)
```bash
./scripts/deploy-app.sh 2
```

## Phase 3 — PostgreSQL + Redis cache
```bash
./scripts/deploy-app.sh 3        # applies Postgres, then adds Redis + env
```

> `kubectl apply -f` still works if you keep the default image
> (`anshdhanani/demo-shop:latest`); the wrapper is only needed to override it.

## Verify what is active
```bash
kubectl -n demo port-forward svc/demo-shop 8080:80 && curl localhost:8080/health
# {"ok":true,"db":"postgres","cache":true}
```

## Revert to Phase 1
```bash
kubectl -n demo delete statefulset postgres svc postgres secret postgres-auth
kubectl -n demo delete deploy redis svc redis
./scripts/deploy-app.sh 1
```

Notes:
- One image serves all phases: `requirements.txt` always ships `psycopg`, so Phase 2/3
  needs no rebuild — only the `DATABASE_URL` / `REDIS_URL` env changes.
- Seed size is controlled with `SEED_N` (default 2000); Postgres seeds via `generate_series`,
  so `SEED_N=1000000` is feasible.
- `/products` is paginated (`?limit=&offset=`, max 200) to avoid unbounded payloads.
