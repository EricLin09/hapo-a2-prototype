-- =============================================================================
-- File        : 02_create_control_tables.sql
-- Purpose     : Create the control tables that every layer writes to:
--               load batches, registered source files and test results.
-- Design link : Solution Architecture 2.1 (CONTROL schema) and Testing Plan
--               (CONTROL.TEST_RESULT); supports UC5 traceability.
-- Owner       : Team 3
-- Run in      : database hapo_a2
-- Depends on  : 01_create_database_schemas.sql
-- Re-runnable : yes (IF NOT EXISTS); existing control history is kept
-- Expected    : control.load_batch, source_file, test_run, test_work, test_result
-- =============================================================================

BEGIN;

-- One row per execution of the source load (06). A batch that finds only files
-- it has already loaded is closed as SKIPPED_NO_CHANGE (idempotency evidence).
CREATE TABLE IF NOT EXISTS control.load_batch (
    load_batch_id  integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_label    text        NOT NULL,
    started_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
    finished_at    timestamptz,
    status         text        NOT NULL DEFAULT 'RUNNING'
                   CHECK (status IN ('RUNNING', 'SUCCESS', 'SKIPPED_NO_CHANGE')),
    files_loaded   integer     NOT NULL DEFAULT 0 CHECK (files_loaded >= 0),
    rows_loaded    integer     NOT NULL DEFAULT 0 CHECK (rows_loaded >= 0)
);

-- One row per source-shaped delivery that was actually loaded. The MD5 is a
-- fingerprint of ordered landing-table rows, not a checksum of original file
-- bytes. Identical loaded content is never inserted twice.
CREATE TABLE IF NOT EXISTS control.source_file (
    source_file_id   integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    load_batch_id    integer     NOT NULL REFERENCES control.load_batch,
    source_system    text        NOT NULL
                     CHECK (source_system IN ('DCJ_RENT', 'ABS_CENSUS', 'ABS_ERP', 'NSW_HOUSING')),
    target_table     text        NOT NULL,   -- src_* table that received the rows
    source_file_name text        NOT NULL,   -- name of the delivered file
    content_md5      text        NOT NULL CHECK (content_md5 ~ '^[0-9a-f]{32}$'),
    row_count        integer     NOT NULL CHECK (row_count >= 0),
    is_synthetic     boolean     NOT NULL,
    registered_at    timestamptz NOT NULL DEFAULT clock_timestamp(),
    UNIQUE (source_system, content_md5)
);

-- Test evidence (file 11). One run_id per execution of the test suite.
CREATE SEQUENCE IF NOT EXISTS control.test_run_seq;

CREATE TABLE IF NOT EXISTS control.test_result (
    test_result_id     bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    run_id             integer     NOT NULL,
    test_id            text        NOT NULL,
    test_group         text        NOT NULL,
    test_name          text        NOT NULL,
    severity           text        NOT NULL CHECK (severity IN ('CRITICAL', 'WARNING')),
    expected_result    text        NOT NULL,
    actual_result      text        NOT NULL,
    status             text        NOT NULL CHECK (status IN ('PASS', 'FAIL')),
    executed_at        timestamptz NOT NULL DEFAULT clock_timestamp(),
    evidence_reference text,
    UNIQUE (run_id, test_id)
);

-- One row per execution of the test suite, with the fingerprint of the
-- dashboard export data that was tested (reporting.dashboard_fingerprint()).
-- The dashboard exporter only marks its output VERIFIED when the data it
-- exports still has this fingerprint and every test of the run passed.
CREATE TABLE IF NOT EXISTS control.test_run (
    run_id             integer     PRIMARY KEY,
    tested_at          timestamptz NOT NULL DEFAULT clock_timestamp(),
    report_fingerprint text        NOT NULL CHECK (report_fingerprint ~ '^[0-9a-f]{32}$')
);

-- Working area for file 11. A permanent table (not a session TEMP table) so
-- that every test statement can be run on its own, in any SQL client, and the
-- file can be split into parts without losing the results already collected.
CREATE TABLE IF NOT EXISTS control.test_work (
    test_id            text PRIMARY KEY,
    test_group         text NOT NULL,
    test_name          text NOT NULL,
    severity           text NOT NULL CHECK (severity IN ('CRITICAL', 'WARNING')),
    expected_result    text NOT NULL,
    actual_result      text,
    evidence_reference text
);

COMMENT ON TABLE control.test_work   IS 'Scratch results of the current test execution; copied to test_result under a new run_id';
COMMENT ON TABLE control.load_batch  IS 'One row per source-load execution; SKIPPED_NO_CHANGE proves idempotent reloads';
COMMENT ON TABLE control.source_file IS 'Loaded source-shaped deliveries; content_md5 fingerprints ordered landing rows, not original file bytes';
COMMENT ON TABLE control.test_run    IS 'One row per test-suite execution with the fingerprint of the tested dashboard data';
COMMENT ON TABLE control.test_result IS 'Results of 11_run_quality_tests.sql, kept as report evidence';

COMMIT;
