# flyway-migration

A Claude skill + validator hook for authoring Postgres **Flyway** migrations to a consistent house standard (derived from `buku-services/janus`).

## Contents

| File | Role |
|---|---|
| `SKILL.md` | The **skill** — conventions, checklist, templates. Auto-recalled when writing/editing `db/migration/*.sql`. Teaches the *why* and the *how*. |
| `hooks/validate_migration.sh` | The **hook** — deterministic guardrail. Runs on every Write/Edit of a migration file and flags mechanical violations. |

Skill vs hook: the **skill** shapes the file before it's written (guidance); the **hook** catches what slipped through regardless of whether the skill was recalled (enforcement). Use both.

## Installing the skill

- **User level:** copy this folder to `~/.claude/skills/flyway-migration/`
- **Project level:** copy to `<repo>/.claude/skills/flyway-migration/`

## Wiring the hook

Register `hooks/validate_migration.sh` as a **PostToolUse** hook matching `Write|Edit`, using an absolute path to the script. The exact config block to paste is in the header comment at the top of `hooks/validate_migration.sh` — put it in your project- or user-level Claude config.

The hook only acts on files under a `db/migration/` directory; everything else exits 0 (silent). On a violation it exits 2 and prints the issues to stderr, which Claude Code surfaces as feedback.

## What the hook checks

- Filename `v<14-digit-UTC>__<snake_case>.sql`, and timestamp is the newest in the dir
- No schema qualifier / search-path change; no `BEGIN`/`COMMIT`
- Idempotency: `CREATE TABLE/INDEX IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`
- Timestamps are `TIMESTAMP WITHOUT TIME ZONE NOT NULL` (no `DEFAULT NOW()`, no bare `TIMESTAMP`)
- New tables with `created_at` have an index covering it
- Duplicate `NOT NULL NOT NULL` modifier

## Verify locally

```bash
echo '{"tool_input":{"file_path":"<path-to>/v20260101000000__example.sql"}}' \
  | bash hooks/validate_migration.sh; echo "exit=$?"
```
