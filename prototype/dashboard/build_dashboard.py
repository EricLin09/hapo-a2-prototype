#!/usr/bin/env python3
"""Export the three tested PostgreSQL report views to a portable static dashboard.

Requires only Python's standard library and the running course PostgreSQL Docker
container. Run after prototype/run_all.sh. The output data.js is read by
index.html even when opened directly from disk; the same folder can be uploaded
to a static host such as Cloudflare Pages.

Safety rules
  * The export is written to a temporary file, read back and checked; only a
    file that passes every check replaces data.js. A failed export leaves the
    previous data.js untouched.
  * VERIFIED requires that every test of the latest SQL test run passed AND
    that the data being exported has the same fingerprint as the data that run
    tested (reporting.dashboard_fingerprint(), recorded in control.test_run).
    Data changed after testing therefore cannot be published as verified.
"""

import argparse
from datetime import datetime, timezone
import json
import math
import os
from pathlib import Path
import subprocess


HERE = Path(__file__).resolve().parent
CONTAINER = os.environ.get("HAPO_PG_CONTAINER", "student-postgres")
DB_USER = os.environ.get("HAPO_DB_USER", "student")
PREFIX = "window.HAPO_DATA = "

# The exporter reads only the dashboard views defined in file 10, in the same
# order the fingerprint function hashes them.
QUERIES = {
    "uc1": "SELECT row_to_json(v)::text FROM reporting.vw_dashboard_uc1 v ORDER BY v.quarter_start, v.lga_name",
    "uc2": "SELECT row_to_json(v)::text FROM reporting.vw_dashboard_uc2 v ORDER BY v.financial_year, v.lga_name",
    "uc3": "SELECT row_to_json(v)::text FROM reporting.vw_dashboard_uc3 v ORDER BY v.month_start, v.lga_name",
}

FINGERPRINT_SQL = "SELECT to_json(reporting.dashboard_fingerprint())::text"

# Latest test run: pass count, when it ran (whole seconds, so every Python 3
# version can parse it) and the fingerprint of the data it tested.
TEST_SUMMARY_SQL = """
    SELECT row_to_json(q)::text FROM (
        SELECT tr.run_id, tr.report_fingerprint,
               date_trunc('second', tr.tested_at) AS tested_at,
               count(r.test_id) AS total,
               count(r.test_id) FILTER (WHERE r.status = 'PASS') AS passed
        FROM control.test_run tr
        LEFT JOIN control.test_result r USING (run_id)
        WHERE tr.run_id = (SELECT max(run_id) FROM control.test_run)
        GROUP BY tr.run_id, tr.report_fingerprint, tr.tested_at
    ) q
"""


def fetch_rows(sql: str) -> list:
    command = [
        "docker", "exec", CONTAINER, "psql", "-X", "-A", "-t",
        "-v", "ON_ERROR_STOP=1", "-U", DB_USER, "-d", "hapo_a2",
        "-c", sql,
    ]
    result = subprocess.run(command, capture_output=True, text=True, check=True)
    return [json.loads(line) for line in result.stdout.splitlines() if line.strip()]


def current_fingerprint() -> str:
    return fetch_rows(FINGERPRINT_SQL)[0]


def verify_synthetic_golden_values(data: dict) -> None:
    """Check the exported file against two hand-calculated fixture values."""
    checks = (
        ("uc1", {"lga_code": "16260", "quarter": "2025-Q1"}, "rent_to_income_pct", 30.00),
        ("uc2", {"lga_code": "16260", "financial_year_label": "FY2024-25"},
         "da_approved_per_1000_residents", 9.05),
    )
    for section, keys, field, expected in checks:
        matches = [row for row in data[section]
                   if all(row.get(key) == value for key, value in keys.items())]
        if len(matches) != 1 or not math.isclose(
            float(matches[0].get(field) or -1), expected, abs_tol=0.001
        ):
            raise SystemExit(
                f"Dashboard golden check failed: {section} {keys} {field} != {expected:.2f}"
            )
    print("Dashboard golden checks passed: Parramatta 30.00% and 9.05 per 1,000")


