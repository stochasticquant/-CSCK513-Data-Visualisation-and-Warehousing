/* Run inside the restored/loaded gravity_dw database.
   Every row must match the "Expected fingerprint" table in README.md. */
SET NOCOUNT ON;
SELECT obj, row_count, checksum_value FROM (
    SELECT 'dbo.dim_book' obj, COUNT_BIG(*) row_count, CHECKSUM_AGG(BINARY_CHECKSUM(*)) checksum_value FROM dbo.dim_book
    UNION ALL SELECT 'dbo.dim_customer', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dbo.dim_customer
    UNION ALL SELECT 'dbo.dim_date', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dbo.dim_date
    UNION ALL SELECT 'dbo.dim_location', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dbo.dim_location
    UNION ALL SELECT 'dbo.dim_shipping_method', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dbo.dim_shipping_method
    UNION ALL SELECT 'dbo.fact_sales', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM dbo.fact_sales
    UNION ALL SELECT 'rpt.v_book_sales', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM rpt.v_book_sales
    UNION ALL SELECT 'rpt.v_campaign_effect', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM rpt.v_campaign_effect
    UNION ALL SELECT 'rpt.v_country_quarterly', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM rpt.v_country_quarterly
    UNION ALL SELECT 'rpt.v_country_sales', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM rpt.v_country_sales
    UNION ALL SELECT 'rpt.v_customer_factors', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM rpt.v_customer_factors
    UNION ALL SELECT 'rpt.v_factor_spread', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM rpt.v_factor_spread
    UNION ALL SELECT 'rpt.v_last3_vs_prior_year', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM rpt.v_last3_vs_prior_year
    UNION ALL SELECT 'rpt.v_monthly_sales', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM rpt.v_monthly_sales
    UNION ALL SELECT 'rpt.v_price_pages_correlation', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM rpt.v_price_pages_correlation
    UNION ALL SELECT 'rpt.v_sales_by_price_band', COUNT_BIG(*), CHECKSUM_AGG(BINARY_CHECKSUM(*)) FROM rpt.v_sales_by_price_band
) x ORDER BY obj;

SELECT COUNT(*) AS fact_rows, SUM(sales_amount) AS total_sales_amount, SUM(quantity) AS total_units,
       MIN(order_date_key) AS first_date_key, MAX(order_date_key) AS last_date_key
FROM dbo.fact_sales;
