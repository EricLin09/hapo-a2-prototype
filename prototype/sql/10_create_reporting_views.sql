-- =============================================================================
-- File        : 10_create_reporting_views.sql
-- Purpose     : Publish the stable query layer used for the three use-case
--               reports and the lineage (traceability) evidence.
-- Design link : Reports and Output Design 6 / 6.1 (UC1 Rental Affordability,
--               UC2 Population Demand vs Housing Supply, UC3 Housing Supply
--               Pipeline, Lineage evidence); Data Flow step 9 "Publish";
--               A1 use cases UC1-UC3 and UC5.
-- Owner       : Team 3 (views); report builders/reconcilers query these views
-- Run in      : database hapo_a2
-- Depends on  : 09_load_facts.sql
-- Re-runnable : yes (views are dropped and recreated)
-- Expected    : 7 views in schema reporting (4 report + 3 dashboard export) and
--               the function reporting.dashboard_fingerprint()
--
-- Rules the views enforce (Report Limitations 6.1)
--   * Facts are aggregated to a common LGA + period BEFORE being combined.
--   * UC1 uses the source's "All dwellings / All bedrooms" median for the LGA
--     headline; subgroup medians are never combined into an LGA median.
--   * UC1 compares current rent with the latest Census income available at
--     that quarter (2021) and says so in every row.
--   * UC2 sums supply over the financial year (July-June) so it lines up with
--     the 30 June population estimates; incomplete years are flagged.
--   * UC3 shows stages as independent period counts - no conversion rates.
-- =============================================================================

BEGIN;

-- Dropped first so that a change in a view's columns never blocks a re-run
-- (CREATE OR REPLACE VIEW cannot remove or reorder columns).
DROP FUNCTION IF EXISTS reporting.dashboard_fingerprint();
DROP VIEW IF EXISTS reporting.vw_dashboard_uc1,
                    reporting.vw_dashboard_uc2,
                    reporting.vw_dashboard_uc3,
                    reporting.vw_lineage,
                    reporting.vw_housing_pipeline,
                    reporting.vw_population_supply,
                    reporting.vw_rental_affordability;

-- -----------------------------------------------------------------------------
-- UC1 - Area-level rental affordability pressure and rent trend proxy.
-- Grain: LGA x quarter x dwelling type x bedroom band.
-- Filter is_lga_headline = TRUE for the one-row-per-LGA view.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.vw_rental_affordability AS
WITH rent AS (
    SELECT f.rental_fact_key,
           f.geography_key,
           f.dwelling_type_key,
           g.lga_code,
           g.lga_name,
           t.date_value                                 AS quarter_start,
           t.calendar_quarter_label,
           t.financial_year_label,
           d.standard_dwelling_type,
           d.bedroom_band,
           (d.is_all_dwellings AND d.is_all_bedrooms)   AS is_lga_headline,
           f.median_weekly_rent,
           f.is_rent_suppressed,
           f.bond_lodgement_count,
           f.is_bond_count_suppressed
    FROM dw.fact_rental f
    JOIN dw.dim_geography g     ON g.geography_key     = f.geography_key
    JOIN dw.dim_time t          ON t.time_key          = f.time_key
    JOIN dw.dim_dwelling_type d ON d.dwelling_type_key = f.dwelling_type_key
),
with_income AS (
    -- Latest Census income published on or before the rent quarter.
    SELECT r.*,
           inc.census_income_fact_key,
           inc.median_weekly_household_income,
           inc.census_vintage,
           round(100 * r.median_weekly_rent / inc.median_weekly_household_income, 2) AS rent_to_income_pct
    FROM rent r
    LEFT JOIN LATERAL (
        SELECT ci.census_income_fact_key, ci.median_weekly_household_income, ci.census_vintage
        FROM dw.fact_census_income ci
        JOIN dw.dim_time ct ON ct.time_key = ci.time_key
        WHERE ci.geography_key = r.geography_key
          AND ct.date_value <= r.quarter_start
        ORDER BY ct.date_value DESC
        LIMIT 1
    ) inc ON TRUE
),
with_change AS (
    SELECT w.*,
           lag(w.median_weekly_rent) OVER win AS prev_median_weekly_rent,
           lag(w.quarter_start)      OVER win AS prev_quarter_start
    FROM with_income w
    WINDOW win AS (PARTITION BY w.geography_key, w.dwelling_type_key ORDER BY w.quarter_start)
)
SELECT lga_code,
       lga_name,
       calendar_quarter_label                        AS quarter,
       quarter_start,
       financial_year_label,
       standard_dwelling_type,
       bedroom_band,
       is_lga_headline,
       median_weekly_rent,
       is_rent_suppressed,
       bond_lodgement_count,
       is_bond_count_suppressed,
       median_weekly_household_income                AS census_median_weekly_household_income,
       census_vintage                                AS income_reference_year,
       rent_to_income_pct,
       -- change only against the immediately preceding quarter
       CASE WHEN prev_quarter_start = (quarter_start - interval '3 months')::date
            THEN median_weekly_rent - prev_median_weekly_rent END                     AS rent_change_vs_prev_qtr,
       CASE WHEN prev_quarter_start = (quarter_start - interval '3 months')::date
            THEN round(100 * (median_weekly_rent / prev_median_weekly_rent - 1), 2) END AS rent_change_pct,
       -- 1 = highest rent-to-income ratio among LGAs in that quarter
       CASE WHEN is_lga_headline
            THEN rank() OVER (PARTITION BY quarter_start, is_lga_headline
                              ORDER BY rent_to_income_pct DESC NULLS LAST) END        AS affordability_pressure_rank,
       rental_fact_key,
       census_income_fact_key,
       'SYNTHETIC DATA. Area-level proxy: quarterly median rent / '
         || coalesce(census_vintage::text, 'n/a')
         || ' Census median household income; not a household rent-burden measure.' AS interpretation_note
