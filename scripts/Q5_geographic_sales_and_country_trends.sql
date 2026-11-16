/* =====================================================================
   Q5_geographic_sales_and_country_trends.sql
   Answers dashboard question Q5 from gravity_dw (localhost,
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
   Q5. What geographical areas have the most sales and what are the
       trends for different countries?
   --------------------------------------------------------------------- */

-- Q5a. Sales by region
SELECT l.region,
       COUNT(DISTINCT l.country_name) AS countries,
       COUNT(*)                       AS units,
       SUM(f.sales_amount)            AS sales,
       CAST(100.0 * SUM(f.sales_amount) / SUM(SUM(f.sales_amount)) OVER () AS decimal(5,1)) AS pct_of_total
FROM fact_sales f JOIN dim_location l ON l.location_key = f.location_key
GROUP BY l.region
ORDER BY sales DESC;

-- Q5b. Top 15 countries with their share and rank
SELECT TOP 15
       RANK() OVER (ORDER BY SUM(f.sales_amount) DESC) AS sales_rank,
       l.country_name, l.region,
       COUNT(DISTINCT f.customer_key) AS customers,
       COUNT(*)                       AS units,
       SUM(f.sales_amount)            AS sales,
       CAST(100.0 * SUM(f.sales_amount) / SUM(SUM(f.sales_amount)) OVER () AS decimal(5,1)) AS pct_of_total
FROM fact_sales f JOIN dim_location l ON l.location_key = f.location_key
GROUP BY l.country_name, l.region
ORDER BY sales DESC;

-- Q5c. Country trend: the last 12 months vs the 12 months before,
--      for the top 10 countries (rolling windows avoid partial years)
WITH bounds AS (SELECT MAX(d.full_date) AS last_date
                FROM fact_sales f JOIN dim_date d ON d.date_key = f.order_date_key),
c AS (
    SELECT l.country_name,
           SUM(CASE WHEN d.full_date >  DATEADD(YEAR, -1, b.last_date) THEN f.sales_amount ELSE 0 END) AS last_12m,
           SUM(CASE WHEN d.full_date >  DATEADD(YEAR, -2, b.last_date)
                     AND d.full_date <= DATEADD(YEAR, -1, b.last_date) THEN f.sales_amount ELSE 0 END) AS prior_12m,
           SUM(f.sales_amount) AS total_sales
    FROM fact_sales f
    JOIN dim_date d     ON d.date_key = f.order_date_key
    JOIN dim_location l ON l.location_key = f.location_key
    CROSS JOIN bounds b
    GROUP BY l.country_name
)
SELECT TOP 10 country_name, prior_12m, last_12m,
       CAST(100.0 * (last_12m - prior_12m) / NULLIF(prior_12m, 0) AS decimal(6,1)) AS pct_change,
       CASE WHEN last_12m > prior_12m * 1.05 THEN 'Growing'
            WHEN last_12m < prior_12m * 0.95 THEN 'Declining'
            ELSE 'Flat' END AS trend
FROM c
ORDER BY total_sales DESC;

-- Q5d. Quarterly sales per country for a line chart / small multiples
--      (top 10 countries only)
WITH top10 AS (
    SELECT TOP 10 l.country_name
    FROM fact_sales f JOIN dim_location l ON l.location_key = f.location_key
    GROUP BY l.country_name ORDER BY SUM(f.sales_amount) DESC
)
SELECT l.country_name, d.year_quarter, SUM(f.sales_amount) AS sales, COUNT(*) AS units
FROM fact_sales f
JOIN dim_date d     ON d.date_key = f.order_date_key
JOIN dim_location l ON l.location_key = f.location_key
WHERE l.country_name IN (SELECT country_name FROM top10)
GROUP BY l.country_name, d.year_quarter
ORDER BY l.country_name, d.year_quarter;
GO
