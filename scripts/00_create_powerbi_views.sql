/* =====================================================================
   00_create_powerbi_views.sql
   Report views for the Power BI dashboard (final assignment). They wrap
   the queries in the Q1-Q5 scripts in this folder. Views can't use TOP/ORDER BY,
   so each one returns the full data plus flag columns to filter on
   in Power BI.

   Same rules as the Q1-Q5 scripts in this folder:
   - "Today" = latest order date in the data, not GETDATE().
   - Partial months are scaled to a full month; the partial first month
     is left out of the expected-range baseline.
   - Expected range = trailing 12-month mean +/- 2 standard deviations.
   - Book cost = average selling price (no list price in the source).

   Views (schema rpt):
     v_monthly_sales          Q1, Q2  one row per month, with expected range
     v_last3_vs_prior_year    Q1      last 3 months vs same period last year
     v_sales_by_price_band    Q3      units sold per price band
     v_book_sales             Q3, Q4  one row per book (incl. unsold)
     v_price_pages_correlation Q3     Pearson r of units vs price / pages
     v_factor_spread          Q4      how strongly each book factor matters
     v_customer_factors       Q4      heard-about, channel, shipping method
     v_campaign_effect        Q4      before vs after the campaign start
     v_country_sales          Q5      country totals, rank, 12-month trend
     v_country_quarterly      Q5      sales per country per quarter
   ===================================================================== */
USE gravity_dw;
GO
IF SCHEMA_ID('rpt') IS NULL EXEC('CREATE SCHEMA rpt');
GO

/* ---------------- Q1 + Q2: monthly sales with expected range -------- */
CREATE OR ALTER VIEW rpt.v_monthly_sales AS
WITH bounds AS (
    SELECT MIN(d.full_date) AS first_date, MAX(d.full_date) AS last_date
    FROM dbo.fact_sales f JOIN dbo.dim_date d ON d.date_key = f.order_date_key
),
monthly AS (
    SELECT DATEFROMPARTS(d.year_num, d.month_num, 1) AS month_start,
           d.year_num, d.month_num, d.month_name, d.year_month,
           SUM(f.sales_amount) AS gross_sales,
           SUM(CASE WHEN f.is_cancelled_or_returned = 0 THEN f.sales_amount ELSE 0 END) AS net_sales,
           COUNT(*) AS units,
           COUNT(DISTINCT f.order_id) AS orders
    FROM dbo.fact_sales f JOIN dbo.dim_date d ON d.date_key = f.order_date_key
    GROUP BY d.year_num, d.month_num, d.month_name, d.year_month
),
scaled AS (
    SELECT m.*, b.first_date, b.last_date,
           DATEDIFF(DAY,
               CASE WHEN b.first_date > m.month_start THEN b.first_date ELSE m.month_start END,
               CASE WHEN b.last_date < EOMONTH(m.month_start) THEN b.last_date ELSE EOMONTH(m.month_start) END) + 1
               AS days_with_data,
           DAY(EOMONTH(m.month_start)) AS days_in_month
    FROM monthly m CROSS JOIN bounds b
),
full_month AS (
    SELECT s.*,
           CAST(s.gross_sales * s.days_in_month * 1.0 / s.days_with_data AS decimal(12,2)) AS full_month_sales,
           CASE WHEN s.days_with_data < s.days_in_month THEN 1 ELSE 0 END AS is_partial_month
    FROM scaled s
),
baseline AS (
    SELECT f.*,
           -- partial first month is not a fair baseline, so it is left out
           CASE WHEN f.month_start < f.first_date THEN NULL ELSE f.full_month_sales END AS baseline_sales
    FROM full_month f
),
w AS (
    SELECT b.*,
           LAG(b.full_month_sales, 12) OVER (ORDER BY b.month_start) AS same_month_last_year,
           AVG(b.baseline_sales)   OVER (ORDER BY b.month_start ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING) AS mean_12m,
           STDEV(b.baseline_sales) OVER (ORDER BY b.month_start ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING) AS sd_12m,
           COUNT(b.baseline_sales) OVER (ORDER BY b.month_start ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING) AS months_in_baseline,
           DATEDIFF(MONTH, b.month_start, b.last_date) AS months_ago
    FROM baseline b
)
SELECT month_start, year_num, month_num, month_name, year_month,
       units, orders, gross_sales, net_sales,
       days_with_data, days_in_month, is_partial_month,
       full_month_sales,
       same_month_last_year,
       CAST(100.0 * (full_month_sales - same_month_last_year) / NULLIF(same_month_last_year, 0) AS decimal(6,1)) AS pct_vs_last_year,
       CAST(mean_12m AS decimal(12,2))                   AS expected_sales,
       CAST(mean_12m - 2 * sd_12m AS decimal(12,2))      AS lower_limit,
       CAST(mean_12m + 2 * sd_12m AS decimal(12,2))      AS upper_limit,
       CAST(100.0 * (full_month_sales - mean_12m) / NULLIF(mean_12m, 0) AS decimal(6,1)) AS pct_vs_expected,
       CAST((full_month_sales - mean_12m) / NULLIF(sd_12m, 0) AS decimal(5,2))           AS z_score,
       CASE WHEN months_in_baseline < 12 THEN 'Not enough history'
            WHEN full_month_sales > mean_12m + 2 * sd_12m THEN 'Above range'
            WHEN full_month_sales < mean_12m - 2 * sd_12m THEN 'Below range'
            ELSE 'Within range' END                      AS range_status,
       months_in_baseline,
       months_ago,
       CASE WHEN months_ago < 3  THEN 1 ELSE 0 END       AS is_last_3_months,
       CASE WHEN months_ago < 24 THEN 1 ELSE 0 END       AS is_last_24_months
