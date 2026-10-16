-- 11_run_quality_tests.sql
-- Runs 50 tests and stores the results in control.test_result. Any CRITICAL
-- failure stops the build. Results collect in control.test_work, so the file
-- can be run in one go or in two parts (see PART 2).
-- Run in: hapo_a2. Depends on: 10.

-- Start a new collection of results.
TRUNCATE control.test_work;

-- Build smoke tests.
INSERT INTO control.test_work
SELECT 'TC-SM-01', 'Build smoke', 'All 10 prototype schemas exist', 'CRITICAL', '10',
       count(*)::text, '01_create_database_schemas.sql'
FROM pg_namespace
WHERE nspname IN ('control','landing','src_rental','src_census','src_population',
                  'src_housing','staging','curated','dw','reporting');

INSERT INTO control.test_work
SELECT 'TC-SM-02', 'Build smoke', 'All required tables and views exist (missing objects)', 'CRITICAL', '0',
       count(*) FILTER (WHERE to_regclass(obj) IS NULL)::text, '03, 04, 10'
FROM unnest(ARRAY[
    'control.load_batch','control.source_file','control.test_result','control.test_run',
    'src_rental.rent_lga_quarter_raw','src_census.census_lga_income_raw',
    'src_population.population_lga_year_raw','src_housing.housing_supply_lga_month_raw',
    'staging.stg_rental','staging.stg_census_income','staging.stg_population','staging.stg_housing_supply',
    'control.test_work',
    'curated.lga_alias','curated.geography_crosswalk','curated.rejected_row',
    'dw.dim_time','dw.dim_geography','dw.dim_dwelling_type','dw.dim_pipeline_stage',
    'dw.fact_rental','dw.fact_census_income','dw.fact_population','dw.fact_housing_supply',
    'reporting.vw_rental_affordability','reporting.vw_population_supply',
    'reporting.vw_housing_pipeline','reporting.vw_lineage',
    'reporting.vw_dashboard_uc1','reporting.vw_dashboard_uc2','reporting.vw_dashboard_uc3']) AS obj;

-- Load and idempotency.
INSERT INTO control.test_work
SELECT 'TC-LD-01', 'Load reconciliation', 'Every registered file has exactly its row count in the source table (files with a mismatch)',
       'CRITICAL', '0',
       count(*) FILTER (WHERE f.row_count <> coalesce(c.n, 0))::text, '06_load_or_insert_source_data.sql'
FROM control.source_file f
LEFT JOIN (
    SELECT source_file_id, count(*) AS n FROM src_rental.rent_lga_quarter_raw GROUP BY 1
    UNION ALL SELECT source_file_id, count(*) FROM src_census.census_lga_income_raw GROUP BY 1
    UNION ALL SELECT source_file_id, count(*) FROM src_population.population_lga_year_raw GROUP BY 1
    UNION ALL SELECT source_file_id, count(*) FROM src_housing.housing_supply_lga_month_raw GROUP BY 1
) c USING (source_file_id);

INSERT INTO control.test_work
SELECT 'TC-LD-02', 'Idempotency', 'Source rows equal delivered rows after loading the same files twice',
       'CRITICAL',
       ((SELECT count(*) FROM landing.dcj_rent_lga_quarter)
      + (SELECT count(*) FROM landing.abs_census_g02_lga)
      + (SELECT count(*) FROM landing.abs_erp_lga)
      + (SELECT count(*) FROM landing.nsw_housing_supply_lga_month))::text,
       ((SELECT count(*) FROM src_rental.rent_lga_quarter_raw)
      + (SELECT count(*) FROM src_census.census_lga_income_raw)
      + (SELECT count(*) FROM src_population.population_lga_year_raw)
      + (SELECT count(*) FROM src_housing.housing_supply_lga_month_raw))::text,
       'results/06b_idempotent_reload.log';

