-- 06_load_or_insert_source_data.sql
-- Loads each landing delivery into its source-system table with lineage and
-- registers it in control.source_file. Content already registered is skipped,
-- so a second run of this file loads nothing.
-- Run in: hapo_a2. Depends on: 05.

BEGIN;

-- Open a new load batch.
CREATE TEMP TABLE this_batch (load_batch_id integer) ON COMMIT DROP;

WITH new_batch AS (
    INSERT INTO control.load_batch (batch_label)
    VALUES ('Synthetic agency deliveries: landing -> source systems')
    RETURNING load_batch_id
)
INSERT INTO this_batch SELECT load_batch_id FROM new_batch;

-- Fingerprint each delivery (MD5 of its ordered rows).
CREATE TEMP TABLE delivered_file ON COMMIT DROP AS
SELECT 'DCJ_RENT'::text AS source_system,
       'src_rental.rent_lga_quarter_raw'::text AS target_table,
       'synthetic_DCJ_rent_LGA_quarterly.csv'::text AS source_file_name,
       md5(string_agg(t::text, E'\n' ORDER BY t.file_row_number)) AS content_md5,
       count(*)::int AS row_count
FROM landing.dcj_rent_lga_quarter t HAVING count(*) > 0
UNION ALL
SELECT 'ABS_CENSUS', 'src_census.census_lga_income_raw',
       '2021Census_G02_NSW_LGA_synthetic.csv',
       md5(string_agg(t::text, E'\n' ORDER BY t.file_row_number)), count(*)::int
FROM landing.abs_census_g02_lga t HAVING count(*) > 0
UNION ALL
SELECT 'ABS_ERP', 'src_population.population_lga_year_raw',
       'synthetic_ABS_ERP_LGA_30June.csv',
       md5(string_agg(t::text, E'\n' ORDER BY t.file_row_number)), count(*)::int
FROM landing.abs_erp_lga t HAVING count(*) > 0
UNION ALL
SELECT 'NSW_HOUSING', 'src_housing.housing_supply_lga_month_raw',
       'synthetic_NSW_housing_supply_LGA_monthly.csv',
       md5(string_agg(t::text, E'\n' ORDER BY t.file_row_number)), count(*)::int
FROM landing.nsw_housing_supply_lga_month t HAVING count(*) > 0;

-- Register only deliveries whose fingerprint is new.
INSERT INTO control.source_file
    (load_batch_id, source_system, target_table, source_file_name, content_md5, row_count, is_synthetic)
SELECT b.load_batch_id, f.source_system, f.target_table, f.source_file_name,
       f.content_md5, f.row_count, TRUE
FROM delivered_file f
CROSS JOIN this_batch b
WHERE NOT EXISTS (SELECT 1
                  FROM control.source_file s
                  WHERE s.source_system = f.source_system
                    AND s.content_md5   = f.content_md5);

-- Copy the newly registered deliveries into the source tables with lineage.
INSERT INTO src_rental.rent_lga_quarter_raw
    (load_batch_id, source_file_id, source_file_name, source_row_number, is_synthetic,
     lga_name, quarter, dwelling_type, bedrooms, median_weekly_rent, new_bonds_lodged)
SELECT sf.load_batch_id, sf.source_file_id, sf.source_file_name, l.file_row_number, sf.is_synthetic,
       l.lga_name, l.quarter, l.dwelling_type, l.bedrooms, l.median_weekly_rent, l.new_bonds_lodged
FROM landing.dcj_rent_lga_quarter l
JOIN control.source_file sf
  ON sf.source_system = 'DCJ_RENT'
 AND sf.load_batch_id = (SELECT load_batch_id FROM this_batch)
ORDER BY l.file_row_number;

INSERT INTO src_census.census_lga_income_raw
    (load_batch_id, source_file_id, source_file_name, source_row_number, is_synthetic,
     lga_code_2021, median_tot_hhd_inc_weekly, tot_hhds)
SELECT sf.load_batch_id, sf.source_file_id, sf.source_file_name, l.file_row_number, sf.is_synthetic,
       l.lga_code_2021, l.median_tot_hhd_inc_weekly, l.tot_hhds
