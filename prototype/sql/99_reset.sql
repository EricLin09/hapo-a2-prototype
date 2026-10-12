-- =============================================================================
-- File        : 99_reset.sql
-- Purpose     : Remove every prototype schema so the build can be demonstrated
--               from an empty database (clean rebuild for the demo video).
-- Design link : Testing plan - "Build smoke test" and "End to end" (reset, build,
--               load, transform, test and query in one uninterrupted run).
-- Owner       : Team 3
-- Run in      : database hapo_a2
-- Depends on  : 00_environment.sql
-- Re-runnable : yes (IF EXISTS)
-- Expected    : no prototype schemas remain; files 01-12 can then run in order
-- Warning     : destructive for hapo_a2 only. It never touches the course
--               database "lab" or any other database.
-- =============================================================================

BEGIN;

-- Dropped from the most dependent layer to the least dependent one.
-- CASCADE removes the tables, views and functions inside each schema.
DROP SCHEMA IF EXISTS reporting      CASCADE;  -- report views
DROP SCHEMA IF EXISTS dw             CASCADE;  -- dimensions and facts
DROP SCHEMA IF EXISTS curated        CASCADE;  -- accepted rows, rejects, reference data
DROP SCHEMA IF EXISTS staging        CASCADE;  -- typed and standardised rows
DROP SCHEMA IF EXISTS src_rental     CASCADE;  -- source systems
DROP SCHEMA IF EXISTS src_census     CASCADE;
DROP SCHEMA IF EXISTS src_population CASCADE;
DROP SCHEMA IF EXISTS src_housing    CASCADE;
DROP SCHEMA IF EXISTS landing        CASCADE;  -- delivered files (synthetic)
DROP SCHEMA IF EXISTS control        CASCADE;  -- batches, files, test results

COMMIT;

SELECT 'hapo_a2 reset: all prototype schemas removed' AS result;