INSERT INTO control.test_work
SELECT 'TC-LD-03', 'Idempotency', 'Latest load skipped the same files with zero rows inserted',
       'CRITICAL', 'SKIPPED_NO_CHANGE|0|0',
       coalesce((SELECT status || '|' || files_loaded || '|' || rows_loaded
                 FROM control.load_batch
                 ORDER BY load_batch_id DESC LIMIT 1), 'NOT_FOUND'),
       'control.load_batch';

-- Validation reconciliation and planted defects.
INSERT INTO control.test_work
SELECT 'TC-VR-0' || n, 'Validation reconciliation', src || ': staged rows = accepted + rejected', 'CRITICAL',
       staged::text, (accepted + rejected)::text, '07_transform_and_validate.sql'
FROM (VALUES
    (1, 'DCJ_RENT',    (SELECT count(*) FROM staging.stg_rental),
                       (SELECT count(*) FROM curated.rental_accepted)),
    (2, 'ABS_CENSUS',  (SELECT count(*) FROM staging.stg_census_income),
                       (SELECT count(*) FROM curated.census_income_accepted)),
    (3, 'ABS_ERP',     (SELECT count(*) FROM staging.stg_population),
                       (SELECT count(*) FROM curated.population_accepted)),
    (4, 'NSW_HOUSING', (SELECT count(*) FROM staging.stg_housing_supply),
                       (SELECT count(*) FROM curated.housing_supply_accepted))
) AS v(n, src, staged, accepted)
CROSS JOIN LATERAL (SELECT count(*) AS rejected FROM curated.rejected_row r
                    WHERE r.source_system = v.src) AS r;

INSERT INTO control.test_work
SELECT 'TC-VR-05', 'Negative tests', 'Rejected rows by source and rule match the planted defects', 'CRITICAL',
       'ABS_CENSUS:R01=1; ABS_CENSUS:R03=1; ABS_ERP:R06=1; ABS_ERP:R07=1; DCJ_RENT:R01=1; DCJ_RENT:R02=1; '
    || 'DCJ_RENT:R03=2; DCJ_RENT:R04=1; DCJ_RENT:R05=1; DCJ_RENT:R07=2; '
    || 'NSW_HOUSING:R03=1; NSW_HOUSING:R05=24; NSW_HOUSING:R06=1',
       string_agg(source_system || ':' || rule_code || '=' || n, '; ' ORDER BY source_system, rule_code),
       'curated.rejected_row'
FROM (SELECT source_system, rule_code, count(*) AS n
      FROM curated.rejected_row GROUP BY 1, 2) x;

-- Transformation units: parsing, aliases, suppression and rules.
INSERT INTO control.test_work VALUES
 ('TC-TU-01', 'Transformation unit', 'Quarter label "Mar Qtr 2025" -> quarter start', 'CRITICAL',
  '2025-01-01', curated.parse_dcj_quarter('Mar Qtr 2025')::text, 'curated.parse_dcj_quarter'),
 ('TC-TU-02', 'Transformation unit', 'Malformed quarter "Qtr 3 2025" -> NULL (rejected as R02)', 'CRITICAL',
  'NULL', coalesce(curated.parse_dcj_quarter('Qtr 3 2025')::text, 'NULL'), 'curated.parse_dcj_quarter'),
 ('TC-TU-03', 'Transformation unit', 'Financial year of 30 Jun 2025 and 1 Jul 2025', 'CRITICAL',
  '2025,2026', curated.financial_year('2025-06-30') || ',' || curated.financial_year('2025-07-01'),
  'curated.financial_year'),
 ('TC-TU-04', 'Transformation unit', 'Month column "mar_2025" -> month start', 'CRITICAL',
  '2025-03-01', curated.parse_month_column('mar_2025')::text, 'curated.parse_month_column'),
 ('TC-TU-05', 'Transformation unit', 'Number "412,345" parsed; "-5" and "" rejected', 'CRITICAL',
  '412345,NULL,NULL',
  curated.to_whole_number('412,345') || ',' ||
  coalesce(curated.to_whole_number('-5')::text, 'NULL') || ',' ||
  coalesce(curated.to_whole_number('')::text, 'NULL'), 'curated.to_whole_number'),
 ('TC-TU-06', 'Transformation unit', 'Name normalisation "  liverpool " -> LIVERPOOL', 'CRITICAL',
  'LIVERPOOL', curated.norm_text('  liverpool '), 'curated.norm_text');

