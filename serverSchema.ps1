param(
    [Parameter(Mandatory = $true)]
    [string]$ServerInstance,

    [Parameter(Mandatory = $true)]
    [string]$OutputFile,

    [string]$Username,
    [string]$Password
)

Write-Host "============================================================"
Write-Host "SCHEMA EXTRACTION DISCLAIMER"
Write-Host "This script extracts ONLY SQL Server schema structure metadata."
Write-Host "No actual table data / row content will be extracted."
Write-Host "Only databases, tables, columns, data types, and indexes are collected"
Write-Host "for structural comparison purposes."
Write-Host "============================================================"
Write-Host ""

$confirmation = Read-Host "Type OK to continue or Cancel to stop"

if ($null -eq $confirmation -or $confirmation.Trim().ToUpper() -ne "OK") {
    Write-Host "Operation cancelled by user."
    exit 0
}

Write-Host "Confirmation accepted. Continuing..."
Write-Host ""

function New-ConnectionString {
    param(
        [string]$Server,
        [string]$Database
    )

    $builder = New-Object System.Data.SqlClient.SqlConnectionStringBuilder
    $builder["Data Source"] = $Server
    $builder["Initial Catalog"] = $Database
    $builder["TrustServerCertificate"] = $true
    $builder["Connect Timeout"] = 15

    if ($Username -and $Password) {
        $builder["Integrated Security"] = $false
        $builder["User ID"] = $Username
        $builder["Password"] = $Password
    }
    else {
        $builder["Integrated Security"] = $true
    }

    return $builder.ConnectionString
}