FROM landing.abs_census_g02_lga l
JOIN control.source_file sf
  ON sf.source_system = 'ABS_CENSUS'
 AND sf.load_batch_id = (SELECT load_batch_id FROM this_batch)
ORDER BY l.file_row_number;

INSERT INTO src_population.population_lga_year_raw
    (load_batch_id, source_file_id, source_file_name, source_row_number, is_synthetic,
     lga_code, lga_name, reference_year, erp)
SELECT sf.load_batch_id, sf.source_file_id, sf.source_file_name, l.file_row_number, sf.is_synthetic,
       l.lga_code, l.lga_name, l.reference_year, l.erp
FROM landing.abs_erp_lga l
JOIN control.source_file sf
  ON sf.source_system = 'ABS_ERP'
 AND sf.load_batch_id = (SELECT load_batch_id FROM this_batch)
ORDER BY l.file_row_number;

INSERT INTO src_housing.housing_supply_lga_month_raw
    (load_batch_id, source_file_id, source_file_name, source_row_number, is_synthetic,
     lga_name, measure,
     jul_2024, aug_2024, sep_2024, oct_2024, nov_2024, dec_2024,
     jan_2025, feb_2025, mar_2025, apr_2025, may_2025, jun_2025,
     jul_2025, aug_2025, sep_2025, oct_2025, nov_2025, dec_2025,
     jan_2026, feb_2026, mar_2026, apr_2026, may_2026, jun_2026)
SELECT sf.load_batch_id, sf.source_file_id, sf.source_file_name, l.file_row_number, sf.is_synthetic,
       l.lga_name, l.measure,
       l.jul_2024, l.aug_2024, l.sep_2024, l.oct_2024, l.nov_2024, l.dec_2024,
       l.jan_2025, l.feb_2025, l.mar_2025, l.apr_2025, l.may_2025, l.jun_2025,
       l.jul_2025, l.aug_2025, l.sep_2025, l.oct_2025, l.nov_2025, l.dec_2025,
       l.jan_2026, l.feb_2026, l.mar_2026, l.apr_2026, l.may_2026, l.jun_2026
FROM landing.nsw_housing_supply_lga_month l
JOIN control.source_file sf
  ON sf.source_system = 'NSW_HOUSING'
 AND sf.load_batch_id = (SELECT load_batch_id FROM this_batch)
ORDER BY l.file_row_number;

-- Stop if any file did not load its full row count.
DO $$
DECLARE
    f      record;
    loaded integer;
BEGIN
    FOR f IN SELECT sf.*
             FROM control.source_file sf
             JOIN this_batch b USING (load_batch_id)
    LOOP
        EXECUTE format('SELECT count(*) FROM %s WHERE source_file_id = $1', f.target_table)
           INTO loaded USING f.source_file_id;
        IF loaded <> f.row_count THEN
            RAISE EXCEPTION 'Load reconciliation failed for %: file has % rows, % loaded',
                            f.source_file_name, f.row_count, loaded;
        END IF;
    END LOOP;
END $$;

-- Close the batch: SUCCESS, or SKIPPED_NO_CHANGE when nothing was new.
UPDATE control.load_batch lb
SET finished_at  = clock_timestamp(),
    files_loaded = s.files,
    rows_loaded  = s.rows,
    status       = CASE WHEN s.files > 0 THEN 'SUCCESS' ELSE 'SKIPPED_NO_CHANGE' END
FROM (SELECT count(sf.source_file_id)::int       AS files,
             coalesce(sum(sf.row_count), 0)::int AS rows
      FROM this_batch b
      LEFT JOIN control.source_file sf USING (load_batch_id)) AS s
WHERE lb.load_batch_id = (SELECT load_batch_id FROM this_batch);

COMMIT;

-- Check: batches and registered files.
SELECT lb.load_batch_id, lb.status, lb.files_loaded, lb.rows_loaded,
       sf.source_system, sf.source_file_name, sf.row_count, sf.content_md5
FROM control.load_batch lb
LEFT JOIN control.source_file sf USING (load_batch_id)
ORDER BY lb.load_batch_id, sf.source_file_id;