INSERT INTO control.test_work
SELECT 'TC-TU-07', 'LGA resolution', 'Rent rows resolved through reviewed aliases (Canterbury Bankstown, Campbelltown)',
       'CRITICAL', '144', count(*)::text, 'curated.lga_alias'
FROM curated.rental_accepted WHERE lga_match_method = 'REVIEWED_ALIAS';

INSERT INTO control.test_work
SELECT 'TC-TU-08', 'LGA resolution', 'Liverpool accepted for all 8 quarters despite one lower-case quarter',
       'CRITICAL', '72', count(*)::text, 'curated.rental_accepted'
FROM curated.rental_accepted WHERE lga_code = '14900';

INSERT INTO control.test_work
SELECT 'TC-TU-09', 'Suppression', 'Suppressed medians ("-") and bond counts ("s", "-") are NULL, never 0 (rows breaking this)',
       'CRITICAL', '0',
       count(*) FILTER (WHERE (is_rent_suppressed AND median_weekly_rent IS NOT NULL)
                           OR (is_bond_count_suppressed AND bond_lodgement_count IS NOT NULL))::text,
       'dw.fact_rental'
FROM dw.fact_rental;

INSERT INTO control.test_work
SELECT 'TC-TU-10', 'Suppression', 'Both DCJ suppression levels occur in the data (median "-" rows | count-only "s" rows)',
       'WARNING', 'true|true',
       (count(*) FILTER (WHERE is_rent_suppressed) > 0)::text || '|' ||
       (count(*) FILTER (WHERE is_bond_count_suppressed AND NOT is_rent_suppressed) > 0)::text,
       'dw.fact_rental'
FROM dw.fact_rental;

INSERT INTO control.test_work VALUES
 ('TC-TU-11', 'Transformation unit', 'Outlier rule: rent 9999 and 35 implausible, 600 plausible', 'CRITICAL',
  'false,false,true',
  curated.is_plausible_weekly_rent(9999) || ',' || curated.is_plausible_weekly_rent(35) || ',' ||
  curated.is_plausible_weekly_rent(600), 'curated.is_plausible_weekly_rent');

INSERT INTO control.test_work
SELECT 'TC-TU-12', 'Negative tests', 'Planted zero rent is rejected as invalid measure R03',
       'CRITICAL', 'R03',

       coalesce((SELECT string_agg(r.rule_code, ',' ORDER BY r.rule_code)
                 FROM curated.rejected_row r
                 JOIN src_rental.rent_lga_quarter_raw s ON s.source_row_id = r.source_row_id
                 WHERE r.source_system = 'DCJ_RENT' AND s.median_weekly_rent = '0'), 'NOT_FOUND'),
       'curated.rejected_row';

INSERT INTO control.test_work VALUES
 ('TC-TU-13', 'Transformation unit', 'Only 2021 Census resolves to a supported reference date',
  'CRITICAL', 'NULL|2021-08-10|NULL',
  coalesce(curated.census_reference_date(2016::smallint)::text, 'NULL') || '|' ||
  curated.census_reference_date(2021::smallint)::text || '|' ||
  coalesce(curated.census_reference_date(NULL::smallint)::text, 'NULL'),
  'curated.census_reference_date');

INSERT INTO control.test_work VALUES
 ('TC-TU-15', 'Transformation unit',
  'Range-safe parsing: integer max | max + 1 | 8-digit money | 9-digit money', 'CRITICAL',
  '2147483647|NULL|99999999.99|NULL',
  coalesce(curated.to_whole_number('2,147,483,647')::text, 'NULL') || '|' ||
  coalesce(curated.to_whole_number('2147483648')::text, 'NULL') || '|' ||
  coalesce(curated.to_money('99999999.99')::text, 'NULL') || '|' ||
  coalesce(curated.to_money('123456789')::text, 'NULL'),
  'curated.to_whole_number, curated.to_money');

