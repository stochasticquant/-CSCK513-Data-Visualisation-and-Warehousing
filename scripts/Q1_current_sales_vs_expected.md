# Q1 – Current sales for the last three months vs expectations

Script: `Q1_current_sales_vs_expected.sql` · Power BI views: `rpt.v_monthly_sales`, `rpt.v_last3_vs_prior_year`

## The question

> What are our current sales for the last three months and how does this match expectations?

We need to answer two things:

1. **How much did we sell** in each of the last three months?
2. **Is that good or bad?** To judge that, we need something to compare it with.

## The problem: there is no "expected" figure in the data

A real business would have a budget or sales target. The Gravity database has none, so we
build the expectation from past sales. The script uses two common benchmarks:

| Benchmark | Meaning | Why it is useful |
|---|---|---|
| **Same month last year** | August 2026 is compared with August 2025 | Allows for seasons, e.g. December is always busier |
| **Trailing 12-month average** | The average of the 12 months *before* this month | Shows the recent "normal" level |

## Two details that matter

**1. What does "today" mean?** The last order in the warehouse is on **27 October 2026**. If we
used `GETDATE()` (the computer's clock), the "last three months" would change every time you ran
the query and might contain no data at all. So the script uses the **latest order date in the
data** as "today".

**2. October 2026 is only partly there.** We only have 27 of its 31 days, so its total looks low
for an unfair reason. The script **scales it up to a full month**:

```
full-month sales = sales so far × days in month ÷ days with data
                 = 4,072.11 × 31 ÷ 27 = 4,675.39
```

The same is done for October 2023 (the data starts on the 29th).

## How the first query works, step by step

The query is built from **CTEs** (Common Table Expressions). A CTE starts with `WITH name AS (...)`
and is like a temporary named table that only exists while the query runs. Each step builds
on the one before, which makes a long query easier to read.

### Step 1 – `bounds`: find the first and last order dates

```sql
SELECT MIN(d.full_date) AS first_date, MAX(d.full_date) AS last_date
FROM fact_sales f JOIN dim_date d ON d.date_key = f.order_date_key
```

- `fact_sales` holds one row per book sold. It stores a date **key** (e.g. `20261027`), not a
  real date.
- `JOIN dim_date` looks up the real date for that key. This is how a star schema works: facts
  in the middle, descriptive dimensions around them.
- `MIN` and `MAX` give the first and last dates: 2023-10-29 and 2026-10-27.

### Step 2 – `monthly`: total each month

```sql
SUM(f.sales_amount)                    AS gross_sales,
SUM(CASE WHEN f.is_cancelled_or_returned = 0
         THEN f.sales_amount ELSE 0 END) AS net_sales,
COUNT(*)                               AS units,
COUNT(DISTINCT f.order_id)             AS orders
...
GROUP BY d.year_num, d.month_num, d.year_month
```

- `GROUP BY` squashes all the rows for one month into one row, and `SUM` / `COUNT` add them up.
- **Gross** sales include everything. **Net** sales leave out cancelled or returned items: the
  `CASE WHEN … THEN … ELSE 0 END` adds a line's value only when it was *not* cancelled or returned.
- `COUNT(*)` counts lines. Each line is one book (quantity is always 1), so this is **units sold**.
- `COUNT(DISTINCT order_id)` counts orders, because one order can contain several books.

### Step 3 – `scaled`: work out the partial-month scale factor

```sql
DAY(EOMONTH(m.month_start)) * 1.0 / (days with data)
```

- `EOMONTH` gives the last day of the month; `DAY(...)` turns that into a number (31, 30, 28…).
- The `CASE` expressions clip the month to the dates we actually have data for.
- For a complete month the factor is `1.0`; for October 2026 it is `31 / 27 = 1.148`.
- The `* 1.0` makes SQL do decimal division. `31 / 27` on whole numbers would give `1`.

### Step 4 – `calc`: look back in time with window functions

```sql
LAG(s.gross_sales, 12) OVER (ORDER BY s.month_start)   AS same_month_last_year,
AVG(s.gross_sales * s.scale_factor) OVER (ORDER BY s.month_start
    ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING)         AS trailing_12m_avg
```

These are **window functions**, the most powerful idea in this script. A normal `AVG` collapses
rows into one; a window function calculates across *other rows* but **keeps every row**.

- `OVER (ORDER BY month_start)` lines the months up in date order.
- `LAG(value, 12)` means "give me the value from 12 rows back", i.e. the same month last year.
- `ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING` is a sliding window: the 12 months *before* the
  current one. The current month is left out because it shouldn't count towards its own
  expectation.

### Step 5 – the final `SELECT`: compare and show the last three months

```sql
100.0 * (full_month_sales - same_month_last_year) / NULLIF(same_month_last_year, 0)
```

- This is the usual **percentage change** formula: (new − old) ÷ old × 100.
- `NULLIF(x, 0)` turns a 0 into `NULL`, so we never divide by zero. Dividing by `NULL` just
  gives `NULL` instead of an error.
- `TOP 3 … ORDER BY month_start DESC` keeps the three most recent months.

## The second query (Q1b) – the three months as one total

This adds up **1 Aug – 27 Oct 2026** as a single figure and compares it with exactly the same
dates a year earlier (**1 Aug – 27 Oct 2025**). Using the same dates means the partial-month
problem doesn't arise. `UNION ALL` stacks the two results on top of each other.

- `DATEADD(MONTH, -2, …)` goes back two months to the start of August.
- `DATEADD(YEAR, -1, …)` shifts a date back one year.

## Results

| Month | Units | Sales | Full-month sales | Same month last year | vs last year | Expected (12-m avg) | vs expected |
|---|---|---|---|---|---|---|---|
| 2026-10 | 395 | 4,072.11 | 4,675.39 | 3,890.40 | +20.2% | 4,296.88 | +8.8% |
| 2026-09 | 396 | 3,978.51 | 3,978.51 | 3,966.26 | +0.3% | 4,295.86 | −7.4% |
| 2026-08 | 456 | 4,516.65 | 4,516.65 | 4,801.24 | −5.9% | 4,319.57 | +4.6% |

| Period | Units | Sales |
|---|---|---|
| Last 3 months (1 Aug – 27 Oct 2026) | 1,247 | 12,567.27 |
| Same period last year | 1,224 | 12,283.84 |

## What this tells us

- Sales over the last three months are **12,567**, about **2.3% higher** than the same period
  last year.
- Every month is within about ±9% of what we would expect. Sales are **in line with
  expectations**: no sign of a problem and no big jump.
- October's +20.2% compared with last year should be treated with care: October 2025 was a
  weak month, and October 2026 has been scaled up from 27 days.

## Ideas to try

- Change `TOP 3` to `TOP 6` to see the last six months.
- Swap `gross_sales` for `net_sales` in the comparison to ignore cancelled and returned orders.
