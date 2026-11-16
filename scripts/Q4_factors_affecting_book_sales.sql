/* =====================================================================
   Q4_factors_affecting_book_sales.sql
   Answers dashboard question Q4 from gravity_dw (localhost,
   Windows auth). The same logic is in 00_create_powerbi_views.sql.

   Notes that apply to every query:
   - Every order line has quantity = 1, so units sold = number of lines.
   - "Sales" = SUM(sales_amount). Cancelled/returned lines are kept in
     gross sales; net sales excludes is_cancelled_or_returned = 1.
   - There is no budget or target table, so "expected" sales are
     derived from history (same month last year, and the trailing
     12-month average +/- 2 standard deviations).
   - "Today" is the latest order date in the data (27 Oct 2026), not
     GETDATE(). The first month (Oct 2023, from 29 Oct) and the last
     month (Oct 2026, to 27 Oct) are partial; partial months are
     scaled to a full month where totals are compared.
   ===================================================================== */
USE gravity_dw;
GO

/* ---------------------------------------------------------------------
   Q4. What are the factors that affect the total sales of a book?
   Book attributes are compared on sales PER BOOK so that a category
   with many titles does not look strong just because it is big.
   --------------------------------------------------------------------- */

-- Q4a. Factor summary: for each factor, how far apart its levels are.
--      A bigger spread in avg sales per book = a stronger factor.
WITH book_sales AS (
    SELECT b.book_key, b.language_group, b.language_name, b.publisher_name,
           b.publication_year, b.num_pages,
           COUNT(f.sales_key)               AS units,
           ISNULL(SUM(f.sales_amount), 0)   AS sales
    FROM dim_book b LEFT JOIN fact_sales f ON f.book_key = b.book_key
    WHERE b.book_key > 0
    GROUP BY b.book_key, b.language_group, b.language_name, b.publisher_name,
             b.publication_year, b.num_pages
),
levels AS (
    SELECT 'Language group' AS factor, language_group AS level_name, book_key, sales FROM book_sales
    UNION ALL SELECT 'Language', language_name, book_key, sales FROM book_sales
    UNION ALL SELECT 'Publication decade',
                     CAST(publication_year / 10 * 10 AS varchar(4)) + 's', book_key, sales FROM book_sales
    UNION ALL SELECT 'Page band',
                     CASE WHEN num_pages IS NULL OR num_pages = 0 THEN 'Unknown'
                          WHEN num_pages < 200 THEN '<200' WHEN num_pages < 400 THEN '200-399'
                          WHEN num_pages < 600 THEN '400-599' ELSE '600+' END, book_key, sales FROM book_sales
    UNION ALL SELECT 'Publisher', publisher_name, book_key, sales FROM book_sales
),
per_level AS (
    SELECT factor, level_name, COUNT(*) AS books, AVG(sales) AS avg_sales_per_book
    FROM levels GROUP BY factor, level_name
    HAVING COUNT(*) >= 30          -- ignore tiny groups, they are just noise
)
SELECT factor,
       COUNT(*)                                     AS levels_compared,
       CAST(MIN(avg_sales_per_book) AS decimal(8,2)) AS lowest_avg_sales_per_book,
       CAST(MAX(avg_sales_per_book) AS decimal(8,2)) AS highest_avg_sales_per_book,
       CAST(MAX(avg_sales_per_book) - MIN(avg_sales_per_book) AS decimal(8,2)) AS spread
FROM per_level
GROUP BY factor
ORDER BY spread DESC;

-- Q4b. Detail per level of a book factor (change the CASE to switch
--      factor; shown here for language)
SELECT b.language_name,
       COUNT(DISTINCT b.book_key)                         AS books,
       COUNT(f.sales_key)                                 AS units_sold,
       ISNULL(SUM(f.sales_amount), 0)                     AS sales,
       CAST(ISNULL(SUM(f.sales_amount), 0) / COUNT(DISTINCT b.book_key) AS decimal(8,2)) AS sales_per_book
FROM dim_book b LEFT JOIN fact_sales f ON f.book_key = b.book_key
WHERE b.book_key > 0
GROUP BY b.language_name
ORDER BY sales DESC;

-- Q4c. Top 15 publishers by sales, with sales per title
SELECT TOP 15 b.publisher_name,
       COUNT(DISTINCT b.book_key) AS titles_sold,
       COUNT(*)                   AS units_sold,
       SUM(f.sales_amount)        AS sales,
       CAST(SUM(f.sales_amount) / COUNT(DISTINCT b.book_key) AS decimal(8,2)) AS sales_per_title
FROM fact_sales f JOIN dim_book b ON b.book_key = f.book_key
GROUP BY b.publisher_name
ORDER BY sales DESC;

-- Q4d. Customer-side factors: how customers heard about us, preferred
--      channel and shipping method
SELECT 'Heard about' AS factor, c.heard_about AS level_name,
       COUNT(DISTINCT c.customer_key) AS customers, COUNT(*) AS units,
       SUM(f.sales_amount) AS sales,
       CAST(SUM(f.sales_amount) / COUNT(DISTINCT c.customer_key) AS decimal(8,2)) AS sales_per_customer
FROM fact_sales f JOIN dim_customer c ON c.customer_key = f.customer_key
GROUP BY c.heard_about
UNION ALL
SELECT 'Preferred channel', c.preferred_channel,
       COUNT(DISTINCT c.customer_key), COUNT(*), SUM(f.sales_amount),
       CAST(SUM(f.sales_amount) / COUNT(DISTINCT c.customer_key) AS decimal(8,2))
FROM fact_sales f JOIN dim_customer c ON c.customer_key = f.customer_key
GROUP BY c.preferred_channel
UNION ALL
SELECT 'Shipping method', s.method_name,
       COUNT(DISTINCT f.customer_key), COUNT(*), SUM(f.sales_amount),
       CAST(SUM(f.sales_amount) / COUNT(DISTINCT f.customer_key) AS decimal(8,2))
FROM fact_sales f JOIN dim_shipping_method s ON s.shipping_key = f.shipping_key
GROUP BY s.method_name
ORDER BY factor, sales DESC;

-- Q4e. Campaign effect: average monthly sales before vs after the
--      assumed campaign start (etl.config: 2025-10-01)
SELECT d.campaign_period,
       COUNT(DISTINCT d.year_month)                               AS months,
       SUM(f.sales_amount)                                        AS sales,
       CAST(SUM(f.sales_amount) / COUNT(DISTINCT d.year_month) AS decimal(10,2)) AS avg_monthly_sales
FROM fact_sales f JOIN dim_date d ON d.date_key = f.order_date_key
GROUP BY d.campaign_period;
GO
