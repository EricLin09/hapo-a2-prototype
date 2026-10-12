-- =============================================================================
-- File        : 04_create_curated_and_dw_tables.sql
-- Purpose     : Create the curated layer (parsing functions, governed reference
--               data, validation rules, accepted and rejected rows) and the
--               dimensional warehouse (4 dimensions, 4 facts).
-- Design link : Data Model 3.1-3.2 and Logical Table Design 4 / 4.1
--               (DIM_TIME, DIM_GEOGRAPHY, DIM_DWELLING_TYPE, DIM_PIPELINE_STAGE,
--               FACT_RENTAL, FACT_CENSUS_INCOME, FACT_POPULATION,
--               FACT_HOUSING_SUPPLY, CURATED.LGA_ALIAS, CURATED.GEOGRAPHY_CROSSWALK,
--               REJECTED_ROW).
-- Owner       : Team 3 (DDL implements Team 2's logical model)
-- Run in      : database hapo_a2
-- Depends on  : 03_create_source_tables.sql
-- Re-runnable : yes - tables use IF NOT EXISTS, functions use CREATE OR REPLACE,
--               reference data is upserted
-- Expected    : curated reference tables populated (10 LGAs, aliases, category
--               maps, 7 validation rules); empty accepted/rejected/dw tables
-- =============================================================================

BEGIN;

-- -----------------------------------------------------------------------------
-- 1. Parsing and standardisation functions
--    Kept as named functions (not inline expressions) so that the exact same
--    rule is used by the ETL (file 07) and unit-tested by file 11.
-- -----------------------------------------------------------------------------

-- Normalise free text for matching: trim, collapse inner spaces, upper case.
CREATE OR REPLACE FUNCTION curated.norm_text(p_value text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT upper(regexp_replace(btrim(p_value), '\s+', ' ', 'g'))
$$;

-- DCJ quarter label "Mar Qtr 2025" -> first day of that quarter (2025-01-01).
-- Only quarters within the ASGS 2021 reference and dim_time range are supported:
-- 2021-Q3 through 2026-Q4. Other labels return NULL (R02 in file 07).
CREATE OR REPLACE FUNCTION curated.parse_dcj_quarter(p_label text)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN btrim(p_label) ~ '^((Sep|Dec) Qtr 2021|(Mar|Jun|Sep|Dec) Qtr 202[2-6])$'
             THEN date_trunc('quarter',
                    to_date(split_part(btrim(p_label), ' ', 1) || ' ' ||
                            split_part(btrim(p_label), ' ', 3), 'Mon YYYY'))::date
           END
$$;

-- Housing workbook month column name "mar_2025" -> 2025-03-01. An
-- unrecognised month or a date outside the supported geography/time range
-- returns NULL (R02), rather than making to_date raise an exception.
CREATE OR REPLACE FUNCTION curated.parse_month_column(p_column text)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_column ~ '^((jul|aug|sep|oct|nov|dec)_2021|(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)_202[2-6])$'
                THEN to_date(p_column, 'mon_YYYY') END
$$;

-- Whole non-negative number published as text, allowing correctly grouped
-- thousands separators ("412,345" -> 412345). Malformed groups such as
-- "12,34" or "1,,234" are invalid rather than silently changed to 1234.
-- Used to tell "not a number" (R03) apart from "a number too large" (R07).
CREATE OR REPLACE FUNCTION curated.is_whole_number_text(p_value text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(btrim(p_value) ~ '^([0-9]+|[0-9]{1,3}(,[0-9]{3})+)$', FALSE)
$$;

-- The range is checked on the digits BEFORE any cast, so an oversized value
-- such as "2147483648" returns NULL (and is quarantined by file 07) instead
-- of raising "integer out of range" and aborting the whole transformation.
-- The nested CASE guarantees the cast is only evaluated for in-range digits.
DROP FUNCTION IF EXISTS curated.to_whole_number(text);   -- return type changed from bigint
CREATE FUNCTION curated.to_whole_number(p_value text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN curated.is_whole_number_text(p_value) THEN
               CASE WHEN length(ltrim(v, '0')) < 10
                      OR (length(ltrim(v, '0')) = 10 AND ltrim(v, '0') <= '2147483647')
                    THEN v::integer END
           END
    FROM (SELECT replace(btrim(p_value), ',', '') AS v) AS s
$$;

-- Dollar amount with up to 2 decimals ("540" or "540.50"). Otherwise NULL.
-- Syntax only: a dollar amount with up to 2 decimals.
CREATE OR REPLACE FUNCTION curated.is_money_text(p_value text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(btrim(p_value) ~ '^[0-9]+(\.[0-9]{1,2})?$', FALSE)
$$;

-- numeric(10,2) holds at most 8 digits before the point; longer amounts
-- return NULL (quarantined as R07) instead of raising "numeric field overflow".
CREATE OR REPLACE FUNCTION curated.to_money(p_value text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN v ~ '^[0-9]+(\.[0-9]{1,2})?$' THEN
               CASE WHEN length(ltrim(split_part(v, '.', 1), '0')) <= 8
                    THEN v::numeric(10,2) END
           END
    FROM (SELECT btrim(p_value) AS v) AS s
$$;

-- Plausibility range for a median weekly rent. Values outside it are treated
-- as outliers (R07) and quarantined for steward review rather than reported.
-- The bounds are deliberately wide: real DCJ LGA medians in the September 2021
-- rent tables range from $35 to $2,500, so $5,000 leaves room for growth while
-- catching typing errors such as 9999.
CREATE OR REPLACE FUNCTION curated.is_plausible_weekly_rent(p_rent numeric)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_rent BETWEEN 50 AND 5000
$$;

-- This prototype has one Census vintage and one ASGS 2021 LGA reference.
-- Returning NULL for other vintages lets file 07 reject them as R02 before
-- loading facts that cannot resolve their time/geography keys.
CREATE OR REPLACE FUNCTION curated.census_reference_date(p_year smallint)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_year = 2021 THEN date '2021-08-10' END
$$;

-- ERP at 30 June is only supported for 2022-2026: 2021-06-30 is before the
-- ASGS 2021 LGA reference begins and 2027 is outside dim_time. An invalid or
-- unsupported year returns NULL (R02) without calling make_date with year 0.
CREATE OR REPLACE FUNCTION curated.parse_erp_reference_date(p_year text)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN btrim(p_year) ~ '^202[2-6]$'
                THEN make_date(btrim(p_year)::integer, 6, 30) END
$$;

-- True when a source cell carries no value at all (NULL or only spaces).
CREATE OR REPLACE FUNCTION curated.is_blank(p_value text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(btrim(p_value), '') IS NULL
$$;

-- Australian financial year, labelled by the year in which it ends:
-- 2025-06-30 -> 2025 (FY2024-25); 2025-07-01 -> 2026 (FY2025-26).
-- Needed because ERP is measured at 30 June, so supply must be summed over
-- July-June to line up with population change (UC2).
CREATE OR REPLACE FUNCTION curated.financial_year(p_date date)
RETURNS smallint LANGUAGE sql IMMUTABLE AS $$
    SELECT extract(year FROM p_date + interval '6 months')::smallint
$$;

-- -----------------------------------------------------------------------------
-- 2. Governed reference data
-- -----------------------------------------------------------------------------

-- Master list of LGAs in scope. Codes and names are ASGS Edition 3 (2021)
-- values; the measures loaded against them are synthetic.
CREATE TABLE IF NOT EXISTS curated.lga_reference (
    lga_code     text PRIMARY KEY CHECK (lga_code ~ '^[0-9]{5}$'),
    lga_name     text NOT NULL UNIQUE,
    state_code   text NOT NULL DEFAULT 'NSW',
    asgs_edition text NOT NULL,
    valid_from   date NOT NULL,
    valid_to     date,                                  -- NULL = still current
    CHECK (valid_to IS NULL OR valid_to > valid_from)
);

INSERT INTO curated.lga_reference (lga_code, lga_name, asgs_edition, valid_from) VALUES
    ('10750', 'Blacktown',            'ASGS Edition 3 (2021)', '2021-07-01'),
    ('11500', 'Campbelltown (NSW)',   'ASGS Edition 3 (2021)', '2021-07-01'),
    ('11570', 'Canterbury-Bankstown', 'ASGS Edition 3 (2021)', '2021-07-01'),
    ('12380', 'Cumberland',           'ASGS Edition 3 (2021)', '2021-07-01'),
    ('12850', 'Fairfield',            'ASGS Edition 3 (2021)', '2021-07-01'),
    ('14900', 'Liverpool',            'ASGS Edition 3 (2021)', '2021-07-01'),
    ('15900', 'Newcastle',            'ASGS Edition 3 (2021)', '2021-07-01'),
    ('16260', 'Parramatta',           'ASGS Edition 3 (2021)', '2021-07-01'),
    ('16350', 'Penrith',              'ASGS Edition 3 (2021)', '2021-07-01'),
    ('17200', 'Sydney',               'ASGS Edition 3 (2021)', '2021-07-01')
ON CONFLICT (lga_code) DO UPDATE
    SET lga_name = EXCLUDED.lga_name, asgs_edition = EXCLUDED.asgs_edition,
        valid_from = EXCLUDED.valid_from;

-- Resolves LGA *names* used by name-based sources (DCJ rent, NSW housing) to
-- an LGA code. Code-based sources (ABS) resolve directly against
-- lga_reference. Design rule 4.1: use the code first, the alias table only
-- when a file contains names without codes.
CREATE TABLE IF NOT EXISTS curated.lga_alias (
    source_system    text NOT NULL,
    source_lga_value text NOT NULL,          -- stored already normalised (norm_text)
    lga_code         text NOT NULL REFERENCES curated.lga_reference,
    match_method     text NOT NULL CHECK (match_method IN ('EXACT_NAME', 'REVIEWED_ALIAS')),
    reviewed_by      text,                   -- steward who approved a non-exact alias
    effective_from   date NOT NULL,
    effective_to     date,
    PRIMARY KEY (source_system, source_lga_value),
    CHECK (match_method = 'EXACT_NAME' OR reviewed_by IS NOT NULL)
);

-- Exact-name matches for both name-based sources.
INSERT INTO curated.lga_alias (source_system, source_lga_value, lga_code, match_method, effective_from)
SELECT s.source_system, curated.norm_text(r.lga_name), r.lga_code, 'EXACT_NAME', r.valid_from
FROM curated.lga_reference r
CROSS JOIN (VALUES ('DCJ_RENT'), ('NSW_HOUSING')) AS s(source_system)
ON CONFLICT (source_system, source_lga_value) DO NOTHING;

-- Spellings that differ from the ABS name and were reviewed by a steward.
INSERT INTO curated.lga_alias
    (source_system, source_lga_value, lga_code, match_method, reviewed_by, effective_from) VALUES
    ('DCJ_RENT',    'CANTERBURY BANKSTOWN', '11570', 'REVIEWED_ALIAS', 'Geography steward (Team 3)', '2021-07-01'),
    ('DCJ_RENT',    'CAMPBELLTOWN',         '11500', 'REVIEWED_ALIAS', 'Geography steward (Team 3)', '2021-07-01'),
    ('NSW_HOUSING', 'CAMPBELLTOWN',         '11500', 'REVIEWED_ALIAS', 'Geography steward (Team 3)', '2021-07-01'),
    ('NSW_HOUSING', 'CITY OF SYDNEY',       '17200', 'REVIEWED_ALIAS', 'Geography steward (Team 3)', '2021-07-01')
ON CONFLICT (source_system, source_lga_value) DO NOTHING;

-- Optional postcode/SA2 correspondence (design: future extension). Created so
-- the logical model is complete; intentionally left empty until the team
-- decides whether a postcode-level source is in scope.
CREATE TABLE IF NOT EXISTS curated.geography_crosswalk (
    correspondence_version text    NOT NULL,
    source_geo_type        text    NOT NULL CHECK (source_geo_type IN ('POSTCODE', 'SA2')),
    source_geo_code        text    NOT NULL,
    target_geo_type        text    NOT NULL CHECK (target_geo_type = 'LGA'),
    target_geo_code        text    NOT NULL REFERENCES curated.lga_reference (lga_code),
    allocation_weight      numeric(7,6) NOT NULL CHECK (allocation_weight > 0 AND allocation_weight <= 1),
    allocation_method      text    NOT NULL,
    valid_from             date    NOT NULL,
    valid_to               date,
    PRIMARY KEY (correspondence_version, source_geo_type, source_geo_code, target_geo_code)
);

-- Source category -> standard dwelling type (DCJ rent file).
CREATE TABLE IF NOT EXISTS curated.dwelling_type_map (
    source_system          text NOT NULL,
    source_value           text NOT NULL,     -- normalised
    standard_dwelling_type text NOT NULL,
    PRIMARY KEY (source_system, source_value)
);
INSERT INTO curated.dwelling_type_map VALUES
    ('DCJ_RENT', 'FLAT/UNIT', 'Flat/Unit'),
    ('DCJ_RENT', 'HOUSE',     'House'),
    ('DCJ_RENT', 'TOWNHOUSE', 'Townhouse'),
    ('DCJ_RENT', 'TOTAL',     'All dwellings')        -- the source's own total row
ON CONFLICT DO NOTHING;

-- Source bedroom value -> standard bedroom band.
CREATE TABLE IF NOT EXISTS curated.bedroom_band_map (
    source_system text     NOT NULL,
    source_value  text     NOT NULL,          -- normalised
    bedroom_band  text     NOT NULL,
    band_order    smallint NOT NULL,
    PRIMARY KEY (source_system, source_value)
);
INSERT INTO curated.bedroom_band_map VALUES
    ('DCJ_RENT', '1',     '1 bedroom',    1),
    ('DCJ_RENT', '2',     '2 bedrooms',   2),
    ('DCJ_RENT', '3',     '3 bedrooms',   3),
    ('DCJ_RENT', '4+',    '4+ bedrooms',  4),
    ('DCJ_RENT', 'TOTAL', 'All bedrooms', 9)
ON CONFLICT DO NOTHING;

-- Housing pipeline stages and the source measure that feeds each of them.
-- Completions are deliberately absent: the selected source publishes them
-- only statewide (A1, Section 2.3), so local reporting stops at construction
-- approval.
CREATE TABLE IF NOT EXISTS curated.pipeline_stage_reference (
    stage_code        text PRIMARY KEY,
    stage_name        text     NOT NULL,
    stage_order       smallint NOT NULL UNIQUE,
    source_definition text     NOT NULL
);
INSERT INTO curated.pipeline_stage_reference VALUES
    ('LODGED',      'Lodged',                        1, 'Dwellings in development applications lodged in the month'),
    ('DA_APPROVED', 'Development approved',          2, 'Dwellings in development applications approved in the month'),
    ('CC_APPROVED', 'Construction approved',         3, 'Dwellings in construction certificates approved in the month')
ON CONFLICT (stage_code) DO NOTHING;

CREATE TABLE IF NOT EXISTS curated.pipeline_stage_map (
    source_system  text NOT NULL,
    source_measure text NOT NULL,             -- normalised
    stage_code     text NOT NULL REFERENCES curated.pipeline_stage_reference,
    PRIMARY KEY (source_system, source_measure)
);
INSERT INTO curated.pipeline_stage_map VALUES
    ('NSW_HOUSING', 'DWELLINGS IN LODGED DAS',                          'LODGED'),
    ('NSW_HOUSING', 'DWELLINGS IN APPROVED DAS',                        'DA_APPROVED'),
    ('NSW_HOUSING', 'DWELLINGS IN APPROVED CONSTRUCTION CERTIFICATES',  'CC_APPROVED')
ON CONFLICT DO NOTHING;

-- -----------------------------------------------------------------------------
-- 3. Validation rules and rejected rows
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS curated.validation_rule (
    rule_code        text PRIMARY KEY,
    rule_description text NOT NULL,
    check_order      smallint NOT NULL UNIQUE   -- first failing rule is recorded
);
INSERT INTO curated.validation_rule VALUES
    ('R01', 'LGA cannot be resolved to an in-scope LGA code',            1),
    ('R02', 'Reference period cannot be parsed',                          2),
    ('R05', 'Source category or measure has no approved mapping',         3),
    ('R06', 'Required measure is missing (blank)',                        4),
    ('R03', 'Measure is non-numeric, negative or zero where not allowed', 5),
    ('R07', 'Measure outside the plausible range (outlier, quarantined)', 6),
    ('R04', 'Duplicate of an earlier row for the same business grain',    7)
ON CONFLICT (rule_code) DO NOTHING;

-- One row per rejected source row (or, for the wide housing file, per rejected
-- month cell). raw_record keeps the original values for investigation.
CREATE TABLE IF NOT EXISTS curated.rejected_row (
    rejected_row_id bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    load_batch_id   integer     NOT NULL REFERENCES control.load_batch,
    source_system   text        NOT NULL,
    source_table    text        NOT NULL,
    source_row_id   bigint      NOT NULL,
    source_column   text,                     -- month column for housing cells, else NULL
    rule_code       text        NOT NULL REFERENCES curated.validation_rule,
    rejected_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
    raw_record      jsonb       NOT NULL
);

-- -----------------------------------------------------------------------------
-- 4. Accepted (validated, standardised) rows - one table per source
-- -----------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS curated.rental_accepted (
    source_row_id          bigint PRIMARY KEY,
    load_batch_id          integer NOT NULL,
    lga_code               text    NOT NULL REFERENCES curated.lga_reference,
    lga_match_method       text    NOT NULL,
    quarter_start          date    NOT NULL,
    standard_dwelling_type text    NOT NULL,
    bedroom_band           text    NOT NULL,
    median_weekly_rent     numeric(10,2) CHECK (median_weekly_rent > 0),   -- NULL when suppressed
    is_rent_suppressed     boolean NOT NULL,                                -- source "-" (10 or fewer bonds)
    bond_lodgement_count   integer CHECK (bond_lodgement_count >= 0),       -- NULL when suppressed
    is_bond_count_suppressed boolean NOT NULL,                              -- source "s" (30 or fewer) or "-"
    UNIQUE (lga_code, quarter_start, standard_dwelling_type, bedroom_band),
    CHECK (is_rent_suppressed = (median_weekly_rent IS NULL)),
    CHECK (is_bond_count_suppressed = (bond_lodgement_count IS NULL))
);

CREATE TABLE IF NOT EXISTS curated.census_income_accepted (
    source_row_id                  bigint PRIMARY KEY,
    load_batch_id                  integer  NOT NULL,
    lga_code                       text     NOT NULL REFERENCES curated.lga_reference,
    census_year                    smallint NOT NULL,
    census_date                    date     NOT NULL,
    median_weekly_household_income numeric(10,2) NOT NULL CHECK (median_weekly_household_income > 0),
    household_count                integer CHECK (household_count >= 0),
    UNIQUE (lga_code, census_year)
);

CREATE TABLE IF NOT EXISTS curated.population_accepted (
    source_row_id                 bigint PRIMARY KEY,
    load_batch_id                 integer NOT NULL,
    lga_code                      text    NOT NULL REFERENCES curated.lga_reference,
    reference_date                date    NOT NULL,          -- always 30 June
    estimated_resident_population integer NOT NULL CHECK (estimated_resident_population >= 0),
    UNIQUE (lga_code, reference_date)
);

CREATE TABLE IF NOT EXISTS curated.housing_supply_accepted (
    source_row_id  bigint  NOT NULL,
    source_column  text    NOT NULL,                         -- month column it was unpivoted from
    load_batch_id  integer NOT NULL,
    lga_code       text    NOT NULL REFERENCES curated.lga_reference,
    month_start    date    NOT NULL,
    stage_code     text    NOT NULL REFERENCES curated.pipeline_stage_reference,
    dwelling_count integer NOT NULL CHECK (dwelling_count >= 0),
    PRIMARY KEY (source_row_id, source_column),
    UNIQUE (lga_code, month_start, stage_code)
);

-- -----------------------------------------------------------------------------
-- 5. Dimensional warehouse - dimensions
--    Dimension keys are assigned deterministically in file 08 (ordered by the
--    business key), so a rebuild produces the same keys every time.
-- -----------------------------------------------------------------------------

-- Day grain, so every fact can point at the exact first day of its period
-- (month start, quarter start, 30 June for ERP, Census night for Census).
CREATE TABLE IF NOT EXISTS dw.dim_time (
    time_key               integer  PRIMARY KEY,      -- YYYYMMDD
    date_value             date     NOT NULL UNIQUE,
    month_start            date     NOT NULL,
    quarter_start          date     NOT NULL,
    calendar_month         smallint NOT NULL,
    calendar_quarter       smallint NOT NULL,
    calendar_quarter_label text     NOT NULL,         -- e.g. 2025-Q1
    calendar_year          smallint NOT NULL,
    financial_year         smallint NOT NULL,         -- FY ending 30 June
    financial_year_label   text     NOT NULL          -- e.g. FY2024-25
);

CREATE TABLE IF NOT EXISTS dw.dim_geography (
    geography_key   integer PRIMARY KEY,
    geography_level text    NOT NULL CHECK (geography_level = 'LGA'),
    geography_code  text    NOT NULL,
    lga_code        text    NOT NULL,
    lga_name        text    NOT NULL,
    state_code      text    NOT NULL,
    asgs_edition    text    NOT NULL,
    valid_from      date    NOT NULL,
    valid_to        date,
    current_flag    boolean NOT NULL,
    UNIQUE (geography_level, geography_code, valid_from)
);

CREATE TABLE IF NOT EXISTS dw.dim_dwelling_type (
    dwelling_type_key      integer PRIMARY KEY,
    standard_dwelling_type text    NOT NULL,
    bedroom_band           text    NOT NULL,
    is_all_dwellings       boolean NOT NULL,          -- source "Total" dwelling row
    is_all_bedrooms        boolean NOT NULL,          -- source "Total" bedroom row
    UNIQUE (standard_dwelling_type, bedroom_band)
);

CREATE TABLE IF NOT EXISTS dw.dim_pipeline_stage (
    pipeline_stage_key integer  PRIMARY KEY,
    stage_code         text     NOT NULL UNIQUE,
    stage_name         text     NOT NULL,
    stage_order        smallint NOT NULL,
    source_definition  text     NOT NULL
);

-- -----------------------------------------------------------------------------
-- 6. Dimensional warehouse - facts (one declared grain each)
--    Every fact keeps load_batch_id and source_row_id (FK to its source row),
--    so any report value can be traced back to a file row (UC5).
-- -----------------------------------------------------------------------------

-- Grain: one LGA x quarter x dwelling type x bedroom band.
-- Median rent is NOT additive: the LGA-level figure is the source's own
-- "All dwellings / All bedrooms" row, never a combination of subgroup medians.
CREATE TABLE IF NOT EXISTS dw.fact_rental (
    rental_fact_key      bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    geography_key        integer NOT NULL REFERENCES dw.dim_geography,
    time_key             integer NOT NULL REFERENCES dw.dim_time,          -- quarter start
    dwelling_type_key    integer NOT NULL REFERENCES dw.dim_dwelling_type,
    median_weekly_rent   numeric(10,2) CHECK (median_weekly_rent > 0),
    is_rent_suppressed   boolean NOT NULL,
    bond_lodgement_count integer CHECK (bond_lodgement_count >= 0),      -- NULL when suppressed
    is_bond_count_suppressed boolean NOT NULL,
    load_batch_id        integer NOT NULL REFERENCES control.load_batch,
    source_row_id        bigint  NOT NULL REFERENCES src_rental.rent_lga_quarter_raw,
    UNIQUE (geography_key, time_key, dwelling_type_key)
);

-- Grain: one LGA x Census reference year.
CREATE TABLE IF NOT EXISTS dw.fact_census_income (
    census_income_fact_key         bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    geography_key                  integer NOT NULL REFERENCES dw.dim_geography,
    time_key                       integer NOT NULL REFERENCES dw.dim_time,  -- Census night
    median_weekly_household_income numeric(10,2) NOT NULL CHECK (median_weekly_household_income > 0),
    household_count                integer CHECK (household_count >= 0),
    census_vintage                 smallint NOT NULL,
    load_batch_id                  integer NOT NULL REFERENCES control.load_batch,
    source_row_id                  bigint  NOT NULL REFERENCES src_census.census_lga_income_raw,
    UNIQUE (geography_key, time_key)
);

-- Grain: one LGA x 30 June reference date. Annual change and growth are
-- derived in the reporting view, not stored, so they always match the stock.
CREATE TABLE IF NOT EXISTS dw.fact_population (
    population_fact_key           bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    geography_key                 integer NOT NULL REFERENCES dw.dim_geography,
    time_key                      integer NOT NULL REFERENCES dw.dim_time,   -- 30 June
    estimated_resident_population integer NOT NULL CHECK (estimated_resident_population >= 0),
    load_batch_id                 integer NOT NULL REFERENCES control.load_batch,
    source_row_id                 bigint  NOT NULL REFERENCES src_population.population_lga_year_raw,
    UNIQUE (geography_key, time_key)
);

-- Grain: one LGA x month x pipeline stage.
CREATE TABLE IF NOT EXISTS dw.fact_housing_supply (
    housing_supply_fact_key bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    geography_key           integer NOT NULL REFERENCES dw.dim_geography,
    time_key                integer NOT NULL REFERENCES dw.dim_time,         -- month start
    pipeline_stage_key      integer NOT NULL REFERENCES dw.dim_pipeline_stage,
    dwelling_count          integer NOT NULL CHECK (dwelling_count >= 0),
    load_batch_id           integer NOT NULL REFERENCES control.load_batch,
    source_row_id           bigint  NOT NULL REFERENCES src_housing.housing_supply_lga_month_raw,
    source_column           text    NOT NULL,                                -- month column in the workbook
    UNIQUE (geography_key, time_key, pipeline_stage_key)
);

COMMIT;

-- Summary of the reference data that drives standardisation.
SELECT 'lga_reference' AS reference_table, count(*) AS row_count FROM curated.lga_reference
UNION ALL SELECT 'lga_alias',            count(*) FROM curated.lga_alias
UNION ALL SELECT 'dwelling_type_map',    count(*) FROM curated.dwelling_type_map
UNION ALL SELECT 'bedroom_band_map',     count(*) FROM curated.bedroom_band_map
UNION ALL SELECT 'pipeline_stage_map',   count(*) FROM curated.pipeline_stage_map
UNION ALL SELECT 'validation_rule',      count(*) FROM curated.validation_rule;
