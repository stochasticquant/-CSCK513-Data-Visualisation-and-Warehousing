/*  30_dq_checks.sql
    dq.usp_run_checks - data-quality checks on the STAGING data, run by the
    first Execute SQL Task of the Transform & Load package (and runnable by hand).
    Each check logs the number of failing rows to gravity_dw.dq.check_log, giving
    a repeatable, timestamped record of data quality on every load.

    Priority order (most important first):
      1. Integrity    - orphan foreign keys (would break fact lookups)
      2. Completeness - missing values in columns the business questions need
      3. Validity     - formats and ranges
      4. Uniqueness   - duplicate business keys / names
      5. Consistency  - codes and names that must be conformed
*/
USE gravity_dw;
GO

CREATE OR ALTER PROCEDURE dq.usp_run_checks
AS
BEGIN
    SET NOCOUNT ON;
    DECLARE @run DATETIME2 = SYSDATETIME();

    INSERT INTO dq.check_log (run_time, check_name, dq_dimension, table_name, failed_rows, severity, treatment)
    SELECT @run, check_name, dq_dimension, table_name, failed_rows, severity, treatment
    FROM (
        /* ---------- 1. Integrity ---------- */
        SELECT 'Order line book not in book table' AS check_name, 'Integrity' AS dq_dimension, 'order_line' AS table_name,
               (SELECT COUNT(*) FROM gravity_staging.stg.order_line ol
                 WHERE NOT EXISTS (SELECT 1 FROM gravity_staging.stg.book b WHERE b.book_id = ol.book_id)) AS failed_rows,
               'High' AS severity, 'Map to unknown book (-1)' AS treatment
        UNION ALL
        SELECT 'Order customer not in customer table', 'Integrity', 'cust_order',
               (SELECT COUNT(*) FROM gravity_staging.stg.cust_order o
                 WHERE NOT EXISTS (SELECT 1 FROM gravity_staging.stg.customer c WHERE c.customer_id = o.customer_id)),
               'High', 'Map to unknown customer (-1)'
        UNION ALL
        SELECT 'Order destination not in address table', 'Integrity', 'cust_order',
               (SELECT COUNT(*) FROM gravity_staging.stg.cust_order o
                 WHERE NOT EXISTS (SELECT 1 FROM gravity_staging.stg.address a WHERE a.address_id = o.dest_address_id)),
               'High', 'Map to unknown location (-1)'
        UNION ALL
        SELECT 'Address country missing from region reference', 'Integrity', 'address',
               (SELECT COUNT(*) FROM gravity_staging.stg.address a
                 WHERE NOT EXISTS (SELECT 1 FROM gravity_staging.stg.country_region r WHERE TRY_CAST(r.country_id AS INT) = a.country_id)),
               'High', 'Region = Unknown'
        UNION ALL
        SELECT 'Survey customer ID not a valid customer', 'Integrity', 'survey',
               (SELECT COUNT(*) FROM gravity_staging.stg.survey s
                 WHERE NOT EXISTS (SELECT 1 FROM gravity_staging.stg.customer c WHERE c.customer_id = TRY_CAST(s.customer_id AS INT))),
               'Medium', 'Exclude survey row'

        /* ---------- 2. Completeness ---------- */
        UNION ALL
        SELECT 'Orders with no status history', 'Completeness', 'cust_order',
               (SELECT COUNT(*) FROM gravity_staging.stg.cust_order o
                 WHERE NOT EXISTS (SELECT 1 FROM gravity_staging.stg.order_history h WHERE h.order_id = o.order_id)),
               'Medium', 'latest_order_status = Unknown'
        UNION ALL
        SELECT 'Customers with no survey response', 'Completeness', 'customer',
               (SELECT COUNT(*) FROM gravity_staging.stg.customer c
                 WHERE NOT EXISTS (SELECT 1 FROM gravity_staging.stg.survey s WHERE TRY_CAST(s.customer_id AS INT) = c.customer_id)),
               'Low', 'Survey attributes = No response'
        UNION ALL
        SELECT 'Address missing city or country', 'Completeness', 'address',
               (SELECT COUNT(*) FROM gravity_staging.stg.address WHERE NULLIF(LTRIM(city), '') IS NULL OR country_id IS NULL),
               'High', 'City/country = Unknown'
        UNION ALL
        SELECT 'Order missing order date', 'Completeness', 'cust_order',
               (SELECT COUNT(*) FROM gravity_staging.stg.cust_order WHERE order_date IS NULL),
               'High', 'Date key = -1'

        /* ---------- 3. Validity ---------- */
        UNION ALL
        SELECT 'ISBN13 not 13 characters', 'Validity', 'book',
               (SELECT COUNT(*) FROM gravity_staging.stg.book WHERE isbn13 IS NULL OR LEN(isbn13) <> 13),
               'Low', 'Left-pad with zeros to 13 characters'
        UNION ALL
        SELECT 'Book with 0 pages', 'Validity', 'book',
               (SELECT COUNT(*) FROM gravity_staging.stg.book WHERE num_pages IS NULL OR num_pages <= 0),
               'Low', 'Set num_pages to NULL (unknown)'
        UNION ALL
        SELECT 'Order line price zero, negative or missing', 'Validity', 'order_line',
               (SELECT COUNT(*) FROM gravity_staging.stg.order_line WHERE price IS NULL OR price <= 0),
               'High', 'Reject to dq.fact_rejects'
        UNION ALL
        SELECT 'Order date in the future', 'Validity', 'cust_order',
               (SELECT COUNT(*) FROM gravity_staging.stg.cust_order WHERE order_date > SYSDATETIME()),
               'Medium', 'Investigate'
        UNION ALL
        SELECT 'Status date before order date', 'Validity', 'order_history',
               (SELECT COUNT(*) FROM gravity_staging.stg.order_history h
                  JOIN gravity_staging.stg.cust_order o ON o.order_id = h.order_id
                 WHERE h.status_date < o.order_date),
               'Medium', 'Investigate'
        UNION ALL
        SELECT 'Invalid email format', 'Validity', 'customer',
               (SELECT COUNT(*) FROM gravity_staging.stg.customer WHERE email IS NULL OR email NOT LIKE '%_@_%._%'),
               'Low', 'Email domain = Unknown'
        UNION ALL
        SELECT 'Survey answer not in allowed list', 'Validity', 'survey',
               (SELECT COUNT(*) FROM gravity_staging.stg.survey
                 WHERE LTRIM(RTRIM(heard_about)) NOT IN ('Friend Recommendation','Web Search','Online Advertisement','Physical Store','Other')
                    OR LTRIM(RTRIM(preferred_channel)) NOT IN ('Online','Physical Store','Book Club','Other')),
               'Medium', 'Map to Other'

        /* ---------- 4. Uniqueness ---------- */
        UNION ALL
        SELECT 'Duplicate country names', 'Uniqueness', 'country',
               (SELECT COUNT(*) FROM (SELECT country_name FROM gravity_staging.stg.country
                                      GROUP BY country_name HAVING COUNT(*) > 1) x),
               'Medium', 'Conform to one clean_country_name'
        UNION ALL
        SELECT 'Duplicate customer emails', 'Uniqueness', 'customer',
               (SELECT COUNT(*) FROM (SELECT email FROM gravity_staging.stg.customer
                                      GROUP BY email HAVING COUNT(*) > 1) x),
               'Low', 'Investigate'
        UNION ALL
        SELECT 'Duplicate survey responses per customer', 'Uniqueness', 'survey',
               (SELECT COUNT(*) FROM (SELECT customer_id FROM gravity_staging.stg.survey
                                      GROUP BY customer_id HAVING COUNT(*) > 1) x),
               'Medium', 'Keep first response'
        UNION ALL
        SELECT 'Duplicate book IDs in extract', 'Uniqueness', 'book',
               (SELECT COUNT(*) FROM (SELECT book_id FROM gravity_staging.stg.book
                                      GROUP BY book_id HAVING COUNT(*) > 1) x),
               'High', 'Fail load - extract ran twice?'

        /* ---------- 5. Consistency ---------- */
        UNION ALL
        SELECT 'Order lines shipped to historical/invalid countries', 'Consistency', 'address',
               (SELECT COUNT(*) FROM gravity_staging.stg.order_line ol
                  JOIN gravity_staging.stg.cust_order o ON o.order_id = ol.order_id
                  JOIN gravity_staging.stg.address a ON a.address_id = o.dest_address_id
                  JOIN gravity_staging.stg.country_region r ON TRY_CAST(r.country_id AS INT) = a.country_id
                 WHERE r.country_status <> 'Current'),
               'Medium', 'Map to modern successor where possible, else flag'
        UNION ALL
        SELECT 'Misspelt country names', 'Consistency', 'country',
               (SELECT COUNT(*) FROM gravity_staging.stg.country_region
                 WHERE country_status = 'Current' AND clean_country_name <> country_name),
               'Low', 'Use clean_country_name'
        UNION ALL
        SELECT 'English language code variants', 'Consistency', 'book_language',
               (SELECT COUNT(*) FROM gravity_staging.stg.book_language
                 WHERE language_code IN ('eng','en-US','en-GB','en-CA','enm')),
               'Low', 'Group as language_group = English'
    ) checks;

    -- Return this run's results so they show in SSMS / the SSIS log
    SELECT check_name, dq_dimension, table_name, failed_rows, severity, treatment
    FROM dq.check_log WHERE run_time = @run ORDER BY check_id;
END
GO
