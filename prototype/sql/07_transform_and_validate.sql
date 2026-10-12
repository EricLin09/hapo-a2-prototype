-- =============================================================================
-- File        : 07_transform_and_validate.sql
-- Purpose     : STAGING - type casting, trimming, date derivation, unpivot of the
--               wide housing file, source-code standardisation.
--               CURATED - LGA resolution, category mapping, validation rules,
--               de-duplication; every row ends up either accepted or rejected
--               with a rule code.
-- Design link : Data Flow steps 5-6 ("Stage", "Validate"); Solution Architecture
--               2.1 STAGING and CURATED; Key Strategy 4.1 (LGA code first, reviewed
--               alias only for names, reject unmatched rows and report the count).
-- Owner       : Team 3
-- Run in      : database hapo_a2
-- Depends on  : 06_load_or_insert_source_data.sql
-- Re-runnable : yes - staging and curated outputs are fully rebuilt each run
--               from the current delivery of each source
-- Expected    : rent 720 accepted / 8 rejected | census 10 / 2 | ERP 29 / 2 |
--               housing cells 718 / 26; staged = accepted + rejected for every source
--
-- Rule codes (curated.validation_rule) are checked in this order and the FIRST
-- failing rule is recorded:
--   R01 LGA unresolved -> R02 period unparseable -> R05 category unmapped ->
--   R06 measure blank -> R03 measure invalid -> R07 outlier -> R04 duplicate
-- "Current delivery" = the most recently registered file of each source system
-- (each delivery is a complete replacement of that source).
-- =============================================================================

BEGIN;

-- 0. Identify the current delivery of each source system.
CREATE TEMP TABLE current_file ON COMMIT DROP AS
SELECT DISTINCT ON (source_system)
       source_system, source_file_id, source_file_name, load_batch_id
FROM control.source_file
ORDER BY source_system, source_file_id DESC;

-- Full refresh of the curated outputs (staging tables are rebuilt below).
TRUNCATE curated.rental_accepted,
         curated.census_income_accepted,
         curated.population_accepted,
         curated.housing_supply_accepted,
         curated.rejected_row;

-- =============================================================================
-- 1. RENT (DCJ): LGA name x quarter x dwelling type x bedrooms
-- =============================================================================

-- 1a. Staging: parse and standardise, keep the parsing outcome visible.
DROP TABLE IF EXISTS staging.stg_rental;
CREATE TABLE staging.stg_rental AS
SELECT r.source_row_id,
       r.load_batch_id,
       r.source_row_number,
       curated.norm_text(r.lga_name)                          AS lga_name_norm,
       curated.parse_dcj_quarter(r.quarter)                   AS quarter_start,
       curated.norm_text(r.dwelling_type)                     AS dwelling_type_norm,
       curated.norm_text(r.bedrooms)                          AS bedrooms_norm,
       -- DCJ suppression symbols: median "-" (10 or fewer bonds);
       -- bond count "s" (30 or fewer) or "-" (10 or fewer)
       coalesce(btrim(r.median_weekly_rent) = '-', FALSE)               AS is_rent_suppressed,
       coalesce(btrim(r.new_bonds_lodged) IN ('s', '-'), FALSE)         AS is_bond_count_suppressed,
       -- syntax flags first, then range-safe parsing: an oversized value
       -- parses to NULL and is quarantined below instead of aborting the run
       curated.is_money_text(r.median_weekly_rent)            AS rent_syntax_ok,
       curated.is_whole_number_text(r.new_bonds_lodged)       AS bonds_syntax_ok,
       curated.to_money(r.median_weekly_rent)                 AS median_weekly_rent,
       curated.to_whole_number(r.new_bonds_lodged)            AS bond_lodgement_count,
       curated.is_blank(r.median_weekly_rent)
         OR curated.is_blank(r.new_bonds_lodged)              AS has_blank_measure
FROM src_rental.rent_lga_quarter_raw r
JOIN current_file cf ON cf.source_file_id = r.source_file_id;

