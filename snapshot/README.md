# gravity_dw – agreed snapshot (18 Nov 2026)

This is the agreed, populated copy of **gravity_dw**, including the `rpt` reporting views.
Use it for the dashboard, documentation and video so all the figures match.
Don't rebuild it from the source scripts: they generate random data, so the numbers would change.

## SQL Server version

| | |
|---|---|
| Product | Microsoft SQL Server 2025 (RTM-GDR, KB5128492) |
| Version | 17.0.1145.4 (x64) |
| Edition | Standard Developer Edition (64-bit) |
| Database compatibility level | 170 |
| Collation | Latin1_General_CI_AS |

## What's included

| File | What it is | When to use it |
|---|---|---|
| `gravity_dw_snapshot_20261118.bak` | Full, compressed, copy-only backup (checksum verified) | Use this if you have **SQL Server 2025**. A .bak file can't be restored on an older version. |
| `gravity_dw_schema_and_data.sql` | Portable T-SQL script: schemas, tables, keys, indexes, all data, then the `rpt` views and the `etl`/`dq` procedures | Use this on **any version** (2016 or later; tested on 2025) or Azure SQL |
| `verify_snapshot.sql` | Fingerprint check (row counts and checksums for every table and `rpt` view) | Run it after loading the database |
| `rpt_view_csv\*.csv` | Output of each of the 10 `rpt` views, as CSV | Quick reference, or a Power BI fallback |

## Option A – restore the .bak (SQL Server 2025 only)

Copy the .bak into SQL Server's backup folder (or any folder the SQL service account can read), then run:

```sql
RESTORE FILELISTONLY FROM DISK = N'C:\path\gravity_dw_snapshot_20261118.bak';  -- shows logical file names
RESTORE DATABASE gravity_dw
  FROM DISK = N'C:\path\gravity_dw_snapshot_20261118.bak'
  WITH MOVE N'gravity_dw'     TO N'<data folder>\gravity_dw.mdf',
       MOVE N'gravity_dw_log' TO N'<log folder>\gravity_dw_log.ldf',
       RECOVERY, STATS = 10;
```

In SSMS you can instead right-click **Databases**, choose **Restore Database…**, pick **Device** and select the .bak file.

## Option B – run the script (any version)

1. Create an **empty** database named `gravity_dw`.
2. Run `gravity_dw_schema_and_data.sql` inside it. It takes about 30 seconds.
   * In SSMS, open the file, select the `gravity_dw` database and press Execute.
   * From the command line, run:
     `sqlcmd -S <server> -E -d gravity_dw -f 65001 -i gravity_dw_schema_and_data.sql`
3. The script finishes by printing `gravity_dw snapshot load complete.`

If your server runs a version older than 2025, set the compatibility level your version supports (for example, 160 for 2022 or 150 for 2019). The script doesn't set one, so the new database keeps your server's default.

## Checking the load

Run `verify_snapshot.sql` in the loaded database. Every row must match the table below:

| Object | Rows | Checksum |
|---|---:|---:|
| dbo.dim_book | 11128 | -2110138952 |
| dbo.dim_customer | 2001 | 871675311 |
| dbo.dim_date | 1462 | 783343486 |
| dbo.dim_location | 1001 | -868387295 |
| dbo.dim_shipping_method | 5 | 1343767319 |
| dbo.fact_sales | 15390 | -1885584237 |
| rpt.v_book_sales | 11127 | -1429456250 |
| rpt.v_campaign_effect | 2 | 149230537 |
| rpt.v_country_quarterly | 1015 | 809933480 |
| rpt.v_country_sales | 109 | -41371377 |
| rpt.v_customer_factors | 15 | -2092089517 |
| rpt.v_factor_spread | 5 | -2134788868 |
| rpt.v_last3_vs_prior_year | 2 | -1873410312 |
| rpt.v_monthly_sales | 37 | 257020903 |
| rpt.v_price_pages_correlation | 1 | 949094841 |
| rpt.v_sales_by_price_band | 4 | -2119381897 |

Headline figures from `dbo.fact_sales`:

* 15,390 order lines
* Total sales amount: **154,966.34**
* Total units: 15,390
* Orders run from 29 Oct 2023 to 27 Oct 2026

The supporting tables also carry over: `dq.check_log` (176 rows), `dq.fact_rejects` (10), `etl.audit` (154) and `etl.config` (3).

## Notes

* None of the `rpt` views depends on the current date. "Last 3 months" in `rpt.v_last3_vs_prior_year` means 1 Aug to 27 Oct 2026, based on the data itself, so the figures stay fixed whenever you run the views.
* The `etl` and `dq` procedures read from `gravity_staging.stg.*`. That database isn't part of this package. You only need it to re-run the ETL, which you shouldn't do, because it would replace the agreed figures.
* The script was tested by loading it into a fresh database on the source server. Every table and view fingerprint matched the original exactly.

## File hashes (SHA-256)

```
6C29D1A27C5977514F3FAD3E0C1FE5DCA72D69DAEDB44D67D7C5199A4260B5C2  gravity_dw_snapshot_20261118.bak
63EEB7BB95CFAEC9B95C19BEC3A49A797518DC4EAD02769F05CABF1BA7B82BE4  gravity_dw_schema_and_data.sql
```
