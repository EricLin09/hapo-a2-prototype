-- =============================================================================
-- File        : 05_generate_source_data.sql
-- Purpose     : Generate the deterministic, clearly synthetic files that the four
--               agencies "deliver" into the landing schema, including a small,
--               known set of defective rows that the ETL must reject.
-- Design link : Prototype (vi)c "SQL scripts with synthetic data"; Source Data
--               and Synthetic Data (section 5): 10 LGAs, labelled synthetic rows,
--               deliberately invalid rows for negative tests.
-- Owner       : Team 3
-- Run in      : database hapo_a2
-- Depends on  : 04_create_curated_and_dw_tables.sql
-- Re-runnable : yes - landing tables are emptied and regenerated identically
-- Expected    : rent 728 rows | census 12 | ERP 31 | housing 31 rows (x 24 months)
--
-- How the data is made
--   * LGA codes/names are real ASGS 2021 values; every measure is synthetic and
--     must not be read as an observed NSW outcome.
--   * No random(): variation comes from landing.synth_u(key), an md5-based value
--     in [0,1). The same key always gives the same number, on any machine, so
--     every rebuild produces identical data and identical report results.
--   * Each source keeps its own conventions (names vs codes, "LGA" prefix,
--     thousands separators, wide month columns, suppression symbols).
--   * Suppression follows the real DCJ rent tables (checked against the
--     September 2021 issue): 30 or fewer new bonds -> the bond count is
--     published as "s"; 10 or fewer -> median and bond count are both "-".
--
-- Planted defects (expected outcome is asserted in file 11)
--   rent    : 1 exact duplicate (R04), unknown LGA "Olympic Park" (R01),
--             unparseable quarter "Qtr 3 2025" (R02), unknown dwelling type
--             "Granny Flat" (R05), negative rent "-450" (R03),
--             zero rent "0" (R03), implausible rent "9999" (R07 outlier),
--             bond count "99999999999", too large to store (R07)
--   census  : unknown code LGA19999 (R01), zero income (R03)
--   ERP     : Cumberland 2025 published blank (R06), "2147483648" persons,
--             beyond PostgreSQL's integer range (R07)
--   housing : one negative month cell (R03), one blank month cell (R06),
--             one unmapped measure row "Dwellings in withdrawn DAs" (R05 x 24 cells)
--   Not defects, but must be standardised: DCJ spells "Canterbury Bankstown"
--   and "Campbelltown", the housing file says "City of Sydney", one DCJ quarter
--   writes Liverpool in lower case with extra spaces, one ERP code has spaces.
--
-- Hand-checkable "golden" values (asserted in file 11)
--   UC1: Parramatta, Mar Qtr 2025, all dwellings: median rent 600; 2021 income
--        2,000 -> rent-to-income 30.00 %
--   UC2: Parramatta FY2024-25: ERP 260,000 -> 265,200 (+5,200, +2.00 %);
--        DA-approved dwellings 12 x 200 = 2,400 -> 9.05 per 1,000 residents
-- =============================================================================

BEGIN;

-- Deterministic pseudo-random number in [0,1) derived from a text key.
CREATE OR REPLACE FUNCTION landing.synth_u(p_key text)
RETURNS numeric LANGUAGE sql IMMUTABLE AS $$
    SELECT ('x' || substr(md5(p_key), 1, 8))::bit(32)::bigint / 4294967296.0
$$;

TRUNCATE landing.dcj_rent_lga_quarter,
         landing.abs_census_g02_lga,
         landing.abs_erp_lga,
         landing.nsw_housing_supply_lga_month;

