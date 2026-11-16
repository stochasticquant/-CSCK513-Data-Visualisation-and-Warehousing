# pbi_connect.ps1
# Shared helper: connects to the model of the Power BI Desktop file that is currently open,
# using Power BI's own Tabular Object Model (TOM) libraries.
# Dot-source it from Windows PowerShell 5.1:  . .\pbi_connect.ps1 ; $model = Connect-PbiModel
$ErrorActionPreference = 'Stop'

function Connect-PbiModel {
    $bin = (Get-AppxPackage Microsoft.MicrosoftPowerBIDesktop).InstallLocation + '\bin'
    foreach ($dll in 'Microsoft.AnalysisServices.Server.Core.dll', 'Microsoft.AnalysisServices.Server.Tabular.dll',
                     'Microsoft.AnalysisServices.Server.Tabular.Json.dll') {
        [void][Reflection.Assembly]::LoadFrom((Join-Path $bin $dll))
    }
    # Power BI Desktop's local Analysis Services port (newest workspace = the open file)
    $portFile = Get-ChildItem "$env:USERPROFILE\Microsoft\Power BI Desktop Store App\AnalysisServicesWorkspaces",
                              "$env:LOCALAPPDATA\Microsoft\Power BI Desktop\AnalysisServicesWorkspaces" `
                    -Recurse -Filter msmdsrv.port.txt -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $portFile) { throw 'Power BI Desktop does not seem to be running with a file open' }
    $port = ([IO.File]::ReadAllText($portFile.FullName) -replace "`0", '').Trim()
    $server = New-Object Microsoft.AnalysisServices.Tabular.Server
    $server.Connect("localhost:$port")
    $script:PbiServer = $server
    return $server.Databases[0].Model
}