INSERT INTO control.test_work VALUES
 ('TC-TU-16', 'Transformation unit', 'Malformed thousands separators are invalid', 'CRITICAL',
  'false|NULL|false|NULL',
  curated.is_whole_number_text('12,34')::text || '|' ||
  coalesce(curated.to_whole_number('12,34')::text, 'NULL') || '|' ||
  curated.is_whole_number_text('1,,234')::text || '|' ||
  coalesce(curated.to_whole_number('1,,234')::text, 'NULL'),
  'curated.is_whole_number_text, curated.to_whole_number'),
 ('TC-TU-17', 'Transformation unit', 'Invalid or unsupported quarter/month labels return NULL',
  'CRITICAL', 'NULL|NULL|NULL|NULL',
  coalesce(curated.parse_dcj_quarter('Mar Qtr 0000')::text, 'NULL') || '|' ||
  coalesce(curated.parse_dcj_quarter('Mar Qtr 2020')::text, 'NULL') || '|' ||
  coalesce(curated.parse_month_column('abc_2025')::text, 'NULL') || '|' ||
  coalesce(curated.parse_month_column('jan_2021')::text, 'NULL'),
  'curated.parse_dcj_quarter, curated.parse_month_column'),
 ('TC-TU-18', 'Transformation unit', 'ERP year is validated before make_date', 'CRITICAL',
  'NULL|NULL|2025-06-30|NULL',
  coalesce(curated.parse_erp_reference_date('0000')::text, 'NULL') || '|' ||
  coalesce(curated.parse_erp_reference_date('2021')::text, 'NULL') || '|' ||
  coalesce(curated.parse_erp_reference_date('2025')::text, 'NULL') || '|' ||
  coalesce(curated.parse_erp_reference_date('2027')::text, 'NULL'),
  'curated.parse_erp_reference_date');

INSERT INTO control.test_work
SELECT 'TC-TU-14', 'Census scope', 'No non-2021 Census rows reach curated accepted data',
       'CRITICAL', '0', count(*)::text, 'curated.census_income_accepted'
FROM curated.census_income_accepted WHERE census_year IS DISTINCT FROM 2021;

-- ============================================================================
-- PART 2: if your SQL client cannot run the whole file, run the part above
-- this line first, then the part below it.
-- ============================================================================

-- Warehouse integrity.
INSERT INTO control.test_work
SELECT 'TC-DW-0' || n, 'Fact completeness', fact || ': fact rows = curated accepted rows', 'CRITICAL',
       accepted::text, facts::text, '09_load_facts.sql'
FROM (VALUES
    (1, 'fact_rental',         (SELECT count(*) FROM dw.fact_rental),         (SELECT count(*) FROM curated.rental_accepted)),
    (2, 'fact_census_income',  (SELECT count(*) FROM dw.fact_census_income),  (SELECT count(*) FROM curated.census_income_accepted)),
    (3, 'fact_population',     (SELECT count(*) FROM dw.fact_population),     (SELECT count(*) FROM curated.population_accepted)),
    (4, 'fact_housing_supply', (SELECT count(*) FROM dw.fact_housing_supply), (SELECT count(*) FROM curated.housing_supply_accepted))
) AS v(n, fact, facts, accepted);

INSERT INTO control.test_work
SELECT 'TC-DW-05', 'Fact-grain uniqueness', 'Duplicate grain groups across all four facts', 'CRITICAL', '0',
       ((SELECT count(*) FROM (SELECT 1 FROM dw.fact_rental GROUP BY geography_key, time_key, dwelling_type_key HAVING count(*) > 1) a)
      + (SELECT count(*) FROM (SELECT 1 FROM dw.fact_census_income GROUP BY geography_key, time_key HAVING count(*) > 1) b)
      + (SELECT count(*) FROM (SELECT 1 FROM dw.fact_population GROUP BY geography_key, time_key HAVING count(*) > 1) c)
      + (SELECT count(*) FROM (SELECT 1 FROM dw.fact_housing_supply GROUP BY geography_key, time_key, pipeline_stage_key HAVING count(*) > 1) d)
       )::text, 'dw.fact_*';