-- 1b. Curated: resolve LGA and categories, apply rules in order.
CREATE TEMP TABLE rental_checked ON COMMIT DROP AS
SELECT s.*,
       a.lga_code,
       a.match_method,
       d.standard_dwelling_type,
       b.bedroom_band,
       CASE
           WHEN a.lga_code IS NULL                              THEN 'R01'
           WHEN s.quarter_start IS NULL                         THEN 'R02'
           WHEN d.standard_dwelling_type IS NULL
             OR b.bedroom_band IS NULL                          THEN 'R05'
           WHEN s.has_blank_measure                             THEN 'R06'
           -- "s" and "-" are legitimate suppressions, not errors; any other
           -- non-numeric, negative or zero value is invalid.
           WHEN NOT s.is_bond_count_suppressed
            AND NOT s.bonds_syntax_ok                           THEN 'R03'
           WHEN NOT s.is_rent_suppressed
            AND (NOT s.rent_syntax_ok
                 OR s.median_weekly_rent = 0)                   THEN 'R03'
           -- a well-formed number too large to store, or a rent outside the
           -- plausible range, is an outlier
           WHEN NOT s.is_bond_count_suppressed
            AND s.bond_lodgement_count IS NULL                  THEN 'R07'
           WHEN NOT s.is_rent_suppressed
            AND (s.median_weekly_rent IS NULL
                 OR NOT curated.is_plausible_weekly_rent(s.median_weekly_rent)) THEN 'R07'
       END AS rule_code
FROM staging.stg_rental s
LEFT JOIN curated.lga_alias a
       ON a.source_system    = 'DCJ_RENT'
      AND a.source_lga_value = s.lga_name_norm
      AND (s.quarter_start IS NULL
           OR (s.quarter_start >= a.effective_from
               AND (a.effective_to IS NULL OR s.quarter_start < a.effective_to)))
LEFT JOIN curated.dwelling_type_map d
       ON d.source_system = 'DCJ_RENT' AND d.source_value = s.dwelling_type_norm
LEFT JOIN curated.bedroom_band_map b
       ON b.source_system = 'DCJ_RENT' AND b.source_value = s.bedrooms_norm;

-- 1c. R04: among otherwise valid rows, keep the first row of each business
--     grain (lowest row number in the file) and reject later repeats.
UPDATE rental_checked c
SET rule_code = 'R04'
FROM (SELECT source_row_id,
             row_number() OVER (PARTITION BY lga_code, quarter_start,
                                             standard_dwelling_type, bedroom_band
                                ORDER BY source_row_number) AS rn
      FROM rental_checked
      WHERE rule_code IS NULL) dup
WHERE c.source_row_id = dup.source_row_id
  AND dup.rn > 1;

-- 1d. Write rejects (with the original row) and accepted rows.
INSERT INTO curated.rejected_row
    (load_batch_id, source_system, source_table, source_row_id, source_column, rule_code, raw_record)
SELECT c.load_batch_id, 'DCJ_RENT', 'src_rental.rent_lga_quarter_raw',
       c.source_row_id, NULL, c.rule_code, to_jsonb(r)
FROM rental_checked c
JOIN src_rental.rent_lga_quarter_raw r USING (source_row_id)
WHERE c.rule_code IS NOT NULL;

INSERT INTO curated.rental_accepted
    (source_row_id, load_batch_id, lga_code, lga_match_method, quarter_start,
     standard_dwelling_type, bedroom_band, median_weekly_rent, is_rent_suppressed,
     bond_lodgement_count, is_bond_count_suppressed)
SELECT source_row_id, load_batch_id, lga_code, match_method, quarter_start,
       standard_dwelling_type, bedroom_band, median_weekly_rent, is_rent_suppressed,
       bond_lodgement_count, is_bond_count_suppressed
FROM rental_checked
WHERE rule_code IS NULL;

-- =============================================================================
-- 2. CENSUS (ABS G02): LGA code x Census year
-- =============================================================================

