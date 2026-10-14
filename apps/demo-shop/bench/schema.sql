-- Schema for the shop tables so pgbench can exercise the same workload
-- that the FastAPI app issues (see apps/demo-shop/main.py).
CREATE TABLE IF NOT EXISTS products (
  id    SERIAL PRIMARY KEY,
  name  TEXT,
  price REAL,
  stock INTEGER
);
CREATE TABLE IF NOT EXISTS carts (
  user_id    TEXT,
  product_id INTEGER,
  qty        INTEGER
);
CREATE INDEX IF NOT EXISTS idx_carts_user ON carts(user_id);
CREATE INDEX IF NOT EXISTS idx_products_name ON products(name);