FROM with_change;

-- -----------------------------------------------------------------------------
-- UC2 - Population growth versus housing approval activity proxy.
-- Grain: LGA x financial year (July-June).
-- Population change = ERP at 30 June (end of FY) - ERP at 30 June a year earlier.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.vw_population_supply AS
WITH years AS (
    -- Keep every in-scope LGA visible for each supplied financial year, even
    -- when one LGA has no housing rows at all for that year.
    SELECT DISTINCT t.financial_year, t.financial_year_label
    FROM dw.fact_housing_supply f
    JOIN dw.dim_time t ON t.time_key = f.time_key
),
supply AS (
    SELECT f.geography_key,
           t.financial_year,
           t.financial_year_label,
           sum(f.dwelling_count) FILTER (WHERE s.stage_code = 'LODGED')      AS lodged_dwellings,
           sum(f.dwelling_count) FILTER (WHERE s.stage_code = 'DA_APPROVED') AS da_approved_dwellings,
           sum(f.dwelling_count) FILTER (WHERE s.stage_code = 'CC_APPROVED') AS cc_approved_dwellings,
           count(*)                                                          AS stage_months_reported
    FROM dw.fact_housing_supply f
    JOIN dw.dim_time t           ON t.time_key           = f.time_key
    JOIN dw.dim_pipeline_stage s ON s.pipeline_stage_key = f.pipeline_stage_key
    GROUP BY f.geography_key, t.financial_year, t.financial_year_label
),
population AS (
    SELECT f.population_fact_key, f.geography_key, t.financial_year,
           f.estimated_resident_population AS erp
    FROM dw.fact_population f
    JOIN dw.dim_time t ON t.time_key = f.time_key
)
SELECT g.lga_code,
       g.lga_name,
       y.financial_year_label,
       y.financial_year,
       p0.erp                                                           AS erp_start_30_june,
       p1.erp                                                           AS erp_end_30_june,
       p1.erp - p0.erp                                                  AS population_change,
       round(100.0 * (p1.erp - p0.erp) / nullif(p0.erp, 0), 2)          AS population_growth_pct,
       s.lodged_dwellings,
       s.da_approved_dwellings,
       s.cc_approved_dwellings,
       coalesce(s.stage_months_reported, 0) AS stage_months_reported,  -- 36 = 12 months x 3 stages
       coalesce(s.stage_months_reported, 0) = 36 AS is_complete_supply_year,
       round(1000.0 * s.da_approved_dwellings / nullif(p1.erp, 0), 2)   AS da_approved_per_1000_residents,
       round((p1.erp - p0.erp)::numeric / nullif(s.da_approved_dwellings, 0), 2)
                                                                        AS added_residents_per_da_approved_dwelling,
       p0.population_fact_key                                           AS start_population_fact_key,
       p1.population_fact_key                                           AS end_population_fact_key,
       'SYNTHETIC DATA. Approvals are not completed dwellings; population and dwellings are different units. '
         || CASE WHEN coalesce(s.stage_months_reported, 0) < 36
                 THEN 'Supply year incomplete (' || coalesce(s.stage_months_reported, 0) || ' of 36 stage-months). '
                 ELSE '' END
         || CASE WHEN p0.erp IS NULL OR p1.erp IS NULL
                 THEN 'Population estimate not available for this year.' ELSE '' END AS interpretation_note
