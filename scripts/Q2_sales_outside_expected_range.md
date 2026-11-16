# Q2 – Have sales been outside the expected range in the past two years?

Script: `Q2_sales_outside_expected_range.sql` · Power BI view: `rpt.v_monthly_sales`
(filter on `is_last_24_months = 1`)

## The question

> Have sales been outside of the expected range any time in the past two years?

Q1 gave a single "expected" number. Here we need an **expected range**: a band that a normal
month falls inside. A month above or below the band is unusual and worth investigating.

## The idea: a control chart

Sales go up and down a little every month just by chance. To tell normal wobble from a real
change, the script uses a technique from quality control called a **control chart**:

```
upper limit = average + 2 × standard deviation
expected    = average of the previous 12 months
lower limit = average − 2 × standard deviation
```

- The **average** (mean) is the typical monthly sales figure.
- The **standard deviation** (SD) measures how much months normally vary around that average.
  A small SD means sales are steady; a large one means they jump around.
- If sales follow a roughly normal pattern, **about 95% of months land within ±2 SD**. A month
  outside the band would happen by chance only about 1 time in 20, so it is a signal.

We use the **previous 12 months** (a rolling window) rather than all history, so the band
follows the business as it grows or shrinks.

### The z-score

The script also shows a **z-score**: how many standard deviations a month is from the average.

```
z = (this month − average) ÷ standard deviation
```

- `z = 0` means exactly average.
- `z = +1.5` means 1.5 SDs above average: higher, but still normal.
- `z` above `+2` or below `−2` means **outside the range**.

## How the query works, step by step

### Step 1 – `bounds`: first and last order dates

As in Q1, "today" is the latest order in the data (27 Oct 2026), not the computer's clock.

### Step 2 – `monthly`: total sales per month

`GROUP BY` year and month, then `SUM(sales_amount)` and `COUNT(*)`. One row per month.

### Step 3 – `scaled`: make every month comparable

```sql
WHERE m.month_start >= DATEADD(DAY, 1, EOMONTH(b.first_date))
```

- The data starts on 29 Oct 2023, so October 2023 has only 3 days. That would pull the
  average down and widen the band unfairly, so this line **removes the first month**.
  `EOMONTH(first_date)` is 31 Oct 2023; adding one day gives 1 Nov 2023, the first full month.
- October 2026 (27 of 31 days) is **scaled up to a full month**, exactly as in Q1.

### Step 4 – `band`: rolling average and standard deviation

```sql
AVG(sales)   OVER (ORDER BY month_start ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING) AS mean_12m,
STDEV(sales) OVER (ORDER BY month_start ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING) AS sd_12m,
COUNT(*)     OVER (ORDER BY month_start ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING) AS months_in_baseline
```

These are **window functions**. For every month they look at the 12 months before it and
work out the average and SD, **without collapsing the rows**, so each month keeps its own
expected value.

- `ROWS BETWEEN 12 PRECEDING AND 1 PRECEDING` is "the 12 rows before this one". The current
  month is left out: you shouldn't judge a month against a band that already includes it.
- `COUNT(*)` tells us how many months were actually in the window. The earliest months don't
  yet have 12 months of history.

### Step 5 – final `SELECT`: label each month

```sql
CASE WHEN sales > mean_12m + 2 * sd_12m THEN 'Above range'
     WHEN sales < mean_12m - 2 * sd_12m THEN 'Below range'
     ELSE 'Within range' END AS status
```

`CASE` is SQL's version of if / else-if / else. It checks each rule in order and returns the
first one that matches.

```sql
WHERE month_start >= DATEADD(MONTH, -23, <first day of last month>)
  AND months_in_baseline = 12
```

- Keeps the **last 24 months** (the latest month plus the 23 before it): November 2024 to
  October 2026.
- Keeps only months with a **full 12-month baseline**, so every band is calculated the same way.

## Results (selected months)

| Month | Sales | Expected | Lower | Upper | Status | z |
|---|---|---|---|---|---|---|
| 2024-11 | 4,246.61 | 4,199.00 | 3,112.86 | 5,285.14 | Within range | 0.09 |
| 2025-05 | 5,160.95 | 4,338.54 | 3,475.41 | 5,201.68 | Within range | **1.91** |
| 2026-06 | 3,857.80 | 4,318.08 | 3,681.33 | 4,954.83 | Within range | −1.45 |
| 2026-07 | 4,814.26 | 4,282.55 | 3,592.21 | 4,972.89 | Within range | 1.54 |
| 2026-10 | 4,675.39 | 4,296.88 | 3,593.30 | 5,000.46 | Within range | 1.08 |

All 24 rows are in the script output; all of them are **Within range**.

## What this tells us

- **No month in the past two years was outside the expected range.** Sales have been stable at
  around 4,300 a month.
- The closest call was **May 2025** (z = 1.91), a strong month that came within about 40 of the
  upper limit.
- The lowest relative month was **June 2026** (z = −1.45), still comfortably inside the band.

## Dashboard tip

In Power BI, draw `full_month_sales` as a line, and `lower_limit` / `upper_limit` as two lighter
lines (or a shaded band) from `rpt.v_monthly_sales`. Colour points by `range_status` so any
future month outside the band stands out straight away.

## Ideas to try

- Change `2 * sd_12m` to `1.5 * sd_12m` for a tighter band; some months will then be flagged.
- Change `12 PRECEDING` to `6 PRECEDING` to use a shorter, more reactive baseline.
