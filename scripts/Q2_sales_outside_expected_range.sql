/* =====================================================================
   Q2_sales_outside_expected_range.sql
   Answers dashboard question Q2 from gravity_dw (localhost,
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
   Q2. Have sales been outside of the expected range any time in the
       past two years?
   Expected range = trailing 12-month mean +/- 2 standard deviations
   (a control-chart band). Partial months are scaled to a full month
   and the partial first month (Oct 2023) is left out of the baseline.
   --------------------------------------------------------------------- */
WITH bounds AS (
    SELECT MIN(d.full_date) AS first_date, MAX(d.full_date) AS last_date
    FROM fact_sales f JOIN dim_date d ON d.date_key = f.order_date_key
),
monthly AS (
    SELECT DATEFROMPARTS(d.year_num, d.month_num, 1) AS month_start,
           d.year_month, SUM(f.sales_amount) AS gross_sales, COUNT(*) AS units
    FROM fact_sales f JOIN dim_date d ON d.date_key = f.order_date_key
    GROUP BY d.year_num, d.month_num, d.year_month
),
scaled AS (
    SELECT m.month_start, m.year_month, m.units,
           CAST(m.gross_sales * DAY(EOMONTH(m.month_start)) * 1.0 /
                (DATEDIFF(DAY, m.month_start,
                    CASE WHEN b.last_date < EOMONTH(m.month_start) THEN b.last_date
                         ELSE EOMONTH(m.month_start) END) + 1) AS decimal(12,2)) AS sales
    FROM monthly m CROSS JOIN bounds b
    WHERE m.month_start >= DATEADD(DAY, 1, EOMONTH(b.first_date))   -- drop partial first month
),
band AS (
    SELECT s.*,
           AVG(sales)   OVER (ORDER BY month_start ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING) AS mean_12m,
           STDEV(sales) OVER (ORDER BY month_start ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING) AS sd_12m,
           COUNT(*)     OVER (ORDER BY month_start ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING) AS months_in_baseline
    FROM scaled s
)
SELECT year_month, units, sales,
       CAST(mean_12m AS decimal(12,2))              AS expected,
       CAST(mean_12m - 2 * sd_12m AS decimal(12,2)) AS lower_limit,
       CAST(mean_12m + 2 * sd_12m AS decimal(12,2)) AS upper_limit,
       CASE WHEN sales > mean_12m + 2 * sd_12m THEN 'Above range'
            WHEN sales < mean_12m - 2 * sd_12m THEN 'Below range'
            ELSE 'Within range' END                 AS status,
       CAST((sales - mean_12m) / NULLIF(sd_12m, 0) AS decimal(5,2)) AS z_score
FROM band b CROSS JOIN bounds
WHERE month_start >= DATEADD(MONTH, -23, DATEFROMPARTS(YEAR(last_date), MONTH(last_date), 1))
  AND months_in_baseline = 12
ORDER BY month_start;
GO
