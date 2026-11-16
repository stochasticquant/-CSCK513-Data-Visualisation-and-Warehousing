# Development Log: Gravity Bookstore Data Warehouse

Source material for the report's **development process** section (debugging steps and design changes) and parts of the **data cleansing** and **lessons learned** sections. Each entry records what happened, why, and what was done about it.

**Entry types:** 🐞 Bug / error · 🔄 Design change · 🧭 Decision · ✅ Verification

---

## Phase 0–1: Environment and databases

### 2026-10-11: Initial build on an Ubuntu server

- 🧭 **Decision:** the operational database `gravity_books` was first built on SQL Server 2022 running on an Ubuntu server (`192.168.1.128`), connecting as a SQL login from the Windows PC.
- 🐞 **Bug:** `01_sqlserver_create.sql` runs `CREATE DATABASE gravity_books` but has no `USE gravity_books`, so the tables would be created in whatever database the session was connected to (e.g. `master`).
  **Fix:** create the database first, then run the scripts against it.
- 🐞 **Bug:** the data model (`data_model.png`) shows `customer_address.status_id → address_status.status_id`, but the create script leaves that foreign key out.
  **Fix:** added `fk_ca_status` after loading.
- 🐞 **Bug:** installing the *SQL Server Integration Services Projects 2022* extension failed with *"Please close following processes before continuing the setup: devenv, ServiceHub…"* (screenshot `error.png`).
  **Fix:** closed all Visual Studio windows and background processes, then reran the installer.
- 🧭 **Decision:** scripts written for staging (`sql/10`), the warehouse (`sql/20`), ETL procedures (`sql/21`) and data-quality checks (`sql/30`). See the plan, §5–§8.

### 2026-10-27: Moved to the local SQL Server 2025

- 🔄 **Design change:** the project moved from the Ubuntu server to the **local SQL Server 2025 Developer edition** on the Windows PC (default instance, `localhost`).
  **Effects:**
  - Connections use **Windows Authentication** instead of a SQL login, so no password is stored in the SSIS packages. That avoids *Login failed* and package-encryption problems.
  - SQL Server, SSIS and Visual Studio are now on one machine, so there's no network dependency.
  - SSIS catalog deployment and SQL Agent scheduling become possible, since both are limited on Linux.
  - The SSIS project's target version is SQL Server 2025.
  - A SQL login `charles` exists on the local server, but the packages deliberately use Windows Authentication.
