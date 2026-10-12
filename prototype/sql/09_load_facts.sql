-- =============================================================================
-- File        : 09_load_facts.sql
-- Purpose     : Load the four fact tables from the curated accepted rows, each at
--               its declared grain, with load_batch_id and source_row_id lineage.
-- Design link : Data Flow step 8 "Load facts"; Data Model 3.2 "Fact Tables and
--               Grain"; Logical Table Design 4 (FACT_RENTAL, FACT_CENSUS_INCOME,
--               FACT_POPULATION, FACT_HOUSING_SUPPLY).
-- Owner       : Team 3
-- Run in      : database hapo_a2
-- Depends on  : 08_load_dimensions.sql
-- Re-runnable : yes - facts are fully reloaded
-- Expected    : fact_rental 720 | fact_census_income 10 | fact_population 29 |
--               fact_housing_supply 718 (each equal to its curated accepted count)
--
-- Facts are never joined to each other here. They have different grains
-- (quarter, Census year, 30 June, month) and are only combined in the report
-- views after aggregation to a common LGA and period.
-- =============================================================================

BEGIN;

TRUNCATE dw.fact_rental, dw.fact_census_income, dw.fact_population, dw.fact_housing_supply
    RESTART IDENTITY;

-- FACT_RENTAL - grain: LGA x quarter (time_key = quarter start) x dwelling type x bedroom band
INSERT INTO dw.fact_rental
    (geography_key, time_key, dwelling_type_key, median_weekly_rent, is_rent_suppressed,
     bond_lodgement_count, is_bond_count_suppressed, load_batch_id, source_row_id)
SELECT g.geography_key,
       t.time_key,
       d.dwelling_type_key,
       a.median_weekly_rent,
       a.is_rent_suppressed,
       a.bond_lodgement_count,
       a.is_bond_count_suppressed,
       a.load_batch_id,
       a.source_row_id
FROM curated.rental_accepted a
JOIN dw.dim_geography g
  ON g.lga_code = a.lga_code
 AND a.quarter_start >= g.valid_from
 AND (g.valid_to IS NULL OR a.quarter_start < g.valid_to)     -- version valid for the period
JOIN dw.dim_time t          ON t.date_value = a.quarter_start
JOIN dw.dim_dwelling_type d ON d.standard_dwelling_type = a.standard_dwelling_type
                           AND d.bedroom_band = a.bedroom_band
ORDER BY a.source_row_id;

-- FACT_CENSUS_INCOME - grain: LGA x Census year (time_key = Census night)
INSERT INTO dw.fact_census_income
    (geography_key, time_key, median_weekly_household_income, household_count,
     census_vintage, load_batch_id, source_row_id)
SELECT g.geography_key,
       t.time_key,
       a.median_weekly_household_income,
       a.household_count,
       a.census_year,
       a.load_batch_id,
       a.source_row_id
FROM curated.census_income_accepted a
JOIN dw.dim_geography g
  ON g.lga_code = a.lga_code
 AND a.census_date >= g.valid_from
 AND (g.valid_to IS NULL OR a.census_date < g.valid_to)
JOIN dw.dim_time t ON t.date_value = a.census_date
ORDER BY a.source_row_id;

-- FACT_POPULATION - grain: LGA x 30 June reference date
INSERT INTO dw.fact_population
    (geography_key, time_key, estimated_resident_population, load_batch_id, source_row_id)
SELECT g.geography_key,
       t.time_key,
       a.estimated_resident_population,
       a.load_batch_id,
       a.source_row_id
FROM curated.population_accepted a
JOIN dw.dim_geography g
  ON g.lga_code = a.lga_code
 AND a.reference_date >= g.valid_from
 AND (g.valid_to IS NULL OR a.reference_date < g.valid_to)
JOIN dw.dim_time t ON t.date_value = a.reference_date
ORDER BY a.source_row_id;

-- FACT_HOUSING_SUPPLY - grain: LGA x month (time_key = month start) x pipeline stage
INSERT INTO dw.fact_housing_supply
    (geography_key, time_key, pipeline_stage_key, dwelling_count, load_batch_id,
     source_row_id, source_column)
SELECT g.geography_key,
       t.time_key,
       s.pipeline_stage_key,
       a.dwelling_count,
       a.load_batch_id,
       a.source_row_id,
       a.source_column
FROM curated.housing_supply_accepted a
JOIN dw.dim_geography g
  ON g.lga_code = a.lga_code
 AND a.month_start >= g.valid_from
 AND (g.valid_to IS NULL OR a.month_start < g.valid_to)
JOIN dw.dim_time t           ON t.date_value = a.month_start
JOIN dw.dim_pipeline_stage s ON s.stage_code = a.stage_code
ORDER BY a.source_row_id, a.month_start;

-- Gate: the dimension joins above are INNER joins. If any accepted row failed
-- to find its dimension member it would silently disappear, so the fact count
-- must equal the curated accepted count for every fact.
DO $$
DECLARE
    rec record;
BEGIN
    FOR rec IN
        SELECT 'fact_rental' AS fact,
               (SELECT count(*) FROM dw.fact_rental)              AS facts,
               (SELECT count(*) FROM curated.rental_accepted)     AS accepted
        UNION ALL
        SELECT 'fact_census_income',
               (SELECT count(*) FROM dw.fact_census_income),
               (SELECT count(*) FROM curated.census_income_accepted)
        UNION ALL
        SELECT 'fact_population',
               (SELECT count(*) FROM dw.fact_population),
               (SELECT count(*) FROM curated.population_accepted)
        UNION ALL
        SELECT 'fact_housing_supply',
               (SELECT count(*) FROM dw.fact_housing_supply),
               (SELECT count(*) FROM curated.housing_supply_accepted)
    LOOP
        IF rec.facts <> rec.accepted THEN
            RAISE EXCEPTION '% lost rows in dimension lookup: % facts vs % accepted',
                            rec.fact, rec.facts, rec.accepted;
        END IF;
    END LOOP;
END $$;

COMMIT;

SELECT 'fact_rental' AS fact_table, count(*) AS row_count FROM dw.fact_rental
UNION ALL SELECT 'fact_census_income',  count(*) FROM dw.fact_census_income
UNION ALL SELECT 'fact_population',     count(*) FROM dw.fact_population
UNION ALL SELECT 'fact_housing_supply', count(*) FROM dw.fact_housing_supply;
