-- 03_create_source_tables.sql
-- Creates the four landing tables (deliveries as received) and the four
-- source-system tables (same columns plus HAPO lineage). Source values stay as text.
-- Run in: hapo_a2. Depends on: 02.

BEGIN;

-- Landing: one table per agency delivery.
CREATE TABLE IF NOT EXISTS landing.dcj_rent_lga_quarter (
    file_row_number    integer PRIMARY KEY,
    lga_name           text,
    quarter            text,
    dwelling_type      text,
    bedrooms           text,
    median_weekly_rent text,
    new_bonds_lodged   text
);

CREATE TABLE IF NOT EXISTS landing.abs_census_g02_lga (
    file_row_number           integer PRIMARY KEY,
    lga_code_2021             text,
    median_tot_hhd_inc_weekly text,
    tot_hhds                  text
);

CREATE TABLE IF NOT EXISTS landing.abs_erp_lga (
    file_row_number integer PRIMARY KEY,
    lga_code        text,
    lga_name        text,
    reference_year  text,
    erp             text
);

CREATE TABLE IF NOT EXISTS landing.nsw_housing_supply_lga_month (
    file_row_number integer PRIMARY KEY,
    lga_name        text,
    measure         text,
    jul_2024 text, aug_2024 text, sep_2024 text, oct_2024 text, nov_2024 text, dec_2024 text,
    jan_2025 text, feb_2025 text, mar_2025 text, apr_2025 text, may_2025 text, jun_2025 text,
    jul_2025 text, aug_2025 text, sep_2025 text, oct_2025 text, nov_2025 text, dec_2025 text,
    jan_2026 text, feb_2026 text, mar_2026 text, apr_2026 text, may_2026 text, jun_2026 text
);

-- Source systems: the delivered columns plus batch, file and row lineage.
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
    UNIQUE (source_file_id, source_row_number)
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