FROM dw.dim_geography g
CROSS JOIN years y
LEFT JOIN supply s ON s.geography_key = g.geography_key AND s.financial_year = y.financial_year
LEFT JOIN population p1 ON p1.geography_key = g.geography_key AND p1.financial_year = y.financial_year
LEFT JOIN population p0 ON p0.geography_key = g.geography_key AND p0.financial_year = y.financial_year - 1
WHERE make_date(y.financial_year - 1, 7, 1) >= g.valid_from
  AND (g.valid_to IS NULL OR make_date(y.financial_year - 1, 7, 1) < g.valid_to);

-- -----------------------------------------------------------------------------
-- UC3 - Housing supply pipeline activity.
-- Grain: LGA x month, one column per stage. A missing stage-month is NULL
-- (not zero) and is counted in stages_reported.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.vw_housing_pipeline AS
WITH month_bounds AS (
    SELECT min(t.date_value) AS first_month, max(t.date_value) AS last_month
    FROM dw.fact_housing_supply f
    JOIN dw.dim_time t ON t.time_key = f.time_key
),
months AS (
    SELECT t.*
    FROM dw.dim_time t
    CROSS JOIN month_bounds b
    WHERE t.date_value = t.month_start
      AND t.date_value BETWEEN b.first_month AND b.last_month
)
SELECT g.lga_code,
       g.lga_name,
       t.date_value                                                       AS month_start,
       to_char(t.date_value, 'Mon YYYY')                                  AS month_label,
       t.calendar_quarter_label,
       t.financial_year_label,
       sum(f.dwelling_count) FILTER (WHERE s.stage_code = 'LODGED')       AS lodged_dwellings,
       sum(f.dwelling_count) FILTER (WHERE s.stage_code = 'DA_APPROVED')  AS da_approved_dwellings,
       sum(f.dwelling_count) FILTER (WHERE s.stage_code = 'CC_APPROVED')  AS cc_approved_dwellings,
       count(f.housing_supply_fact_key)                                    AS stages_reported,
       'SYNTHETIC DATA. Independent counts per stage for the month, not the same projects moving '
         || 'through a workflow; local completions are not available (statewide only in the source).'
                                                                          AS interpretation_note
FROM dw.dim_geography g
CROSS JOIN months t
LEFT JOIN dw.fact_housing_supply f ON f.geography_key = g.geography_key AND f.time_key = t.time_key
LEFT JOIN dw.dim_pipeline_stage s ON s.pipeline_stage_key = f.pipeline_stage_key
WHERE t.date_value >= g.valid_from
  AND (g.valid_to IS NULL OR t.date_value < g.valid_to)
GROUP BY g.lga_code, g.lga_name, t.date_value, t.calendar_quarter_label, t.financial_year_label;

-- -----------------------------------------------------------------------------
-- UC5 support - lineage of every fact row back to its source file row.
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW reporting.vw_lineage AS
SELECT 'fact_rental'::text       AS fact_table,
       f.rental_fact_key          AS fact_key,
       g.lga_code, g.lga_name,
       t.date_value               AS period_start,
       sf.source_system,
       sf.target_table            AS source_table,
       f.source_row_id,
       s.source_row_number,
       NULL::text                 AS source_column,
       sf.source_file_name,
       sf.content_md5,
       f.load_batch_id,
       b.started_at               AS batch_started_at,
       s.is_synthetic
FROM dw.fact_rental f
JOIN dw.dim_geography g                 ON g.geography_key  = f.geography_key
JOIN dw.dim_time t                      ON t.time_key       = f.time_key
JOIN src_rental.rent_lga_quarter_raw s  ON s.source_row_id  = f.source_row_id
JOIN control.source_file sf             ON sf.source_file_id = s.source_file_id
JOIN control.load_batch b               ON b.load_batch_id  = f.load_batch_id
UNION ALL
SELECT 'fact_census_income', f.census_income_fact_key, g.lga_code, g.lga_name, t.date_value,
       sf.source_system, sf.target_table, f.source_row_id, s.source_row_number, NULL,
       sf.source_file_name, sf.content_md5, f.load_batch_id, b.started_at, s.is_synthetic
