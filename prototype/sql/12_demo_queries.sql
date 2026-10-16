-- 12_demo_queries.sql
-- Read-only queries for the report and the demo video: the three use-case
-- reports, a lineage trace, rejected rows and the test summary.
-- Run in: hapo_a2. Depends on: 11.

-- UC1: LGAs ranked by rent-to-income ratio in the latest quarter.
SELECT affordability_pressure_rank AS rank,
       lga_name,
       quarter,
       median_weekly_rent,
       census_median_weekly_household_income AS income_2021,
       rent_to_income_pct,
       rent_change_vs_prev_qtr,
       rent_change_pct,
       bond_lodgement_count
FROM reporting.vw_rental_affordability
WHERE is_lga_headline
  AND quarter_start = (SELECT max(quarter_start) FROM reporting.vw_rental_affordability)
ORDER BY rank;

-- UC1: ratio trend over all quarters.
SELECT lga_name, quarter, rent_to_income_pct
FROM reporting.vw_rental_affordability
WHERE is_lga_headline
ORDER BY lga_name, quarter_start;

-- UC1: detail by dwelling type and bedroom band (suppressed medians stay NULL).
SELECT lga_name, quarter, standard_dwelling_type, bedroom_band,
       median_weekly_rent, is_rent_suppressed, rent_to_income_pct
FROM reporting.vw_rental_affordability
WHERE standard_dwelling_type = 'House'
  AND quarter = '2026-Q2'
ORDER BY lga_name, bedroom_band;

-- UC2: population growth vs approval activity by financial year.
SELECT lga_name,
       financial_year_label,
       population_change,
       population_growth_pct,
       da_approved_dwellings,
       cc_approved_dwellings,
       da_approved_per_1000_residents,
       added_residents_per_da_approved_dwelling,
       is_complete_supply_year,
       interpretation_note
FROM reporting.vw_population_supply
ORDER BY financial_year, population_growth_pct DESC NULLS LAST;

-- UC3: quarterly totals per stage.
SELECT lga_name,
       calendar_quarter_label,
       sum(lodged_dwellings)      AS lodged,
       sum(da_approved_dwellings) AS da_approved,
       sum(cc_approved_dwellings) AS cc_approved,
       min(stages_reported) < 3   AS has_missing_month
FROM reporting.vw_housing_pipeline
GROUP BY lga_name, calendar_quarter_label
ORDER BY lga_name, calendar_quarter_label;

-- UC3: monthly detail for one LGA.
SELECT month_label, lodged_dwellings, da_approved_dwellings, cc_approved_dwellings, stages_reported
FROM reporting.vw_housing_pipeline
WHERE lga_name = 'Penrith'
ORDER BY month_start;

-- Lineage: trace Parramatta 2025-Q1 = 30.00% to its source file rows.
SELECT l.fact_table, l.lga_name, l.period_start, l.source_system, l.source_file_name,
       l.source_row_number, l.content_md5, l.load_batch_id, l.is_synthetic
FROM reporting.vw_rental_affordability r
JOIN reporting.vw_lineage l
  ON (l.fact_table = 'fact_rental'        AND l.fact_key = r.rental_fact_key)
  OR (l.fact_table = 'fact_census_income' AND l.fact_key = r.census_income_fact_key)
WHERE r.lga_code = '16260' AND r.quarter = '2025-Q1' AND r.is_lga_headline;

-- Rejected rows and their rules.
SELECT r.source_system, r.rule_code, v.rule_description, r.source_column, r.raw_record
FROM curated.rejected_row r
JOIN curated.validation_rule v USING (rule_code)
WHERE NOT (r.source_system = 'NSW_HOUSING' AND r.rule_code = 'R05')
UNION ALL
SELECT 'NSW_HOUSING', 'R05', 'Source category or measure has no approved mapping',
       count(*)::text || ' cells', (array_agg(raw_record ORDER BY rejected_row_id))[1]
FROM curated.rejected_row
WHERE source_system = 'NSW_HOUSING' AND rule_code = 'R05'
ORDER BY 1, 2;

-- Test summary of the latest run.
SELECT test_group, count(*) AS tests,
       count(*) FILTER (WHERE status = 'PASS') AS passed
FROM control.test_result
WHERE run_id = (SELECT max(run_id) FROM control.test_result)
GROUP BY test_group
ORDER BY test_group;
