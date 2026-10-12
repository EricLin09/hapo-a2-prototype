-- =============================================================================
-- File        : 01_create_database_schemas.sql
-- Purpose     : Create the schemas that make up the layered batch architecture.
-- Design link : Solution Architecture 2.1 "Database and Schema Layout".
--               landing -> src_* -> staging -> curated -> dw -> reporting,
--               with control spanning every layer.
-- Owner       : Team 3
-- Run in      : database hapo_a2
-- Depends on  : 00_environment.sql
-- Re-runnable : yes (IF NOT EXISTS)
-- Expected    : 10 schemas exist
-- Naming      : all object names are lower case. PostgreSQL folds unquoted names
--               to lower case, so SRC_RENTAL in the design = src_rental here.
-- =============================================================================

BEGIN;

CREATE SCHEMA IF NOT EXISTS control;        -- load batches, source files, test results
CREATE SCHEMA IF NOT EXISTS landing;        -- selected source-shaped extracts used by the prototype
CREATE SCHEMA IF NOT EXISTS src_rental;     -- source system 1: DCJ Rent and Sales (LGA, quarter)
CREATE SCHEMA IF NOT EXISTS src_census;     -- source system 2: ABS Census DataPack (LGA, 2021)
CREATE SCHEMA IF NOT EXISTS src_population; -- source system 3: ABS estimated resident population
CREATE SCHEMA IF NOT EXISTS src_housing;    -- source system 4: NSW Housing Supply (LGA, month)
CREATE SCHEMA IF NOT EXISTS staging;        -- type casting, trimming, unpivot, code standardisation
CREATE SCHEMA IF NOT EXISTS curated;        -- validation, LGA resolution, dedup, explicit rejects
CREATE SCHEMA IF NOT EXISTS dw;             -- dimensional warehouse (star schema)
CREATE SCHEMA IF NOT EXISTS reporting;      -- stable views for the three use cases + lineage

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

SELECT nspname AS schema_name
FROM pg_namespace
WHERE nspname IN ('control','landing','src_rental','src_census','src_population',
                  'src_housing','staging','curated','dw','reporting')
ORDER BY nspname;