- 🔄 **Design change:** the source build was automated with `sql/00_build_gravity_books.ps1`. It recreates the database, runs the 13 provided scripts in order without editing them, works around the missing `USE`, and adds `fk_ca_status`. That makes the build repeatable and documents the fixes in one place.
- 🐞 **Potential bug avoided:** four of the provided scripts (`02` author, `03` publisher, `05` book, `08` address) are **UTF-8** and contain accented characters (e.g. *Prétear*, typographic quotes in *Oh, The Places You'll Go!*). If `sqlcmd` reads them in the default code page, those characters get corrupted.
  **Fix:** run `sqlcmd` with `-f 65001` (UTF-8 input).
  **Check:** titles with accents came through correctly.
- ⚠️ **Finding:** scripts 10–13 generate customer addresses, orders, order lines and order history **at random** (`NEWID()`, `RAND()`, dates relative to `GETDATE()`), so the rebuild produced different figures from the first build:

  | Measure | Ubuntu build (2026-10-11) | Local build (2026-10-27) |
  |---|---|---|
  | Order date range | 2023-10-12 → 2026-10-11 | 2023-10-29 → 2026-10-27 |
  | Non-English order lines | 830 | 820 (5.3%) |
  | Cancelled / returned orders | 497 | 487 |
  | Order lines with price ≤ 0 | 7 | 10 |
  | Orders with no status history | 5 | 3 |
  | order_history rows | 22,345 | 22,347 |

  Fixed totals (7,550 orders, 15,400 order lines, 2,000 customers, 11,127 books) and the structural data problems (25 short ISBNs, 77 zero-page books, country issues) didn't change.
  **Lesson:** source data used for a report must be frozen. The database must not be rebuilt after report screenshots are taken. In a real project you'd take a snapshot or backup of the source.
- ✅ **Verification:** `gravity_books` has 15 tables and 15 foreign keys. `gravity_staging` has 13 tables. `gravity_dw` has 10 tables, 3 procedures, and the campaign start date (2025-10-01) in `etl.config`.
- 🧭 **Tooling:** Power BI Desktop wasn't installed on this PC, so it was installed from the Microsoft Store (version 2.159.883.0).

---

## Phase 2: Extract package (`Extract_To_Staging.dtsx`)

### 2026-10-27: Building the package

- 🧭 **Decision:** the package was **generated with the SSIS object model** (C# program `ssis/tools/BuildExtractPackage.cs`, run by `ssis/tools/build_extract_package.ps1`) rather than drawn by hand. It has 13 near-identical data flows, so generating them avoids copy-paste mistakes such as forgotten column mappings. The package can still be opened and edited in Visual Studio like any other.
- 🧭 **Control flow:** `SQL Truncate staging tables` → `SEQ Extract OLTP` (11 data flows, not linked, so they run in **parallel**) → `SEQ Extract files` (survey + country/region CSVs) → `SQL Log row counts`. An **OnError** event handler writes a `Failed` row to `etl.audit` naming the failing task.
  **Why:** truncating first makes the package re-runnable. Staging has no foreign keys, so load order doesn't matter and the tables can load in parallel.
- 🧭 **Data flows:** `OLE DB Source` (explicit column list, not `SELECT *`) → `Row Count` (one variable per table) → `OLE DB Destination` (fast load, `TABLOCK`, keep NULLs). `load_datetime` is left unmapped so it takes its default (the load time).
- 🔄 **Design change (from the guide):** the guide used project-level connection managers. The generated package uses **package-level** connection managers, because the object model creates them inside the package. Package 2 will define its own. Project-level managers can be added later in Visual Studio if wanted.
- 🐞 **Potential bug avoided:** SSIS reads flat-file columns as **Unicode (DT_WSTR) with width 50** by default, while staging uses `VARCHAR`. That would cause *"cannot convert between unicode and non-unicode string data types"* and *"Text was truncated"* errors.
  **Fix:** every CSV column is defined as **DT_STR (code page 1252)**, with widths matching the staging columns (e.g. `country_status` 20, `region` 50).
- 🐞 **Potential bug avoided:** SSIS expression functions such as `TRIM()` return **Unicode** text, even when the input is non-Unicode.
  **Fix:** the survey's trimming Derived Column casts its result back with `(DT_STR, n, 1252)TRIM(column)`.
- 🔄 **Design change (from the guide):** the guide logged row counts from `sys.partitions`, which can be approximate. The package logs an exact `COUNT(*)` per staging table instead.
- 🧭 **Input files:** both CSVs are ASCII with Windows (CRLF) line endings and a header row. `country_region.csv` uses a `"` text qualifier, because names like `"Virgin Islands, British"` contain commas.
- ✅ **Verification:** the generated package passed SSIS validation with no errors or warnings.

### 2026-10-27: First run and debugging

- 🐞 **Bug (first run failed):** `dtexec` reported 33 errors and every data flow failed. The **first** error explained it, and the rest were knock-on failures:
  > *Cannot insert the value NULL into column 'load_datetime', table 'gravity_staging.stg.shipping_method'; column does not allow nulls. INSERT fails.*

  **Cause:** the OLE DB Destinations had **Keep nulls** (`FastLoadKeepNulls`) switched on. In fast-load (bulk insert) mode, that inserts NULL into columns with no input, including the unmapped `load_datetime`, instead of applying the column's `DEFAULT SYSDATETIME()`.
  **Fix:** turned Keep nulls off. NULL values in the source still arrive as NULL, because no other staging column has a default (checked: 0 NULL `load_datetime` values, and source vs staging comparisons match).
  **Lesson:** when a package fails, read the *first* error. Later messages (`DTS_E_PROCESSINPUTFAILED`, `MAXIMUMERRORCOUNTREACHED`) are consequences of it.
- ✅ **The OnError handler worked:** the failed run wrote one `Failed` row per failing data flow to `gravity_dw.etl.audit` (e.g. `DFT book | Failed`). Those rows are kept as evidence of error logging.
- ✅ **Second run succeeded** (`DTSER_SUCCESS`, about 2.2 seconds). The only warning: *"Could not open global shared memory… performance counters are not available"*. It's harmless and only means Windows performance counters need admin rights.
- ✅ **Reconciliation, source vs staging (all OK):**

  | Table | Rows | | Table | Rows |
  |---|---|---|---|---|
  | book | 11,127 | | cust_order | 7,550 |
  | book_language | 27 | | order_line | 15,400 |
  | publisher | 2,264 | | order_history | 22,347 |
  | customer | 2,000 | | order_status | 6 |
  | address | 1,000 | | shipping_method | 4 |
  | country | 232 | | survey (CSV) | 1,999 |
  | | | | country_region (CSV) | 232 |

  Content check: comparing source and staging row by row (`EXCEPT`) for `book`, `cust_order` and `order_line` found **0 differences**. The quoted CSV value `"Virgin Islands, British"` loaded as one field, and the survey values were trimmed.
- ✅ **Re-runnable:** a second run left the counts unchanged (15,400 order lines, 1,999 survey rows), so truncate-then-load works.
- ✅ **Data-quality baseline** (`EXEC dq.usp_run_checks` on the staged data, logged to `dq.check_log`). **23 checks**; failing ones:

  | Check | Dimension | Failed rows | Treatment planned |
  |---|---|---|---|
  | Orders with no status history | Completeness | 3 | `latest_order_status = Unknown` |
  | Customers with no survey response | Completeness | 1 | `No response` |
  | ISBN13 not 13 characters | Validity | 25 | Left-pad with zeros |
  | Book with 0 pages | Validity | 77 | `num_pages = NULL` |
  | Order line price zero/negative/missing | Validity | 10 | Reject to `dq.fact_rejects` |
  | Duplicate country names (Singapore) | Uniqueness | 1 | Conform to one name |
  | Misspelt country names (Boliva) | Consistency | 1 | Use `clean_country_name` |
  | English language code variants | Consistency | 5 | `language_group = English` |

  Clean (0 failures): all 5 integrity/orphan checks, missing city/country, missing order date, future order dates, status before order date, email format, survey answers outside the allowed list, duplicate emails, survey responses or book IDs, and order lines shipped to historical or invalid countries.
- 📝 **Correction:** the plan said "24 checks"; `sql/30_dq_checks.sql` actually contains **23**.

### 2026-10-27: Opened in Visual Studio, run and screenshots

- 🧭 Created the SSIS project `ssis/GravityETL` in Visual Studio 2022 (target SQL Server 2025) and added `Extract_To_Staging.dtsx` with *Add Existing Package*.
- 🐞 **Layout:** the generated package has no designer layout, so every box opened stacked in the top-left corner.
  **Fix:** *Format → Auto Layout → Diagram* on the Control Flow and on each Data Flow used for screenshots.
  **Lesson:** the layout can't be changed during debugging, so tidy it and save before pressing F5.
- ✅ **Run in Visual Studio (F5):** every task got a green tick, and the status bar read *"Package execution completed with success"*. Data-flow paths showed 11,127 rows for `DFT book` and 1,999 rows for `DFT survey`, matching the `dtexec` runs.
- 📸 **Screenshots saved in `diagrams/`:**
  - `extract_control_flow.png`: control flow, all green, with the connection managers pane
  - `extract_dft_book.png`: table-copy data flow (Source → Row Count → Destination, 11,127 rows)
  - `extract_dft_survey.png`: CSV data flow with the TRIM Derived Column (1,999 rows)
  - `extract_derived_column.png`: Derived Column editor showing the `(DT_STR,n,1252)TRIM(...)` expressions

### 2026-10-27: Control-flow layout fix

- 🐞 **Problem:** Auto Layout put all 11 extract data flows in **one very wide row**, which would be unreadable at page width in the report. Dragging the boxes by hand didn't stick: Visual Studio kept its in-memory copy of the package (the `*` in the tab title), so the edits were lost.
- 🔄 **Fix:** the designer layout is stored as XML in the package's `DesignTimeProperties` section, separate from the runtime logic. `ssis/tools/grid_layout_extract.ps1` rewrites it into a **4-column grid**, resizes the container, and moves the items and arrows below it down. A backup is kept as `Extract_To_Staging.dtsx.bak`.
- 🐞 **Bug in the fix:** the first version of the script matched `Size="` inside `PanelSize="`, so it set the container's inner size twice and left its outer size unchanged.
  **Fix:** added a regex look-behind `(?<!\w)` so `Size` only matches as a whole attribute name. Re-applied it from the backup and validated with `dtexec /Validate` (success).
- 🐞 **Reloading:** Visual Studio didn't reload the file changed outside it.
  **Fix:** stop debugging, close the package tab and choose **No** to "Save changes?" (Yes would overwrite the new layout), then reopen it.
  **Lesson:** never edit a package file while it's open in Visual Studio with unsaved changes.
- 📸 Retook `diagrams/extract_control_flow.png`: grid layout, all green, with the connection managers and the "completed with success" status line.

---

## Phase 3: Transform & load package (`Transform_Load_DW.dtsx`)

### 2026-10-27: Design

- 🧭 **Generated** like Package 1 (`ssis/tools/BuildTransformPackage.cs`, run by `build_transform_package.ps1`), saved to `ssis/packages/Transform_Load_DW.dtsx`.
- 🧭 **Control flow:** `SQL Run data-quality checks` (`dq.usp_run_checks`) → `SQL Prepare full load` (`etl.usp_prepare_full_load`) → `SQL Load dim_date` (`etl.usp_load_dim_date`) → `SEQ Load dimensions` (4 data flows in **parallel**) → `DFT fact_sales` → `SQL Reconcile row counts`. Plus an OnError handler that logs to `etl.audit`.
  **Why this order:** the fact table needs the dimensions' surrogate keys, so it runs only after every dimension loads successfully. The dimensions don't depend on each other, so they run in parallel.
- 🧭 **Split between SQL and SSIS:** each data flow joins its staging tables in the OLE DB Source query, where joins are fastest. The **cleansing rules are SSIS Derived Columns**, where they're visible and documented in the package:

  | Data flow | Cleansing / transformation |
  |---|---|
  | `DFT dim_book` | ISBN left-padded to 13 (`RIGHT("0000000000000" + TRIM(isbn13), 13)`); `num_pages <= 0` → NULL; `publication_year`; `language_group` (5 English codes → English, the rest incl. `mul` → Non-English) |
  | `DFT dim_customer` | Survey joined on customer_id (first response only, in case of duplicates); missing answers → `No response`; `full_name`; `email_domain`; `survey_responded` flag |
  | `DFT dim_location` | **Lookup** to the `country_region` reference: clean country name (Boliva → Bolivia, one Singapore, historical → modern successor), `region`, `country_status`. Missing values → `Unknown` |
  | `DFT dim_shipping_method` | Straight copy |
  | `DFT fact_sales` | `DER Date key` (yyyymmdd) → **Conditional Split** (price NULL or ≤ 0 → `dq.fact_rejects` with a reason) → **5 Lookups** (dim_date, customer, book, location via the order's *destination* address, shipping method) → `DER Unknown members` (no match → key -1) |

- 🧭 **Fact source query:** latest order status = the most recent `order_history` row (`OUTER APPLY TOP 1 … ORDER BY status_date DESC`); `is_cancelled_or_returned` = the order was *ever* cancelled or returned.
- 🧭 **Lookups use full cache** (the reference table is loaded into memory once) and **Ignore failure**, so an unmatched row keeps flowing with a NULL key, which is then set to the unknown member (-1). No row is silently dropped.
- 🧭 **Full reload, not incremental:** `etl.usp_prepare_full_load` empties the star schema before each run, so the dimension loads are plain inserts and don't need SCD lookups. Incremental loading (watermark on `order_date` / `line_id`, SCD Type 1 updates via Lookup + OLE DB Command or the SCD wizard) is the production alternative for the report.
- 🔄 **Design change (automated check):** the reconcile step **fails the package** (`THROW 50001`) if any table's `rows_read ≠ rows_written + rows_rejected`. It turns the plan's "reconcile row counts" into an automatic control, which is one of the "automated checking" improvements the brief asks about.

### 2026-10-27: Debugging

- 🐞 **Derived Column rejected the ISBN expression** (`0xC0204006` when setting `Expression`):
  `ISNULL([isbn13]) ? NULL(DT_STR,13,1252) : (DT_STR,13,1252)RIGHT("0000000000000" + TRIM([isbn13]), 13)`.
  **Fix:** removed the NULL branch, giving `(DT_STR,13,1252)RIGHT("0000000000000" + TRIM([isbn13]), 13)`. It isn't needed: SSIS string functions return NULL for NULL input.
  **Lesson:** keep expressions as simple as possible, and add error messages that say *which* expression failed. The generator was changed to report the column name and expression.
- 🐞 **Lookup failed validation:** *"LKP dim_date.Inputs[Lookup Input] has an invalid error or truncation row disposition"* (`VS_ISCORRUPT`).
  **Cause:** "Ignore failure" was set on the Lookup's **input**. Inspecting the saved package XML showed that the Lookup keeps its no-match handling on the **Lookup Match Output** (`errorOrTruncationOperation="Lookup"`).
  **Fix:** set `ErrorRowDisposition = IgnoreFailure` on the match output. Validation then succeeded.
- ✅ **First run succeeded** (`DTSER_SUCCESS`, about 7 seconds).
- 🐞 **Surrogate keys started at 0, not 1.** `etl.usp_prepare_full_load` reseeds the identities with `DBCC CHECKIDENT (…, RESEED, 0)`. On a table whose identity has **never been used**, the next key is the reseed value itself (0), not reseed + 1. Inserting the -1 unknown member with `IDENTITY_INSERT` doesn't count as using the identity (`sys.identity_columns.last_value` stayed NULL). So the first load numbered keys from 0 and every later load from 1, which breaks "same keys on every reload".
  **Fix:** the procedure now reseeds to 1 when `last_value IS NULL` and to 0 otherwise (`sql/21_etl_procedures.sql`).
  **Check:** tested on a fresh table in `tempdb` (first key = 1). Two consecutive loads gave identical keys (1–2,000 customers, 1–11,127 books, same fact checksum).

### 2026-10-27: Verification

- ✅ **Reconciliation (`etl.audit`), all `Success`:**

  | Table | Read (staging) | Written (DW) | Rejected |
  |---|---|---|---|
  | dim_book | 11,127 | 11,127 | 0 |
  | dim_customer | 2,000 | 2,000 | 0 |
  | dim_location | 1,000 | 1,000 | 0 |
  | dim_shipping_method | 4 | 4 | 0 |
  | dim_date | 1,461 days (2023-01-01 → 2026-12-31) | 1,461 | 0 |
  | **fact_sales** | **15,400** | **15,390** | **10** |

- ✅ **Rejects:** 10 lines, all *"Price zero or negative"* (price 0.00).
- ✅ **Cleansing rules worked:**
  - 0 ISBNs not 13 characters (e.g. `8987059752` → `0008987059752`)
  - 0 books with 0 pages (77 now NULL)
  - 1 customer `No response`, 1,999 responded
  - books: 10,544 English / 583 Non-English (+1 Unknown member)
  - addresses by region: Asia 451, Europe 300, South America 94, North America 79, Africa 65, Oceania 11
- ⚠️ **Finding:** none of the 1,000 addresses are in Singapore, Bolivia or a historical/invalid country, so those country rules are in place (and checked by `dq.usp_run_checks`) but change no rows in this data. The rules still protect the warehouse if such addresses appear later. Say this in the report rather than claiming they fixed live rows.
- ✅ **Fact matches the source:**
  - total sales **154,966.34**, equal to the source sum of valid prices
  - 820 non-English lines
  - 487 cancelled/returned orders
  - 6 lines (3 orders) with status `Unknown`
  - 0 location mismatches against the order's destination address, 0 date mismatches
  - 0 lines on unknown members
  - 7,549 distinct orders, because one order's only line had a zero price and was rejected
- ✅ **Unknown-member test:** a fake staging order line (`line_id 999999`, `book_id 999999`, which doesn't exist) loaded with **`book_key = -1`** and wasn't lost. The reconciliation still balanced (15,401 = 15,391 + 10), and the DQ check *"Order line book not in book table"* reported 1. The fake row was then deleted and the warehouse reloaded (15,390 rows, 0 unknown).
- 📊 **First look at the campaign split** (campaign start assumed 2025-10-01):

  | Period | Lines | Sales | Non-English lines |
  |---|---|---|---|
  | Pre-campaign (about 2 years) | 9,836 | 99,331.72 | 506 |
  | Post-campaign (about 1 year) | 5,554 | 55,634.62 | 314 |

  Per month, post-campaign volume is higher (about 463 lines/month vs about 410). The dashboard should compare **monthly averages** or equal-length periods, not raw totals.

### 2026-10-27: Opened in Visual Studio, run and screenshots

- 🧭 Added `Transform_Load_DW.dtsx` to the `GravityETL` project (*Add Existing Package*) and tidied it with *Format → Auto Layout → Diagram*.
- 🐞 **Layout:** the fact data flow has 14 components in one chain, so it came out too tall to read on one screen. A fully zoomed-out screenshot was unreadable.
  **Fix:** moved the reject branch into its own column beside the main chain, and captured the flow in **two halves at 100% zoom**.
- ✅ **Run in Visual Studio (F5):** every task green, *"Package execution completed with success"*. The data-flow paths showed the same counts as the `dtexec` runs: 11,127 books, 1,000 locations, 15,400 order lines → *Valid* 15,390 / *Invalid price* 10.
- 📸 **Screenshots saved in `diagrams/`:**
  - `tl_control_flow.png`: control flow (DQ checks → prepare → dim_date → 4 parallel dimension loads → fact → reconcile), all green
  - `tl_dft_dim_book.png`: dimension data flow with the cleansing Derived Column (11,127 rows)
  - `tl_dft_dim_location.png`: dimension data flow with the country/region Lookup (1,000 rows)
  - `tl_dft_fact_sales_top.png`: fact flow, top half: source, date key, price split (15,390 valid / 10 invalid) and the reject branch
  - `tl_dft_fact_sales_bottom.png`: fact flow, bottom half: surrogate-key lookups, unknown members, destination (15,390 rows). Crop the Visual Studio "no longer supported" banner off the top in the report.
---

## Phase 4: Data quality

### 2026-10-27: Before/after checks

- 🔄 **Design change:** the original checks (`dq.usp_run_checks`) only look at **staging**, so they show the "before" state on every run. Added **`dq.usp_run_dw_checks`** (`sql/31_dw_checks.sql`, 15 checks) that look at the **loaded warehouse** and log to the same `dq.check_log` (table names prefixed `dw.`), so before and after can be compared.
- ✅ **Result:** 14 of 15 warehouse checks return 0. The only non-zero result is expected: *"Fact lines with unknown order status"* = 6, the lines of 3 orders placed in the 12 hours before the source build, which have no history yet.
- 📝 Summary table, priorities and improvement ideas written up in `docs/Data_Quality_Summary.md`.
---

## Phase 5: Power BI

### 2026-10-27: Preparation

- 🧭 **Import mode** against `gravity_dw` only (6 tables: 5 dimensions + `fact_sales`). The `dq`/`etl` tables are left out of the dashboard.
- 🔄 **Design change: campaign comparison by rate, not totals.** The data runs from 29 Oct 2023 to 27 Oct 2026, so the pre-campaign period (703 days) is almost twice as long as the post-campaign period (392 days), and both ends are partial months. Comparing raw totals, or averages per calendar month, would be misleading. The dashboard compares **lines per 30 days** (DAX `Days in Period` = first to last sale date in the current filter).
- 📊 **Expected figures**, calculated in SQL to check the dashboard against:
  - total lines per 30 days: 419.7 → 425.1 (**+1.3%**)
  - non-English lines per 30 days: 21.6 → 24.0 (**+11.3%**)
  - non-English share: 5.14% → 5.65%

  Full list in `docs/PowerBI_Guide.md` §5.
- ⚠️ **Caveat for the report:** the campaign date is assumed, and the orders are randomly generated, so the differences show how the warehouse *would* measure a campaign effect rather than proving one.
- 🧭 Removed the `-1` row from `dim_date` in Power Query, so `full_date` can be marked as the date table (no fact row uses it).- ✅ **Relationships came from the warehouse foreign keys:** Power BI imported all 5 fact → dimension relationships (including `order_date_key → date_key`, whose names differ) from the FK constraints in `20_create_dw.sql`. Creating it by hand gave *"there is already a relationship"*. This is a benefit of declaring FKs in the warehouse schema.
- 📸 `diagrams/pbi_model.png`: the Power BI model, a star with `fact_sales` in the centre and 5 one-to-many relationships.
- 🧭 **Measures added by script**, not typed in: `powerbi/tools/add_measures.ps1` connects to Power BI Desktop's local Analysis Services engine through the Tabular Object Model (the same route external tools like Tabular Editor use) and creates 20 DAX measures in `fact_sales`, with number formats and display folders (*1 Sales*, *2 Non-English*, *3 Campaign*). This avoids typos across 20 formulas.
  - 🐞 The TOM library in the Windows GAC is from SQL Server 2016 (v13), too old for a Power BI model (compatibility level 1606). **Fix:** load Power BI's own v17 libraries from its install folder.
- ✅ **Measures verified** with DAX queries (`powerbi/tools/check_measures.ps1`, via Power BI's ADOMD client). Every figure matches the SQL results exactly: Total Sales 154,966.34 · 15,390 lines · 7,549 orders · 1,747 customers · 109 countries · 820 non-English lines (5.33%) · lines per 30 days 419.7 → 425.1 (+1.3%) · non-English per 30 days 21.6 → 24.0 (+11.3%) · non-English share 5.14% → 5.65% · non-English customers by channel Online 384 / Physical Store 148 / Book Club 69 / Other 34 / No response 1 · excluding cancelled/returned 14,400 lines, 145,104.43.
- ✅ Model settings confirmed through TOM: `dim_date` marked as the date table, `month_name` sorted by `month_num`, `country_name` = Country, `order_id` not summarised, 5 fact → dimension relationships.
- 🧭 **Report pages generated:** this Power BI version stores the report inside the `.pbix` in the PBIR format (`Report/definition/pages/<page>/visuals/<visual>/visual.json`). `powerbi/tools/build_report_pages.ps1` writes the 3 pages (30 visuals, following `docs/PowerBI_Guide.md` §4) into `Gravity_Marketing.pbix` with Power BI closed. The data model is copied unchanged, and the old `SecurityBindings` part is dropped so Power BI accepts the edited report. Backup: `Gravity_Marketing_before_pages.pbix`.
  - 🐞 "Save as .pbip" saved a normal `.pbix` (the project option wasn't offered). It didn't matter: the `.pbix` already contained the PBIR report definition.
- 🐞 **Maps appeared, then vanished.** The classic Map visual (Bing Maps) needs *Options → Global → Security → "Use Map and Filled Map visuals"*, and the setting only takes effect after a **full restart** of Power BI Desktop. After restarting, both maps render. Azure Maps wasn't available in this version.
- 🔄 **Report polish after the first review of the pages:**
  - friendly field labels (`displayName`: Country, Year, Period…) instead of column names
  - automatic visual subtitles switched off
  - slicers labelled once
  - cards show full values (display units = None: 154,966.34 instead of 154.97K)
  - page subtitles note that 2023-Q4 and 2026-Q4 are partial quarters, so their dips aren't read as real drops
- ✅ **Dashboard checked against SQL:** every card, table and matrix matches the warehouse figures in `docs/PowerBI_Guide.md` §5.
- 📸 `diagrams/pbi_p1_customer_locations.png`, `pbi_p2_non_english_demand.png`, `pbi_p3_channel_campaign.png`: the three pages, unfiltered.
- 📸 **Dashboard in use:**
  - `diagrams/pbi_p1_filtered_2024.png` (Year = 2024): 2,455 orders, 1,298 customers, 108 countries, 51,295.65 sales, which matches the 2024 column of the region × year matrix
  - `diagrams/pbi_p2_filtered_europe.png` (Region = Europe): 230 non-English lines, 5.02% share, with the map zoomed to Europe

---

## Phase 6: Diagrams

### 2026-10-28: ER diagrams

- 🧭 **Generated from the live databases**, not drawn by hand: `diagrams/tools/build_er_diagrams.py` reads every table's columns, types, nullability, primary, unique and foreign keys from SQL Server's catalog views (`sys.tables`, `sys.columns`, `sys.indexes`, `sys.foreign_key_columns`) and draws them as SVG. Microsoft Edge (headless) renders the SVG to high-resolution PNG. So the diagrams always match what's actually built.
- 📸 `diagrams/er_staging.png` / `.svg`: `gravity_staging`, 13 tables grouped as *copied 1:1 from gravity_books* (11) and *loaded from CSV files* (2). No keys by design, with notes on why, and the logical links the transform uses.
- 📸 `diagrams/er_warehouse.png` / `.svg`: `gravity_dw` star schema. `fact_sales` (order-line grain) in the centre, 5 dimensions with crow's-foot one-to-many relationships (surrogate PK → fact FK), unique business keys marked `UQ`, and the `etl`/`dq` control tables shown separately as outside the star.
- 🐞 First render cut off `dim_book` and `dim_location` at the right edge (canvas width taken from the bottom row of control tables).
  **Fix:** width = the widest element.
### 2026-10-28: Report outline

- 🧭 `report/Gravity_DW_Report_Outline.docx` (plus `.pdf`) built from the university template (`Computing - Template - Report.doc`) by `report/tools/build_outline.ps1`, through Word itself, so the template's cover pages, automatic chapter numbering, caption numbering, contents page and lists of tables/figures are kept.
- Content:
  - 8 chapters following the plan's outline (§11), each with a word budget and the brief's requirement as blue guidance notes
  - the key points, facts and figures as bullets
  - 17 numbered figures (12 in the body, 5 in appendices) and 2 draft tables (design decisions; data quality before/after)
  - suggested Harvard references and an appendices plan
- 🐞 Template quirks found while building:
  - its *List Bullet 2* style is a numbered list, so sub-points use *List Bullet* demoted one level
  - *Heading 6* auto-prefixes "Appendix X.", so appendix titles don't repeat it
- 🔄 **Outline layout tidied (22 → 19 pages):**
  - narrow SSIS data-flow screenshots placed **side by side** in borderless two-column tables (book + survey extract flows, dim_book + dim_location flows, fact flow parts 1 + 2), each with its own numbered caption
  - all figures and captions centred, with heights capped so each fits a page with its caption
  - direct paragraph formatting reset after every element; "keep with next" carried over from figures had been dragging whole blocks onto the next page and leaving gaps
  - appendix and section headings kept with the content that follows
  - a small spacer after tables
  - 🐞 Word merges two tables that touch, which pushed pictures into caption paragraphs (and into the List of Figures). **Fix:** a spacer paragraph between consecutive tables.

### 2026-10-28: Narrative report draft

- 🧭 `report/Gravity_DW_Report_Draft.docx` (plus `.pdf`): full narrative draft in the university template, built by `report/tools/build_report.ps1` from the text in `report/tools/report_content.ps1` (the outline stays as notes).
  - Formal prose in all 8 chapters.
  - In-text Harvard citations (Inmon 2005; Kimball and Ross 2013; Batini and Scannapieco 2016; Microsoft 2025).
  - Every figure and table referenced in the text.
  - Appendix C contains the full warehouse data-quality results.
- 📏 **Word count**, measured by Word from the Introduction heading to REFERENCES, captions and tables included, and written onto the cover automatically:
  - first draft: 1,695
  - after tightening the prose and shortening captions: 1,510
  - final: **1,465** (limit 1,500)
- 🐞 Build issues:
  - PowerShell treats the typographic apostrophe ’ as a string delimiter. **Fix:** plain apostrophes in the source, converted to ’ when written to Word.
  - Table 1 split across pages, and then its caption was stranded. **Fix:** rows and caption set to keep with next.

### 2026-11-04: Final assignment – dashboard queries

- 🧭 `sql/40_dashboard_queries.sql`: one query set per dashboard question (Q1–Q5), run against `gravity_dw` on localhost (Windows auth). All ran without errors.
- 🧭 Decisions:
  - No budget/target table exists, so "expected" sales = same month last year and the trailing 12-month mean; the "expected range" = trailing 12-month mean ± 2 standard deviations.
  - "Today" = latest order date in the data (2026-10-27), not GETDATE(). Partial months (Oct 2023 from the 29th, Oct 2026 to the 27th) are scaled to a full month; Oct 2023 is left out of the baseline.
  - There's no list price, and the same book sells at different prices, so a book's cost = its average selling price.
  - Book factors are compared on sales per book so that big categories don't look strong just because they have more titles.
- ✅ Key results:
  - Last 3 months (1 Aug–27 Oct 2026): 1,247 units, 12,567.27 in sales vs 12,283.84 for the same period last year (+2.3%).
  - All 24 months from Nov 2024 to Oct 2026 are within the ±2 SD range. Largest z-score: May 2025 (+1.91).
  - Correlation of units sold with price r = 0.001 and with pages r = 0.002 (9,470 books): no relationship.
  - Asia has 44.7% of sales and Europe 29.9%. China (17.7%) and Indonesia (12.5%) lead. Over the last 12 months China fell 15.8% while the Philippines rose 10.1%.
  - Post-campaign average monthly sales were 4,279.59 vs 4,138.82 before (+3.4%).

### 2026-11-04: Power BI report views and `scripts` folder

- 🧭 `scripts/00_create_powerbi_views.sql` creates 10 views in a new `rpt` schema in `gravity_dw` for Power BI:
  - `v_monthly_sales` (Q1, Q2): one row per month with expected sales, ±2 SD limits, `range_status`, `z_score` and `is_last_3_months` / `is_last_24_months` flags
  - `v_last3_vs_prior_year` (Q1)
  - `v_sales_by_price_band`, `v_book_sales`, `v_price_pages_correlation` (Q3)
  - `v_factor_spread`, `v_customer_factors`, `v_campaign_effect` (Q4); `v_book_sales` also has the book attributes used here
  - `v_country_sales`, `v_country_quarterly` (Q5)
- 🔄 Views can't use TOP/ORDER BY, so they return all rows plus flag columns (`is_last_3_months`, `is_top_10_country`, `is_partial_quarter`) for Power BI filters.
- 🔄 The per-question queries moved from `sql/` into `scripts/`, one file per question (`Q1_…` to `Q5_…`). All five run without errors.
- 🐞 The first test query stalled for over 2 minutes waiting on RESOURCE_SEMAPHORE (a memory grant), with `max server memory` left at its default. Each view then ran on its own in about 1 second, so this was a one-off wait on the server, not a problem with the views. **Fix:** killed the session and re-ran the checks.
- ✅ The views match the original queries (last 3 months 12,567.27 vs 12,283.84; 24/24 months within range; r = 0.001 / 0.002). Total sales reconcile across `v_book_sales`, `v_country_sales` and `v_country_quarterly`: 154,966.34 each, the same as `fact_sales`.

### 2026-11-04: Beginner guides for the question scripts

- 🧭 Added a Markdown guide next to each script (`scripts/Q1_…md` to `scripts/Q5_…md`). Each one covers the question, the approach, each step of the SQL, the SQL ideas used (CTEs, LEFT JOIN, CASE, window functions such as LAG, rolling AVG/STDEV, RANK and SUM() OVER ()), the actual results and how to read them.
- 🐞 While writing the Q4 guide I found that the Q4a page-band CASE put books with no page count (NULL) into "600+", because NULL fails every `<` test and drops through to ELSE. **Fix:** added an 'Unknown' band first, as in `rpt.v_book_sales`. Page band now has 5 levels; the spread is unchanged at 0.56.
