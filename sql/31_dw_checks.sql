/*  31_dw_checks.sql
    dq.usp_run_dw_checks - data-quality checks on the loaded WAREHOUSE (after cleansing).
    Companion to dq.usp_run_checks (30_dq_checks.sql), which checks the raw STAGING data.
    Each check repeats a staging issue, or a warehouse rule, and should return 0 failing rows
    once the ETL has done its job. Results go to the same dq.check_log table, with table names
    prefixed 'dw.' so before (staging) and after (warehouse) can be compared.
    Run after Transform_Load_DW.dtsx:  EXEC gravity_dw.dq.usp_run_dw_checks;
*/
USE gravity_dw;
GO

CREATE OR ALTER PROCEDURE dq.usp_run_dw_checks
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run DATETIME2 = SYSDATETIME();

    INSERT INTO dq.check_log (run_time, check_name, dq_dimension, table_name, failed_rows, severity, treatment)
    SELECT @run, check_name, dq_dimension, table_name, failed_rows, severity, treatment
    FROM (
        /* ---------- Integrity ---------- */
        SELECT 'Fact rows on an unknown member (-1)' AS check_name, 'Integrity' AS dq_dimension, 'dw.fact_sales' AS table_name,
               (SELECT COUNT(*) FROM dbo.fact_sales
                 WHERE -1 IN (order_date_key, customer_key, book_key, location_key, shipping_key)) AS failed_rows,
               'High' AS severity, 'Investigate source orphans' AS treatment
        UNION ALL
        SELECT 'Order lines lost between staging and warehouse', 'Integrity', 'dw.fact_sales',
               (SELECT COUNT(*) FROM gravity_staging.stg.order_line) - (SELECT COUNT(*) FROM dbo.fact_sales) - (SELECT COUNT(*) FROM dq.fact_rejects),
               'High', 'Reconcile step fails the package'
        UNION ALL
        SELECT 'Fact location differs from order destination', 'Integrity', 'dw.fact_sales',
               (SELECT COUNT(*) FROM dbo.fact_sales f
                  JOIN dbo.dim_location l ON l.location_key = f.location_key
                  JOIN gravity_staging.stg.cust_order o ON o.order_id = f.order_id
                 WHERE o.dest_address_id <> l.address_id),
               'High', 'Check location lookup'

        /* ---------- Completeness ---------- */
        UNION ALL
        SELECT 'Customers with missing survey attributes', 'Completeness', 'dw.dim_customer',
               (SELECT COUNT(*) FROM dbo.dim_customer WHERE customer_key <> -1
                   AND (NULLIF(heard_about, '') IS NULL OR NULLIF(preferred_channel, '') IS NULL)),
               'Low', 'Labelled No response'
        UNION ALL
        SELECT 'Locations with missing country or region', 'Completeness', 'dw.dim_location',
               (SELECT COUNT(*) FROM dbo.dim_location WHERE location_key <> -1
                   AND (country_name IN ('', 'Unknown') OR region IN ('', 'Unknown'))),
               'High', 'Add country to country_region.csv'
        UNION ALL
        SELECT 'Fact lines with unknown order status', 'Completeness', 'dw.fact_sales',
               (SELECT COUNT(*) FROM dbo.fact_sales WHERE latest_order_status = 'Unknown'),
               'Low', 'Expected: orders placed in the last 12 hours have no history yet'

        /* ---------- Validity ---------- */
        UNION ALL
        SELECT 'ISBN13 not 13 characters', 'Validity', 'dw.dim_book',
               (SELECT COUNT(*) FROM dbo.dim_book WHERE book_key <> -1 AND (isbn13 IS NULL OR LEN(isbn13) <> 13)),
               'Low', 'Left-padded in DER Cleanse book'
        UNION ALL
        SELECT 'Book with 0 pages', 'Validity', 'dw.dim_book',
               (SELECT COUNT(*) FROM dbo.dim_book WHERE num_pages <= 0),
               'Low', 'Set to NULL in DER Cleanse book'
        UNION ALL
        SELECT 'Fact line price zero, negative or missing', 'Validity', 'dw.fact_sales',
               (SELECT COUNT(*) FROM dbo.fact_sales WHERE sales_amount IS NULL OR sales_amount <= 0),
               'High', 'Rejected by CSPL Validate price'
        UNION ALL
        SELECT 'Survey answer not in allowed list', 'Validity', 'dw.dim_customer',
               (SELECT COUNT(*) FROM dbo.dim_customer WHERE customer_key <> -1
                   AND (heard_about NOT IN ('Friend Recommendation','Web Search','Online Advertisement','Physical Store','Other','No response')
                     OR preferred_channel NOT IN ('Online','Physical Store','Book Club','Other','No response'))),
               'Medium', 'Map to Other'

        /* ---------- Uniqueness ---------- */
        UNION ALL
        SELECT 'Duplicate business keys in dimensions', 'Uniqueness', 'dw.dim_*',
               (SELECT COUNT(*) FROM (SELECT book_id FROM dbo.dim_book GROUP BY book_id HAVING COUNT(*) > 1) x)
             + (SELECT COUNT(*) FROM (SELECT customer_id FROM dbo.dim_customer GROUP BY customer_id HAVING COUNT(*) > 1) x)
             + (SELECT COUNT(*) FROM (SELECT address_id FROM dbo.dim_location GROUP BY address_id HAVING COUNT(*) > 1) x),
               'High', 'Enforced by unique constraints'
        UNION ALL
        SELECT 'Country name used by more than one source country (not conformed)', 'Uniqueness', 'dw.dim_location',
               (SELECT COUNT(*) FROM (SELECT l.country_name FROM dbo.dim_location l
                                        JOIN gravity_staging.stg.country_region r ON TRY_CAST(r.country_id AS INT) = l.country_id
                                       WHERE l.location_key <> -1 AND l.country_name <> r.clean_country_name
                                       GROUP BY l.country_name) x),
               'Medium', 'Names come from clean_country_name'

        /* ---------- Consistency ---------- */
        UNION ALL
        SELECT 'English language code not grouped as English', 'Consistency', 'dw.dim_book',
               (SELECT COUNT(*) FROM dbo.dim_book
                 WHERE language_code IN ('eng','en-US','en-GB','en-CA','enm') AND language_group <> 'English'),
               'Low', 'language_group in DER Cleanse book'
        UNION ALL
        SELECT 'Misspelt or historical country name in warehouse', 'Consistency', 'dw.dim_location',
               (SELECT COUNT(*) FROM dbo.dim_location l
                  JOIN gravity_staging.stg.country_region r ON TRY_CAST(r.country_id AS INT) = l.country_id
                 WHERE l.country_name <> r.clean_country_name),
               'Low', 'Use clean_country_name'
        UNION ALL
        SELECT 'Sales total differs from source (valid lines)', 'Consistency', 'dw.fact_sales',
               CASE WHEN (SELECT SUM(sales_amount) FROM dbo.fact_sales)
                       = (SELECT SUM(price) FROM gravity_staging.stg.order_line WHERE price > 0) THEN 0 ELSE 1 END,
               'High', 'Investigate'
    ) checks;

    SELECT check_name, dq_dimension, table_name, failed_rows, severity, treatment
    FROM dq.check_log WHERE run_time = @run ORDER BY check_id;
END
GO