-- 2a. Staging: strip the "LGA" prefix; the Census year is not a column in a
--     DataPack, it comes from the file name (e.g. "2021Census_G02_...").
DROP TABLE IF EXISTS staging.stg_census_income;
CREATE TABLE staging.stg_census_income AS
SELECT c.source_row_id,
       c.load_batch_id,
       c.source_row_number,
       regexp_replace(btrim(c.lga_code_2021), '^LGA', '')                AS lga_code,
       substring(cf.source_file_name FROM '^([0-9]{4})Census')::smallint AS census_year,
       curated.is_money_text(c.median_tot_hhd_inc_weekly)                AS income_syntax_ok,
       curated.to_money(c.median_tot_hhd_inc_weekly)                     AS median_weekly_household_income,
       NOT curated.is_blank(c.tot_hhds)                                  AS has_household_count,
       curated.is_whole_number_text(c.tot_hhds)                          AS households_syntax_ok,
       curated.to_whole_number(c.tot_hhds)                               AS household_count,
       curated.is_blank(c.median_tot_hhd_inc_weekly)                     AS has_blank_measure
FROM src_census.census_lga_income_raw c
JOIN current_file cf ON cf.source_file_id = c.source_file_id;

-- 2b. Curated checks. Census night is the reference date for the time key.
CREATE TEMP TABLE census_checked ON COMMIT DROP AS
SELECT s.*,
       curated.census_reference_date(s.census_year) AS census_date,
       CASE
           WHEN r.lga_code IS NULL                                   THEN 'R01'
           WHEN curated.census_reference_date(s.census_year) IS NULL THEN 'R02'
           WHEN s.has_blank_measure                                  THEN 'R06'
           WHEN NOT s.income_syntax_ok
             OR s.median_weekly_household_income = 0                 THEN 'R03'
           WHEN s.has_household_count AND NOT s.households_syntax_ok THEN 'R03'
           -- well-formed but too large to store
           WHEN s.median_weekly_household_income IS NULL
             OR (s.has_household_count AND s.household_count IS NULL) THEN 'R07'
       END AS rule_code
FROM staging.stg_census_income s
LEFT JOIN curated.lga_reference r ON r.lga_code = s.lga_code;

UPDATE census_checked c
SET rule_code = 'R04'
FROM (SELECT source_row_id,
             row_number() OVER (PARTITION BY lga_code, census_year
                                ORDER BY source_row_number) AS rn
      FROM census_checked
      WHERE rule_code IS NULL) dup
WHERE c.source_row_id = dup.source_row_id
  AND dup.rn > 1;

INSERT INTO curated.rejected_row
    (load_batch_id, source_system, source_table, source_row_id, source_column, rule_code, raw_record)
SELECT c.load_batch_id, 'ABS_CENSUS', 'src_census.census_lga_income_raw',
       c.source_row_id, NULL, c.rule_code, to_jsonb(r)
FROM census_checked c
JOIN src_census.census_lga_income_raw r USING (source_row_id)
WHERE c.rule_code IS NOT NULL;

INSERT INTO curated.census_income_accepted
    (source_row_id, load_batch_id, lga_code, census_year, census_date,
     median_weekly_household_income, household_count)
SELECT source_row_id, load_batch_id, lga_code, census_year, census_date,
       median_weekly_household_income, household_count
FROM census_checked
WHERE rule_code IS NULL;

-- =============================================================================
-- 3. POPULATION (ABS ERP): LGA code x 30 June
-- =============================================================================
DROP TABLE IF EXISTS staging.stg_population;
CREATE TABLE staging.stg_population AS
SELECT p.source_row_id,
       p.load_batch_id,
       p.source_row_number,
       btrim(p.lga_code)                                            AS lga_code,
       curated.parse_erp_reference_date(p.reference_year)             AS reference_date,
       curated.is_whole_number_text(p.erp)                          AS erp_syntax_ok,
       curated.to_whole_number(p.erp)                               AS estimated_resident_population,
       curated.is_blank(p.erp)                                      AS has_blank_measure
FROM src_population.population_lga_year_raw p
JOIN current_file cf ON cf.source_file_id = p.source_file_id;

CREATE TEMP TABLE population_checked ON COMMIT DROP AS
SELECT s.*,
       CASE
           WHEN r.lga_code IS NULL                          THEN 'R01'
           WHEN s.reference_date IS NULL                    THEN 'R02'
           WHEN s.has_blank_measure                         THEN 'R06'
           WHEN NOT s.erp_syntax_ok                         THEN 'R03'
           WHEN s.estimated_resident_population IS NULL     THEN 'R07'   -- too large to store
       END AS rule_code