FROM w;
GO

/* ---------------- Q1: last 3 months vs same period last year -------- */
CREATE OR ALTER VIEW rpt.v_last3_vs_prior_year AS
WITH bounds AS (
    SELECT MAX(d.full_date) AS last_date
    FROM dbo.fact_sales f JOIN dbo.dim_date d ON d.date_key = f.order_date_key
),
p AS (
    SELECT DATEADD(MONTH, -2, DATEFROMPARTS(YEAR(last_date), MONTH(last_date), 1)) AS cur_start,
           last_date AS cur_end
    FROM bounds
),
periods AS (
    SELECT 1 AS sort_order, 'Last 3 months' AS period, cur_start AS from_date, cur_end AS to_date FROM p
    UNION ALL
    SELECT 2, 'Same period last year', DATEADD(YEAR, -1, cur_start), DATEADD(YEAR, -1, cur_end) FROM p
)
SELECT pr.sort_order, pr.period, pr.from_date, pr.to_date,
       COUNT(f.sales_key)                 AS units,
       COUNT(DISTINCT f.order_id)         AS orders,
       ISNULL(SUM(f.sales_amount), 0)     AS gross_sales,
       ISNULL(SUM(CASE WHEN f.is_cancelled_or_returned = 0 THEN f.sales_amount END), 0) AS net_sales
FROM periods pr
LEFT JOIN dbo.dim_date d    ON d.full_date BETWEEN pr.from_date AND pr.to_date
LEFT JOIN dbo.fact_sales f  ON f.order_date_key = d.date_key
GROUP BY pr.sort_order, pr.period, pr.from_date, pr.to_date;
GO

/* ---------------- Q3: units sold per price band --------------------- */
CREATE OR ALTER VIEW rpt.v_sales_by_price_band AS
WITH s AS (
    SELECT f.sales_amount,
           CASE WHEN f.sales_amount <  5 THEN 1 WHEN f.sales_amount < 10 THEN 2
                WHEN f.sales_amount < 15 THEN 3 ELSE 4 END AS band_order
    FROM dbo.fact_sales f
)
SELECT band_order,
       CASE band_order WHEN 1 THEN 'Under 5' WHEN 2 THEN '5 - 9.99'
                       WHEN 3 THEN '10 - 14.99' ELSE '15 and over' END AS price_band,
       COUNT(*)                                AS units_sold,
       SUM(sales_amount)                       AS sales,
       CAST(AVG(sales_amount) AS decimal(6,2)) AS avg_price
FROM s
GROUP BY band_order;
GO

