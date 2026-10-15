# hapo_a2 database snapshot

`hapo_a2.sql` is a complete copy of the prototype database (all 10 schemas, tables, views, functions and data), exported with `pg_dump` from the build of 12 Oct 2026 (50/50 tests passed). Use it to explore or reuse the database without running the build scripts. All measures are synthetic.

It is a snapshot: if the SQL scripts in `prototype/sql/` change, this file does not update itself. Rebuilding with `prototype/run_all.sh` always gives the current version.

## Load it into your lab environment

Start the course lab first (`docker compose up -d` in your `advanced-database-lab` folder). Then, from this folder:

```bash
docker exec student-postgres psql -U student -d postgres -c "CREATE DATABASE hapo_a2"
docker cp hapo_a2.sql student-postgres:/tmp/hapo_a2.sql
docker exec student-postgres psql -q -U student -d hapo_a2 -v ON_ERROR_STOP=1 -f /tmp/hapo_a2.sql
```

These commands work the same in macOS Terminal and Windows PowerShell.

If `CREATE DATABASE` says the database already exists, you already have a copy (for example from `run_all.sh`). To replace it, drop it first with `docker exec student-postgres psql -U student -d postgres -c "DROP DATABASE hapo_a2"`; this deletes only `hapo_a2`, never the course database `lab`.

The file can also be opened in CloudBeaver or VS Code and run as a script against an empty `hapo_a2` database; it uses plain `INSERT` statements, so no command-line tools are needed.

## Check it worked

```bash
docker exec student-postgres psql -U student -d hapo_a2 -c "SELECT rent_to_income_pct FROM reporting.vw_dashboard_uc1 WHERE lga_code = '16260' AND quarter = '2025-Q1'"
```

The result should be `30.00` (Parramatta, 2025-Q1). Connect in CloudBeaver at http://localhost:8978 with host `postgres`, database `hapo_a2`, user and password `student`.

## How it was made

```bash
docker exec student-postgres pg_dump -U student -d hapo_a2 --no-owner --no-privileges --inserts > database/hapo_a2.sql
```

Run the same command from the repository root after a rebuild to refresh the snapshot.
