-- 08_load_dimensions.sql
-- Loads the four conformed dimensions before any facts.
-- Run in: hapo_a2. Depends on: 07.

BEGIN;

-- Clear the facts first, because they reference the dimensions.
TRUNCATE dw.fact_rental, dw.fact_census_income, dw.fact_population, dw.fact_housing_supply
    RESTART IDENTITY;
TRUNCATE dw.dim_time, dw.dim_geography, dw.dim_dwelling_type, dw.dim_pipeline_stage CASCADE;

-- One row per day, 2021-2026, with quarter and financial year.
INSERT INTO dw.dim_time
    (time_key, date_value, month_start, quarter_start, calendar_month, calendar_quarter,
     calendar_quarter_label, calendar_year, financial_year, financial_year_label)
SELECT to_char(d, 'YYYYMMDD')::int,
       d,
       date_trunc('month', d)::date,
       date_trunc('quarter', d)::date,
       extract(month   FROM d)::smallint,
       extract(quarter FROM d)::smallint,
       to_char(d, 'YYYY') || '-Q' || extract(quarter FROM d),
       extract(year    FROM d)::smallint,
       curated.financial_year(d),
       'FY' || (curated.financial_year(d) - 1) || '-' ||
               right(curated.financial_year(d)::text, 2)
FROM generate_series(date '2021-01-01', date '2026-12-31', interval '1 day') AS g(day_ts)
CROSS JOIN LATERAL (SELECT g.day_ts::date AS d) AS x;

-- One row per in-scope LGA (ASGS 2021).
INSERT INTO dw.dim_geography
    (geography_key, geography_level, geography_code, lga_code, lga_name, state_code,
     asgs_edition, valid_from, valid_to, current_flag)
SELECT row_number() OVER (ORDER BY lga_code, valid_from)::int,
       'LGA', lga_code, lga_code, lga_name, state_code,
       asgs_edition, valid_from, valid_to, valid_to IS NULL
FROM curated.lga_reference;

-- Dwelling type x bedroom band, including the Total/Total headline member.
INSERT INTO dw.dim_dwelling_type
    (dwelling_type_key, standard_dwelling_type, bedroom_band, is_all_dwellings, is_all_bedrooms)
SELECT row_number() OVER (ORDER BY (t.standard_dwelling_type = 'All dwellings'),
                                   t.standard_dwelling_type, b.band_order)::int,
       t.standard_dwelling_type,
       b.bedroom_band,
       t.standard_dwelling_type = 'All dwellings',
       b.bedroom_band = 'All bedrooms'
FROM (SELECT DISTINCT standard_dwelling_type FROM curated.dwelling_type_map) t
CROSS JOIN (SELECT DISTINCT bedroom_band, band_order FROM curated.bedroom_band_map) b;

-- The three approval stages.
INSERT INTO dw.dim_pipeline_stage
    (pipeline_stage_key, stage_code, stage_name, stage_order, source_definition)
SELECT stage_order, stage_code, stage_name, stage_order, source_definition
FROM curated.pipeline_stage_reference;

COMMIT;

-- Check: dimension row counts.
SELECT 'dim_time' AS dimension, count(*) AS row_count,
       min(date_value)::text AS first_member, max(date_value)::text AS last_member
FROM dw.dim_time
UNION ALL
SELECT 'dim_geography', count(*), min(lga_name), max(lga_name) FROM dw.dim_geography
UNION ALL
SELECT 'dim_dwelling_type', count(*), min(standard_dwelling_type), max(standard_dwelling_type) FROM dw.dim_dwelling_type
UNION ALL
SELECT 'dim_pipeline_stage', count(*), min(stage_code), max(stage_code) FROM dw.dim_pipeline_stage;