FROM staging.stg_population s
LEFT JOIN curated.lga_reference r ON r.lga_code = s.lga_code;

UPDATE population_checked c
SET rule_code = 'R04'
FROM (SELECT source_row_id,
             row_number() OVER (PARTITION BY lga_code, reference_date
                                ORDER BY source_row_number) AS rn
      FROM population_checked
      WHERE rule_code IS NULL) dup
WHERE c.source_row_id = dup.source_row_id
  AND dup.rn > 1;

INSERT INTO curated.rejected_row
    (load_batch_id, source_system, source_table, source_row_id, source_column, rule_code, raw_record)
SELECT c.load_batch_id, 'ABS_ERP', 'src_population.population_lga_year_raw',
       c.source_row_id, NULL, c.rule_code, to_jsonb(r)
FROM population_checked c
JOIN src_population.population_lga_year_raw r USING (source_row_id)
WHERE c.rule_code IS NOT NULL;

INSERT INTO curated.population_accepted
    (source_row_id, load_batch_id, lga_code, reference_date, estimated_resident_population)
SELECT source_row_id, load_batch_id, lga_code, reference_date, estimated_resident_population
FROM population_checked
WHERE rule_code IS NULL;

-- =============================================================================
-- 4. HOUSING SUPPLY (NSW): wide month columns -> one row per LGA, month, stage
-- =============================================================================

-- 4a. Staging: unpivot. Each month column ("mar_2025") becomes its own row,
--     found generically from the column name, so adding a month to the source
--     file needs no code change here.
DROP TABLE IF EXISTS staging.stg_housing_supply;
CREATE TABLE staging.stg_housing_supply AS
SELECT h.source_row_id,
       h.load_batch_id,
       h.source_row_number,
       curated.norm_text(h.lga_name)              AS lga_name_norm,
       curated.norm_text(h.measure)               AS measure_norm,
       cell.key                                   AS source_column,
       curated.parse_month_column(cell.key)       AS month_start,
       cell.value                                 AS value_raw,
       curated.is_blank(cell.value)               AS is_blank_value,
       curated.is_whole_number_text(cell.value)   AS value_syntax_ok,
       curated.to_whole_number(cell.value)        AS dwelling_count
FROM src_housing.housing_supply_lga_month_raw h
JOIN current_file cf ON cf.source_file_id = h.source_file_id
CROSS JOIN LATERAL jsonb_each_text(to_jsonb(h)) AS cell(key, value)
WHERE cell.key ~ '^[a-z]{3}_[0-9]{4}$';

CREATE TEMP TABLE housing_checked ON COMMIT DROP AS
SELECT s.*,
       a.lga_code,
       m.stage_code,
       CASE
           WHEN a.lga_code IS NULL          THEN 'R01'
           WHEN s.month_start IS NULL       THEN 'R02'
           WHEN m.stage_code IS NULL        THEN 'R05'
           WHEN s.is_blank_value            THEN 'R06'   -- missing is NOT zero
           WHEN NOT s.value_syntax_ok       THEN 'R03'   -- negative or non-numeric
           WHEN s.dwelling_count IS NULL    THEN 'R07'   -- too large to store
       END AS rule_code
FROM staging.stg_housing_supply s
LEFT JOIN curated.lga_alias a
       ON a.source_system    = 'NSW_HOUSING'
      AND a.source_lga_value = s.lga_name_norm
      AND (s.month_start IS NULL
           OR (s.month_start >= a.effective_from
               AND (a.effective_to IS NULL OR s.month_start < a.effective_to)))
LEFT JOIN curated.pipeline_stage_map m
       ON m.source_system  = 'NSW_HOUSING'
      AND m.source_measure = s.measure_norm;

UPDATE housing_checked c
SET rule_code = 'R04'
FROM (SELECT source_row_id, source_column,
             row_number() OVER (PARTITION BY lga_code, month_start, stage_code
                                ORDER BY source_row_number) AS rn
      FROM housing_checked
      WHERE rule_code IS NULL) dup
