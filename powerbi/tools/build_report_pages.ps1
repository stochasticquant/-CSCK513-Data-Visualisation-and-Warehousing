# build_report_pages.ps1
# Writes the three dashboard pages (Customer Locations, Non-English Demand, Channel & Campaign)
# into Gravity_Marketing.pbix, using the PBIR report format that this Power BI version stores
# inside the .pbix (Report/definition/pages/<page>/visuals/<visual>/visual.json).
# The data model (tables, relationships, measures) is copied unchanged.
# Power BI Desktop must be CLOSED. A backup is kept as Gravity_Marketing_before_pages.pbix.
# Run with PowerShell 7.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$dir    = Split-Path $PSScriptRoot -Parent
$pbix   = Join-Path $dir 'Gravity_Marketing.pbix'
$backup = Join-Path $dir 'Gravity_Marketing_before_pages.pbix'
if (-not (Test-Path $backup)) { Copy-Item $pbix $backup }

$VC = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definition/visualContainer/2.13.0/schema.json'
$PG = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definition/page/2.1.0/schema.json'
$PS = 'https://developer.microsoft.com/json-schemas/fabric/item/report/definition/pagesMetadata/1.1.0/schema.json'

# ---------- field and visual helpers ----------
function C([string]$t, [string]$c, [string]$label) { @{ k = 'Column';  t = $t; p = $c; n = $label } }   # label = friendly header
function M([string]$m)             { @{ k = 'Measure'; t = 'fact_sales'; p = $m } }
function FieldExpr($f) { @{ $f.k = [ordered]@{ Expression = @{ SourceRef = @{ Entity = $f.t } }; Property = $f.p } } }
function Proj($f) {
    $p = [ordered]@{ field = (FieldExpr $f); queryRef = "$($f.t).$($f.p)"; nativeQueryRef = $f.p }
    if ($f.n) { $p.displayName = $f.n }
    $p
}
function Lit([string]$v) { @{ expr = @{ Literal = @{ Value = $v } } } }
function Str([string]$s) { Lit ("'" + $s.Replace("'", "''") + "'") }

function Visual([string]$name, [int]$x, [int]$y, [int]$w, [int]$h, [string]$type, $roles, [string]$title,
                $sortField = $null, [string]$sortDir = 'Descending', $objects = $null) {
    $qs = [ordered]@{}
    foreach ($role in $roles.Keys) { $qs[$role] = @{ projections = @($roles[$role] | ForEach-Object { Proj $_ }) } }
    $query = [ordered]@{ queryState = $qs }
    if ($sortField) { $query.sortDefinition = [ordered]@{ sort = @(@{ field = (FieldExpr $sortField); direction = $sortDir }); isDefaultSort = $false } }
    $visual = [ordered]@{ visualType = $type; query = $query }
    if ($objects) { $visual.objects = $objects }
    # Our own title; the automatic subtitle ("Orders by country_name") is switched off
    $vco = [ordered]@{ subTitle = @(@{ properties = @{ show = (Lit 'false') } }) }
    if ($title) { $vco.title = @(@{ properties = [ordered]@{ show = (Lit 'true'); text = (Str $title) } }) }
    $visual.visualContainerObjects = $vco
    $visual.drillFilterOtherVisuals = $true
    [ordered]@{ '$schema' = $VC; name = $name; position = [ordered]@{ x = $x; y = $y; z = 0; width = $w; height = $h }; visual = $visual }
}
function Card([string]$name, [int]$x, [int]$y, [int]$w, [int]$h, $measure) {
    # Display units = None, so 154,966.34 is shown in full rather than 154.97K
    $obj = @{ labels = @(@{ properties = @{ labelDisplayUnits = (Lit '1D') } }) }
    Visual $name $x $y $w $h 'card' @{ Values = @($measure) } $null $null 'Descending' $obj
}
function Slicer([string]$name, [int]$x, [int]$y, [int]$w, [int]$h, $col) {
    # The slicer header shows the field's friendly label, so no separate title
    $obj = @{ data = @(@{ properties = @{ mode = (Str 'Dropdown') } }) }
    Visual $name $x $y $w $h 'slicer' @{ Values = @($col) } $null $null 'Ascending' $obj
}
function Title([string]$name, [string]$text, [string]$sub) {
    $runs = @(@{ textRuns = @(@{ value = $text; textStyle = @{ fontSize = '22pt'; fontWeight = 'bold' } }) })
    if ($sub) { $runs += @{ textRuns = @(@{ value = $sub; textStyle = @{ fontSize = '12pt' } }) } }
    [ordered]@{ '$schema' = $VC; name = $name; position = [ordered]@{ x = 20; y = 10; z = 0; width = 1440; height = 80 }
                visual = [ordered]@{ visualType = 'textbox'; objects = @{ general = @(@{ properties = @{ paragraphs = $runs } }) }; drillFilterOtherVisuals = $true } }
}

