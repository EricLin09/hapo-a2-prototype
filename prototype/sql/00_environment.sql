-- 00_environment.sql
-- Checks the PostgreSQL version and whether the hapo_a2 database exists.
-- Run in: the postgres database. If no row comes back, run CREATE DATABASE hapo_a2; once.

SELECT version() AS lab_postgres_version;
-- Does hapo_a2 exist?
SELECT datname AS prototype_database
FROM pg_database
WHERE datname = 'hapo_a2';
