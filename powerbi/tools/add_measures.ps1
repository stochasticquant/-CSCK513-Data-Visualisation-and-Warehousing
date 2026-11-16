# add_measures.ps1
# Adds (or updates) the dashboard's DAX measures in the Power BI file that is open in
# Power BI Desktop. The formulas are the ones listed in docs/PowerBI_Guide.md section 3.
# Run with Windows PowerShell 5.1, then press Ctrl+S in Power BI to save them into the .pbix.
. (Join-Path $PSScriptRoot 'pbi_connect.ps1')
$model = Connect-PbiModel
$fact  = $model.Tables['fact_sales']

$pct2 = '0.00%'; $pct1 = '+0.0%;-0.0%;0.0%'; $int = '#,0'; $money = '#,0.00'; $dec1 = '#,0.0'
$measures = @(
    # name, folder, format, expression
    @('Total Sales',           '1 Sales',       $money, 'SUM ( fact_sales[sales_amount] )'),
    @('Order Lines',           '1 Sales',       $int,   'COUNTROWS ( fact_sales )'),
    @('Orders',                '1 Sales',       $int,   'DISTINCTCOUNT ( fact_sales[order_id] )'),
    @('Customers',             '1 Sales',       $int,   'DISTINCTCOUNT ( fact_sales[customer_key] )'),
    @('Countries',             '1 Sales',       $int,   'CALCULATE ( DISTINCTCOUNT ( dim_location[country_name] ), fact_sales )'),
    @('Non-English Lines',     '2 Non-English', $int,   'CALCULATE ( [Order Lines], dim_book[language_group] = "Non-English" )'),
    @('Non-English Sales',     '2 Non-English', $money, 'CALCULATE ( [Total Sales], dim_book[language_group] = "Non-English" )'),
    @('Non-English Customers', '2 Non-English', $int,   'CALCULATE ( [Customers], dim_book[language_group] = "Non-English" )'),
    @('Non-English %',         '2 Non-English', $pct2,  'DIVIDE ( [Non-English Lines], [Order Lines] )'),
    @('Days in Period',        '3 Campaign',    $int,
      "VAR FirstDay = CALCULATE ( MIN ( dim_date[full_date] ), fact_sales, REMOVEFILTERS ( dim_book ) )`nVAR LastDay  = CALCULATE ( MAX ( dim_date[full_date] ), fact_sales, REMOVEFILTERS ( dim_book ) )`nRETURN IF ( NOT ISBLANK ( FirstDay ), DATEDIFF ( FirstDay, LastDay, DAY ) + 1 )"),
    @('Lines per 30 Days',               '3 Campaign', $dec1, 'DIVIDE ( [Order Lines], [Days in Period] ) * 30'),
    @('Non-English Lines per 30 Days',   '3 Campaign', $dec1, 'DIVIDE ( [Non-English Lines], [Days in Period] ) * 30'),
    @('Lines per 30 Days (Pre)',         '3 Campaign', $dec1, 'CALCULATE ( [Lines per 30 Days], dim_date[campaign_period] = "Pre-campaign" )'),
    @('Lines per 30 Days (Post)',        '3 Campaign', $dec1, 'CALCULATE ( [Lines per 30 Days], dim_date[campaign_period] = "Post-campaign" )'),
    @('Lines Change %',                  '3 Campaign', $pct1, 'DIVIDE ( [Lines per 30 Days (Post)] - [Lines per 30 Days (Pre)], [Lines per 30 Days (Pre)] )'),
    @('Non-English per 30 Days (Pre)',   '3 Campaign', $dec1, 'CALCULATE ( [Non-English Lines per 30 Days], dim_date[campaign_period] = "Pre-campaign" )'),
    @('Non-English per 30 Days (Post)',  '3 Campaign', $dec1, 'CALCULATE ( [Non-English Lines per 30 Days], dim_date[campaign_period] = "Post-campaign" )'),
    @('Non-English Change %',            '3 Campaign', $pct1, 'DIVIDE ( [Non-English per 30 Days (Post)] - [Non-English per 30 Days (Pre)], [Non-English per 30 Days (Pre)] )'),
    @('Non-English % (Pre)',             '3 Campaign', $pct2, 'CALCULATE ( [Non-English %], dim_date[campaign_period] = "Pre-campaign" )'),
    @('Non-English % (Post)',            '3 Campaign', $pct2, 'CALCULATE ( [Non-English %], dim_date[campaign_period] = "Post-campaign" )')
)

foreach ($d in $measures) {
    $m = $fact.Measures.Find($d[0])
    if (-not $m) { $m = New-Object Microsoft.AnalysisServices.Tabular.Measure; $m.Name = $d[0]; $fact.Measures.Add($m) }
    $m.DisplayFolder = $d[1]
    $m.FormatString  = $d[2]
    $m.Expression    = $d[3]
}
$model.SaveChanges() | Out-Null

# Report any measure the engine could not evaluate
$errors = 0
foreach ($m in $fact.Measures) { if ($m.State -ne 'Ready') { $errors++; "ERROR  $($m.Name): $($m.ErrorMessage)" } }
"$($fact.Measures.Count) measures in fact_sales, $errors with errors"
