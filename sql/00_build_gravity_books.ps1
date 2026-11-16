# 00_build_gravity_books.ps1
# Builds the gravity_books operational database on the local SQL Server
# from the provided scripts in ..\gravity_sqlserver (which are left unchanged).
#
# Fixes applied on top of the provided scripts:
#   1. 01_sqlserver_create.sql has no "USE gravity_books", so the database is
#      created first and every script is run with -d gravity_books.
#   2. The data model has a customer_address -> address_status key that the
#      create script leaves out; it is added at the end as fk_ca_status.
#
# WARNING: scripts 10-13 generate customer addresses, orders, order lines and
# order history at random. Re-running this gives different numbers, so don't
# rebuild after taking screenshots for the report.
#
# Usage:  .\00_build_gravity_books.ps1            (server defaults to localhost)
#         .\00_build_gravity_books.ps1 -Server .\SQLEXPRESS

param([string]$Server = 'localhost')
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot '..\gravity_sqlserver'

function Invoke-Sql([string[]]$sqlArgs) {
    & sqlcmd -S $Server -E -C -b -f 65001 @sqlArgs
    if ($LASTEXITCODE -ne 0) { throw "sqlcmd failed: $sqlArgs" }
}

Write-Host "Creating empty gravity_books on $Server"
Invoke-Sql @('-Q', "IF DB_ID('gravity_books') IS NOT NULL BEGIN ALTER DATABASE gravity_books SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE gravity_books; END; CREATE DATABASE gravity_books;")

foreach ($f in Get-ChildItem $src -Filter '*.sql' | Sort-Object Name) {
    Write-Host "Running $($f.Name)"
    $file = $f.FullName
    if ($f.Name -like '01_*') {
        # Skip the script's own CREATE DATABASE line (the database already exists)
        $file = Join-Path $env:TEMP '01_sqlserver_create_nodb.sql'
        (Get-Content $f.FullName | Where-Object { $_ -notmatch '^\s*CREATE DATABASE' }) | Set-Content $file -Encoding utf8
    }
    Invoke-Sql @('-d', 'gravity_books', '-i', $file, '-o', (Join-Path $env:TEMP "gravity_$($f.BaseName).log"))
}

Write-Host "Adding fk_ca_status"
Invoke-Sql @('-d', 'gravity_books', '-Q', "ALTER TABLE dbo.customer_address ADD CONSTRAINT fk_ca_status FOREIGN KEY (status_id) REFERENCES dbo.address_status (status_id);")

Write-Host "Row counts:"
Invoke-Sql @('-d', 'gravity_books', '-W', '-Q', "SELECT t.name AS table_name, SUM(p.rows) AS row_count FROM sys.tables t JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1) GROUP BY t.name ORDER BY t.name; SELECT COUNT(*) AS foreign_keys FROM sys.foreign_keys;")
