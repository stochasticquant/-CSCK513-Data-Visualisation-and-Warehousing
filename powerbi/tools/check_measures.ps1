# check_measures.ps1
# Evaluates the dashboard measures in the open Power BI file with DAX queries, so the
# results can be compared with the SQL figures in docs/PowerBI_Guide.md section 5.
$ErrorActionPreference = 'Stop'
$bin = (Get-AppxPackage Microsoft.MicrosoftPowerBIDesktop).InstallLocation + '\bin'
[void][Reflection.Assembly]::LoadFrom((Join-Path $bin 'Microsoft.PowerBI.AdomdClient.dll'))
$portFile = Get-ChildItem "$env:USERPROFILE\Microsoft\Power BI Desktop Store App\AnalysisServicesWorkspaces",
                          "$env:LOCALAPPDATA\Microsoft\Power BI Desktop\AnalysisServicesWorkspaces" `
                -Recurse -Filter msmdsrv.port.txt -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
$port = ([IO.File]::ReadAllText($portFile.FullName) -replace "`0", '').Trim()
$conn = New-Object Microsoft.AnalysisServices.AdomdClient.AdomdConnection("Data Source=localhost:$port")
$conn.Open()

function Run-Dax([string]$title, [string]$dax) {
    "--- $title"
    $cmd = $conn.CreateCommand(); $cmd.CommandText = $dax
    $r = $cmd.ExecuteReader()
    $names = 0..($r.FieldCount - 1) | ForEach-Object { ($r.GetName($_) -replace '^.*\[|\]$', '') }
    $rows = while ($r.Read()) {
        $o = [ordered]@{}
        for ($i = 0; $i -lt $r.FieldCount; $i++) { $v = $r.GetValue($i); if ($v -is [double] -or $v -is [decimal]) { $v = [math]::Round([double]$v, 4) }; $o[$names[$i]] = $v }
        [pscustomobject]$o
    }
    $r.Close()
    $rows | Format-Table -AutoSize | Out-String -Width 200
}

Run-Dax 'Totals' 'EVALUATE ROW ( "Total Sales", [Total Sales], "Order Lines", [Order Lines], "Orders", [Orders], "Customers", [Customers], "Countries", [Countries], "NE Lines", [Non-English Lines], "NE Sales", [Non-English Sales], "NE %", [Non-English %] )'
Run-Dax 'Campaign' 'EVALUATE ROW ( "Lines/30d Pre", [Lines per 30 Days (Pre)], "Lines/30d Post", [Lines per 30 Days (Post)], "Lines Chg", [Lines Change %], "NE/30d Pre", [Non-English per 30 Days (Pre)], "NE/30d Post", [Non-English per 30 Days (Post)], "NE Chg", [Non-English Change %], "NE% Pre", [Non-English % (Pre)], "NE% Post", [Non-English % (Post)] )'
Run-Dax 'Non-English customers by channel' 'EVALUATE SUMMARIZECOLUMNS ( dim_customer[preferred_channel], "NE Customers", [Non-English Customers] ) ORDER BY [NE Customers] DESC'
Run-Dax 'Top 5 countries by orders' 'EVALUATE TOPN ( 5, SUMMARIZECOLUMNS ( dim_location[country_name], "Orders", [Orders] ), [Orders], DESC ) ORDER BY [Orders] DESC'
Run-Dax 'Excluding cancelled/returned' 'EVALUATE ROW ( "Lines", CALCULATE ( [Order Lines], fact_sales[is_cancelled_or_returned] = FALSE () ), "Sales", CALCULATE ( [Total Sales], fact_sales[is_cancelled_or_returned] = FALSE () ) )'
$conn.Close()