/* ---------------- Q3 + Q4: one row per book ------------------------- */
CREATE OR ALTER VIEW rpt.v_book_sales AS
WITH b AS (
    SELECT bk.book_key, bk.book_id, bk.title, bk.num_pages, bk.publication_year,
           bk.publisher_name, bk.language_name, bk.language_group,
           COUNT(f.sales_key)             AS units_sold,
           ISNULL(SUM(f.sales_amount), 0) AS sales,
           CAST(AVG(f.sales_amount) AS decimal(6,2)) AS avg_price
    FROM dbo.dim_book bk
    LEFT JOIN dbo.fact_sales f ON f.book_key = bk.book_key
    WHERE bk.book_key > 0
    GROUP BY bk.book_key, bk.book_id, bk.title, bk.num_pages, bk.publication_year,
             bk.publisher_name, bk.language_name, bk.language_group
)
SELECT b.*,
       CASE WHEN units_sold = 0 THEN 0 ELSE 1 END AS has_sold,
       CASE WHEN num_pages IS NULL OR num_pages = 0 THEN 0
            WHEN num_pages < 200 THEN 1 WHEN num_pages < 400 THEN 2
            WHEN num_pages < 600 THEN 3 WHEN num_pages < 800 THEN 4 ELSE 5 END AS page_band_order,
       CASE WHEN num_pages IS NULL OR num_pages = 0 THEN 'Unknown'
            WHEN num_pages < 200 THEN 'Under 200' WHEN num_pages < 400 THEN '200 - 399'
            WHEN num_pages < 600 THEN '400 - 599' WHEN num_pages < 800 THEN '600 - 799'
            ELSE '800 and over' END AS page_band,
       CASE WHEN avg_price IS NULL THEN 'Not sold'
            WHEN avg_price <  5 THEN 'Under 5' WHEN avg_price < 10 THEN '5 - 9.99'
            WHEN avg_price < 15 THEN '10 - 14.99' ELSE '15 and over' END AS avg_price_band,
       CAST(publication_year / 10 * 10 AS varchar(4)) + 's' AS publication_decade
FROM b;
GO

/* ---------------- Q3: correlation of units with price and pages ----- */
CREATE OR ALTER VIEW rpt.v_price_pages_correlation AS
WITH x AS (
    SELECT CAST(units_sold AS float) AS units,
           CAST(avg_price  AS float) AS price,
           CAST(num_pages  AS float) AS pages
    FROM rpt.v_book_sales
    WHERE units_sold > 0 AND num_pages > 0
)
SELECT COUNT(*) AS books,
       CAST((AVG(units*price) - AVG(units)*AVG(price)) / (STDEVP(units)*STDEVP(price)) AS decimal(5,3)) AS r_units_vs_price,
       CAST((AVG(units*pages) - AVG(units)*AVG(pages)) / (STDEVP(units)*STDEVP(pages)) AS decimal(5,3)) AS r_units_vs_pages,
       CAST((AVG(price*pages) - AVG(price)*AVG(pages)) / (STDEVP(price)*STDEVP(pages)) AS decimal(5,3)) AS r_price_vs_pages
FROM x;
GO

/* ---------------- Q4: how strongly each book factor matters --------- */
CREATE OR ALTER VIEW rpt.v_factor_spread AS
WITH levels AS (
    SELECT 'Language group' AS factor, language_group AS level_name, sales FROM rpt.v_book_sales
    UNION ALL SELECT 'Language', language_name, sales FROM rpt.v_book_sales
    UNION ALL SELECT 'Publication decade', publication_decade, sales FROM rpt.v_book_sales
    UNION ALL SELECT 'Page band', page_band, sales FROM rpt.v_book_sales
    UNION ALL SELECT 'Publisher', publisher_name, sales FROM rpt.v_book_sales
),
per_level AS (
    SELECT factor, level_name, COUNT(*) AS books, AVG(sales) AS avg_sales_per_book
    FROM levels
    GROUP BY factor, level_name
    HAVING COUNT(*) >= 30          -- ignore tiny groups, they are just noise
)
SELECT factor,
       COUNT(*)                                      AS levels_compared,
       CAST(MIN(avg_sales_per_book) AS decimal(8,2)) AS lowest_avg_sales_per_book,
       CAST(MAX(avg_sales_per_book) AS decimal(8,2)) AS highest_avg_sales_per_book,
       CAST(MAX(avg_sales_per_book) - MIN(avg_sales_per_book) AS decimal(8,2)) AS spread
FROM per_level
GROUP BY factor;
GO

/* ---------------- Q4: customer-side factors ------------------------- */
CREATE OR ALTER VIEW rpt.v_customer_factors AS
SELECT 'Heard about' AS factor, c.heard_about AS level_name,
       COUNT(DISTINCT c.customer_key) AS customers, COUNT(*) AS units,
       SUM(f.sales_amount) AS sales,
       CAST(SUM(f.sales_amount) / COUNT(DISTINCT c.customer_key) AS decimal(8,2)) AS sales_per_customer
FROM dbo.fact_sales f JOIN dbo.dim_customer c ON c.customer_key = f.customer_key
GROUP BY c.heard_about
UNION ALL
SELECT 'Preferred channel', c.preferred_channel,
       COUNT(DISTINCT c.customer_key), COUNT(*), SUM(f.sales_amount),
       CAST(SUM(f.sales_amount) / COUNT(DISTINCT c.customer_key) AS decimal(8,2))
