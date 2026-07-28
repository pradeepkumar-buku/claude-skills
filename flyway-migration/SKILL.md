---
name: flyway-migration
description: Conventions and checklist for authoring Flyway SQL migrations (Postgres, Flyway-managed schema). Use whenever creating, editing, or reviewing a `.sql` migration under a `db/migration` directory — "add a db migration", "create a migration", "alter a table", "add a column", "new Flyway migration". Derived from the buku-services/janus repo conventions.
---

# Flyway migrations

Schema is **Flyway-managed** with Hibernate `ddl-auto: none` — nothing is auto-created. Every schema change MUST ship as a migration file, or it will not exist in any environment. The application/JPA layer populates timestamp values; the DB does not default them.

Migrations live under: `<module>/src/main/resources/db/migration/` (in janus: `persistence/src/main/resources/db/migration/`).

Flyway config of note:
```yaml
flyway:
  schemas: ${DB_SCHEMA:staging}      # dev = 'development', staging/prod = 'staging'
  sql-migration-prefix: v            # files MUST start with lowercase 'v'
  validate-on-migrate: false         # checksum drift is NOT caught — discipline matters
  ignore-missing-migrations: true
```

## Filename convention (STRICT)

```
v<YYYYMMDDHHMMSS>__<snake_case_description>.sql
```

- Lowercase `v`, a **14-digit UTC timestamp**, **double underscore** `__`, snake_case description.
  - ✅ `v20260707120000__add_idfy_req_resp_to_routing.sql`
  - ❌ `V20260707__addColumns.sql` (uppercase V, 8 digits, camelCase, single `_`)
- Timestamp MUST be **greater than the current max** in the directory — Flyway applies in version order. List the dir and pick a stamp after the latest. (Legacy 12-digit stamps exist; new files are 14-digit.)
- Description is a verb phrase: `create_`, `add_`, `alter_`, `seed_`, `drop_`.

## Never edit an applied migration

Flyway checksums applied migrations. Once a file has run anywhere (dev/staging/prod), treat it as immutable — **add a new migration** instead. Editing an applied file diverges environments (masked here only because `validate-on-migrate: false`).

## No schema qualification

Target schema comes from `flyway.schemas`. Use **unqualified** names.
- ✅ `CREATE TABLE IF NOT EXISTS user_provider_routing (...)`
- ❌ `CREATE TABLE staging.user_provider_routing (...)` / `SET search_path TO staging;`

(Schema-qualified `.sql` files elsewhere are usually ad-hoc *query* helpers, not migrations — don't mirror them.)

## No transaction control

Flyway wraps each migration in its own transaction (Postgres DDL is transactional). Do **not** add `BEGIN;` / `COMMIT;` / `BEGIN TRANSACTION`.

## Idempotency — every statement re-runnable

- `CREATE TABLE IF NOT EXISTS` / `CREATE INDEX IF NOT EXISTS`
- `ALTER TABLE ... ADD COLUMN IF NOT EXISTS`
- `ALTER TABLE ... DROP CONSTRAINT IF EXISTS` **before** re-adding a constraint
- `CREATE EXTENSION IF NOT EXISTS <ext>` at the top when needed (`pgcrypto` for `gen_random_uuid()`, `citext`, `hstore`)
- Seeds/backfills: `INSERT ... ON CONFLICT (<cols>) DO NOTHING`

## Column & object conventions

| Thing | Canonical form |
|---|---|
| UUID primary key | `id VARCHAR(36) PRIMARY KEY DEFAULT gen_random_uuid()` (needs `pgcrypto`) |
| FK id columns | `VARCHAR(36)` + `REFERENCES <table> (<col>)` (add `ON DELETE CASCADE` when the child is owned) |
| **Timestamps** | **`TIMESTAMP WITHOUT TIME ZONE NOT NULL`** — NO `DEFAULT NOW()` (app/JPA sets it), NEVER bare `TIMESTAMP` |
| `created_at` / `updated_at` | both present on every table, in the exact timestamp form above |
| **`created_at` index** | every table gets one: `CREATE INDEX IF NOT EXISTS idx_<table>_created_at ON <table> (created_at);` — or fold `created_at` into a composite `(filter_col, created_at)` when a filtered time-scan is the access pattern (then a standalone index is redundant) |
| JSON columns | `JSONB NOT NULL DEFAULT '{}'::jsonb` (or `'[]'::jsonb`) |
| Named constraints | `CONSTRAINT uq_<table>_<cols> UNIQUE (...)`, `CHECK (...)` |
| Indexes | `idx_<table-or-abbrev>_<cols>`; use a **partial unique index** for conditional uniqueness, e.g. `... WHERE status = 'IN_PROGRESS'` |

## Safe ordering for ALTER + backfill + constraint

Add a NOT NULL column that later gets a unique/constraint in this order so existing rows don't collide:
1. `ADD COLUMN IF NOT EXISTS ... DEFAULT <safe default>`
2. `UPDATE` to backfill correct values
3. `DROP CONSTRAINT IF EXISTS ...` then add the constraint/unique index

## Comment the *why*

SQL comments explain intent and downstream effect (why a constraint, why a partial index, why this backfill order) — not the obvious.

## Pre-write checklist

- [ ] Filename: `v` + 14-digit UTC stamp + `__` + snake_case, stamp **> current max** in the dir
- [ ] No schema qualifier, no `SET search_path`, no `BEGIN/COMMIT`
- [ ] Every DDL statement idempotent (`IF [NOT] EXISTS`, `ON CONFLICT DO NOTHING`)
- [ ] `CREATE EXTENSION IF NOT EXISTS` present for any function used (`gen_random_uuid` → `pgcrypto`)
- [ ] Timestamps are `TIMESTAMP WITHOUT TIME ZONE NOT NULL` — no `DEFAULT NOW()`, no bare `TIMESTAMP`
- [ ] Every new table has `created_at` + `updated_at` AND an index covering `created_at`
- [ ] Constraints/indexes explicitly named
- [ ] No duplicated modifiers (watch for `NOT NULL NOT NULL`)
- [ ] Not editing an already-applied migration
- [ ] Matching JPA entity/`@Column` exists (schema is not auto-generated)

## Template — new table

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS <table_name> (
    id          VARCHAR(36) PRIMARY KEY DEFAULT gen_random_uuid(),
    <col>       VARCHAR(50) NOT NULL,
    status      VARCHAR(20) NOT NULL DEFAULT 'IN_PROGRESS',
    metadata    JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    updated_at  TIMESTAMP WITHOUT TIME ZONE NOT NULL,
    CONSTRAINT uq_<table>_<cols> UNIQUE (<cols>)
);

-- created_at index (standalone; or fold into a composite below and drop this)
CREATE INDEX IF NOT EXISTS idx_<table>_created_at
    ON <table_name> (created_at);

-- composite for the common filtered time-scan (leading filter col also serves time order)
CREATE INDEX IF NOT EXISTS idx_<table>_status_created_at
    ON <table_name> (status, created_at);
```

## Template — add column

```sql
-- Why this column exists / when it's populated.
ALTER TABLE <table_name>
    ADD COLUMN IF NOT EXISTS <col> JSONB;
```

## Verifying locally

The app runs Flyway on boot against `${DB_SCHEMA}`; a malformed migration fails startup. Build/run on the project's required JDK. Never point Flyway at prod from a dev machine.
