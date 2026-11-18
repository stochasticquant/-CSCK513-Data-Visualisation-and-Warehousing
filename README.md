# CSCK513 Data Visualisation and Warehousing: Gravity Books

Group project for CSCK513. It takes the Gravity Books data warehouse built for the mid-module assignment and uses it to answer five business questions with a Power BI dashboard.

## Business questions

| # | Question | Short answer |
|---|---|---|
| Q1 | What are our current sales for the last three months and how does this match expectations? | 12,567.27 for 1 Aug – 27 Oct 2026, 2.3% above the same period last year and within about ±9% of expected each month |
| Q2 | Have sales been outside of the expected range any time in the past two years? | No. All 24 months sit inside the 12-month mean ± 2 SD band |
| Q3 | How do the cost of the book and the number of pages affect the number of books sold? | They don't: r = 0.001 (price) and 0.002 (pages) |
| Q4 | What are the factors that affect the total sales of a book? | No book attribute stands out (about 14 per book); totals follow the number of titles. Campaign period +3.4% |
| Q5 | What geographical areas have the most sales and what are the trends for different countries? | Asia 44.7%, Europe 29.9%. China, the largest market, is down 15.8%; the Philippines, Poland and Indonesia are growing |

Method, assumptions and full results for each question are in `scripts/Q*.md` and in [`handoverNotes.md`](handoverNotes.md).

## Architecture

```
gravity_books (OLTP) ─┐
bookstore survey.csv ─┼─ SSIS Extract ─▶ gravity_staging ─ SSIS Transform/Load ─▶ gravity_dw (star schema) ─▶ rpt views ─▶ Power BI
country_region.csv  ──┘
```

`gravity_dw` is a star schema with one fact table, `fact_sales` (one row per order line), and five dimensions: `dim_date`, `dim_customer`, `dim_book`, `dim_location` and `dim_shipping_method`.

## Repository layout

| Folder / file | Contents |
|---|---|
| `gravity_sqlserver/` | Provided scripts that create and populate the source `gravity_books` database |
| `sql/` | Staging and warehouse DDL, ETL procedures, data-quality checks |
| `ssis/` | `GravityETL` Visual Studio project with the extract and transform/load packages |
| `scripts/` | Q1–Q5 analysis SQL with explanations, and the Power BI reporting views |
| `powerbi/` | Power BI file and helper scripts |
| `diagrams/` | ER diagrams, SSIS flow and Power BI screenshots |
| `docs/` | Data quality summary, Power BI guide |
| `snapshot/` | Agreed populated `gravity_dw` snapshot: SQL Server 2025 backup, portable schema-and-data script, `rpt` view CSVs, verification query |
| `reference/`, `bookstore survey.csv` | Country-to-region map and survey data |
| `DW_Project_Plan.md` | Design plan and decisions |
| `handoverNotes.md` | Full solution handover: model, assumptions, answers, file catalog |
| `handoverNotes.html` | The same handover as a self-contained web page |

Start with [`handoverNotes.md`](handoverNotes.md), which GitHub displays. `handoverNotes.html` has the same content as a single page to download and open in a browser.

## Restoring the agreed database

The [`snapshot/`](snapshot/) folder holds the agreed, populated `gravity_dw`, including the `rpt` views. It was taken from **SQL Server 2025 (17.0.1145.4)**. Restore it rather than rebuilding, so the dashboard, documentation and video all show the same figures.

A `.bak` backup can only be restored on the version it came from or a newer one. On older versions, use the script instead.

| Your SQL Server | Method | Compatibility level |
|---|---|---|
| SQL Server 2025 (17.x), any edition, incl. Express/Developer | **A – restore `gravity_dw_snapshot_20261118.bak`** (script B also works) | 170 |
| SQL Server 2022 (16.x) | **B – run `gravity_dw_schema_and_data.sql`** | 160 |
| SQL Server 2019 (15.x) | **B** | 150 |
| SQL Server 2017 (14.x) | **B** | 140 |
| SQL Server 2016 (13.x) | **B** | 130 |
| SQL Server 2014 or older | Not supported (out of Microsoft support, untested). Upgrade, or use Docker (C). | – |
| Azure SQL Database / Managed Instance | **B** | default |
| macOS, Linux, or no SQL Server installed | **C – SQL Server 2025 in Docker**, then A | 170 |

To find your version, run `SELECT @@VERSION;`.

### A. SQL Server 2025: restore the backup