FROM dw.fact_census_income f
JOIN dw.dim_geography g                  ON g.geography_key  = f.geography_key
JOIN dw.dim_time t                       ON t.time_key       = f.time_key
JOIN src_census.census_lga_income_raw s  ON s.source_row_id  = f.source_row_id
JOIN control.source_file sf              ON sf.source_file_id = s.source_file_id
JOIN control.load_batch b                ON b.load_batch_id  = f.load_batch_id
UNION ALL
SELECT 'fact_population', f.population_fact_key, g.lga_code, g.lga_name, t.date_value,
       sf.source_system, sf.target_table, f.source_row_id, s.source_row_number, NULL,
       sf.source_file_name, sf.content_md5, f.load_batch_id, b.started_at, s.is_synthetic
FROM dw.fact_population f
JOIN dw.dim_geography g                      ON g.geography_key  = f.geography_key
JOIN dw.dim_time t                           ON t.time_key       = f.time_key
JOIN src_population.population_lga_year_raw s ON s.source_row_id = f.source_row_id
JOIN control.source_file sf                  ON sf.source_file_id = s.source_file_id
JOIN control.load_batch b                    ON b.load_batch_id  = f.load_batch_id
UNION ALL
SELECT 'fact_housing_supply', f.housing_supply_fact_key, g.lga_code, g.lga_name, t.date_value,
       sf.source_system, sf.target_table, f.source_row_id, s.source_row_number, f.source_column,
       sf.source_file_name, sf.content_md5, f.load_batch_id, b.started_at, s.is_synthetic
FROM dw.fact_housing_supply f
JOIN dw.dim_geography g                          ON g.geography_key  = f.geography_key
JOIN dw.dim_time t                               ON t.time_key       = f.time_key
JOIN src_housing.housing_supply_lga_month_raw s  ON s.source_row_id  = f.source_row_id
JOIN control.source_file sf                      ON sf.source_file_id = s.source_file_id
JOIN control.load_batch b                        ON b.load_batch_id  = f.load_batch_id;

-- -----------------------------------------------------------------------------
-- Dashboard export: exactly the rows and columns written to dashboard/data.js.
-- The exporter reads ONLY these views, and the fingerprint below hashes the
-- same rows in the same order. File 11 records the fingerprint of the data it
-- tested; the exporter marks data.js VERIFIED only if the data it exports has
-- that same fingerprint, i.e. nothing changed between testing and export.
-- -----------------------------------------------------------------------------
CREATE VIEW reporting.vw_dashboard_uc1 AS
SELECT lga_code, lga_name, quarter, quarter_start,
       median_weekly_rent, census_median_weekly_household_income,
       income_reference_year, rent_to_income_pct, rent_change_pct
FROM reporting.vw_rental_affordability
WHERE is_lga_headline;

CREATE VIEW reporting.vw_dashboard_uc2 AS
SELECT lga_code, lga_name, financial_year, financial_year_label,
       erp_start_30_june, erp_end_30_june,
       population_change, population_growth_pct,
       da_approved_dwellings, da_approved_per_1000_residents,
       is_complete_supply_year
FROM reporting.vw_population_supply;

CREATE VIEW reporting.vw_dashboard_uc3 AS
SELECT lga_code, lga_name, month_start, month_label,
       lodged_dwellings, da_approved_dwellings,
       cc_approved_dwellings, stages_reported
FROM reporting.vw_housing_pipeline;

CREATE FUNCTION reporting.dashboard_fingerprint()
RETURNS text LANGUAGE sql STABLE AS $$
    SELECT md5(
        (SELECT coalesce(string_agg(row_to_json(v)::text, E'\n' ORDER BY v.quarter_start, v.lga_name), '')
           FROM reporting.vw_dashboard_uc1 v) || E'\n|uc2|\n' ||
        (SELECT coalesce(string_agg(row_to_json(v)::text, E'\n' ORDER BY v.financial_year, v.lga_name), '')
           FROM reporting.vw_dashboard_uc2 v) || E'\n|uc3|\n' ||
        (SELECT coalesce(string_agg(row_to_json(v)::text, E'\n' ORDER BY v.month_start, v.lga_name), '')
           FROM reporting.vw_dashboard_uc3 v))
$$;

COMMIT;

SELECT table_name AS reporting_view
FROM information_schema.views
WHERE table_schema = 'reporting'
ORDER BY table_name;
