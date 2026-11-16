# grid_layout_extract.ps1
# Rearranges the 11 data flows inside "SEQ Extract OLTP" into a 4-column grid in the
# Visual Studio copy of Extract_To_Staging.dtsx, so the control-flow screenshot is readable.
# Only the designer layout (DesignTimeProperties) changes; runtime behaviour is untouched.
# A backup is written next to the package first.
$ErrorActionPreference = 'Stop'
$file = Join-Path $PSScriptRoot '..\GravityETL\Extract_To_Staging.dtsx'
Copy-Item $file "$file.bak" -Force
$x = [IO.File]::ReadAllText($file)
$inv = [Globalization.CultureInfo]::InvariantCulture

function Set-Attr([string]$id, [string]$attr, [string]$value) {
    $pattern = '(Id="' + [regex]::Escape($id) + '"\s+' + $attr + '=")[^"]*(")'
    if (-not [regex]::IsMatch($script:x, $pattern)) {
        # attribute may come before Id (e.g. Size, PanelSize)
        # (?<!\w) stops 'Size' from matching inside 'PanelSize'
        $pattern = '((?<!\w)' + $attr + '=")[^"]*("(?:\s+\w+="[^"]*")*\s+Id="' + [regex]::Escape($id) + '")'
    }
    if (-not [regex]::IsMatch($script:x, $pattern)) { throw "Not found: $attr of $id" }
    $script:x = [regex]::Replace($script:x, $pattern, '${1}' + $value + '${2}')
}
function P([double]$a, [double]$b) { $a.ToString($inv) + ',' + $b.ToString($inv) }

$dfts = 'address','book','book_language','country','cust_order','customer',
        'order_history','order_line','order_status','publisher','shipping_method'
$cols = 4; $colW = 230; $rowH = 70; $nodeW = 187
for ($i = 0; $i -lt $dfts.Count; $i++) {
    $c = $i % $cols; $r = [math]::Floor($i / $cols)
    Set-Attr "Package\SEQ Extract OLTP\DFT $($dfts[$i])" 'TopLeft' (P (5.5 + $c * $colW) (5.5 + $r * $rowH))
}

# Container: sized to the grid and centred on the arrows (x = 1170.5)
$panelW = $cols * $colW - ($colW - $nodeW) + 11
$panelH = 3 * $rowH - ($rowH - 42) + 11
$header = 43
$left = 1170.5 - $panelW / 2
Set-Attr 'Package\SEQ Extract OLTP' 'PanelSize' (P $panelW $panelH)
Set-Attr 'Package\SEQ Extract OLTP' 'Size' (P $panelW ($panelH + $header))
Set-Attr 'Package\SEQ Extract OLTP' 'TopLeft' (P $left 107.5)

# Shift everything below the container down by the change in its height (was 146)
$dy = ($panelH + $header) - 146
Set-Attr 'Package.PrecedenceConstraints[{7ABF56F5-C3FC-4941-BA65-265FBC73A96A\}]' 'TopLeft' (P 1170.5 (253.5 + $dy))
Set-Attr 'Package\SEQ Extract files' 'TopLeft' (P 978.5 (313.5 + $dy))
Set-Attr 'Package.PrecedenceConstraints[{F3E2E914-A82F-46C0-81BD-46F22C87300F\}]' 'TopLeft' (P 1170.5 (459.5 + $dy))
Set-Attr 'Package\SQL Log row counts' 'TopLeft' (P 1081.5 (519.5 + $dy))

[IO.File]::WriteAllText($file, $x, (New-Object Text.UTF8Encoding($true)))
"Layout updated (container $panelW x $($panelH + $header), shifted lower items by $dy). Backup: $file.bak"