FROM dbo.fact_sales f JOIN dbo.dim_customer c ON c.customer_key = f.customer_key
GROUP BY c.preferred_channel
UNION ALL
SELECT 'Shipping method', s.method_name,
       COUNT(DISTINCT f.customer_key), COUNT(*), SUM(f.sales_amount),
       CAST(SUM(f.sales_amount) / COUNT(DISTINCT f.customer_key) AS decimal(8,2))
FROM dbo.fact_sales f JOIN dbo.dim_shipping_method s ON s.shipping_key = f.shipping_key
GROUP BY s.method_name;
GO

/* ---------------- Q4: campaign effect ------------------------------- */
CREATE OR ALTER VIEW rpt.v_campaign_effect AS
SELECT d.campaign_period,
       COUNT(DISTINCT d.year_month) AS months,
       COUNT(*)                     AS units,
       SUM(f.sales_amount)          AS sales,
       CAST(SUM(f.sales_amount) / COUNT(DISTINCT d.year_month) AS decimal(10,2)) AS avg_monthly_sales
FROM dbo.fact_sales f JOIN dbo.dim_date d ON d.date_key = f.order_date_key
GROUP BY d.campaign_period;
GO

/* ---------------- Q5: country totals, rank and 12-month trend ------- */
CREATE OR ALTER VIEW rpt.v_country_sales AS
WITH bounds AS (
    SELECT MAX(d.full_date) AS last_date
    FROM dbo.fact_sales f JOIN dbo.dim_date d ON d.date_key = f.order_date_key
),
c AS (
    SELECT l.country_name, l.region,
           COUNT(DISTINCT f.customer_key) AS customers,
           COUNT(*)                       AS units,
           SUM(f.sales_amount)            AS sales,
           SUM(CASE WHEN d.full_date > DATEADD(YEAR, -1, b.last_date) THEN f.sales_amount ELSE 0 END) AS last_12m_sales,
           SUM(CASE WHEN d.full_date > DATEADD(YEAR, -2, b.last_date)
                     AND d.full_date <= DATEADD(YEAR, -1, b.last_date) THEN f.sales_amount ELSE 0 END) AS prior_12m_sales
    FROM dbo.fact_sales f
    JOIN dbo.dim_date d     ON d.date_key = f.order_date_key
    JOIN dbo.dim_location l ON l.location_key = f.location_key
    CROSS JOIN bounds b
    GROUP BY l.country_name, l.region
)
SELECT country_name, region, customers, units, sales,
       RANK() OVER (ORDER BY sales DESC)                                   AS sales_rank,
       CAST(100.0 * sales / SUM(sales) OVER () AS decimal(5,1))            AS pct_of_total,
       prior_12m_sales, last_12m_sales,
       CAST(100.0 * (last_12m_sales - prior_12m_sales) / NULLIF(prior_12m_sales, 0) AS decimal(6,1)) AS pct_change_12m,
       CASE WHEN prior_12m_sales = 0 THEN 'New'
            WHEN last_12m_sales > prior_12m_sales * 1.05 THEN 'Growing'
            WHEN last_12m_sales < prior_12m_sales * 0.95 THEN 'Declining'
            ELSE 'Flat' END                                                AS trend
FROM c;
GO

/* ---------------- Q5: sales per country per quarter ----------------- */
CREATE OR ALTER VIEW rpt.v_country_quarterly AS
WITH bounds AS (
    SELECT MIN(d.full_date) AS first_date, MAX(d.full_date) AS last_date
    FROM dbo.fact_sales f JOIN dbo.dim_date d ON d.date_key = f.order_date_key
),
q AS (
    SELECT l.country_name, l.region, d.year_num, d.quarter_num, d.year_quarter,
           DATEFROMPARTS(d.year_num, (d.quarter_num - 1) * 3 + 1, 1) AS quarter_start,
           SUM(f.sales_amount) AS sales,
           COUNT(*)            AS units
    FROM dbo.fact_sales f
    JOIN dbo.dim_date d     ON d.date_key = f.order_date_key
    JOIN dbo.dim_location l ON l.location_key = f.location_key
    GROUP BY l.country_name, l.region, d.year_num, d.quarter_num, d.year_quarter
)
SELECT q.*,
       r.sales_rank,
       CASE WHEN r.sales_rank <= 10 THEN 1 ELSE 0 END AS is_top_10_country,
       -- first and last quarters only have part of their data
       CASE WHEN q.quarter_start < b.first_date
              OR EOMONTH(DATEADD(MONTH, 2, q.quarter_start)) > b.last_date THEN 1 ELSE 0 END AS is_partial_quarter
FROM q
JOIN rpt.v_country_sales r ON r.country_name = q.country_name
CROSS JOIN bounds b;
GO
