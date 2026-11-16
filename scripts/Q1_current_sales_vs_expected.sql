/* =====================================================================
   Q1_current_sales_vs_expected.sql
   Answers dashboard question Q1 from gravity_dw (localhost,
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
   Q1. What are our current sales for the last three months and how
       does this match expectations?
   Expectation 1: the same month one year earlier.
   Expectation 2: the average of the 12 complete months before it.
   --------------------------------------------------------------------- */
WITH bounds AS (
    SELECT MIN(d.full_date) AS first_date, MAX(d.full_date) AS last_date
    FROM fact_sales f JOIN dim_date d ON d.date_key = f.order_date_key
),
monthly AS (
    SELECT d.year_num, d.month_num, d.year_month,
           DATEFROMPARTS(d.year_num, d.month_num, 1)            AS month_start,
           SUM(f.sales_amount)                                   AS gross_sales,
           SUM(CASE WHEN f.is_cancelled_or_returned = 0
                    THEN f.sales_amount ELSE 0 END)              AS net_sales,
           COUNT(*)                                              AS units,
           COUNT(DISTINCT f.order_id)                            AS orders
    FROM fact_sales f JOIN dim_date d ON d.date_key = f.order_date_key
    GROUP BY d.year_num, d.month_num, d.year_month
),
scaled AS (   -- scale partial first/last months to a full month
    SELECT m.*,
           DAY(EOMONTH(m.month_start)) * 1.0 /
           (DATEDIFF(DAY,
                CASE WHEN b.first_date > m.month_start THEN b.first_date ELSE m.month_start END,
                CASE WHEN b.last_date  < EOMONTH(m.month_start) THEN b.last_date ELSE EOMONTH(m.month_start) END) + 1)
                                                                 AS scale_factor
    FROM monthly m CROSS JOIN bounds b
),
calc AS (
    SELECT s.*,
           CAST(s.gross_sales * s.scale_factor AS decimal(12,2)) AS full_month_sales,
           LAG(s.gross_sales, 12) OVER (ORDER BY s.month_start)  AS same_month_last_year,
           AVG(s.gross_sales * s.scale_factor) OVER (ORDER BY s.month_start
               ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING)        AS trailing_12m_avg
    FROM scaled s
)
SELECT TOP 3
       year_month, units, orders, gross_sales, net_sales,
       scale_factor                                              AS partial_month_scale,
       full_month_sales,
       same_month_last_year,
       CAST(100.0 * (full_month_sales - same_month_last_year)
            / NULLIF(same_month_last_year, 0) AS decimal(6,1))   AS pct_vs_last_year,
       CAST(trailing_12m_avg AS decimal(12,2))                   AS expected_trailing_12m_avg,
       CAST(100.0 * (full_month_sales - trailing_12m_avg)
            / NULLIF(trailing_12m_avg, 0) AS decimal(6,1))       AS pct_vs_expected
FROM calc
ORDER BY month_start DESC;

-- Q1b. The three months as one total vs the same three months last year
WITH bounds AS (SELECT MAX(d.full_date) AS last_date
                FROM fact_sales f JOIN dim_date d ON d.date_key = f.order_date_key),
p AS (SELECT DATEADD(MONTH, -2, DATEFROMPARTS(YEAR(last_date), MONTH(last_date), 1)) AS cur_start,
             last_date AS cur_end FROM bounds)
SELECT 'Last 3 months'                AS period, p.cur_start AS from_date, p.cur_end AS to_date,
       COUNT(*) AS units, SUM(f.sales_amount) AS gross_sales
FROM fact_sales f JOIN dim_date d ON d.date_key = f.order_date_key CROSS JOIN p
WHERE d.full_date BETWEEN p.cur_start AND p.cur_end
GROUP BY p.cur_start, p.cur_end
UNION ALL
SELECT 'Same period last year', DATEADD(YEAR, -1, p.cur_start), DATEADD(YEAR, -1, p.cur_end),
       COUNT(*), SUM(f.sales_amount)
FROM fact_sales f JOIN dim_date d ON d.date_key = f.order_date_key CROSS JOIN p
WHERE d.full_date BETWEEN DATEADD(YEAR, -1, p.cur_start) AND DATEADD(YEAR, -1, p.cur_end)
GROUP BY p.cur_start, p.cur_end;
GO
