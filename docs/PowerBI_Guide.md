# Power BI Dashboard Guide: Gravity Marketing

## 1. Model

Open **Model view**, the third icon on the left.

1. **Relationships.** Power BI auto-detects the keys with matching names (`customer_key`, `book_key`, `location_key`, `shipping_key`). Check that each one is a line from the dimension (**1**) to `fact_sales` (**\***).
2. `order_date_key` → `date_key` has different names, so create it yourself: drag **fact_sales[order_date_key]** onto **dim_date[date_key]**. Cardinality *Many to one*, cross-filter *Single* → OK.
3. **Delete any other relationships** Power BI guessed, e.g. between two dimension tables. Only the 5 dimension → fact lines should remain: a star.
4. **Mark the date table:** select `dim_date` → **Table tools → Mark as date table** → column **full_date** → OK.
5. **Sort month names:** select `dim_date[month_name]` → **Column tools → Sort by column → month_num**.
6. **Map category:** select `dim_location[country_name]` → **Column tools → Data category → Country/Region**. Set `city` to **City**.
7. Optional but tidy: right-click the key columns in `fact_sales` (`*_key`, `sales_key`, `line_id`) → **Hide in report view**.

📸 `pbi_model.png`: Model view showing the star (fact in the middle, 5 dimensions around it).

## 2. Measures

Select the **fact_sales** table in the Data pane → **Home → New measure**, and paste each formula. One measure per **New measure** click.

```dax
Total Sales = SUM ( fact_sales[sales_amount] )
```
```dax
Order Lines = COUNTROWS ( fact_sales )
```
```dax
Orders = DISTINCTCOUNT ( fact_sales[order_id] )
```
```dax
Customers = DISTINCTCOUNT ( fact_sales[customer_key] )
```
```dax
Countries = CALCULATE ( DISTINCTCOUNT ( dim_location[country_name] ), fact_sales )
```
```dax
Non-English Lines = CALCULATE ( [Order Lines], dim_book[language_group] = "Non-English" )
```
```dax
Non-English Sales = CALCULATE ( [Total Sales], dim_book[language_group] = "Non-English" )
```
```dax
Non-English Customers = CALCULATE ( [Customers], dim_book[language_group] = "Non-English" )
```
```dax
Non-English % = DIVIDE ( [Non-English Lines], [Order Lines] )
```
*(Format `Non-English %` as **Percentage**, 2 decimals: Measure tools → Format.)*

**Fair campaign comparison.** The pre-campaign period is about 23 months and the post-campaign period about 13, with partial months at both ends. So compare **rates per 30 days**, not totals:

```dax
Days in Period =
VAR FirstDay = CALCULATE ( MIN ( dim_date[full_date] ), fact_sales, REMOVEFILTERS ( dim_book ) )
VAR LastDay  = CALCULATE ( MAX ( dim_date[full_date] ), fact_sales, REMOVEFILTERS ( dim_book ) )
RETURN IF ( NOT ISBLANK ( FirstDay ), DATEDIFF ( FirstDay, LastDay, DAY ) + 1 )
```
```dax
Lines per 30 Days = DIVIDE ( [Order Lines], [Days in Period] ) * 30
```
```dax
Non-English Lines per 30 Days = DIVIDE ( [Non-English Lines], [Days in Period] ) * 30
```
```dax
Lines per 30 Days (Pre) = CALCULATE ( [Lines per 30 Days], dim_date[campaign_period] = "Pre-campaign" )
```
```dax
Lines per 30 Days (Post) = CALCULATE ( [Lines per 30 Days], dim_date[campaign_period] = "Post-campaign" )
```
```dax
Lines Change % = DIVIDE ( [Lines per 30 Days (Post)] - [Lines per 30 Days (Pre)], [Lines per 30 Days (Pre)] )
```
```dax
Non-English per 30 Days (Pre) = CALCULATE ( [Non-English Lines per 30 Days], dim_date[campaign_period] = "Pre-campaign" )
```
```dax
Non-English per 30 Days (Post) = CALCULATE ( [Non-English Lines per 30 Days], dim_date[campaign_period] = "Post-campaign" )
```
```dax
Non-English Change % = DIVIDE ( [Non-English per 30 Days (Post)] - [Non-English per 30 Days (Pre)], [Non-English per 30 Days (Pre)] )
```
*(Format both `Change %` measures as **Percentage**, 1 decimal.)*

## 3. Pages

**Map visuals:** if the Map visual shows a warning or stays blank, go to **File → Options and settings → Options → Global → Security** and tick **"Use Map and Filled Map visuals"**, then restart Power BI. If maps are blocked on your PC, use a bar chart of country instead.

### Page 1: Customer Locations (answers BQ1)

*Where are our customers, and how has that changed over time?*