-- -----------------------------------------------------------------------------
-- Generation parameters per LGA (synthetic, chosen to be plausible in scale).
--   base_rent      all-dwelling median weekly rent in Sep Qtr 2024 ($)
--   q_growth       quarterly rent growth
--   income_2021    Census 2021 median weekly household income ($)
--   erp_2023..2025 estimated resident population at 30 June
--   bonds_base     new bonds per quarter (all dwellings)
--   supply_base    dwellings in lodged DAs per month
-- -----------------------------------------------------------------------------
CREATE TEMP TABLE lga_param ON COMMIT DROP AS
SELECT * FROM (VALUES
 -- code    ABS name                DCJ spelling            housing spelling        rent growth  inc   hhds    erp23   erp24   erp25   bonds supply
 ('10750', 'Blacktown',            'Blacktown',            'Blacktown',            560, 0.018, 1980, 128000, 420500, 432100, 441900, 2100, 260),
 ('11500', 'Campbelltown (NSW)',   'Campbelltown',         'Campbelltown',         520, 0.015, 1720,  61500, 182300, 186000, 189400,  900, 140),
 ('11570', 'Canterbury-Bankstown', 'Canterbury Bankstown', 'Canterbury-Bankstown', 570, 0.012, 1640, 118000, 379800, 384900, 389600, 1900, 180),
 ('12380', 'Cumberland',           'Cumberland',           'Cumberland',           560, 0.013, 1610,  73000, 243200, 247800, 252100, 1500, 150),
 ('12850', 'Fairfield',            'Fairfield',            'Fairfield',            540, 0.010, 1450,  65000, 211400, 212900, 214600,  800,  90),
 ('14900', 'Liverpool',            'Liverpool',            'Liverpool',            580, 0.016, 1870,  72000, 238900, 245600, 251800, 1300, 200),
 ('15900', 'Newcastle',            'Newcastle',            'Newcastle',            540, 0.014, 1590,  70000, 172800, 175100, 177300, 1000, 120),
 ('16260', 'Parramatta',           'Parramatta',           'Parramatta',           588, 0.010, 2000,  93000, 255100, 260000, 265200, 2400, 220),
 ('16350', 'Penrith',              'Penrith',              'Penrith',              550, 0.020, 1860,  76000, 221600, 226300, 230900, 1100, 170),
 ('17200', 'Sydney',               'Sydney',               'City of Sydney',       820, 0.011, 2200, 118000, 225300, 231100, 236800, 4200, 160)
) AS p(lga_code, abs_name, dcj_name, housing_name, base_rent, q_growth, income_2021,
       households_2021, erp_2023, erp_2024, erp_2025, bonds_base, supply_base);

-- =============================================================================
-- 1. DCJ Rent and Sales file: 10 LGAs x 8 quarters x 9 dwelling/bedroom rows
-- =============================================================================
INSERT INTO landing.dcj_rent_lga_quarter
    (file_row_number, lga_name, quarter, dwelling_type, bedrooms, median_weekly_rent, new_bonds_lodged)
WITH quarter_list AS (                      -- Sep Qtr 2024 ... Jun Qtr 2026
    SELECT n AS q_index,
           (date '2024-07-01' + make_interval(months => 3 * n))::date AS quarter_start
    FROM generate_series(0, 7) AS n
),
combo AS (                                  -- detail rows; shares of bonds sum to 1
    SELECT * FROM (VALUES
        (1, 'Flat/Unit', '1',  0.78, 0.14), (2, 'Flat/Unit', '2',  0.95, 0.24),
        (3, 'Flat/Unit', '3',  1.12, 0.06), (4, 'House',     '2',  0.92, 0.05),
        (5, 'House',     '3',  1.08, 0.20), (6, 'House',     '4+', 1.30, 0.14),
        (7, 'Townhouse', '2',  0.97, 0.05), (8, 'Townhouse', '3',  1.12, 0.12)
    ) AS c(combo_order, dwelling_type, bedrooms, rent_factor, bond_share)
),
lga_quarter AS (                            -- underlying rent trend per LGA and quarter
    SELECT p.lga_code, p.dcj_name, p.bonds_base, q.q_index, q.quarter_start,
           p.base_rent * power(1 + p.q_growth, q.q_index) AS trend_rent
    FROM lga_param p CROSS JOIN quarter_list q
),
detail AS (
    SELECT lq.lga_code, lq.dcj_name, lq.quarter_start, c.combo_order, c.dwelling_type, c.bedrooms,
           -- New bonds. Houses in the City of Sydney are made rare (3-30 a
           -- quarter) so that both suppression levels occur: some counts are
           -- "s" (11-30 bonds) and some medians are "-" (10 or fewer).
           (CASE WHEN lq.lga_code = '17200' AND c.dwelling_type = 'House'
                 THEN 3 + floor(28 * landing.synth_u(concat_ws('|', 'bonds', lq.lga_code, lq.q_index, c.combo_order)))
                 ELSE round(lq.bonds_base * c.bond_share *
                            (0.9 + 0.2 * landing.synth_u(concat_ws('|', 'bonds', lq.lga_code, lq.q_index, c.combo_order))))
            END)::int AS bonds,
           round(lq.trend_rent * c.rent_factor *
                 (0.98 + 0.04 * landing.synth_u(concat_ws('|', 'rent', lq.lga_code, lq.q_index, c.combo_order))))::int AS median_rent
    FROM lga_quarter lq CROSS JOIN combo c
),
total AS (                                  -- the source's own "Total / Total" row
    SELECT lq.lga_code, lq.dcj_name, lq.quarter_start, 9 AS combo_order,
           'Total' AS dwelling_type, 'Total' AS bedrooms,
           -- counts are additive, so the total equals the sum of the details
           (SELECT sum(d.bonds) FROM detail d
             WHERE d.lga_code = lq.lga_code AND d.quarter_start = lq.quarter_start)::int AS bonds,
           -- medians are not additive: the total median is its own value
           CASE WHEN lq.lga_code = '16260' AND lq.quarter_start = date '2025-01-01'
                THEN 600                                         -- golden UC1 value
                ELSE round(lq.trend_rent *
                     (0.99 + 0.02 * landing.synth_u(concat_ws('|', 'rent_total', lq.lga_code, lq.q_index))))::int
           END AS median_rent
    FROM lga_quarter lq
),
all_rows AS (
    SELECT * FROM detail
    UNION ALL
    SELECT * FROM total
)
SELECT row_number() OVER (ORDER BY quarter_start, lga_code, combo_order)::int,
       -- inconsistent casing/spacing in one quarter (must be standardised, not rejected)
       CASE WHEN lga_code = '14900' AND quarter_start = date '2025-07-01'
            THEN '  ' || lower(dcj_name) || ' ' ELSE dcj_name END,
       -- quarter label as published: month the quarter ends + year
       to_char(quarter_start + interval '2 months', 'Mon') || ' Qtr ' || to_char(quarter_start, 'YYYY'),
       dwelling_type,
       bedrooms,
       -- DCJ suppression: median shown as "-" when 10 or fewer bonds
       CASE WHEN bonds <= 10 THEN '-' ELSE median_rent::text END,
       -- bond count shown as "-" (10 or fewer) or "s" (11-30)
       CASE WHEN bonds <= 10 THEN '-'
            WHEN bonds <= 30 THEN 's'
            ELSE bonds::text END
