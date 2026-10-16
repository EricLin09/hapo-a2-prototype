-- 99_reset.sql
-- Drops every prototype schema so the build starts from an empty database.
-- Run in: hapo_a2. Run this first in a clean manual build.

BEGIN;

DROP SCHEMA IF EXISTS reporting      CASCADE;
DROP SCHEMA IF EXISTS dw             CASCADE;
DROP SCHEMA IF EXISTS curated        CASCADE;
DROP SCHEMA IF EXISTS staging        CASCADE;
DROP SCHEMA IF EXISTS src_rental     CASCADE;
DROP SCHEMA IF EXISTS src_census     CASCADE;
DROP SCHEMA IF EXISTS src_population CASCADE;
DROP SCHEMA IF EXISTS src_housing    CASCADE;
DROP SCHEMA IF EXISTS landing        CASCADE;
DROP SCHEMA IF EXISTS control        CASCADE;

COMMIT;

SELECT 'hapo_a2 reset: all prototype schemas removed' AS result;
