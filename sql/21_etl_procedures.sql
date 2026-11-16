/*  21_etl_procedures.sql
    Stored procedures called from the SSIS Transform & Load package
    through Execute SQL Tasks.

      etl.usp_prepare_full_load  - empties the star schema before a full reload
                                   (keeps the -1 unknown members)
      etl.usp_load_dim_date      - generates dim_date for the configured range and
                                   tags each date as Pre-/Post-campaign
*/
USE gravity_dw;
GO

CREATE OR ALTER PROCEDURE etl.usp_prepare_full_load
AS
BEGIN
    SET NOCOUNT ON;
    -- Fact first (it references every dimension)
    TRUNCATE TABLE dbo.fact_sales;
    TRUNCATE TABLE dq.fact_rejects;

    DELETE FROM dbo.dim_customer        WHERE customer_key <> -1;
    DELETE FROM dbo.dim_book            WHERE book_key     <> -1;
    DELETE FROM dbo.dim_location        WHERE location_key <> -1;
    DELETE FROM dbo.dim_shipping_method WHERE shipping_key <> -1;
    DELETE FROM dbo.dim_date            WHERE date_key     <> -1;

    -- Restart surrogate keys at 1 so every reload gives the same keys.
    -- RESEED behaves differently on a table whose identity has never been used
    -- (the next key is the reseed value itself, not reseed + 1), so reseed to 1 in
    -- that case and to 0 otherwise. Without this, the first load numbered keys from 0.
    DECLARE @t SYSNAME, @seed INT;
    DECLARE c CURSOR LOCAL FAST_FORWARD FOR
        SELECT 'dbo.' + name FROM (VALUES ('dim_customer'), ('dim_book'), ('dim_location'), ('dim_shipping_method')) v(name);
    OPEN c;
    FETCH NEXT FROM c INTO @t;
    WHILE @@FETCH_STATUS = 0
    BEGIN
        SET @seed = CASE WHEN (SELECT last_value FROM sys.identity_columns WHERE object_id = OBJECT_ID(@t)) IS NULL THEN 1 ELSE 0 END;
        DBCC CHECKIDENT (@t, RESEED, @seed) WITH NO_INFOMSGS;
        FETCH NEXT FROM c INTO @t;
    END
    CLOSE c; DEALLOCATE c;
END
GO

CREATE OR ALTER PROCEDURE etl.usp_load_dim_date
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @start    DATE = (SELECT CAST(config_value AS DATE) FROM etl.config WHERE config_key = 'dim_date_start');
    DECLARE @end      DATE = (SELECT CAST(config_value AS DATE) FROM etl.config WHERE config_key = 'dim_date_end');
    DECLARE @campaign DATE = (SELECT CAST(config_value AS DATE) FROM etl.config WHERE config_key = 'campaign_start_date');

    DELETE FROM dbo.dim_date WHERE date_key <> -1;

    WITH n AS (
        SELECT TOP (DATEDIFF(DAY, @start, @end) + 1)
               ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS i
        FROM sys.all_objects a CROSS JOIN sys.all_objects b
    ), d AS (
        SELECT DATEADD(DAY, i, @start) AS dt FROM n
    )
    INSERT INTO dbo.dim_date (date_key, full_date, day_of_month, day_name, month_num, month_name,
                              quarter_num, quarter_label, year_num, year_month, year_quarter, campaign_period)
    SELECT CONVERT(INT, FORMAT(dt, 'yyyyMMdd')),
           dt,
           DAY(dt),
           DATENAME(WEEKDAY, dt),
           MONTH(dt),
           DATENAME(MONTH, dt),
           DATEPART(QUARTER, dt),
           'Q' + CAST(DATEPART(QUARTER, dt) AS CHAR(1)),
           YEAR(dt),
           FORMAT(dt, 'yyyy-MM'),
           CAST(YEAR(dt) AS CHAR(4)) + '-Q' + CAST(DATEPART(QUARTER, dt) AS CHAR(1)),
           CASE WHEN dt < @campaign THEN 'Pre-campaign' ELSE 'Post-campaign' END
    FROM d;
END
GO