INSERT INTO control.test_work
SELECT 'TC-DW-06', 'Referential integrity', 'Fact rows whose dimension key does not resolve', 'CRITICAL', '0',
       ((SELECT count(*) FROM dw.fact_rental f
           LEFT JOIN dw.dim_geography g USING (geography_key)
           LEFT JOIN dw.dim_time t USING (time_key)
           LEFT JOIN dw.dim_dwelling_type d USING (dwelling_type_key)
          WHERE g.geography_key IS NULL OR t.time_key IS NULL OR d.dwelling_type_key IS NULL)
      + (SELECT count(*) FROM dw.fact_census_income f
           LEFT JOIN dw.dim_geography g USING (geography_key)
           LEFT JOIN dw.dim_time t USING (time_key)
          WHERE g.geography_key IS NULL OR t.time_key IS NULL)
      + (SELECT count(*) FROM dw.fact_population f
           LEFT JOIN dw.dim_geography g USING (geography_key)
           LEFT JOIN dw.dim_time t USING (time_key)
          WHERE g.geography_key IS NULL OR t.time_key IS NULL)
      + (SELECT count(*) FROM dw.fact_housing_supply f
           LEFT JOIN dw.dim_geography g USING (geography_key)
           LEFT JOIN dw.dim_time t USING (time_key)
           LEFT JOIN dw.dim_pipeline_stage s USING (pipeline_stage_key)
          WHERE g.geography_key IS NULL OR t.time_key IS NULL OR s.pipeline_stage_key IS NULL)
       )::text, 'dw.fact_*';

INSERT INTO control.test_work
SELECT 'TC-DW-07', 'Domain and range', 'Out-of-range measures (rent <= 0, income <= 0, negative counts)', 'CRITICAL', '0',
       ((SELECT count(*) FROM dw.fact_rental WHERE median_weekly_rent <= 0 OR bond_lodgement_count < 0)
      + (SELECT count(*) FROM dw.fact_census_income WHERE median_weekly_household_income <= 0)
      + (SELECT count(*) FROM dw.fact_population WHERE estimated_resident_population < 0)
      + (SELECT count(*) FROM dw.fact_housing_supply WHERE dwelling_count < 0))::text, 'dw.fact_*';

INSERT INTO control.test_work
SELECT 'TC-DW-08', 'Lineage (UC5)', 'Every fact row traces to a source file row', 'CRITICAL',
       ((SELECT count(*) FROM dw.fact_rental) + (SELECT count(*) FROM dw.fact_census_income)
      + (SELECT count(*) FROM dw.fact_population) + (SELECT count(*) FROM dw.fact_housing_supply))::text,
       count(*) FILTER (WHERE source_file_name IS NOT NULL AND source_row_number IS NOT NULL)::text,
       'reporting.vw_lineage'
FROM reporting.vw_lineage;

-- Metrics: hand-calculated golden values.
INSERT INTO control.test_work
SELECT 'TC-MT-01', 'Metric', 'UC1 Parramatta 2025-Q1: rent | 2021 income | rent-to-income %', 'CRITICAL',
       '600.00|2000.00|30.00',
       coalesce((SELECT string_agg(median_weekly_rent || '|' || census_median_weekly_household_income
                                   || '|' || rent_to_income_pct, ' ; ')
                 FROM reporting.vw_rental_affordability
                 WHERE lga_code = '16260' AND quarter = '2025-Q1' AND is_lga_headline), 'NOT_FOUND'),
       'reporting.vw_rental_affordability';

INSERT INTO control.test_work
SELECT 'TC-MT-02', 'Metric', 'UC2 Parramatta FY2024-25: ERP start | end | change | growth % | DA approved | per 1,000',
       'CRITICAL', '260000|265200|5200|2.00|2400|9.05',
       coalesce((SELECT string_agg(erp_start_30_june || '|' || erp_end_30_june || '|' || population_change
                                   || '|' || population_growth_pct || '|' || da_approved_dwellings
                                   || '|' || da_approved_per_1000_residents, ' ; ')
                 FROM reporting.vw_population_supply
                 WHERE lga_code = '16260' AND financial_year_label = 'FY2024-25'), 'NOT_FOUND'),
       'reporting.vw_population_supply';

