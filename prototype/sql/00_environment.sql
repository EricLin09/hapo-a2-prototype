-- =============================================================================
-- File        : 00_environment.sql
-- Purpose     : Confirm the Lab PostgreSQL version and whether the prototype
--               database hapo_a2 exists.
-- Design link : Solution Architecture - platform decision (PostgreSQL in the
--               subject Docker lab environment, one database for the prototype).
-- Owner       : Team 3 (Source Systems, ETL and Data Warehouse)
-- Run in      : the default "postgres" database (hapo_a2 may not exist yet)
-- Depends on  : Docker lab environment running (docker compose up -d)
-- Re-runnable : yes (read only)
-- Expected    : one version row; one row for hapo_a2 once it has been created
-- Creating the database
--   CREATE DATABASE cannot run inside a transaction and has no IF NOT EXISTS,
--   so it is not in this file. run_all.sh creates hapo_a2 automatically when
--   it is missing. For a manual build in CloudBeaver / VS Code, if the second
--   query below returns no row, run this once:   CREATE DATABASE hapo_a2;
-- =============================================================================

-- 1. Record which server version the build ran on (evidence for the report).
SELECT version() AS lab_postgres_version;

-- 2. Check whether hapo_a2 already exists (no row = create it first).
SELECT datname AS prototype_database
FROM pg_database
WHERE datname = 'hapo_a2';
