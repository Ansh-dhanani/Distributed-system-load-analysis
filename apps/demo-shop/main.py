import contextlib
import os
import random
import sqlite3
import time
import uuid
import json
import logging

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import HTMLResponse, PlainTextResponse
from pydantic import BaseModel

# ---------------------------------------------------------------------------
# Logging: structured JSON to stdout (collected by kubectl logs / node-exporter)
# ---------------------------------------------------------------------------
logging.basicConfig(level=logging.INFO, format="%(message)s")
log = logging.getLogger("demo-shop")


def log_event(**kw):
    log.info(json.dumps(kw, default=str))


# ---------------------------------------------------------------------------
# Metrics: prometheus_client (scraped by the lab Prometheus)
# ---------------------------------------------------------------------------
from prometheus_client import Counter, Histogram, generate_latest, CONTENT_TYPE_LATEST

REQUESTS = Counter("shop_requests_total", "HTTP requests", ["endpoint", "method", "status"])
LATENCY = Histogram(
    "shop_request_latency_seconds", "End-to-end request latency", ["endpoint"]
)
DB_QUERY = Histogram("shop_db_query_seconds", "DB query time", ["op"])
CACHE = Counter("shop_cache_events_total", "Cache hits/misses", ["result"])

# ---------------------------------------------------------------------------
# Tracing (optional): only active when OTEL_EXPORTER_OTLP_ENDPOINT is set
# ---------------------------------------------------------------------------
TRACER = None
if os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT"):
    from opentelemetry import trace
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor

    # service.name is what shows up in Jaeger (otherwise "unknown_service").
    _provider = TracerProvider(resource=Resource.create({"service.name": "demo-shop"}))
    _provider.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
    trace.set_tracer_provider(_provider)
    TRACER = trace.get_tracer("demo-shop")

app = FastAPI()

# ---------------------------------------------------------------------------
# Storage: SQLite (default) or PostgreSQL (DATABASE_URL), chosen by env
# ---------------------------------------------------------------------------
DATABASE_URL = os.getenv("DATABASE_URL")
DB_PATH = os.getenv("DB_PATH", "/data/shop.db")
SEED = int(os.getenv("SEED_N", "2000"))
PAGE_SIZE = int(os.getenv("PAGE_SIZE", "50"))

REDIS_URL = os.getenv("REDIS_URL")
r = None
if REDIS_URL:
    try:
        import redis

        r = redis.from_url(REDIS_URL)
    except Exception:
        r = None

PG = bool(DATABASE_URL)

if PG:
    import psycopg
    from psycopg.rows import dict_row

    def db():
        return psycopg.connect(DATABASE_URL, row_factory=dict_row)

    P = "%s"
else:

    def db():
        c = sqlite3.connect(DB_PATH)
        c.row_factory = sqlite3.Row
        return c

    P = "?"


@contextlib.contextmanager
def db_cursor():
    """Works for BOTH backends: sqlite3.Cursor has no __enter__, psycopg's does."""
    conn = db()
    cur = conn.cursor()
    try:
        yield conn, cur
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        try:
            cur.close()
        finally:
            conn.close()


def timed_db(op):
    """Context manager: records DB query duration and emits an OTEL span when tracing is on."""
    import contextlib

    @contextlib.contextmanager
    def _cm():
        from opentelemetry import trace as _trace

        _tracer = _trace.get_tracer("demo-shop")
        t0 = time.perf_counter()
        with _tracer.start_as_current_span(f"db.{op}") as span:
            span.set_attribute("db.system", "postgresql" if PG else "sqlite")
            span.set_attribute("db.operation", op)
            try:
                yield
            finally:
                dt = time.perf_counter() - t0
                span.set_attribute("db.duration_ms", round(dt * 1000, 3))
                DB_QUERY.labels(op=op).observe(dt)

    return _cm()


def simulated_work(name, lo, hi):
    """Emits a span around simulated work so the trace shows where time goes."""
    import contextlib

    @contextlib.contextmanager
    def _cm():
        from opentelemetry import trace as _trace

        _tracer = _trace.get_tracer("demo-shop")
        with _tracer.start_as_current_span(f"work.{name}") as span:
            t0 = time.perf_counter()
            try:
                yield
            finally:
                span.set_attribute("work.duration_ms", round((time.perf_counter() - t0) * 1000, 3))

    return _cm()