WHERE c.source_row_id = dup.source_row_id
  AND c.source_column = dup.source_column
  AND dup.rn > 1;

-- Rejected at cell level: the row identity plus the single offending cell.
INSERT INTO curated.rejected_row
    (load_batch_id, source_system, source_table, source_row_id, source_column, rule_code, raw_record)
SELECT c.load_batch_id, 'NSW_HOUSING', 'src_housing.housing_supply_lga_month_raw',
       c.source_row_id, c.source_column, c.rule_code,
       jsonb_build_object('lga_name', r.lga_name, 'measure', r.measure,
                          'source_column', c.source_column, 'value', c.value_raw,
                          'source_row_number', r.source_row_number)
FROM housing_checked c
JOIN src_housing.housing_supply_lga_month_raw r USING (source_row_id)
WHERE c.rule_code IS NOT NULL;

INSERT INTO curated.housing_supply_accepted
    (source_row_id, source_column, load_batch_id, lga_code, month_start, stage_code, dwelling_count)
SELECT source_row_id, source_column, load_batch_id, lga_code, month_start, stage_code, dwelling_count
FROM housing_checked
WHERE rule_code IS NULL;

-- =============================================================================
-- 5. Reconciliation gate: staged = accepted + rejected for every source.
--    If any row was lost or double-counted, abort the whole transformation.
-- =============================================================================
DO $$
DECLARE
    rec record;
BEGIN
    FOR rec IN
        SELECT 'DCJ_RENT' AS src,
               (SELECT count(*) FROM staging.stg_rental)        AS staged,
               (SELECT count(*) FROM curated.rental_accepted)   AS accepted,
               (SELECT count(*) FROM curated.rejected_row WHERE source_system = 'DCJ_RENT') AS rejected
        UNION ALL
        SELECT 'ABS_CENSUS',
               (SELECT count(*) FROM staging.stg_census_income),
               (SELECT count(*) FROM curated.census_income_accepted),
               (SELECT count(*) FROM curated.rejected_row WHERE source_system = 'ABS_CENSUS')
        UNION ALL
        SELECT 'ABS_ERP',
               (SELECT count(*) FROM staging.stg_population),
               (SELECT count(*) FROM curated.population_accepted),
               (SELECT count(*) FROM curated.rejected_row WHERE source_system = 'ABS_ERP')
        UNION ALL
        SELECT 'NSW_HOUSING',
               (SELECT count(*) FROM staging.stg_housing_supply),
               (SELECT count(*) FROM curated.housing_supply_accepted),
               (SELECT count(*) FROM curated.rejected_row WHERE source_system = 'NSW_HOUSING')
    LOOP
        IF rec.staged <> rec.accepted + rec.rejected THEN
            RAISE EXCEPTION 'Reconciliation failed for %: staged % <> accepted % + rejected %',
                            rec.src, rec.staged, rec.accepted, rec.rejected;
        END IF;
    END LOOP;
END $$;

COMMIT;

-- Evidence: accepted vs rejected per source and rule.
SELECT source_system, rule_code, v.rule_description, count(*) AS rejected_rows
FROM curated.rejected_row r
JOIN curated.validation_rule v USING (rule_code)
GROUP BY source_system, rule_code, v.rule_description, v.check_order
ORDER BY source_system, v.check_order;

SELECT 'DCJ_RENT' AS source_system,
       (SELECT count(*) FROM staging.stg_rental) AS staged,
       (SELECT count(*) FROM curated.rental_accepted) AS accepted
UNION ALL SELECT 'ABS_CENSUS',  (SELECT count(*) FROM staging.stg_census_income),  (SELECT count(*) FROM curated.census_income_accepted)
UNION ALL SELECT 'ABS_ERP',     (SELECT count(*) FROM staging.stg_population),     (SELECT count(*) FROM curated.population_accepted)
UNION ALL SELECT 'NSW_HOUSING', (SELECT count(*) FROM staging.stg_housing_supply), (SELECT count(*) FROM curated.housing_supply_accepted);
