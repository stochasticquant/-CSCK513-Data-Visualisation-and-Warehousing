# Q3 – How do book cost and number of pages affect the number of books sold?

Script: `Q3_price_and_pages_vs_units_sold.sql` · Power BI views: `rpt.v_sales_by_price_band`,
`rpt.v_book_sales`, `rpt.v_price_pages_correlation`

## The question

> How do the cost of the book and the number of pages affect the number of books sold?

We want to know: do cheaper books sell more? Do long books sell fewer copies?

## First, what is "the cost of the book"?

The `book` table in the source database has **no price column**. The price is stored on each
**order line**, and the same book was sold at different prices on different orders (for
example, one book sold for 1.98 once and 19.83 another time). So the script uses two views of
price:

- **Price of each sale.** Used to group sales into price bands (query 3a).
- **A book's average selling price.** Used when we look at one row per book (3c, 3d).

## The script has four queries

### 3a – Units sold by price band

```sql
CASE WHEN sales_amount <  5 THEN '1. Under 5'
     WHEN sales_amount < 10 THEN '2. 5 - 9.99'
     WHEN sales_amount < 15 THEN '3. 10 - 14.99'
     ELSE                        '4. 15 and over' END AS price_band
```

- `CASE` puts each sale into a **band** (a bucket). The rules are checked in order, so a sale of
  7.50 fails the first rule (< 5), matches the second (< 10), and stops there.
- The numbers `1.`, `2.` at the front make the bands sort in the right order. Without them,
  "10 - 14.99" would sort before "5 - 9.99" because text is sorted character by character.
- `GROUP BY` the same `CASE` expression then counts the sales in each band.

| Price band | Units sold | Sales | Avg price |
|---|---|---|---|
| Under 5 | 3,770 | 9,345.81 | 2.48 |
| 5 – 9.99 | 3,835 | 28,719.18 | 7.49 |
| 10 – 14.99 | 3,898 | 48,817.22 | 12.52 |
| 15 and over | 3,887 | 68,084.13 | 17.52 |

**Reading it:** each band sells almost **the same number of books** (about 3,800). Cheap books
don't sell more copies. Expensive books bring in far more **money** simply because each sale is
worth more.

### 3b – Units sold by page band, per book

```sql
FROM dim_book b LEFT JOIN fact_sales f ON f.book_key = b.book_key
```

Two important ideas here:

**`LEFT JOIN` instead of `JOIN`.** A normal (inner) `JOIN` only keeps books that have at least
one sale. A `LEFT JOIN` keeps **every book** from `dim_book`, and for books that never sold, the
sales columns come back empty (`NULL`). `COUNT(f.sales_key)` then gives 0 for those books. This
matters because "how many books never sold" is part of the answer.

**Average per book, not the total.** There are 5,102 books with 200–399 pages but only 438 with
800+ pages. Of course the bigger group sells more in total, because it has more books. To compare
fairly, we divide by the number of books: `AVG(units * 1.0)`. The `* 1.0` forces decimal maths;
otherwise SQL rounds the average of whole numbers down to a whole number.

| Page band | Books | Units sold | Avg units per book | % never sold |
|---|---|---|---|---|
| Under 200 | 2,824 | 3,875 | 1.372 | 14.6% |
| 200 – 399 | 5,102 | 7,140 | 1.399 | 13.6% |
| 400 – 599 | 2,049 | 2,787 | 1.360 | 15.5% |
| 600 – 799 | 637 | 890 | 1.397 | 13.3% |
| 800 and over | 438 | 596 | 1.361 | 16.7% |

**Reading it:** every page band sells about **1.4 copies per book**. Length makes no real
difference.

### 3c – One row per book for a scatter plot

This simply lists every book that sold with its pages, average price, units and sales. It is
the raw data for a **scatter plot** in Power BI (pages on one axis, price on the other, bubble
size = units). If there were a pattern, you would see the bubbles bunch up somewhere; here they
are spread evenly.

### 3d – Correlation coefficients

Correlation (`r`) is a single number from −1 to +1 that measures how strongly two things move
together:

| r | Meaning |
|---|---|
| +1 | Perfect: when one goes up, the other always goes up |
| 0 | No relationship at all |
| −1 | Perfect opposite: when one goes up, the other always goes down |

SQL Server has no built-in `CORREL` function, so the script uses the textbook formula:

```sql
(AVG(units*price) - AVG(units)*AVG(price)) / (STDEVP(units) * STDEVP(price))
```

This is "covariance ÷ (SD of x × SD of y)". `STDEVP` is the standard deviation of the whole
population (every book), which is the right partner for this formula. The values are converted
to `float` first so the maths isn't rounded.

| Books | r (units vs price) | r (units vs pages) | r (price vs pages) |
|---|---|---|---|
| 9,470 | 0.001 | 0.002 | −0.004 |

## What this tells us

- **Price does not affect how many books are sold** (r = 0.001). Each price band sells about
  3,800 units.
- **Page count does not affect how many books are sold** (r = 0.002). Every length band
  averages about 1.4 copies per book.
- Price and pages aren't related either: long books are not more expensive.
- The order data in the Gravity database was **randomly generated**, which explains why no
  pattern appears. "No relationship" is a valid and honest finding to report.

## Ideas to try

- Change the price band boundaries (e.g. steps of 2.50) and check the pattern still holds.
- Add a `WHERE b.language_group = 'English'` filter to see if the result changes for one
  group of books.