# ---------- common fields ----------
$country  = C 'dim_location' 'country_name' 'Country'; $region = C 'dim_location' 'region' 'Region'
$quarter  = C 'dim_date' 'year_quarter' 'Quarter';     $year   = C 'dim_date' 'year_num' 'Year'; $campaign = C 'dim_date' 'campaign_period' 'Period'
$language = C 'dim_book' 'language_name' 'Language';   $langGroup = C 'dim_book' 'language_group' 'Language group'
$channel  = C 'dim_customer' 'preferred_channel' 'Preferred channel'; $heard = C 'dim_customer' 'heard_about' 'Heard about Gravity via'
$cancelled = C 'fact_sales' 'is_cancelled_or_returned' 'Cancelled or returned'
$partial  = ' (2023-Q4 and 2026-Q4 are partial quarters)'

# ---------- Page 1: Customer Locations (BQ1) ----------
$p1 = @(
    (Title 'p1_title' 'Where are our customers? (BQ1)' ('Orders by destination country and region, and how the mix changes over time' + $partial)),
    (Slicer 'p1_slicer_year' 1500 10 400 80 $year),
    (Card 'p1_card_orders'    20  100 455 130 (M 'Orders')),
    (Card 'p1_card_customers' 495 100 455 130 (M 'Customers')),
    (Card 'p1_card_countries' 970 100 455 130 (M 'Countries')),
    (Card 'p1_card_sales'     1445 100 455 130 (M 'Total Sales')),
    (Visual 'p1_map_orders' 20 250 930 450 'map' ([ordered]@{ Category = @($country); Size = @((M 'Orders')) }) 'Orders by country'),
    (Visual 'p1_table_top_countries' 970 250 930 450 'tableEx' @{ Values = @($country, $region, (M 'Orders'), (M 'Customers'), (M 'Total Sales')) } 'Countries ranked by orders' (M 'Orders')),
    (Visual 'p1_line_region_quarter' 20 720 930 340 'lineChart' ([ordered]@{ Category = @($quarter); Y = @((M 'Orders')); Series = @($region) }) 'Orders by region per quarter' $quarter 'Ascending'),
    (Visual 'p1_matrix_region_year' 970 720 930 340 'pivotTable' ([ordered]@{ Rows = @($region); Columns = @($year); Values = @((M 'Orders')) }) 'Orders by region and year')
)

# ---------- Page 2: Non-English Demand (BQ2: demand over time) ----------
$p2 = @(
    (Title 'p2_title' 'How has demand for non-English books changed? (BQ2)' ('Order lines for books not in English, by country, language and quarter' + $partial)),
    (Slicer 'p2_slicer_region' 1500 10 400 80 $region),
    (Card 'p2_card_ne_lines' 20   100 613 130 (M 'Non-English Lines')),
    (Card 'p2_card_ne_sales' 653  100 613 130 (M 'Non-English Sales')),
    (Card 'p2_card_ne_pct'   1286 100 614 130 (M 'Non-English %')),
    (Visual 'p2_map_ne' 20 250 930 450 'map' ([ordered]@{ Category = @($country); Size = @((M 'Non-English Lines')) }) 'Non-English order lines by country'),
    (Visual 'p2_column_language_quarter' 970 250 930 450 'columnChart' ([ordered]@{ Category = @($quarter); Y = @((M 'Non-English Lines')); Series = @($language) }) 'Non-English order lines per quarter, by language' $quarter 'Ascending'),
    (Visual 'p2_line_ne_pct' 20 720 930 340 'lineChart' ([ordered]@{ Category = @($quarter); Y = @((M 'Non-English %')) }) 'Non-English share of order lines per quarter' $quarter 'Ascending'),
    (Visual 'p2_matrix_language_region' 970 720 930 340 'pivotTable' ([ordered]@{ Rows = @($language); Columns = @($region); Values = @((M 'Non-English Lines')) }) 'Non-English order lines: language by region' (M 'Non-English Lines'))
)

