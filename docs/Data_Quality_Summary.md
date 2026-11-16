# Data Quality Summary: Gravity Bookstore Data Warehouse

Material for the report's **data cleansing** section: the checks made, the issues found, how they were treated, and how the process could be automated further. All figures come from the local build (2026-10-27) and are stored in `gravity_dw.dq.check_log`.

## 1. How the checks work

| Stage | Procedure | Runs on | When |
|---|---|---|---|
| **Before** cleansing | `dq.usp_run_checks` (`sql/30_dq_checks.sql`), 23 checks | Raw data in `gravity_staging` | First task of `Transform_Load_DW.dtsx`, every load |
| **After** cleansing | `dq.usp_run_dw_checks` (`sql/31_dw_checks.sql`), 15 checks | Loaded star schema in `gravity_dw` | After the load (run manually; could be added as the package's last task) |
| **Reconciliation** | `SQL Reconcile row counts` task | Staging vs warehouse row counts | Last task of `Transform_Load_DW.dtsx`. **Fails the package** on a mismatch |

Every check writes one row to `dq.check_log` (check name, data-quality dimension, table, failing rows, severity, treatment, run time), so data quality is recorded on every load and can be compared over time.

## 2. Priority order

Checks are run and reported in this order: the most damaging problems first.

1. **Integrity:** orphan foreign keys would make fact rows lose their customer, book or location. Handled by surrogate-key Lookups with an **unknown member (-1)**, so no row is dropped.
2. **Completeness:** missing values in fields the business questions need: country, order date, survey answers.
3. **Validity:** formats and ranges: ISBN length, page counts, prices, dates, email format.
4. **Uniqueness:** duplicate business keys or names, which would double-count in Power BI.
5. **Consistency:** codes and names that must be conformed, such as language variants and country names.

## 3. Before vs after

| # | Issue | Dimension | Before (staging) | Treatment in ETL | After (warehouse) |
|---|---|---|---|---|---|
| 1 | ISBN13 not 13 characters (leading zeros lost, e.g. `8987059752`) | Validity | **25** books | Left-pad to 13 in `DER Cleanse book` | **0** |
| 2 | Books with 0 pages | Validity | **77** books | `num_pages` set to NULL (unknown) | **0** |
| 3 | Order lines with price 0 | Validity | **10** lines | `CSPL Validate price` → `dq.fact_rejects` with a reason | **0** in fact, 10 in rejects |
| 4 | Orders with no status history | Completeness | **3** orders | `latest_order_status = 'Unknown'` | **6** lines flagged (by design) |
| 5 | Customer with no survey response (customer 2000) | Completeness | **1** | `heard_about` / `preferred_channel = 'No response'` | **0** missing |
| 6 | Duplicate country name ("Singapore", IDs 179 and 231) | Uniqueness | **1** | Conformed via `country_region.csv` → `clean_country_name` | **0** |
| 7 | Misspelt country ("Boliva") | Consistency | **1** | Corrected to "Bolivia" via `clean_country_name` | **0** |
| 8 | Historical / invalid countries (Soviet Union, West Germany, "Unknown"…) | Consistency | 24 in the reference list, **0** used by orders | Mapped to a modern successor or flagged in `country_status` | **0** |
| 9 | English language code variants (`eng`, `en-US`, `en-GB`, `en-CA`, `enm`) | Consistency | **5** codes | Grouped as `language_group = 'English'` | **0** ungrouped |
| 10 | Order lines lost between staging and warehouse | Integrity | n/a | Reconcile task fails the package on any difference | **0** (15,400 = 15,390 + 10) |
| 11 | Fact rows on an unknown member | Integrity | 0 orphans in staging | Lookups with Ignore failure → key -1 | **0** (tested: an injected orphan line loaded as -1) |
| 12 | Survey: "why prefer Gravity" question missing from the CSV | Completeness | Whole column | Can't be fixed in ETL: reported as a requirements gap | n/a |
| 13 | Books with no author | Completeness | **1,069** books | Not needed for the business questions: logged only | n/a |

**Checks that were clean in the source** (worth stating, because a clean result is also a result):
- no orphan keys between order lines, orders, customers, addresses and books
- no addresses missing a city or country
- no missing or future order dates
- no status dates before the order date
- no invalid or duplicate emails
- no duplicate survey responses, and no survey answers outside the expected list

**Note on the country rules:** none of the 1,000 addresses are in Singapore, Bolivia or a historical country, so rules 6–8 are in place and verified but changed no address in this data. They protect the warehouse if such addresses appear in later loads.

## 4. Key decisions to discuss

- **Reject vs flag:** zero-price lines are **rejected** to `dq.fact_rejects` (with the reason and time) rather than loaded, so they can't distort average prices. Cancelled and returned orders are **kept and flagged** (`is_cancelled_or_returned`), because they're real sales activity the user may want to include or exclude.
- **Fix vs label:** values with a clear correct form are fixed (ISBN padding, country names). Values that can't be known are labelled explicitly (`NULL` pages, `No response`, `Unknown` status) instead of guessed.
- **Never silently drop a row:** unknown members, the reject table and the reconciliation together mean every source order line is accounted for.

## 5. How the process could be improved

| Improvement | How |
|---|---|
| **Fail fast on severe issues** | Thresholds per check (e.g. any High-severity failure > 0) that make the first task fail the package before loading |
| **Run the warehouse checks automatically** | Add `EXEC dq.usp_run_dw_checks` as the last task of `Transform_Load_DW.dtsx` |
| **Schedule and alert** | Deploy to the SSIS catalog (SSISDB) and run nightly from a SQL Agent job, with email alerts on failure (both are available on the local SQL Server) |
| **Data-quality dashboard** | A Power BI page on `dq.check_log` showing failing rows per check over time |
| **Specialist tools** | SQL Server Data Quality Services (knowledge bases for country and language names), or frameworks like Great Expectations / dbt tests |
| **Fix at source** | Store ISBNs as text with leading zeros, validate prices > 0 and page counts > 0 at order entry, and add the missing survey question |