FROM all_rows;

-- Planted defect R04: an exact duplicate of an existing row, appended later in the file.
INSERT INTO landing.dcj_rent_lga_quarter
SELECT (SELECT max(file_row_number) FROM landing.dcj_rent_lga_quarter) + 1,
       lga_name, quarter, dwelling_type, bedrooms, median_weekly_rent, new_bonds_lodged
FROM landing.dcj_rent_lga_quarter
WHERE lga_name = 'Parramatta' AND quarter = 'Mar Qtr 2025' AND dwelling_type = 'Total';

-- Planted defects R01, R05, R02, R03, R07.
INSERT INTO landing.dcj_rent_lga_quarter
SELECT (SELECT max(file_row_number) FROM landing.dcj_rent_lga_quarter) + v.n,
       v.lga_name, v.quarter, v.dwelling_type, v.bedrooms, v.median_weekly_rent, v.new_bonds_lodged
FROM (VALUES
    (1, 'Olympic Park', 'Jun Qtr 2025', 'Total',       'Total', '690',  '54'),   -- R01 not an LGA
    (2, 'Blacktown',    'Dec Qtr 2025', 'Granny Flat', '1',     '410',  '12'),   -- R05 unmapped type
    (3, 'Penrith',      'Qtr 3 2025',   'Total',       'Total', '640',  '880'),  -- R02 bad quarter label
    (4, 'Fairfield',    'Mar Qtr 2026', 'Flat/Unit',   '2',     '-450', '95'),   -- R03 negative rent
    (5, 'Sydney',       'Dec Qtr 2025', 'Total',       'Total', '9999', '6500'), -- R07 implausible rent
    (6, 'Fairfield',    'Jun Qtr 2026', 'Flat/Unit',   '2',     '0',    '95'),   -- R03 zero rent
    (7, 'Newcastle',    'Mar Qtr 2026', 'House',       '3',     '590',  '99999999999')  -- R07 count too large to store
) AS v(n, lga_name, quarter, dwelling_type, bedrooms, median_weekly_rent, new_bonds_lodged);

-- =============================================================================
-- 2. ABS Census 2021 G02-style file: one row per LGA, code with "LGA" prefix
-- =============================================================================
INSERT INTO landing.abs_census_g02_lga (file_row_number, lga_code_2021, median_tot_hhd_inc_weekly, tot_hhds)
SELECT row_number() OVER (ORDER BY lga_code)::int,
       'LGA' || lga_code,
       income_2021::text,
       households_2021::text
FROM lga_param;

INSERT INTO landing.abs_census_g02_lga VALUES
    (11, 'LGA19999', '1500', '20000'),   -- R01 code not in scope
    (12, 'LGA12850', '0',    '65000');   -- R03 zero income cannot be a denominator

-- =============================================================================
-- 3. ABS ERP file: 10 LGAs x 30 June 2023-2025, thousands separators
-- =============================================================================
INSERT INTO landing.abs_erp_lga (file_row_number, lga_code, lga_name, reference_year, erp)
SELECT row_number() OVER (ORDER BY y.reference_year, p.lga_code)::int,
       CASE WHEN p.lga_code = '14900' AND y.reference_year = 2023
            THEN ' 14900 ' ELSE p.lga_code END,                  -- stray spaces (standardise)
       p.abs_name,
       y.reference_year::text,
       CASE WHEN p.lga_code = '12380' AND y.reference_year = 2025
            THEN ''                                              -- R06 published blank
            ELSE to_char(y.erp, 'FM999,999,999') END
