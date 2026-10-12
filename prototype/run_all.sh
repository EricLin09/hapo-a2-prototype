#!/usr/bin/env bash
# =============================================================================
# run_all.sh - rebuild the HAPO A2 prototype from an empty database and run the
# full Source -> ETL -> Warehouse -> Report flow plus all quality tests.
#
# Usage (from any folder):   bash run_all.sh            full clean rebuild
#                            bash run_all.sh --upto 07  stop after file 07
#
# Requires the course lab environment to be running:
#   cd advanced-database-lab && docker compose up -d
# The source load (06) is run twice on purpose: the second run must load
# nothing, which file 11 checks as the idempotency test.
# =============================================================================
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# The course docker-compose.yml names the PostgreSQL container "student-postgres",
# so the build works from any folder. Override if your container name differs.
PG_CONTAINER="${HAPO_PG_CONTAINER:-student-postgres}"
DB_USER="${HAPO_DB_USER:-student}"
DB_NAME="hapo_a2"
# Validate options before creating a database or running the destructive reset.
if [[ $# -eq 0 ]]; then
  UPTO=99
elif [[ $# -eq 2 && "${1:-}" == "--upto" && "${2:-}" =~ ^(0?[1-9]|1[0-2])$ ]]; then
  UPTO=$((10#$2))
else
  echo "Usage: bash run_all.sh [--upto 01..12]" >&2
  exit 2
fi

mkdir -p "$HERE/results"

if ! docker exec "$PG_CONTAINER" pg_isready -U "$DB_USER" >/dev/null 2>&1; then
  echo "PostgreSQL container '$PG_CONTAINER' is not running."
  echo "Start the course lab first:  cd <your advanced-database-lab folder> && docker compose up -d"
  exit 1
fi

# run <database> <sql file> [log name]
run() {
  local db="$1" file="$2" log="$HERE/results/${3:-${2%.sql}}.log"
  printf '%-58s' "${4:-$file}"
  if docker exec -i "$PG_CONTAINER" \
       psql -X -U "$DB_USER" -d "$db" -v ON_ERROR_STOP=1 \
       < "$HERE/sql/$file" > "$log" 2>&1; then
    echo "ok"
  else
    echo "FAILED  (log: results/$(basename "$log"))"
    tail -n 15 "$log"
    exit 1
  fi
}

step() { [[ "$1" -le "$UPTO" ]]; }

# Create the prototype database when it is missing. CREATE DATABASE cannot run
# inside a transaction or a SQL script with IF NOT EXISTS, so it is done here.
if ! docker exec "$PG_CONTAINER" psql -X -U "$DB_USER" -d postgres -Atc \
       "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'" | grep -q 1; then
  docker exec "$PG_CONTAINER" psql -X -U "$DB_USER" -d postgres -v ON_ERROR_STOP=1 \
    -c "CREATE DATABASE $DB_NAME" >/dev/null
  echo "Created database $DB_NAME"
fi

run postgres 00_environment.sql
run "$DB_NAME" 99_reset.sql
step 1  && run "$DB_NAME" 01_create_database_schemas.sql
step 2  && run "$DB_NAME" 02_create_control_tables.sql
step 3  && run "$DB_NAME" 03_create_source_tables.sql
step 4  && run "$DB_NAME" 04_create_curated_and_dw_tables.sql
step 5  && run "$DB_NAME" 05_generate_source_data.sql
step 6  && run "$DB_NAME" 06_load_or_insert_source_data.sql
step 6  && run "$DB_NAME" 06_load_or_insert_source_data.sql 06b_idempotent_reload \
                "06 again (idempotency check: must load 0 rows)"
step 7  && run "$DB_NAME" 07_transform_and_validate.sql
step 8  && run "$DB_NAME" 08_load_dimensions.sql
step 9  && run "$DB_NAME" 09_load_facts.sql
step 10 && run "$DB_NAME" 10_create_reporting_views.sql
step 11 && run "$DB_NAME" 11_run_quality_tests.sql
step 12 && run "$DB_NAME" 12_demo_queries.sql
if step 12; then
  printf '%-58s' 'Dashboard export from tested report views'
  if python3 "$HERE/dashboard/build_dashboard.py" --verify-synthetic --verified-build \
       > "$HERE/results/dashboard_export.log" 2>&1; then
    echo "ok"
    cat "$HERE/results/dashboard_export.log"
  else
    echo "FAILED  (log: results/dashboard_export.log)"
    cat "$HERE/results/dashboard_export.log"
    exit 1
  fi
fi

echo "Done. Logs are in $HERE/results/"
