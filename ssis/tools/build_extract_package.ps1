# build_extract_package.ps1
# Compiles BuildExtractPackage.cs against the SQL Server 2025 SSIS libraries
# and generates ssis\packages\Extract_To_Staging.dtsx.
$ErrorActionPreference = 'Stop'
$tools = $PSScriptRoot
$root  = (Resolve-Path (Join-Path $tools '..\..')).Path
$out   = Join-Path $root 'ssis\packages'
New-Item -ItemType Directory -Force $out | Out-Null

$gac = 'C:\Windows\Microsoft.NET\assembly'
$v   = 'v4.0_17.0.0.0__89845dcd8080cc91'
$refs = @(
    "$gac\GAC_MSIL\Microsoft.SqlServer.ManagedDTS\$v\Microsoft.SqlServer.ManagedDTS.dll",
    "$gac\GAC_MSIL\Microsoft.SqlServer.DTSPipelineWrap\$v\Microsoft.SqlServer.DTSPipelineWrap.dll",
    "$gac\GAC_64\Microsoft.SqlServer.DTSRuntimeWrap\$v\Microsoft.SqlServer.DTSRuntimeWrap.dll"
)
$exe = Join-Path $env:TEMP 'BuildExtractPackage.exe'
$csc = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
& $csc /nologo /platform:x64 /out:$exe ($refs | ForEach-Object { "/r:$_" }) (Join-Path $tools 'BuildExtractPackage.cs')
if ($LASTEXITCODE -ne 0) { throw 'Compile failed' }

& $exe $root (Join-Path $out 'Extract_To_Staging.dtsx')
if ($LASTEXITCODE -ne 0) { throw 'Package generation failed validation' }