FROM lga_param p
CROSS JOIN LATERAL (VALUES (2023, p.erp_2023), (2024, p.erp_2024), (2025, p.erp_2025))
           AS y(reference_year, erp);

-- Planted defect R07: a well-formed number beyond PostgreSQL's integer range.
-- It must be quarantined, not crash the transformation with "integer out of range".
INSERT INTO landing.abs_erp_lga VALUES (31, '16260', 'Parramatta', '2024', '2147483648');

-- =============================================================================
-- 4. NSW Housing Supply workbook: 10 LGAs x 3 measures, 24 month columns
--    Generated in long form, then pivoted to the wide layout the source uses.
--    Stages are generated independently: a month can have more approvals than
--    lodgements, as happens with real period counts.
-- =============================================================================
INSERT INTO landing.nsw_housing_supply_lga_month (
    file_row_number, lga_name, measure,
    jul_2024, aug_2024, sep_2024, oct_2024, nov_2024, dec_2024,
    jan_2025, feb_2025, mar_2025, apr_2025, may_2025, jun_2025,
    jul_2025, aug_2025, sep_2025, oct_2025, nov_2025, dec_2025,
    jan_2026, feb_2026, mar_2026, apr_2026, may_2026, jun_2026)
WITH month_list AS (
    SELECT (date '2024-07-01' + make_interval(months => n))::date AS month_start
    FROM generate_series(0, 23) AS n
),
measure AS (
    SELECT * FROM (VALUES
        (1, 'Dwellings in lodged DAs',                         1.00),
        (2, 'Dwellings in approved DAs',                       0.85),
        (3, 'Dwellings in approved construction certificates', 0.70)
    ) AS m(measure_order, measure, stage_factor)
),
cell AS (
    SELECT p.lga_code, p.housing_name, m.measure_order, m.measure, ml.month_start,
           CASE WHEN p.lga_code = '16260' AND m.measure_order = 2
                     AND ml.month_start BETWEEN date '2024-07-01' AND date '2025-06-01'
                THEN 200                                          -- golden UC2 value
                ELSE round(p.supply_base * m.stage_factor
                           * (1 + 0.12 * cos(2 * pi() * extract(month FROM ml.month_start) / 12))
                           * (0.75 + 0.5 * landing.synth_u(concat_ws('|', 'supply', p.lga_code,
                                                                     m.measure_order, ml.month_start))))::int
           END AS dwellings
    FROM lga_param p CROSS JOIN measure m CROSS JOIN month_list ml
)
SELECT row_number() OVER (ORDER BY lga_code, measure_order)::int, housing_name, measure,
       max(dwellings) FILTER (WHERE month_start = '2024-07-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2024-08-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2024-09-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2024-10-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2024-11-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2024-12-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2025-01-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2025-02-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2025-03-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2025-04-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2025-05-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2025-06-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2025-07-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2025-08-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2025-09-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2025-10-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2025-11-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2025-12-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2026-01-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2026-02-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2026-03-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2026-04-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2026-05-01')::text,
       max(dwellings) FILTER (WHERE month_start = '2026-06-01')::text
FROM cell
GROUP BY lga_code, housing_name, measure_order, measure;

-- Planted defect R03: a negative count in one month cell.
UPDATE landing.nsw_housing_supply_lga_month
SET mar_2025 = '-5'
WHERE lga_name = 'Penrith' AND measure = 'Dwellings in approved construction certificates';

-- Planted defect R06: one month cell published blank (missing, which is not zero).
UPDATE landing.nsw_housing_supply_lga_month
SET nov_2025 = ''
WHERE lga_name = 'Fairfield' AND measure = 'Dwellings in approved DAs';

-- Planted defect R05: a measure with no approved stage mapping (all 24 cells).
INSERT INTO landing.nsw_housing_supply_lga_month
SELECT 31, 'Blacktown', 'Dwellings in withdrawn DAs',
       '3','2','4','1','3','2','5','2','3','4','1','2',
       '3','2','2','4','3','1','2','3','4','2','3','1';

COMMIT;

-- Row counts of the delivered files.
SELECT 'landing.dcj_rent_lga_quarter' AS landing_table, count(*) AS file_rows FROM landing.dcj_rent_lga_quarter
UNION ALL SELECT 'landing.abs_census_g02_lga',           count(*) FROM landing.abs_census_g02_lga
UNION ALL SELECT 'landing.abs_erp_lga',                  count(*) FROM landing.abs_erp_lga
UNION ALL SELECT 'landing.nsw_housing_supply_lga_month', count(*) FROM landing.nsw_housing_supply_lga_month;