| Visual | Fields |
|---|---|
| 4 × **Card** | `Orders` · `Customers` · `Countries` · `Total Sales` |
| **Map** (bubble) | Location: `dim_location[country_name]` · Bubble size: `Orders` |
| **Line chart** | X-axis: `dim_date[year_quarter]` · Y-axis: `Orders` · Legend: `dim_location[region]` |
| **Matrix** | Rows: `dim_location[region]` · Columns: `dim_date[year_num]` · Values: `Orders` |
| **Table**, top 10 | `dim_location[country_name]`, `Orders`, `Total Sales`. Filter pane → country_name → *Top N* → 10 by `Orders` |
| **Slicer** | `dim_date[year_num]`, style *Tile* (Format → Slicer settings) |

### Page 2: Non-English Demand (answers BQ2, "how has demand changed")

| Visual | Fields |
|---|---|
| 3 × **Card** | `Non-English Lines` · `Non-English Sales` · `Non-English %` |
| **Map** (bubble) | Location: `country_name` · Bubble size: `Non-English Lines` |
| **Stacked column chart** | X-axis: `dim_date[year_quarter]` · Y-axis: `Non-English Lines` · Legend: `dim_book[language_name]` |
| **Line chart** | X-axis: `dim_date[year_quarter]` · Y-axis: `Non-English %` |
| **Matrix** | Rows: `dim_book[language_name]` · Columns: `dim_location[region]` · Values: `Non-English Lines` |

For every visual on this page, add a visual-level filter `dim_book[language_group]` = **Non-English** if needed. The measures already filter, but this keeps English rows out of the language legend.

### Page 3: Channel & Campaign (answers BQ2, "where do they prefer to buy", plus the campaign effect)

| Visual | Fields |
|---|---|
| **Clustered bar chart** | Y-axis: `dim_customer[preferred_channel]` · X-axis: `Non-English Customers` |
| **Matrix** | Rows: `dim_customer[heard_about]` · Columns: `dim_customer[preferred_channel]` · Values: `Non-English Customers` |
| **Clustered column chart** | X-axis: `dim_date[campaign_period]` · Y-axis: `Lines per 30 Days`, `Non-English Lines per 30 Days`. Sort the axis by campaign_period **descending**, so Pre comes before Post. |
| 2 × **Card** | `Lines Change %` · `Non-English Change %` |
| **Slicers** | `dim_location[region]` · `dim_book[language_group]` · `fact_sales[is_cancelled_or_returned]` |

Give each page a title with a **Text box**, e.g. *"Where are our customers? (BQ1)"*.

## 4. Check your numbers

All figures are for the whole period with no slicers applied (cancelled and returned orders included). They were calculated from `gravity_dw` with SQL.

| Measure / visual | Expected |
|---|---|
| Total Sales | **154,966.34** |
| Order Lines | **15,390** |
| Orders | **7,549** |
| Customers (who bought) | **1,747** |
| Countries | **109** |
| Non-English Lines / Sales / % | **820** / **8,537.35** / **5.33%** |
| Top 5 countries by orders | China 1,361 · Indonesia 956 · Russia 480 · Brazil 319 · Portugal 307 |
| Orders by region, 2025 | Asia 1,167 · Europe 776 · South America 250 · North America 202 · Africa 142 · Oceania 17 |
| Top non-English languages (lines) | Spanish 305 · French 210 · German 128 · Japanese 67 · Chinese 21 |
| Top non-English countries (lines) | China 143 · Indonesia 115 · Russia 46 · Brazil 38 · Philippines 37 |
| Non-English customers by channel | Online 384 · Physical Store 148 · Book Club 69 · Other 34 · No response 1 |
| Lines per 30 days, Pre / Post / Change | 419.7 / 425.1 / **+1.3%** |
| Non-English lines per 30 days, Pre / Post / Change | 21.6 / 24.0 / **+11.3%** |
| Non-English %, Pre / Post | 5.14% / 5.65% |
| Excluding cancelled/returned | 14,400 lines · 145,104.43 sales |

**Partial periods:** sales start on 29 Oct 2023 and end on 27 Oct 2026, so 2023-Q4 and 2026-Q4 look low on the quarterly charts. Say this in the report, or filter those two quarters out.

## 5. How the dashboard answers the questions (for the report)

- **BQ1, where are customers:** the map and top-10 table show demand concentrated in Asia (China and Indonesia alone are about 30% of orders), then Europe and South America.
  **Change over time:** the region × year matrix and the quarterly line chart show each region's trend. Use the year slicer to compare years.
- **BQ2, where non-English books are bought:**
  - *Geographically:* the non-English map follows the overall pattern (China, Indonesia, Russia).
  - *By channel:* non-English buyers mostly prefer **Online** (384 of 636 non-English buyers, 60%), then Physical Store (148).
  - *By language:* Spanish, French and German lead.
- **BQ2, demand over time and the campaign:** non-English lines per 30 days rose **about 11%** after the assumed campaign start, versus about 1% for all lines. The non-English share rose from 5.1% to 5.7%.
- **Caveat:** the campaign date (2025-10-01) is an assumption, and the order data is randomly generated, so these differences can't be read as a proven campaign effect. The dashboard provides the means to measure it on real data.