INSERT INTO control.test_work
SELECT 'TC-MT-03', 'Metric', 'UC2 incomplete supply years are flagged (Penrith FY2024-25, Fairfield FY2025-26)',
       'CRITICAL', 'Fairfield FY2025-26; Penrith FY2024-25',
       string_agg(lga_name || ' ' || financial_year_label, '; ' ORDER BY lga_name),
       'reporting.vw_population_supply'
FROM reporting.vw_population_supply
WHERE NOT is_complete_supply_year;

INSERT INTO control.test_work
SELECT 'TC-MT-04', 'Metric', 'UC2 growth is unavailable (not zero) where an ERP is missing', 'CRITICAL', '0',
       count(*) FILTER (WHERE (erp_start_30_june IS NULL OR erp_end_30_june IS NULL)
                         AND population_growth_pct IS NOT NULL)::text,
       'reporting.vw_population_supply'
FROM reporting.vw_population_supply;

-- Report reconciliation.
INSERT INTO control.test_work
SELECT 'TC-RR-01', 'Report reconciliation',
       'UC1 headline bonds = sum of details, or >= sum of published details when some are suppressed (violations)',
       'CRITICAL', '0', count(*)::text, 'reporting.vw_rental_affordability'
FROM (SELECT lga_code, quarter,
             sum(bond_lodgement_count) FILTER (WHERE is_lga_headline)     AS headline,
             sum(bond_lodgement_count) FILTER (WHERE NOT is_lga_headline) AS detail,
             bool_or(is_bond_count_suppressed) FILTER (WHERE NOT is_lga_headline) AS any_detail_suppressed
      FROM reporting.vw_rental_affordability
      GROUP BY lga_code, quarter) x
WHERE (NOT any_detail_suppressed AND headline IS DISTINCT FROM detail)
   OR (any_detail_suppressed AND (headline IS NULL OR headline < detail));

INSERT INTO control.test_work
SELECT 'TC-RR-02', 'Report reconciliation', 'UC2 total DA-approved dwellings = fact total', 'CRITICAL',
       (SELECT sum(f.dwelling_count) FROM dw.fact_housing_supply f
          JOIN dw.dim_pipeline_stage s USING (pipeline_stage_key)
         WHERE s.stage_code = 'DA_APPROVED')::text,
       (SELECT sum(da_approved_dwellings) FROM reporting.vw_population_supply)::text,
       'reporting.vw_population_supply';

INSERT INTO control.test_work
SELECT 'TC-RR-03', 'Report reconciliation', 'UC3 total dwellings across stages = fact total', 'CRITICAL',
       (SELECT sum(dwelling_count) FROM dw.fact_housing_supply)::text,
       (SELECT sum(coalesce(lodged_dwellings, 0) + coalesce(da_approved_dwellings, 0)
                 + coalesce(cc_approved_dwellings, 0)) FROM reporting.vw_housing_pipeline)::text,
       'reporting.vw_housing_pipeline';

INSERT INTO control.test_work
SELECT 'TC-RR-04', 'Median sanity', 'LGA headline median lies within its detail medians (violations)', 'WARNING', '0',
       count(*)::text, 'reporting.vw_rental_affordability'
FROM (SELECT lga_code, quarter,
             max(median_weekly_rent) FILTER (WHERE is_lga_headline)     AS headline,
             min(median_weekly_rent) FILTER (WHERE NOT is_lga_headline) AS lo,
             max(median_weekly_rent) FILTER (WHERE NOT is_lga_headline) AS hi
      FROM reporting.vw_rental_affordability
      GROUP BY lga_code, quarter) x
WHERE headline < lo OR headline > hi;

