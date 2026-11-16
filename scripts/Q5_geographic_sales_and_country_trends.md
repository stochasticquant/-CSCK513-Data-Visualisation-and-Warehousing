# Q5 – Which geographical areas sell the most, and what are the country trends?

Script: `Q5_geographic_sales_and_country_trends.sql` · Power BI views: `rpt.v_country_sales`,
`rpt.v_country_quarterly`

## The question

> What geographical areas have the most sales and what are the trends for different countries?

Two parts:

1. **Where** do sales come from? (a ranking by region and country)
2. **How is each country changing** over time? (growing, flat or declining)

## Where the location comes from

Each sale in `fact_sales` has a `location_key` pointing to `dim_location`, which holds the
**delivery address**: city, country and a `region` (continent) column added during the ETL. So
"where" means **where the books were shipped to**.

## The script has four queries

### 5a – Sales by region

```sql
SUM(f.sales_amount) AS sales,
100.0 * SUM(f.sales_amount) / SUM(SUM(f.sales_amount)) OVER () AS pct_of_total
```

The percentage line looks odd, but it is a common trick:

- The inner `SUM(f.sales_amount)` is the region's total (from the `GROUP BY`).
- `SUM(...) OVER ()` is a **window function** with an empty window `()`, which means "across all
  rows of the result". So it adds up every region's total to give the **grand total**.
- Region ÷ grand total × 100 = the region's share.

This gets the percentage in one query, without working out the grand total separately.

| Region | Countries | Units | Sales | % of total |
|---|---|---|---|---|
| Asia | 29 | 6,944 | 69,259.81 | 44.7% |
| Europe | 33 | 4,584 | 46,407.39 | 29.9% |
| South America | 7 | 1,499 | 15,481.43 | 10.0% |
| North America | 10 | 1,245 | 12,275.00 | 7.9% |
| Africa | 24 | 959 | 9,846.72 | 6.4% |
| Oceania | 6 | 159 | 1,695.99 | 1.1% |

### 5b – Top 15 countries

```sql
RANK() OVER (ORDER BY SUM(f.sales_amount) DESC) AS sales_rank
```

`RANK()` numbers the rows 1, 2, 3… in the order given. Two countries with exactly the same
sales would share a rank. The same `pct_of_total` trick is used, and
`COUNT(DISTINCT customer_key)` shows how many different customers each country has.

| Rank | Country | Region | Customers | Sales | % of total |
|---|---|---|---|---|---|
| 1 | China | Asia | 517 | 27,493.88 | 17.7% |
| 2 | Indonesia | Asia | 388 | 19,356.58 | 12.5% |
| 3 | Russia | Europe | 209 | 9,718.73 | 6.3% |
| 4 | Brazil | South America | 133 | 6,657.03 | 4.3% |
| 5 | Portugal | Europe | 121 | 6,461.64 | 4.2% |

(The full top 15 is in the script output.)

### 5c – Trend: last 12 months vs the 12 months before

A simple way to describe a trend is to compare **this year with last year**. Calendar years
don't work well here: 2023 has only 3 days and 2026 isn't finished. So the script uses
**rolling 12-month periods** that end on the last order date (27 Oct 2026):

| Period | Dates |
|---|---|
| Last 12 months | 28 Oct 2025 – 27 Oct 2026 |
| Prior 12 months | 28 Oct 2024 – 27 Oct 2025 |

```sql
SUM(CASE WHEN d.full_date > DATEADD(YEAR, -1, b.last_date) THEN f.sales_amount ELSE 0 END) AS last_12m
```

This is **conditional aggregation**: `CASE` inside `SUM`. For each sale, if the date falls in
the period, add its amount; otherwise add 0. Two of these side by side give both periods in one
pass over the data, one row per country.

The trend label uses a ±5% tolerance, so small wobbles count as "Flat":

```sql
CASE WHEN last_12m > prior_12m * 1.05 THEN 'Growing'
     WHEN last_12m < prior_12m * 0.95 THEN 'Declining'
     ELSE 'Flat' END
```

| Country | Prior 12 m | Last 12 m | Change | Trend |
|---|---|---|---|---|
| China | 10,134.35 | 8,530.09 | −15.8% | Declining |
| Indonesia | 6,530.89 | 6,868.81 | +5.2% | Growing |
| Russia | 3,266.85 | 3,287.67 | +0.6% | Flat |
| Brazil | 2,266.11 | 2,190.29 | −3.3% | Flat |
| Portugal | 2,328.34 | 2,188.63 | −6.0% | Declining |
| Philippines | 2,122.91 | 2,336.47 | +10.1% | Growing |
| Poland | 1,817.91 | 1,995.11 | +9.7% | Growing |
| United States | 1,651.95 | 1,635.78 | −1.0% | Flat |
| France | 1,565.11 | 1,610.71 | +2.9% | Flat |
| Peru | 1,445.70 | 1,481.84 | +2.5% | Flat |

### 5d – Quarterly sales per country (for line charts)

This gives sales for each of the top 10 countries in every quarter, which is ideal for a line
chart with one line per country.

```sql
WITH top10 AS (SELECT TOP 10 l.country_name ... ORDER BY SUM(f.sales_amount) DESC)
...
WHERE l.country_name IN (SELECT country_name FROM top10)
```

- The `top10` CTE finds the ten biggest countries first.
- `IN (SELECT …)` then keeps only sales for those countries. This is a **subquery**: a query
  inside another query.

**Watch out:** the first quarter (2023-Q4, only 3 days) and the last quarter (2026-Q4, 27 days)
are **partial**, so they always look like a sudden drop. In Power BI, filter them out with
`is_partial_quarter = 0` in `rpt.v_country_quarterly`.

## What this tells us

- **Asia is the biggest region** (44.7% of sales), followed by **Europe** (29.9%). Together
  they make up three-quarters of all sales.
- **China (17.7%) and Indonesia (12.5%)** are by far the biggest countries; together they make
  up nearly a third of all sales.
- **Trends differ by country:**
  - **China is declining** (−15.8% over the last 12 months). Its quarterly sales peaked in
    2024-Q4 (2,887) and have been around 2,000–2,200 since. Because China is the largest
    market, this is the trend most worth watching.
  - **The Philippines (+10.1%), Poland (+9.7%) and Indonesia (+5.2%) are growing.**
  - Russia, Brazil, the USA, France and Peru are broadly **flat**.

## Dashboard tip

Use a **filled map** coloured by `sales` (or `pct_change_12m`) from `rpt.v_country_sales`, a bar
chart of the top 10, and a line chart from `rpt.v_country_quarterly` with
`is_top_10_country = 1` and `is_partial_quarter = 0`.

## Ideas to try

- Change the ±5% tolerance (`1.05` / `0.95`) to ±10% and see which countries are still labelled
  as growing or declining.
- In 5c, change `TOP 10 … ORDER BY total_sales DESC` to `ORDER BY pct_change DESC` to find the
  fastest-growing countries of any size.
