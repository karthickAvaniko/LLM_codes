-- Avaniko gateway schema — api_keys, users, sessions.
-- Reverse-engineered from every query in main.py against these three tables
-- (2026-09-07): no CREATE TABLE for them exists in main.py itself (only
-- extraction_cache auto-creates there), and avaniko_db.sql is gitignored /
-- was never committed — a fresh deploy with no prior backup has nothing to
-- apply until this file exists. Apply once, on first deploy:
--   mysql avaniko < /workspace/gateway/schema.sql

CREATE TABLE IF NOT EXISTS api_keys (
  key_hash     VARCHAR(64)  PRIMARY KEY,
  id           VARCHAR(32),
  name         VARCHAR(255),
  email        VARCHAR(255),
  created      VARCHAR(64),
  active       TINYINT(1)   DEFAULT 1,
  expires      VARCHAR(64)  NULL,
  rpm_limit    INT          DEFAULT 60,
  daily_limit  INT          DEFAULT 5000,
  requests     INT          DEFAULT 0,
  tokens_in    BIGINT       DEFAULT 0,
  tokens_out   BIGINT       DEFAULT 0,
  last_used    VARCHAR(64)  NULL,
  self_service TINYINT(1)   DEFAULT 0,
  raw_key      VARCHAR(64),
  thinking     TINYINT(1)   DEFAULT 0,
  ocr_enabled  TINYINT(1)   DEFAULT 1,
  INDEX (email)
) CHARACTER SET utf8mb4;

CREATE TABLE IF NOT EXISTS users (
  email    VARCHAR(255) PRIMARY KEY,
  name     VARCHAR(255),
  pw_hash  VARCHAR(255),
  created  VARCHAR(64),
  active   TINYINT(1) DEFAULT 1
) CHARACTER SET utf8mb4;

CREATE TABLE IF NOT EXISTS sessions (
  token_hash VARCHAR(64) PRIMARY KEY,
  email      VARCHAR(255),
  created    VARCHAR(64),
  expires    DOUBLE,
  INDEX (email)
) CHARACTER SET utf8mb4;
