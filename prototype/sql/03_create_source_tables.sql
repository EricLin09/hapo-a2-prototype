-- =============================================================================
-- File        : 03_create_source_tables.sql
-- Purpose     : Create (a) source-shaped landing extracts with the columns
--               selected for this prototype, and (b) four source-system tables
--               that hold those extracts plus HAPO load lineage.
-- Design link : Prototype (vi)a "Databases and schemas of source systems";
--               Solution Architecture 2.1 (SRC_RENTAL, SRC_CENSUS,
--               SRC_POPULATION, SRC_HOUSING); Data Flow steps 3-4.
-- Owner       : Team 3
-- Run in      : database hapo_a2
-- Depends on  : 02_create_control_tables.sql
-- Re-runnable : yes (IF NOT EXISTS)
-- Expected    : 4 landing tables and 4 source tables
--
-- Design notes
--   * Every business column is TEXT. Source files contain thousands separators,
--     suppression symbols ("s"), blanks and malformed values; keeping them as
--     text means nothing is lost or silently converted before validation.
--   * Each agency uses its own conventions on purpose: DCJ identifies LGAs by
--     name, ABS by code (Census adds an "LGA" prefix), and the housing workbook
--     is wide (one column per month). Resolving these differences is the job of
--     staging and curated (file 07).
--   * Landing tables carry only the row position in the file. HAPO lineage
--     (batch, file, load time, synthetic flag) is added when rows are copied
--     into the src_* tables (file 06), because HAPO does not own the agencies'
--     systems - it is a governed consumer of their releases (A1, Section 2.2).
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- (a) LANDING - one selected source-shaped extract per source system
-- -----------------------------------------------------------------------------

-- DCJ Rent and Sales: median weekly rent and new bonds by LGA name and quarter.
CREATE TABLE IF NOT EXISTS landing.dcj_rent_lga_quarter (
    file_row_number    integer PRIMARY KEY,  -- line position in the file (header excluded)
    lga_name           text,                 -- e.g. "Canterbury Bankstown" (DCJ spelling)
    quarter            text,                 -- e.g. "Mar Qtr 2025"
    dwelling_type      text,                 -- Flat/Unit, House, Townhouse, Total
    bedrooms           text,                 -- 1, 2, 3, 4+, Total
    median_weekly_rent text,                 -- dollars, or "s" when suppressed
    new_bonds_lodged   text                  -- count of new bonds in the quarter
);

-- ABS Census 2021 DataPack (G02-style medians) by LGA code.
CREATE TABLE IF NOT EXISTS landing.abs_census_g02_lga (
    file_row_number           integer PRIMARY KEY,
    lga_code_2021             text,          -- e.g. "LGA10750"
    median_tot_hhd_inc_weekly text,          -- median total household income ($/week)
    tot_hhds                  text           -- total households (illustrative field)
);

-- ABS Regional Population: estimated resident population at 30 June.
CREATE TABLE IF NOT EXISTS landing.abs_erp_lga (
    file_row_number integer PRIMARY KEY,
    lga_code        text,                    -- 5-digit ASGS 2021 LGA code
    lga_name        text,
    reference_year  text,                    -- ERP is "as at 30 June" of this year
    erp             text                     -- persons, published with thousands separators
);

-- NSW Housing Supply workbook: one row per LGA and measure, one column per month.
CREATE TABLE IF NOT EXISTS landing.nsw_housing_supply_lga_month (
    file_row_number integer PRIMARY KEY,
    lga_name        text,                    -- council name as used by the dashboard
    measure         text,                    -- e.g. "Dwellings in approved DAs"
    jul_2024 text, aug_2024 text, sep_2024 text, oct_2024 text, nov_2024 text, dec_2024 text,
    jan_2025 text, feb_2025 text, mar_2025 text, apr_2025 text, may_2025 text, jun_2025 text,
    jul_2025 text, aug_2025 text, sep_2025 text, oct_2025 text, nov_2025 text, dec_2025 text,
    jan_2026 text, feb_2026 text, mar_2026 text, apr_2026 text, may_2026 text, jun_2026 text
);