-- Join integrity.
INSERT INTO control.test_work
SELECT 'TC-JN-01', 'Join integrity', 'UC1 view has exactly one row per rental fact (joins do not multiply rows)',
       'CRITICAL',
       (SELECT count(*) FROM dw.fact_rental)::text,
       (SELECT count(*) FROM reporting.vw_rental_affordability)::text,
       'reporting.vw_rental_affordability';

INSERT INTO control.test_work
SELECT 'TC-JN-02', 'Join integrity', 'UC1 report grain (LGA, quarter, dwelling type, bedrooms) is unique (duplicate groups)',
       'CRITICAL', '0', count(*)::text, 'reporting.vw_rental_affordability'
FROM (SELECT 1 FROM reporting.vw_rental_affordability
      GROUP BY lga_code, quarter_start, standard_dwelling_type, bedroom_band
      HAVING count(*) > 1) x;

INSERT INTO control.test_work
SELECT 'TC-JN-03', 'Join integrity', 'UC2 report grain (LGA, financial year) is unique (duplicate groups)',
       'CRITICAL', '0', count(*)::text, 'reporting.vw_population_supply'
FROM (SELECT 1 FROM reporting.vw_population_supply
      GROUP BY lga_code, financial_year
      HAVING count(*) > 1) x;

INSERT INTO control.test_work
SELECT 'TC-JN-04', 'Join integrity', 'UC3 report grain (LGA, month) is unique (duplicate groups)',
       'CRITICAL', '0', count(*)::text, 'reporting.vw_housing_pipeline'
FROM (SELECT 1 FROM reporting.vw_housing_pipeline
      GROUP BY lga_code, month_start
      HAVING count(*) > 1) x;

INSERT INTO control.test_work
SELECT 'TC-JN-05', 'Temporal join', 'UC1 never uses Census income dated after the rent quarter starts (rows)',
       'CRITICAL', '0', count(*)::text, 'reporting.vw_rental_affordability'
FROM reporting.vw_rental_affordability r
JOIN dw.fact_census_income ci ON ci.census_income_fact_key = r.census_income_fact_key
JOIN dw.dim_time ct           ON ct.time_key = ci.time_key
WHERE ct.date_value > r.quarter_start;

-- Completeness: every other test wrote a result.
INSERT INTO control.test_work
SELECT 'TC-SM-03', 'Build smoke', 'All 49 other tests wrote a result in this execution', 'CRITICAL',
       '49', count(*)::text, '11_run_quality_tests.sql'
FROM control.test_work;

-- Record the run with the fingerprint of the tested report data.
INSERT INTO control.test_run (run_id, report_fingerprint)
SELECT nextval('control.test_run_seq'), reporting.dashboard_fingerprint();

INSERT INTO control.test_result
    (run_id, test_id, test_group, test_name, severity, expected_result, actual_result, status, evidence_reference)
SELECT r.run_id, w.test_id, w.test_group, w.test_name, w.severity, w.expected_result,
       coalesce(w.actual_result, 'NULL'),
       CASE WHEN w.actual_result IS NOT DISTINCT FROM w.expected_result THEN 'PASS' ELSE 'FAIL' END,
       w.evidence_reference
FROM control.test_work w
CROSS JOIN (SELECT max(run_id) AS run_id FROM control.test_run) r;

-- Show the results.
SELECT test_id, severity, status, test_name, expected_result, actual_result
FROM control.test_result
WHERE run_id = (SELECT max(run_id) FROM control.test_result)
ORDER BY test_id;

SELECT status, count(*) AS tests
FROM control.test_result
WHERE run_id = (SELECT max(run_id) FROM control.test_result)
GROUP BY status;

-- Gate: stop the build if any CRITICAL test failed.
DO $$
DECLARE
    failed text;
BEGIN
    SELECT string_agg(test_id, ', ' ORDER BY test_id) INTO failed
    FROM control.test_result
    WHERE run_id = (SELECT max(run_id) FROM control.test_result)
      AND severity = 'CRITICAL' AND status = 'FAIL';
    IF failed IS NOT NULL THEN
        RAISE EXCEPTION 'CRITICAL tests failed: %', failed;
    END IF;
END $$;