1. Copy `gravity_dw_snapshot_20261118.bak` to a folder the SQL Server service account can read, such as the instance's `Backup` folder (`C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\`). The service usually can't read your user folders, such as Documents or Downloads.
2. Restore it. In SSMS, right-click **Databases**, choose **Restore Database…**, pick **Device**, select the `.bak` and click **OK**. Or run:

   ```sql
   RESTORE DATABASE gravity_dw
     FROM DISK = N'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\Backup\gravity_dw_snapshot_20261118.bak'
     WITH MOVE N'gravity_dw'     TO N'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\DATA\gravity_dw.mdf',
          MOVE N'gravity_dw_log' TO N'C:\Program Files\Microsoft SQL Server\MSSQL17.MSSQLSERVER\MSSQL\DATA\gravity_dw_log.ldf',
          RECOVERY, STATS = 10;
   ```

   For a named instance, change the `MSSQL17.MSSQLSERVER` part of the paths. If a `gravity_dw` database already exists, add `REPLACE` to the `WITH` list; this overwrites it.

### B. SQL Server 2016–2022 or Azure SQL: run the script

1. Create an empty database, and set the compatibility level for your version from the table above:

   ```sql
   CREATE DATABASE gravity_dw COLLATE Latin1_General_CI_AS;
   ALTER DATABASE gravity_dw SET COMPATIBILITY_LEVEL = 160;   -- 2022; use 150/140/130 for 2019/2017/2016
   ```

   On Azure SQL Database, create the database in the portal (or with `CREATE DATABASE`) while connected to `master`, and skip the `ALTER`.
2. Run `snapshot/gravity_dw_schema_and_data.sql` **inside** `gravity_dw`. It takes about 30 seconds.
   * **SSMS:** open the file, select `gravity_dw` in the database drop-down, then press **Execute**.
   * **Command line:** `sqlcmd -S <server> -E -d gravity_dw -f 65001 -i snapshot\gravity_dw_schema_and_data.sql`. On Azure, use `-U <user> -P <password>` instead of `-E`. `-f 65001` makes sure the file is read as UTF-8.
3. The script finishes with `gravity_dw snapshot load complete.`

On **Azure SQL Database**, the two `dq.*` procedures may fail to create, because they refer to the separate `gravity_staging` database and Azure SQL Database doesn't allow that. You can ignore those errors. The tables, data and `rpt` views still load, and the procedures aren't needed for the dashboard.

### C. No Windows SQL Server: run SQL Server 2025 in Docker

```bash
docker run -e "ACCEPT_EULA=Y" -e "MSSQL_SA_PASSWORD=<StrongPassw0rd!>" -p 1433:1433 --name gravity -d mcr.microsoft.com/mssql/server:2025-latest
docker cp snapshot/gravity_dw_snapshot_20261118.bak gravity:/var/opt/mssql/data/
```

Then connect to `localhost,1433` as `sa` (from SSMS, Azure Data Studio or VS Code) and restore:

```sql
RESTORE DATABASE gravity_dw FROM DISK = N'/var/opt/mssql/data/gravity_dw_snapshot_20261118.bak'
  WITH MOVE N'gravity_dw'     TO N'/var/opt/mssql/data/gravity_dw.mdf',
       MOVE N'gravity_dw_log' TO N'/var/opt/mssql/data/gravity_dw_log.ldf', RECOVERY;
```

On Apple Silicon Macs, add `--platform linux/amd64` to `docker run`, and enable Rosetta in Docker Desktop settings.

### Check the restore (every method)

Run `snapshot/verify_snapshot.sql` in `gravity_dw`. Each row count and checksum must match the table in [`snapshot/README.md`](snapshot/README.md). The headline figures are 15,390 rows in `dbo.fact_sales` and total sales of 154,966.34.

Then point Power BI at the restored server (**Transform data**, then **Data source settings**) and refresh.

> Testing: the backup was restored and verified on SQL Server 2025. The script was loaded into fresh databases at compatibility levels 170 and 130 (SQL Server 2016 behaviour), and both matched the original exactly. It hasn't been run on actual 2016–2022 servers or on Azure.

## Rebuilding

Requires SQL Server (Windows authentication), Visual Studio with the SSIS extension, and Power BI Desktop.

1. Build the source database: run `sql/00_build_gravity_books.ps1`.
2. Create staging and the warehouse: run `sql/10_create_staging.sql`, `20_create_dw.sql`, `21_etl_procedures.sql`, `30_dq_checks.sql` and `31_dw_checks.sql`.
3. Open `ssis/GravityETL/GravityETL.sln` and run `Extract_To_Staging.dtsx`, then `Transform_Load_DW.dtsx`.
4. Create the reporting views: run `scripts/00_create_powerbi_views.sql`.
5. Open `powerbi/Gravity_Marketing.pbix` and refresh.

The order data in `gravity_books` is randomly generated by source scripts 10–13, so a rebuild changes every figure above.

To work with the agreed figures, don't rebuild. Restore the snapshot instead (see [Restoring the agreed database](#restoring-the-agreed-database)).
