# Q4 – What factors affect the total sales of a book?

Script: `Q4_factors_affecting_book_sales.sql` · Power BI views: `rpt.v_factor_spread`,
`rpt.v_book_sales`, `rpt.v_customer_factors`, `rpt.v_campaign_effect`

## The question

> What are the factors that affect the total sales of a book?

A "factor" is anything that might make a book sell more or less. The warehouse lets us test
two kinds:

| Kind | Factors available | Where they come from |
|---|---|---|
| **About the book** | language, publisher, publication decade, number of pages | `dim_book` |
| **About the sale** | how the customer heard about us, their preferred channel, shipping method, the marketing campaign | `dim_customer`, `dim_shipping_method`, `dim_date` |

## The trap: big groups look strong

English has **8,911 books**; Japanese has **46**. English will always have higher *total* sales,
just because there are more English books. That doesn't mean being in English makes a book
sell better.

So the script compares **average sales per book**:

```
sales per book = total sales of the group ÷ number of books in the group
```

Now every group is compared fairly, whatever its size.

## The script has five queries

### 4a – Factor summary: which factor matters most?

This is the key query. For each factor it asks: **how far apart are the best and worst groups?**

- If language really mattered, some languages would sell much more per book than others,
  so the **spread** (best − worst) would be large.
- If it didn't matter, every language would average about the same and the spread would be small.

**How it's built:**

1. **`book_sales` CTE**: one row per book with its total sales. It uses a `LEFT JOIN` so books
   that never sold are still included, with sales of 0. `ISNULL(SUM(...), 0)` turns "no sales"
   (`NULL`) into 0.

2. **`levels` CTE**: the clever bit. It uses `UNION ALL` to stack the same books five times,
   once for each factor:

   ```sql
   SELECT 'Language group' AS factor, language_group AS level_name, book_key, sales FROM book_sales
   UNION ALL SELECT 'Language', language_name, book_key, sales FROM book_sales
   UNION ALL ...
   ```

   This turns five different columns into one common shape (`factor`, `level_name`, `sales`),
   so all five factors can be summarised by the same `GROUP BY`. This is called **unpivoting**.

   The publication year is rounded to a decade with `publication_year / 10 * 10`. Dividing
   whole numbers in SQL drops the remainder, so 1997 / 10 = 199, and × 10 = 1990.

3. **`per_level` CTE**: average sales per book for each level, e.g. "Language = Spanish".
   `HAVING COUNT(*) >= 30` drops tiny groups. `HAVING` is like `WHERE`, but it filters
   *after* grouping. A language with 1 book could have an average of 45 just by luck, which
   would make the spread meaningless.

4. **Final `SELECT`**: for each factor, the lowest and highest average and the gap between them.

| Factor | Levels compared | Lowest avg / book | Highest avg / book | Spread |
|---|---|---|---|---|
| Publisher | 77 | 10.55 | 18.49 | 7.95 |
| Language | 7 | 13.28 | 16.12 | 2.85 |
| Publication decade | 6 | 13.61 | 14.50 | 0.90 |
| Language group | 2 | 13.89 | 14.64 | 0.76 |
| Page band | 5 | 13.59 | 14.15 | 0.56 |

**Careful reading:** publisher has the biggest spread, but with 77 publishers of around 30–50
books each, *some* will be high and some low by chance alone. The more groups you compare and
the smaller they are, the bigger the spread you get from luck. So this is **mostly noise, not a
real effect**. The other factors all sit within about 1 of each other, around 14 per book.

### 4b – Detail by language

Total and per-book sales for every language. English dominates the **totals** (123,425), but
per book it is ordinary (13.85). Small languages like Portuguese (23.18 per book) look high, but
with only 10 books that is luck.

To look at a different factor, change `b.language_name` in the `SELECT` and the `GROUP BY` to
`b.publisher_name` or `b.publication_year`.

### 4c – Top 15 publishers

`TOP 15 … ORDER BY sales DESC` shows the biggest publishers. Vintage, Penguin Books and Penguin
Classics lead on total sales because they have the most titles. Their **sales per title**
(about 16–18) are very similar.

### 4d – Customer and delivery factors

Three small queries joined with `UNION ALL`, each grouping by a different customer or delivery
attribute. `COUNT(DISTINCT customer_key)` counts customers (each one once), while `COUNT(*)`
counts books bought.

| Factor | Finding |
|---|---|
| Heard about us | Friend recommendation brings the most customers (547), but every source spends about **88 per customer** |
| Preferred channel | Online is the biggest channel (1,075 customers); spend per customer is about 88–91 for all |
| Shipping method | Express is used for most sales (8,848 books, 57% of sales) |

The "sales per customer" for shipping isn't comparable across methods, because one customer can
use several methods. Compare the **units and sales** columns instead.

### 4e – Campaign effect

```sql
GROUP BY d.campaign_period
```

`dim_date` labels every date as `Pre-campaign` or `Post-campaign`, based on an **assumed**
campaign start of 1 Oct 2025 (stored in `etl.config`; it isn't in the source data). Because the
two periods have different lengths (24 vs 13 months), the query compares **average monthly
sales**, not totals.

| Period | Months | Avg monthly sales |
|---|---|---|
| Pre-campaign | 24 | 4,138.82 |
| Post-campaign | 13 | 4,279.59 |

Post-campaign months average **3.4% higher**, a small increase that is well within normal
month-to-month variation (see Q2).

## What this tells us

- **No book attribute strongly affects sales.** Language, page count and publication decade
  all give about 14 per book. Publisher shows a bigger spread, but that is consistent with
  random variation between many small groups.
- **The main driver of a group's total sales is simply how many titles it has.** English books
  and big publishers sell more in total because there are more of them.
- On the customer side, **word of mouth (friend recommendation) and online** are the biggest
  sources of customers, and **Express** is the most-used shipping method.
- The campaign period shows a small **+3.4%** lift.

## Ideas to try

- Lower `HAVING COUNT(*) >= 30` to `>= 5` and watch the publisher spread grow. This shows how
  small groups create false "effects".
- Add a factor to the `levels` CTE, e.g. `'Has sold'` with
  `CASE WHEN sales > 0 THEN 'Yes' ELSE 'No' END`.