-- -----------------------------------------------------------------------------
-- (b) SOURCE SYSTEMS - source-shaped columns + lineage columns
--     Lineage columns (same in all four tables):
--       source_row_id      surrogate id of the loaded row (referenced by facts)
--       load_batch_id      control.load_batch that loaded the row
--       source_file_id     control.source_file the row came from
--       source_file_name   delivered file name (denormalised for quick tracing)
--       source_row_number  line position inside that file
--       loaded_at          load timestamp
--       is_synthetic       always TRUE in this prototype
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS src_rental.rent_lga_quarter_raw (
    source_row_id      bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    load_batch_id      integer     NOT NULL REFERENCES control.load_batch,
    source_file_id     integer     NOT NULL REFERENCES control.source_file,
    source_file_name   text        NOT NULL,
    source_row_number  integer     NOT NULL CHECK (source_row_number > 0),
    loaded_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    is_synthetic       boolean     NOT NULL,
    lga_name           text,
    quarter            text,
    dwelling_type      text,
    bedrooms           text,
    median_weekly_rent text,
    new_bonds_lodged   text,
    UNIQUE (source_file_id, source_row_number)   -- a file row is loaded at most once
);

CREATE TABLE IF NOT EXISTS src_census.census_lga_income_raw (
    source_row_id             bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    load_batch_id             integer     NOT NULL REFERENCES control.load_batch,
    source_file_id            integer     NOT NULL REFERENCES control.source_file,
    source_file_name          text        NOT NULL,
    source_row_number         integer     NOT NULL CHECK (source_row_number > 0),
    loaded_at                 timestamptz NOT NULL DEFAULT clock_timestamp(),
    is_synthetic              boolean     NOT NULL,
    lga_code_2021             text,
    median_tot_hhd_inc_weekly text,
    tot_hhds                  text,
    UNIQUE (source_file_id, source_row_number)
);

CREATE TABLE IF NOT EXISTS src_population.population_lga_year_raw (
    source_row_id     bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    load_batch_id     integer     NOT NULL REFERENCES control.load_batch,
    source_file_id    integer     NOT NULL REFERENCES control.source_file,
    source_file_name  text        NOT NULL,
    source_row_number integer     NOT NULL CHECK (source_row_number > 0),
    loaded_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    is_synthetic      boolean     NOT NULL,
    lga_code          text,
    lga_name          text,
    reference_year    text,
    erp               text,
    UNIQUE (source_file_id, source_row_number)
);

CREATE TABLE IF NOT EXISTS src_housing.housing_supply_lga_month_raw (
    source_row_id     bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    load_batch_id     integer     NOT NULL REFERENCES control.load_batch,
    source_file_id    integer     NOT NULL REFERENCES control.source_file,
    source_file_name  text        NOT NULL,
    source_row_number integer     NOT NULL CHECK (source_row_number > 0),
    loaded_at         timestamptz NOT NULL DEFAULT clock_timestamp(),
    is_synthetic      boolean     NOT NULL,
    lga_name          text,
    measure           text,
    jul_2024 text, aug_2024 text, sep_2024 text, oct_2024 text, nov_2024 text, dec_2024 text,
    jan_2025 text, feb_2025 text, mar_2025 text, apr_2025 text, may_2025 text, jun_2025 text,
    jul_2025 text, aug_2025 text, sep_2025 text, oct_2025 text, nov_2025 text, dec_2025 text,
    jan_2026 text, feb_2026 text, mar_2026 text, apr_2026 text, may_2026 text, jun_2026 text,
    UNIQUE (source_file_id, source_row_number)
);

COMMENT ON TABLE src_rental.rent_lga_quarter_raw            IS 'Source system 1 (synthetic DCJ Rent and Sales): LGA name x quarter x dwelling type x bedrooms';
COMMENT ON TABLE src_census.census_lga_income_raw           IS 'Source system 2 (synthetic ABS Census 2021 G02): LGA code, median household income';
COMMENT ON TABLE src_population.population_lga_year_raw     IS 'Source system 3 (synthetic ABS ERP): LGA code x 30 June reference year';
COMMENT ON TABLE src_housing.housing_supply_lga_month_raw   IS 'Source system 4 (synthetic NSW Housing Supply): LGA name x measure, wide month columns';

COMMIT;