# ---------- Page 3: Channel & Campaign (BQ2: where they prefer to buy + campaign) ----------
$p3 = @(
    (Title 'p3_title' 'Where do non-English buyers prefer to buy, and did the campaign help? (BQ2)' 'Preferred channel from the customer survey; campaign assumed to start 2025-10-01, compared per 30 days'),
    (Slicer 'p3_slicer_region'    20  100 380 90 $region),
    (Slicer 'p3_slicer_language'  420 100 380 90 $langGroup),
    (Slicer 'p3_slicer_cancelled' 820 100 380 90 $cancelled),
    (Card 'p3_card_lines_change' 1220 100 330 130 (M 'Lines Change %')),
    (Card 'p3_card_ne_change'    1570 100 330 130 (M 'Non-English Change %')),
    (Visual 'p3_bar_channel' 20 250 930 400 'clusteredBarChart' ([ordered]@{ Category = @($channel); Y = @((M 'Non-English Customers')) }) 'Non-English buyers by preferred buying channel' (M 'Non-English Customers')),
    (Visual 'p3_column_ne_per30' 970 250 455 400 'clusteredColumnChart' ([ordered]@{ Category = @($campaign); Y = @((M 'Non-English Lines per 30 Days')) }) 'Non-English lines per 30 days' $campaign 'Descending'),
    (Visual 'p3_column_ne_pct' 1445 250 455 400 'clusteredColumnChart' ([ordered]@{ Category = @($campaign); Y = @((M 'Non-English %')) }) 'Non-English share' $campaign 'Descending'),
    (Visual 'p3_matrix_heard_channel' 20 670 930 390 'pivotTable' ([ordered]@{ Rows = @($heard); Columns = @($channel); Values = @((M 'Non-English Customers')) }) 'Non-English buyers: how they heard of Gravity vs preferred channel'),
    (Visual 'p3_table_campaign' 970 670 930 390 'tableEx' @{ Values = @($campaign, (M 'Days in Period'), (M 'Lines per 30 Days'), (M 'Non-English Lines per 30 Days'), (M 'Non-English %'), (M 'Customers')) } 'Before vs after the campaign' $campaign 'Descending')
)

$pages = [ordered]@{
    '47774db8cb3f7b317486' = @{ display = 'Customer Locations'; visuals = $p1 }   # the existing empty page, reused
    'a1c2e3f4a5b6c7d8e9f0' = @{ display = 'Non-English Demand'; visuals = $p2 }
    'b1d2f3a4b5c6d7e8f9a0' = @{ display = 'Channel & Campaign'; visuals = $p3 }
}

# ---------- write a new .pbix ----------
function ToJson($o) { $o | ConvertTo-Json -Depth 40 -Compress }
$utf8 = New-Object Text.UTF8Encoding($false)
$tmp = "$pbix.tmp"
if (Test-Path $tmp) { Remove-Item $tmp }
$src = [IO.Compression.ZipFile]::OpenRead($backup)
$dst = [IO.Compression.ZipFile]::Open($tmp, 'Create')
function AddText([string]$path, [string]$text) {
    $e = $dst.CreateEntry($path, 'Optimal'); $s = $e.Open(); $b = $utf8.GetBytes($text); $s.Write($b, 0, $b.Length); $s.Close()
}
foreach ($e in $src.Entries) {
    if ($e.FullName -like 'Report/definition/pages/*') { continue }   # rewritten below
    if ($e.FullName -eq 'SecurityBindings') { continue }              # signature of the old report; Power BI recreates it
    if ($e.FullName -eq '[Content_Types].xml') {
        $r = New-Object IO.StreamReader($e.Open()); $xml = $r.ReadToEnd(); $r.Close()
        AddText $e.FullName ($xml -replace '<Override PartName="/SecurityBindings" ContentType="" />', '')
        continue
    }
    $n = $dst.CreateEntry($e.FullName, 'Optimal'); $in = $e.Open(); $out = $n.Open(); $in.CopyTo($out); $out.Close(); $in.Close()
}
AddText 'Report/definition/pages/pages.json' (ToJson ([ordered]@{ '$schema' = $PS; pageOrder = @($pages.Keys); activePageName = @($pages.Keys)[0] }))
foreach ($id in $pages.Keys) {
    AddText "Report/definition/pages/$id/page.json" (ToJson ([ordered]@{ '$schema' = $PG; name = $id; displayName = $pages[$id].display; displayOption = 'FitToPage'; height = 1080; width = 1920 }))
    foreach ($v in $pages[$id].visuals) { AddText "Report/definition/pages/$id/visuals/$($v.name)/visual.json" (ToJson $v) }
}
$dst.Dispose(); $src.Dispose()
Move-Item $tmp $pbix -Force
"Wrote $($pages.Count) pages, $(($pages.Values | ForEach-Object { $_.visuals.Count } | Measure-Object -Sum).Sum) visuals to $pbix (backup: $backup)"