def init():
    if PG:
        with db_cursor() as (conn, cur):
            # Serialize seeding across replicas (two pods can start at once and
            # would otherwise both see an empty table and double-seed).
            cur.execute("SELECT pg_advisory_xact_lock(4242)")
            cur.execute(
                "CREATE TABLE IF NOT EXISTS products"
                "(id SERIAL PRIMARY KEY, name TEXT, price REAL, stock INTEGER)"
            )
            cur.execute(
                "CREATE TABLE IF NOT EXISTS carts"
                "(user_id TEXT, product_id INTEGER, qty INTEGER)"
            )
            cur.execute("CREATE INDEX IF NOT EXISTS idx_carts_user ON carts(user_id)")
            cur.execute("SELECT COUNT(*) AS n FROM products")
            if cur.fetchone()["n"] == 0:
                cur.execute(
                    "INSERT INTO products(name,price,stock) "
                    "SELECT 'Item-' || g, random()*199 + 1, floor(random()*1000)::int "
                    "FROM generate_series(1, %s) g",
                    (SEED,),
                )
        return

    db_dir = os.path.dirname(DB_PATH)
    if db_dir:
        os.makedirs(db_dir, exist_ok=True)
    c = db()
    c.execute(
        "CREATE TABLE IF NOT EXISTS products"
        "(id INTEGER PRIMARY KEY,name TEXT,price REAL,stock INTEGER)"
    )
    c.execute(
        "CREATE TABLE IF NOT EXISTS carts"
        "(user_id TEXT,product_id INTEGER,qty INTEGER)"
    )
    c.execute("CREATE INDEX IF NOT EXISTS idx_carts_user ON carts(user_id)")
    if c.execute("SELECT COUNT(*) FROM products").fetchone()[0] == 0:
        c.executemany(
            "INSERT INTO products(name,price,stock) VALUES (?,?,?)",
            [
                (f"Item-{i}", round(random.uniform(1, 200), 2), random.randint(0, 1000))
                for i in range(SEED)
            ],
        )
    c.commit()
    c.close()


@app.on_event("startup")
def startup():
    init()
    log_event(event="startup", db="postgres" if PG else "sqlite", cache=bool(r),
              seed=SEED, tracing=bool(TRACER), pod=os.getenv("HOSTNAME"))


# ---------------------------------------------------------------------------
# Middleware: request id, latency, logs, metrics
# ---------------------------------------------------------------------------
@app.middleware("http")
async def observe(request: Request, call_next):
    rid = request.headers.get("x-request-id") or uuid.uuid4().hex[:12]
    t0 = time.perf_counter()
    status = 500
    try:
        response = await call_next(request)
        status = response.status_code
        response.headers["x-request-id"] = rid
        return response
    finally:
        dt = time.perf_counter() - t0
        ep = request.url.path
        REQUESTS.labels(endpoint=ep, method=request.method, status=str(status)).inc()
        LATENCY.labels(endpoint=ep).observe(dt)
        # attach node/pod + request id to the active trace span (if tracing)
        from opentelemetry import trace as _t

        span = _t.get_current_span()
        if span is not None:
            span.set_attribute("k8s.pod", os.getenv("HOSTNAME", "unknown"))
            span.set_attribute("request.id", rid)
            span.set_attribute("http.status", status)
        log_event(
            event="request",
            rid=rid,
            method=request.method,
            path=ep,
            status=status,
            latency_ms=round(dt * 1000, 2),
            pod=os.getenv("HOSTNAME"),
        )


# Instrument AFTER the custom middleware: the last-registered ASGI middleware is
# the outermost, so the OTel server span wraps `observe` and stays active while
# it sets k8s.pod / request.id / http.status (otherwise those land on an ended span).
if TRACER:
    FastAPIInstrumentor.instrument_app(app)


