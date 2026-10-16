-- 04_create_curated_and_dw_tables.sql
-- Creates the parsing functions, curated reference and validation tables,
-- accepted and rejected tables, and the warehouse (4 dimensions, 4 facts).
-- Run in: hapo_a2. Depends on: 03.

BEGIN;

-- Parsing helpers. Numbers are range-checked before casting, so a value too
-- large to store returns NULL (rejected as R07) instead of stopping the run.
CREATE OR REPLACE FUNCTION curated.norm_text(p_value text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT upper(regexp_replace(btrim(p_value), '\s+', ' ', 'g'))
$$;

CREATE OR REPLACE FUNCTION curated.parse_dcj_quarter(p_label text)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
             WHEN btrim(p_label) ~ '^((Sep|Dec) Qtr 2021|(Mar|Jun|Sep|Dec) Qtr 202[2-6])$'
             THEN date_trunc('quarter',
                    to_date(split_part(btrim(p_label), ' ', 1) || ' ' ||
                            split_part(btrim(p_label), ' ', 3), 'Mon YYYY'))::date
           END
$$;

CREATE OR REPLACE FUNCTION curated.parse_month_column(p_column text)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_column ~ '^((jul|aug|sep|oct|nov|dec)_2021|(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)_202[2-6])$'
                THEN to_date(p_column, 'mon_YYYY') END
$$;

CREATE OR REPLACE FUNCTION curated.is_whole_number_text(p_value text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(btrim(p_value) ~ '^([0-9]+|[0-9]{1,3}(,[0-9]{3})+)$', FALSE)
$$;

DROP FUNCTION IF EXISTS curated.to_whole_number(text);
CREATE FUNCTION curated.to_whole_number(p_value text)
RETURNS integer LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN curated.is_whole_number_text(p_value) THEN
               CASE WHEN length(ltrim(v, '0')) < 10
                      OR (length(ltrim(v, '0')) = 10 AND ltrim(v, '0') <= '2147483647')
                    THEN v::integer END
           END
    FROM (SELECT replace(btrim(p_value), ',', '') AS v) AS s
$$;

CREATE OR REPLACE FUNCTION curated.is_money_text(p_value text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT coalesce(btrim(p_value) ~ '^[0-9]+(\.[0-9]{1,2})?$', FALSE)
$$;

CREATE OR REPLACE FUNCTION curated.to_money(p_value text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN v ~ '^[0-9]+(\.[0-9]{1,2})?$' THEN
               CASE WHEN length(ltrim(split_part(v, '.', 1), '0')) <= 8
                    THEN v::numeric(10,2) END
           END
    FROM (SELECT btrim(p_value) AS v) AS s
$$;

CREATE OR REPLACE FUNCTION curated.is_plausible_weekly_rent(p_rent numeric)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT p_rent BETWEEN 50 AND 5000
$$;

CREATE OR REPLACE FUNCTION curated.census_reference_date(p_year smallint)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN p_year = 2021 THEN date '2021-08-10' END
$$;

CREATE OR REPLACE FUNCTION curated.parse_erp_reference_date(p_year text)
RETURNS date LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE WHEN btrim(p_year) ~ '^202[2-6]$'
                THEN make_date(btrim(p_year)::integer, 6, 30) END
$$;

CREATE OR REPLACE FUNCTION curated.is_blank(p_value text)
RETURNS boolean LANGUAGE sql IMMUTABLE AS $$
    SELECT nullif(btrim(p_value), '') IS NULL
$$;

CREATE OR REPLACE FUNCTION curated.financial_year(p_date date)
RETURNS smallint LANGUAGE sql IMMUTABLE AS $$
    SELECT extract(year FROM p_date + interval '6 months')::smallint
$$;

-- In-scope LGAs (ASGS 2021) and reviewed name aliases.
CREATE TABLE IF NOT EXISTS curated.lga_reference (
    lga_code     text PRIMARY KEY CHECK (lga_code ~ '^[0-9]{5}$'),
    lga_name     text NOT NULL UNIQUE,
    state_code   text NOT NULL DEFAULT 'NSW',
    asgs_edition text NOT NULL,
    valid_from   date NOT NULL,
    valid_to     date,
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

CREATE TABLE IF NOT EXISTS curated.lga_alias (
    source_system    text NOT NULL,
    source_lga_value text NOT NULL,
    lga_code         text NOT NULL REFERENCES curated.lga_reference,
    match_method     text NOT NULL CHECK (match_method IN ('EXACT_NAME', 'REVIEWED_ALIAS')),
    reviewed_by      text,
    effective_from   date NOT NULL,
    effective_to     date,
    PRIMARY KEY (source_system, source_lga_value),
    CHECK (match_method = 'EXACT_NAME' OR reviewed_by IS NOT NULL)
);

INSERT INTO curated.lga_alias (source_system, source_lga_value, lga_code, match_method, effective_from)
SELECT s.source_system, curated.norm_text(r.lga_name), r.lga_code, 'EXACT_NAME', r.valid_from
FROM curated.lga_reference r
CROSS JOIN (VALUES ('DCJ_RENT'), ('NSW_HOUSING')) AS s(source_system)
ON CONFLICT (source_system, source_lga_value) DO NOTHING;

INSERT INTO curated.lga_alias
    (source_system, source_lga_value, lga_code, match_method, reviewed_by, effective_from) VALUES
    ('DCJ_RENT',    'CANTERBURY BANKSTOWN', '11570', 'REVIEWED_ALIAS', 'Geography steward (Team 3)', '2021-07-01'),
    ('DCJ_RENT',    'CAMPBELLTOWN',         '11500', 'REVIEWED_ALIAS', 'Geography steward (Team 3)', '2021-07-01'),
    ('NSW_HOUSING', 'CAMPBELLTOWN',         '11500', 'REVIEWED_ALIAS', 'Geography steward (Team 3)', '2021-07-01'),
    ('NSW_HOUSING', 'CITY OF SYDNEY',       '17200', 'REVIEWED_ALIAS', 'Geography steward (Team 3)', '2021-07-01')
ON CONFLICT (source_system, source_lga_value) DO NOTHING;

-- Reserved for a future postcode/SA2 allocation; empty in this prototype.
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

-- Mappings from source categories to standard values.
CREATE TABLE IF NOT EXISTS curated.dwelling_type_map (
    source_system          text NOT NULL,
    source_value           text NOT NULL,
    standard_dwelling_type text NOT NULL,
    PRIMARY KEY (source_system, source_value)
);
INSERT INTO curated.dwelling_type_map VALUES
    ('DCJ_RENT', 'FLAT/UNIT', 'Flat/Unit'),
    ('DCJ_RENT', 'HOUSE',     'House'),
    ('DCJ_RENT', 'TOWNHOUSE', 'Townhouse'),
    ('DCJ_RENT', 'TOTAL',     'All dwellings')
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS curated.bedroom_band_map (
    source_system text     NOT NULL,
    source_value  text     NOT NULL,
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
    source_measure text NOT NULL,
    stage_code     text NOT NULL REFERENCES curated.pipeline_stage_reference,
    PRIMARY KEY (source_system, source_measure)
);
INSERT INTO curated.pipeline_stage_map VALUES
    ('NSW_HOUSING', 'DWELLINGS IN LODGED DAS',                          'LODGED'),
    ('NSW_HOUSING', 'DWELLINGS IN APPROVED DAS',                        'DA_APPROVED'),
    ('NSW_HOUSING', 'DWELLINGS IN APPROVED CONSTRUCTION CERTIFICATES',  'CC_APPROVED')
ON CONFLICT DO NOTHING;

-- Validation rules R01-R07; check_order sets the first-failure order.
CREATE TABLE IF NOT EXISTS curated.validation_rule (
    rule_code        text PRIMARY KEY,
    rule_description text NOT NULL,
    check_order      smallint NOT NULL UNIQUE
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

-- Every rejected row or cell, with its rule code and original values.
CREATE TABLE IF NOT EXISTS curated.rejected_row (
    rejected_row_id bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    load_batch_id   integer     NOT NULL REFERENCES control.load_batch,
    source_system   text        NOT NULL,
    source_table    text        NOT NULL,
    source_row_id   bigint      NOT NULL,
    source_column   text,
    rule_code       text        NOT NULL REFERENCES curated.validation_rule,
    rejected_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
    raw_record      jsonb       NOT NULL
);

-- Accepted rows at each source's own grain.
CREATE TABLE IF NOT EXISTS curated.rental_accepted (
    source_row_id          bigint PRIMARY KEY,
    load_batch_id          integer NOT NULL,
    lga_code               text    NOT NULL REFERENCES curated.lga_reference,
    lga_match_method       text    NOT NULL,
    quarter_start          date    NOT NULL,
    standard_dwelling_type text    NOT NULL,
    bedroom_band           text    NOT NULL,
    median_weekly_rent     numeric(10,2) CHECK (median_weekly_rent > 0),
    is_rent_suppressed     boolean NOT NULL,
    bond_lodgement_count   integer CHECK (bond_lodgement_count >= 0),
    is_bond_count_suppressed boolean NOT NULL,
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
    reference_date                date    NOT NULL,
    estimated_resident_population integer NOT NULL CHECK (estimated_resident_population >= 0),
    UNIQUE (lga_code, reference_date)
);

CREATE TABLE IF NOT EXISTS curated.housing_supply_accepted (
    source_row_id  bigint  NOT NULL,
    source_column  text    NOT NULL,
    load_batch_id  integer NOT NULL,
    lga_code       text    NOT NULL REFERENCES curated.lga_reference,
    month_start    date    NOT NULL,
    stage_code     text    NOT NULL REFERENCES curated.pipeline_stage_reference,
    dwelling_count integer NOT NULL CHECK (dwelling_count >= 0),
    PRIMARY KEY (source_row_id, source_column),
    UNIQUE (lga_code, month_start, stage_code)
);

-- Warehouse dimensions.
CREATE TABLE IF NOT EXISTS dw.dim_time (
    time_key               integer  PRIMARY KEY,
    date_value             date     NOT NULL UNIQUE,
    month_start            date     NOT NULL,
    quarter_start          date     NOT NULL,
    calendar_month         smallint NOT NULL,
    calendar_quarter       smallint NOT NULL,
    calendar_quarter_label text     NOT NULL,
    calendar_year          smallint NOT NULL,
    financial_year         smallint NOT NULL,
    financial_year_label   text     NOT NULL
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
    is_all_dwellings       boolean NOT NULL,
    is_all_bedrooms        boolean NOT NULL,
    UNIQUE (standard_dwelling_type, bedroom_band)
);

CREATE TABLE IF NOT EXISTS dw.dim_pipeline_stage (
    pipeline_stage_key integer  PRIMARY KEY,
    stage_code         text     NOT NULL UNIQUE,
    stage_name         text     NOT NULL,
    stage_order        smallint NOT NULL,
    source_definition  text     NOT NULL
);

-- Facts at their declared grains; each keeps load_batch_id and source_row_id.
CREATE TABLE IF NOT EXISTS dw.fact_rental (
    rental_fact_key      bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    geography_key        integer NOT NULL REFERENCES dw.dim_geography,
    time_key             integer NOT NULL REFERENCES dw.dim_time,
    dwelling_type_key    integer NOT NULL REFERENCES dw.dim_dwelling_type,
    median_weekly_rent   numeric(10,2) CHECK (median_weekly_rent > 0),
    is_rent_suppressed   boolean NOT NULL,
    bond_lodgement_count integer CHECK (bond_lodgement_count >= 0),
    is_bond_count_suppressed boolean NOT NULL,
    load_batch_id        integer NOT NULL REFERENCES control.load_batch,
    source_row_id        bigint  NOT NULL REFERENCES src_rental.rent_lga_quarter_raw,
    UNIQUE (geography_key, time_key, dwelling_type_key)
);

CREATE TABLE IF NOT EXISTS dw.fact_census_income (
    census_income_fact_key         bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    geography_key                  integer NOT NULL REFERENCES dw.dim_geography,
    time_key                       integer NOT NULL REFERENCES dw.dim_time,
    median_weekly_household_income numeric(10,2) NOT NULL CHECK (median_weekly_household_income > 0),
    household_count                integer CHECK (household_count >= 0),
    census_vintage                 smallint NOT NULL,
    load_batch_id                  integer NOT NULL REFERENCES control.load_batch,
    source_row_id                  bigint  NOT NULL REFERENCES src_census.census_lga_income_raw,
    UNIQUE (geography_key, time_key)
);

CREATE TABLE IF NOT EXISTS dw.fact_population (
    population_fact_key           bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    geography_key                 integer NOT NULL REFERENCES dw.dim_geography,
    time_key                      integer NOT NULL REFERENCES dw.dim_time,
    estimated_resident_population integer NOT NULL CHECK (estimated_resident_population >= 0),
    load_batch_id                 integer NOT NULL REFERENCES control.load_batch,
    source_row_id                 bigint  NOT NULL REFERENCES src_population.population_lga_year_raw,
    UNIQUE (geography_key, time_key)
);

CREATE TABLE IF NOT EXISTS dw.fact_housing_supply (
    housing_supply_fact_key bigint  GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    geography_key           integer NOT NULL REFERENCES dw.dim_geography,
    time_key                integer NOT NULL REFERENCES dw.dim_time,
    pipeline_stage_key      integer NOT NULL REFERENCES dw.dim_pipeline_stage,
    dwelling_count          integer NOT NULL CHECK (dwelling_count >= 0),
    load_batch_id           integer NOT NULL REFERENCES control.load_batch,
    source_row_id           bigint  NOT NULL REFERENCES src_housing.housing_supply_lga_month_raw,
    source_column           text    NOT NULL,
    UNIQUE (geography_key, time_key, pipeline_stage_key)
);

COMMIT;

-- Check: reference table row counts.
SELECT 'lga_reference' AS reference_table, count(*) AS row_count FROM curated.lga_reference
UNION ALL SELECT 'lga_alias',            count(*) FROM curated.lga_alias
UNION ALL SELECT 'dwelling_type_map',    count(*) FROM curated.dwelling_type_map
UNION ALL SELECT 'bedroom_band_map',     count(*) FROM curated.bedroom_band_map
UNION ALL SELECT 'pipeline_stage_map',   count(*) FROM curated.pipeline_stage_map
UNION ALL SELECT 'validation_rule',      count(*) FROM curated.validation_rule;
