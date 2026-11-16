/* =====================================================================
   Q3_price_and_pages_vs_units_sold.sql
   Answers dashboard question Q3 from gravity_dw (localhost,
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
   Q3. How do the cost of the book and the number of pages affect the
       number of books sold?
   The source has no list price; each sale carries its own price, so a
   book's cost = its average selling price.
   --------------------------------------------------------------------- */

-- Q3a. Units sold by price band (one row per sale)
SELECT CASE WHEN sales_amount <  5 THEN '1. Under 5'
            WHEN sales_amount < 10 THEN '2. 5 - 9.99'
            WHEN sales_amount < 15 THEN '3. 10 - 14.99'
            ELSE                        '4. 15 and over' END AS price_band,
       COUNT(*)                         AS units_sold,
       SUM(sales_amount)                AS sales,
       CAST(AVG(sales_amount) AS decimal(6,2)) AS avg_price
FROM fact_sales
GROUP BY CASE WHEN sales_amount <  5 THEN '1. Under 5'
              WHEN sales_amount < 10 THEN '2. 5 - 9.99'
              WHEN sales_amount < 15 THEN '3. 10 - 14.99'
              ELSE                        '4. 15 and over' END
ORDER BY price_band;

-- Q3b. Units sold by page band, normalised per book in the catalogue
--      (includes books that never sold)
WITH book_units AS (
    SELECT b.book_key, b.num_pages, COUNT(f.sales_key) AS units
    FROM dim_book b LEFT JOIN fact_sales f ON f.book_key = b.book_key
    WHERE b.book_key > 0
    GROUP BY b.book_key, b.num_pages
)
SELECT CASE WHEN num_pages IS NULL OR num_pages = 0 THEN '0. Unknown'
            WHEN num_pages < 200 THEN '1. Under 200'
            WHEN num_pages < 400 THEN '2. 200 - 399'
            WHEN num_pages < 600 THEN '3. 400 - 599'
            WHEN num_pages < 800 THEN '4. 600 - 799'
            ELSE                      '5. 800 and over' END AS page_band,
       COUNT(*)                                   AS books_in_catalogue,
       SUM(units)                                 AS units_sold,
       CAST(AVG(units * 1.0) AS decimal(6,3))     AS avg_units_per_book,
       CAST(100.0 * SUM(CASE WHEN units = 0 THEN 1 ELSE 0 END) / COUNT(*) AS decimal(5,1)) AS pct_never_sold
FROM book_units
GROUP BY CASE WHEN num_pages IS NULL OR num_pages = 0 THEN '0. Unknown'
              WHEN num_pages < 200 THEN '1. Under 200'
              WHEN num_pages < 400 THEN '2. 200 - 399'
              WHEN num_pages < 600 THEN '3. 400 - 599'
              WHEN num_pages < 800 THEN '4. 600 - 799'
              ELSE                      '5. 800 and over' END
ORDER BY page_band;

-- Q3c. Book-level data for a scatter plot (pages vs avg price, sized by units)
SELECT b.book_key, b.title, b.num_pages,
       COUNT(*)                                AS units_sold,
       CAST(AVG(f.sales_amount) AS decimal(6,2)) AS avg_price,
       SUM(f.sales_amount)                     AS sales
FROM fact_sales f JOIN dim_book b ON b.book_key = f.book_key
WHERE b.book_key > 0
GROUP BY b.book_key, b.title, b.num_pages;

-- Q3d. Pearson correlation of units sold with price and with pages
--      (books that sold at least once; r near 0 = no relationship)
WITH x AS (
    SELECT CAST(COUNT(*) AS float)            AS units,
           CAST(AVG(f.sales_amount) AS float) AS price,
           CAST(MAX(b.num_pages) AS float)    AS pages
    FROM fact_sales f JOIN dim_book b ON b.book_key = f.book_key
    WHERE b.book_key > 0 AND b.num_pages > 0
    GROUP BY b.book_key
)
SELECT COUNT(*) AS books,
       CAST((AVG(units*price) - AVG(units)*AVG(price))
            / (STDEVP(units) * STDEVP(price)) AS decimal(5,3)) AS r_units_vs_price,
       CAST((AVG(units*pages) - AVG(units)*AVG(pages))
            / (STDEVP(units) * STDEVP(pages)) AS decimal(5,3)) AS r_units_vs_pages,
       CAST((AVG(price*pages) - AVG(price)*AVG(pages))
            / (STDEVP(price) * STDEVP(pages)) AS decimal(5,3)) AS r_price_vs_pages
FROM x;
GO
