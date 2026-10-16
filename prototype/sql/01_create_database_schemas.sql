-- 01_create_database_schemas.sql
-- Creates the 10 schemas of the layered architecture:
-- landing -> src_* -> staging -> curated -> dw -> reporting, plus control.
-- Run in: hapo_a2. Re-runnable (IF NOT EXISTS).

BEGIN;

CREATE SCHEMA IF NOT EXISTS control;
CREATE SCHEMA IF NOT EXISTS landing;
CREATE SCHEMA IF NOT EXISTS src_rental;
CREATE SCHEMA IF NOT EXISTS src_census;
CREATE SCHEMA IF NOT EXISTS src_population;
CREATE SCHEMA IF NOT EXISTS src_housing;
CREATE SCHEMA IF NOT EXISTS staging;
CREATE SCHEMA IF NOT EXISTS curated;
CREATE SCHEMA IF NOT EXISTS dw;
CREATE SCHEMA IF NOT EXISTS reporting;

-- Describe each schema in the database catalogue.
COMMENT ON SCHEMA control        IS 'Operational metadata: load batches, source files, test results';
COMMENT ON SCHEMA landing        IS 'Synthetic stand-in for the CSV files delivered by each agency; no HAPO metadata';
COMMENT ON SCHEMA src_rental     IS 'Source-shaped copy of DCJ Rent and Sales data (synthetic) plus load lineage';
COMMENT ON SCHEMA src_census     IS 'Source-shaped copy of ABS Census G02 LGA data (synthetic) plus load lineage';
COMMENT ON SCHEMA src_population IS 'Source-shaped copy of ABS ERP by LGA (synthetic) plus load lineage';
COMMENT ON SCHEMA src_housing    IS 'Source-shaped copy of NSW Housing Supply workbook (synthetic) plus load lineage';
COMMENT ON SCHEMA staging        IS 'Typed and standardised rows, rebuilt on every run';
COMMENT ON SCHEMA curated        IS 'Validated rows, rejected rows and governed reference data';
COMMENT ON SCHEMA dw             IS 'Integrated dimensional warehouse with declared fact grains';
COMMENT ON SCHEMA reporting      IS 'Report views for UC1-UC3 and the lineage view';

COMMIT;

-- Check: 10 schemas exist.
SELECT nspname AS schema_name
FROM pg_namespace
WHERE nspname IN ('control','landing','src_rental','src_census','src_population',
                  'src_housing','staging','curated','dw','reporting')
ORDER BY nspname;