# ---------------------------------------------------------------------------
# API
# ---------------------------------------------------------------------------
@app.get("/health")
def health():
    try:
        with db_cursor() as (conn, cur):
            cur.execute("SELECT 1")
        return {"ok": True, "db": "postgres" if PG else "sqlite", "cache": bool(r)}
    except Exception as e:
        raise HTTPException(503, str(e))


@app.get("/metrics", response_class=PlainTextResponse)
def metrics():
    return PlainTextResponse(generate_latest(), media_type=CONTENT_TYPE_LATEST)


@app.get("/", response_class=HTMLResponse)
def home():
    with timed_db("count"):
        with db_cursor() as (conn, cur):
            cur.execute("SELECT COUNT(*) AS n FROM products")
            total = cur.fetchone()["n"]
    with timed_db("home_list"):
        with db_cursor() as (conn, cur):
            cur.execute(f"SELECT * FROM products ORDER BY id LIMIT {P}", (PAGE_SIZE,))
            rows = cur.fetchall()
    items = "".join(
        f"<li>{p['name']} — ${float(p['price']):.2f} (stock {p['stock']})</li>" for p in rows
    )
    return f"""<html><body>
<h1>Demo Shop</h1>
<p>DB: {"postgres" if PG else "sqlite"} | cache: {"on" if r else "off"} | {total} products</p>
<p>pod: {os.getenv("HOSTNAME")} | <a href="/metrics">metrics</a></p>
<ul>{items}</ul>
<p>POST /cart with JSON {{"user_id":"u1","product_id":1,"qty":1}}, then POST /checkout/u1</p>
</body></html>"""


@app.get("/products")
def products(limit: int = PAGE_SIZE, offset: int = 0):
    limit = max(1, min(limit, 200))
    offset = max(0, offset)
    key = f"products:{limit}:{offset}"
    if r:
        try:
            v = r.get(key)
        except Exception:
            CACHE.labels(result="error").inc()
            v = None
        if v:
            CACHE.labels(result="hit").inc()
            with simulated_work("cache_hit", 0.0, 0.0):
                pass
            return {"items": json.loads(v.decode()), "cached": True}
        CACHE.labels(result="miss").inc()
    with timed_db("products_list"):
        with db_cursor() as (conn, cur):
            cur.execute(
                f"SELECT * FROM products ORDER BY id LIMIT {P} OFFSET {P}", (limit, offset)
            )
            rows = [dict(x) for x in cur.fetchall()]
    if r:
        try:
            r.setex(key, 10, json.dumps(rows, default=str))
        except Exception:
            CACHE.labels(result="error").inc()
    with simulated_work("products_list", 0.05, 0.15):
        time.sleep(random.uniform(0.05, 0.15))  # simulated real work
    return {"items": rows, "cached": False}


@app.get("/products/{pid}")
def product(pid: int):
    with timed_db("product_get"):
        with db_cursor() as (conn, cur):
            cur.execute(f"SELECT * FROM products WHERE id={P}", (pid,))
            row = cur.fetchone()
    if not row:
        raise HTTPException(404)
    with simulated_work("product_get", 0.03, 0.1):
        time.sleep(random.uniform(0.03, 0.1))
    return dict(row)


class CartIn(BaseModel):
    user_id: str
    product_id: int
    qty: int = 1


@app.post("/cart")
def cart(i: CartIn):
    with timed_db("cart_insert"):
        with db_cursor() as (conn, cur):
            cur.execute(
                f"INSERT INTO carts(user_id,product_id,qty) VALUES ({P},{P},{P})",
                (i.user_id, i.product_id, i.qty),
            )
    return {"added": True}


@app.post("/checkout/{user_id}")
def checkout(user_id: str):
    with timed_db("checkout"):
        with db_cursor() as (conn, cur):
            cur.execute(f"SELECT * FROM carts WHERE user_id={P}", (user_id,))
            items = cur.fetchall()
            cur.execute(f"DELETE FROM carts WHERE user_id={P}", (user_id,))
    with simulated_work("checkout_process", 0.1, 0.3):
        time.sleep(random.uniform(0.1, 0.3))
    return {"ordered": len(items)}
