#!/usr/bin/env bash
# Flyway migration validator — Claude Code PostToolUse hook (Write|Edit).
#
# Wire it up (project or user settings.json):
#   {
#     "hooks": {
#       "PostToolUse": [
#         { "matcher": "Write|Edit",
#           "hooks": [ { "type": "command",
#                        "command": "bash <abs-path>/flyway-migration/hooks/validate_migration.sh" } ] }
#       ]
#     }
#   }
#
# Reads the tool-call JSON on stdin, extracts the target path, and — only for files
# under a db/migration directory — checks the house conventions. Emits reminders on
# stderr and exits 2 so Claude Code surfaces them as feedback. Non-migration files exit 0.

set -euo pipefail

input="$(cat)"

# Extract file path (jq if present, else a portable python fallback).
path=""
if command -v jq >/dev/null 2>&1; then
  path="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null || true)"
fi
if [ -z "$path" ] && command -v python3 >/dev/null 2>&1; then
  path="$(printf '%s' "$input" | python3 -c 'import sys,json;d=json.load(sys.stdin).get("tool_input",{});print(d.get("file_path") or d.get("path") or "")' 2>/dev/null || true)"
fi

# Only act on Flyway migration files.
case "$path" in
  *db/migration/*.sql) : ;;
  *) exit 0 ;;
esac
[ -f "$path" ] || exit 0

base="$(basename "$path")"
dir="$(dirname "$path")"
issues=()

# 1) Filename: v + 14-digit UTC stamp + __ + snake_case
if ! printf '%s' "$base" | grep -Eq '^v[0-9]{14}__[a-z0-9_]+\.sql$'; then
  issues+=("naming: '$base' must match v<14-digit-UTC>__<snake_case>.sql (lowercase v, double underscore).")
fi

# 2) Timestamp must be greater than the current max in the directory
stamp="$(printf '%s' "$base" | grep -oE '^v[0-9]{14}' | tr -d 'v' || true)"
if [ -n "$stamp" ]; then
  max="$(ls -1 "$dir" 2>/dev/null | grep -oE '^v[0-9]{14}' | tr -d 'v' | sort | tail -1 || true)"
  if [ -n "$max" ] && [ "$stamp" \< "$max" ]; then
    issues+=("ordering: timestamp $stamp is not the newest (current max $max) — Flyway applies in version order.")
  fi
fi

content="$(cat "$path")"

# 3) No schema qualification / search_path
if printf '%s' "$content" | grep -Eiq '\b(staging|development|public)\.[a-z_]|set +search_path'; then
  issues+=("schema: remove schema qualifiers / SET search_path — migrations run against \${DB_SCHEMA}.")
fi

# 4) No transaction control (Flyway wraps each migration)
if printf '%s' "$content" | grep -Eiq '^\s*(begin|commit)\s*;|begin +transaction'; then
  issues+=("txn: remove BEGIN/COMMIT — Flyway wraps each migration in its own transaction.")
fi

# 5) Idempotency guards
if printf '%s' "$content" | grep -Eiq 'create table( +if +not +exists)?' \
   && printf '%s' "$content" | grep -Eiq 'create +table +[a-z]' \
   && ! printf '%s' "$content" | grep -Eiq 'create +table +if +not +exists'; then
  issues+=("idempotency: use CREATE TABLE IF NOT EXISTS.")
fi
if printf '%s' "$content" | grep -Eiq 'create +index +[a-z]' \
   && ! printf '%s' "$content" | grep -Eiq 'create +(unique +)?index +if +not +exists'; then
  issues+=("idempotency: use CREATE INDEX IF NOT EXISTS.")
fi
if printf '%s' "$content" | grep -Eiq 'add +column +[a-z]' \
   && ! printf '%s' "$content" | grep -Eiq 'add +column +if +not +exists'; then
  issues+=("idempotency: use ADD COLUMN IF NOT EXISTS.")
fi

# 6) Timestamp column form: TIMESTAMP WITHOUT TIME ZONE NOT NULL, no DEFAULT NOW(), no bare TIMESTAMP
if printf '%s' "$content" | grep -Eiq '(created_at|updated_at)[^,]*timestamp[^,]*default +now\(\)'; then
  issues+=("timestamp: drop DEFAULT NOW() — created_at/updated_at are set by the app, use 'TIMESTAMP WITHOUT TIME ZONE NOT NULL'.")
fi
if printf '%s' "$content" | grep -Eiq '(created_at|updated_at) +timestamp( +not +null)?( *,| *$| +default)' \
   && ! printf '%s' "$content" | grep -Eiq '(created_at|updated_at) +timestamp +without +time +zone'; then
  issues+=("timestamp: use 'TIMESTAMP WITHOUT TIME ZONE', not bare 'TIMESTAMP'.")
fi

# 7) created_at present but no index referencing it
if printf '%s' "$content" | grep -Eiq 'create +table' \
   && printf '%s' "$content" | grep -Eiq 'created_at' \
   && ! printf '%s' "$content" | grep -Eiq 'index[^;]*\(created_at|,\s*created_at'; then
  issues+=("index: new table has created_at but no index covering it — add idx_<table>_created_at or a (filter, created_at) composite.")
fi

# 8) Duplicated NOT NULL modifier (real defect seen in the repo)
if printf '%s' "$content" | grep -Eiq 'not +null[[:space:]]+not +null'; then
  issues+=("defect: duplicated 'NOT NULL NOT NULL' modifier.")
fi

if [ "${#issues[@]}" -gt 0 ]; then
  {
    echo "Flyway migration checks flagged '$base':"
    for i in "${issues[@]}"; do echo "  - $i"; done
    echo "See the flyway-migration skill for the full convention set."
  } >&2
  exit 2
fi

exit 0
