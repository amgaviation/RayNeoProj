#!/bin/bash
# Applies the migrations to a scratch database on plain Postgres and runs the checks.
# Usage: supabase/tests/db/run.sh [psql connection options]
set -euo pipefail
cd "$(dirname "$0")/../.."
DB="bluenudge_test_$$"
PSQL=(psql -v ON_ERROR_STOP=1 -X -q "$@")
"${PSQL[@]}" -d postgres -c "create database $DB"
trap '"${PSQL[@]}" -d postgres -c "drop database if exists $DB" >/dev/null' EXIT
"${PSQL[@]}" -d "$DB" -f tests/db/stub_supabase.sql
for migration in migrations/*.sql; do
  echo "Applying $migration"
  "${PSQL[@]}" -d "$DB" -f "$migration"
done
"${PSQL[@]}" -d "$DB" -f tests/db/texting_test.sql
