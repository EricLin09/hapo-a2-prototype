# HAPO A2 — Data Warehouse Prototype

Shared repository for Assignment 2 of UTS 32113 Advanced Database (Spring 2026). It holds the working prototype for the NSW Housing Affordability Planning Office (HAPO) case: four source systems are loaded, cleaned, integrated into a dimensional warehouse in PostgreSQL 15, tested, and published to a static dashboard.

> **Private repository. All measures are synthetic.** LGA codes and names are real ASGS 2021 values; every rent, income, population and housing figure is generated test data and must not be reported as a real NSW finding.

**Current build:** 10 Oct 2026 · 50/50 tests pass · same content as `hapo_a2_prototype_final_2026-10-10.zip`

## What is in here

```
prototype/
├── run_all.sh        one-command rebuild: reset → load → transform → warehouse → tests → dashboard
├── sql/              00–12 and 99, one file per design component (each header says what it builds)
├── dashboard/        static dashboard (index.html, app.js, style.css, data.js) and its exporter
├── results/          logs from the latest build; 11_run_quality_tests.log = test evidence
└── README.md         full details: file → design mapping, deviations from the draft, limitations
database/             hapo_a2.sql: full database snapshot (pg_dump) with restore instructions
docs/                 architecture and data model diagrams (added when the first diagram is committed)
```

## Look at it without installing anything

Download the repository (**Code → Download ZIP**) and open `prototype/dashboard/index.html` in a browser. It shows the result of the latest tested build; the top bar should say **VERIFIED**.

## Rebuild and test it

You need Docker Desktop, the course lab environment and Python 3.

```bash
cd <your advanced-database-lab folder> && docker compose up -d
bash prototype/run_all.sh
```

Every step prints `ok`, and the run ends with `Verified SQL run …: 50/50 PASS, data fingerprint matches`. The build uses its own database `hapo_a2`, so the course database `lab` is never touched. To run the files one at a time in CloudBeaver or VS Code instead, follow the order in [`prototype/README.md`](../prototype/README.md) (file 06 runs twice).

## How the pipeline fits together

| Layer | Schemas | Built by |
|---|---|---|
| Source deliveries | `landing`, `src_rental`, `src_census`, `src_population`, `src_housing` | 03, 05, 06 |
| Cleaning and validation | `staging`, `curated` (rules R01–R07, `rejected_row`) | 04, 07 |
| Warehouse | `dw`: 4 dimensions, 4 facts | 08, 09 |
| Reports | `reporting`: UC1–UC3 views, lineage view, dashboard export views | 10 |
| Control and tests | `control`: load batches, source files, test runs and results | 02, 11 |

## Working together

The architecture (Team 1), data model (Team 2) and prototype (Team 3) have to describe the same system, so this repository is the single current version of the prototype and its diagrams.

- **Pull before you start** (`git pull`) so you are looking at the latest version.
- **Changed the prototype?** Rebuild with `run_all.sh`, check it still passes 50/50 (or the new total), commit with a message that says what changed, push, and tell the group so the architecture and data model can be checked against it.
- **Diagrams** go in `docs/`: commit the editable source (for example draw.io) together with the exported PNG used in the report.
- **Report text stays in Teams/OneDrive.** This repository is for code and diagrams only.
- **Not using git?** Send your file to Xi and it will be added for you.
- The marked submission is the zip package, not this repository.

Maintainer: Xi Lin (Team 3)