def build_metadata(verified_build: bool) -> dict:
    metadata = {"generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                "verified": False, "test_run": None}
    if not verified_build:
        return metadata
    summaries = fetch_rows(TEST_SUMMARY_SQL)
    if len(summaries) != 1:
        raise SystemExit("Verified export requires a completed SQL test run (file 11)")
    summary = summaries[0]
    if summary["total"] <= 0 or summary["passed"] != summary["total"]:
        raise SystemExit(f"Verified export refused: test run {summary['run_id']} passed "
                         f"{summary['passed']}/{summary['total']}")
    if summary["report_fingerprint"] != current_fingerprint():
        raise SystemExit(f"Verified export refused: report data changed after test run "
                         f"{summary['run_id']}; rerun 11_run_quality_tests.sql first")
    metadata["verified"] = True
    metadata["test_run"] = {"id": summary["run_id"], "passed": summary["passed"],
                            "total": summary["total"], "tested_at": summary["tested_at"],
                            "fingerprint": summary["report_fingerprint"]}
    return metadata


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--verify-synthetic", action="store_true",
        help="check the two hand-calculated values in the synthetic fixture",
    )
    parser.add_argument(
        "--verified-build", action="store_true",
        help="mark the export VERIFIED; refused unless the latest test run passed every "
             "test on exactly the data being exported",
    )
    args = parser.parse_args()

    metadata = build_metadata(args.verified_build)
    data = {name: fetch_rows(query) for name, query in QUERIES.items()}
    if args.verified_build and current_fingerprint() != metadata["test_run"]["fingerprint"]:
        raise SystemExit("Verified export refused: report data changed during the export")
    for name, rows in data.items():
        if not rows:
            raise SystemExit(f"{name}: reporting view returned no rows")
    unique_keys = {"uc1": ("lga_code", "quarter_start"),
                   "uc2": ("lga_code", "financial_year"),
                   "uc3": ("lga_code", "month_start")}
    for name, rows in data.items():
        keys = unique_keys[name]
        if len({tuple(row.get(key) for key in keys) for row in rows}) != len(rows):
            raise SystemExit(f"{name}: duplicate report grain {keys}")
    data["meta"] = metadata
    payload = json.dumps(data, ensure_ascii=False, separators=(",", ":"))
    # Guard against a source label accidentally terminating the script element.
    payload = payload.replace("</", "<\\/")

    output = HERE / "data.js"
    temporary = HERE / f".data.js.{os.getpid()}.tmp"
    try:
        temporary.write_text(PREFIX + payload + ";\n", encoding="utf-8")
        # Check the file exactly as the browser will load it, before publishing.
        exported = temporary.read_text(encoding="utf-8")
        if not exported.startswith(PREFIX) or not exported.endswith(";\n"):
            raise SystemExit("Dashboard export has an invalid JavaScript wrapper")
        saved_data = json.loads(exported[len(PREFIX):-2])
        if saved_data.get("meta") != metadata:
            raise SystemExit("Dashboard verification metadata changed during serialization")
        if args.verify_synthetic:
            verify_synthetic_golden_values(saved_data)
        # Every check passed: replace data.js in one step (atomic on one disk).
        os.replace(temporary, output)
    finally:
        if temporary.exists():
            temporary.unlink()   # a failed export never leaves a file behind

    if metadata["verified"]:
        run = metadata["test_run"]
        print(f"Verified SQL run {run['id']}: {run['passed']}/{run['total']} PASS, "
              f"data fingerprint matches")
    else:
        print("Export is UNVERIFIED: run the SQL test suite and export with --verified-build "
              "before claiming a verified snapshot")
    print(f"Wrote {output} ({', '.join(f'{k}: {len(data[k])}' for k in QUERIES)})")


if __name__ == "__main__":
    main()
