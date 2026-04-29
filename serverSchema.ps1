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
Write-Host "You entered: [$confirmation]"

if ([string]::IsNullOrWhiteSpace($confirmation) -or $confirmation.Trim().ToUpper() -ne "OK") {
    Write-Host "Operation cancelled by user."
    exit 0
}

Write-Host "Confirmation accepted. Script will continue now..."
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

function Invoke-SqlQuery {
    param(
        [string]$Database = "master",
        [string]$Query
    )

    $connectionString = New-ConnectionString -Server $ServerInstance -Database $Database

    # ------------------------------------------------------------
    # Primary path: SqlDataReader -> PSCustomObject[]
    # ------------------------------------------------------------
    try {
        $connection = New-Object System.Data.SqlClient.SqlConnection $connectionString
        $command = $connection.CreateCommand()
        $command.CommandText = $Query
        $command.CommandTimeout = 0

        $rows = @()
        $reader = $null

        try {
            $connection.Open()
            $reader = $command.ExecuteReader()

            while ($reader.Read()) {
                $obj = [ordered]@{}
                for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                    $name = $reader.GetName($i)
                    if ($reader.IsDBNull($i)) {
                        $obj[$name] = $null
                    }
                    else {
                        $obj[$name] = $reader.GetValue($i)
                    }
                }
                $rows += [pscustomobject]$obj
            }

            Write-Host "Query mode: SqlDataReader"
            return @($rows)
        }
        finally {
            if ($reader -ne $null) {
                $reader.Close()
            }
            if ($connection.State -ne 'Closed') {
                $connection.Close()
            }
            $connection.Dispose()
        }
    }
    catch {
        Write-Warning "SqlDataReader mode failed for database [$Database]. Falling back to DataAdapter mode. Error: $($_.Exception.Message)"
    }

    # ------------------------------------------------------------
    # Fallback path: DataAdapter -> DataTable -> PSCustomObject[]
    # ------------------------------------------------------------
    $connection2 = New-Object System.Data.SqlClient.SqlConnection $connectionString
    $command2 = $connection2.CreateCommand()
    $command2.CommandText = $Query
    $command2.CommandTimeout = 0

    $adapter = New-Object System.Data.SqlClient.SqlDataAdapter $command2
    $dataSet = New-Object System.Data.DataSet

    try {
        $connection2.Open()
        [void]$adapter.Fill($dataSet)

        $rows = @()

        if ($dataSet.Tables.Count -gt 0) {
            foreach ($row in $dataSet.Tables[0].Rows) {
                $obj = [ordered]@{}
                foreach ($col in $dataSet.Tables[0].Columns) {
                    $colName = $col.ColumnName
                    if ($row.IsNull($colName)) {
                        $obj[$colName] = $null
                    }
                    else {
                        $obj[$colName] = $row[$colName]
                    }
                }
                $rows += [pscustomobject]$obj
            }
        }

        Write-Host "Query mode: DataAdapter fallback"
        return @($rows)
    }
    finally {
        if ($connection2.State -ne 'Closed') {
            $connection2.Close()
        }
        $connection2.Dispose()
    }
}

Write-Host "Connecting to SQL Server instance: $ServerInstance"
Write-Host ""

$serverInfoQuery = @"
SELECT
    CAST(@@SERVERNAME AS nvarchar(128)) AS ServerName,
    CAST(SERVERPROPERTY('ServerName') AS nvarchar(128)) AS ServerProperty_ServerName,
    CAST(SERVERPROPERTY('MachineName') AS nvarchar(128)) AS MachineName,
    CAST(SERVERPROPERTY('InstanceName') AS nvarchar(128)) AS InstanceName,
    CAST(SERVERPROPERTY('Edition') AS nvarchar(128)) AS Edition,
    CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(128)) AS ProductVersion,
    CAST(SERVERPROPERTY('ProductLevel') AS nvarchar(128)) AS ProductLevel,
    CAST(SERVERPROPERTY('EngineEdition') AS nvarchar(128)) AS EngineEdition;
"@

$serverInfoRows = @(Invoke-SqlQuery -Database "master" -Query $serverInfoQuery)

if ($serverInfoRows.Count -eq 0) {
    throw "Could not retrieve server verification details from [$ServerInstance]."
}

$serverInfo = $serverInfoRows[0]

Write-Host "SERVER VERIFICATION"
Write-Host "  Requested ServerInstance : $ServerInstance"
Write-Host "  @@SERVERNAME             : $($serverInfo.ServerName)"
Write-Host "  ServerProperty Name      : $($serverInfo.ServerProperty_ServerName)"
Write-Host "  Machine Name             : $($serverInfo.MachineName)"
Write-Host "  Instance Name            : $($serverInfo.InstanceName)"
Write-Host "  Edition                  : $($serverInfo.Edition)"
Write-Host "  Product Version          : $($serverInfo.ProductVersion)"
Write-Host "  Product Level            : $($serverInfo.ProductLevel)"
Write-Host "  Engine Edition           : $($serverInfo.EngineEdition)"
Write-Host ""

$dbQuery = @"
SELECT CAST(name AS nvarchar(128)) AS name
FROM sys.databases
WHERE database_id > 4
  AND state_desc = 'ONLINE'
ORDER BY name;
"@

Write-Host "Loading non-system online databases..."
$databaseRows = @(Invoke-SqlQuery -Database "master" -Query $dbQuery)

Write-Host "Databases to process: $($databaseRows.Count)"
foreach ($db in $databaseRows) {
    Write-Host "  - $($db.name)"
}
Write-Host ""

$snapshot = [ordered]@{
    disclaimer = "This file contains ONLY SQL Server schema structure metadata. No actual table data / row content has been extracted. The content is limited to databases, tables, columns, types, and indexes for structural comparison."
    server = [ordered]@{
        requested_server_instance = $ServerInstance
        detected_server_name      = [string]$serverInfo.ServerName
        server_property_name      = [string]$serverInfo.ServerProperty_ServerName
        machine_name              = [string]$serverInfo.MachineName
        instance_name             = if ($null -eq $serverInfo.InstanceName) { "" } else { [string]$serverInfo.InstanceName }
        edition                   = [string]$serverInfo.Edition
        product_version           = [string]$serverInfo.ProductVersion
        product_level             = [string]$serverInfo.ProductLevel
        engine_edition            = [string]$serverInfo.EngineEdition
    }
    extracted = (Get-Date).ToString("s")
    databases = @()
    failed_databases = @()
}

foreach ($db in $databaseRows) {
    $dbName = [string]$db.name

    if ([string]::IsNullOrWhiteSpace($dbName)) {
        Write-Warning "Skipping one database row because the name is empty."
        continue
    }

    Write-Host "Extracting schema structure from database [$dbName]..."

    try {
        $columnsQuery = @"
SELECT
    CAST(s.name AS nvarchar(128)) AS SchemaName,
    CAST(t.name AS nvarchar(128)) AS TableName,
    c.column_id AS ColumnId,
    CAST(c.name AS nvarchar(128)) AS ColumnName,
    CAST(ty.name AS nvarchar(128)) AS DataType,
    c.max_length AS MaxLength,
    c.precision AS [Precision],
    c.scale AS Scale,
    c.is_nullable AS IsNullable,
    c.is_identity AS IsIdentity,
    c.is_computed AS IsComputed,
    CAST(dc.definition AS nvarchar(max)) AS DefaultDefinition
FROM sys.tables t
INNER JOIN sys.schemas s
    ON t.schema_id = s.schema_id
INNER JOIN sys.columns c
    ON t.object_id = c.object_id
INNER JOIN sys.types ty
    ON c.user_type_id = ty.user_type_id
LEFT JOIN sys.default_constraints dc
    ON c.default_object_id = dc.object_id
WHERE t.is_ms_shipped = 0
ORDER BY s.name, t.name, c.column_id;
"@

        $indexesQuery = @"
SELECT
    CAST(sc.name AS nvarchar(128)) AS SchemaName,
    CAST(t.name AS nvarchar(128)) AS TableName,
    CAST(i.name AS nvarchar(128)) AS IndexName,
    CAST(i.type_desc AS nvarchar(60)) AS IndexType,
    i.is_primary_key AS IsPrimaryKey,
    i.is_unique AS IsUnique,
    i.is_unique_constraint AS IsUniqueConstraint,
    CAST(c.name AS nvarchar(128)) AS ColumnName,
    ic.key_ordinal AS KeyOrdinal,
    ic.is_included_column AS IsIncludedColumn
FROM sys.tables t
INNER JOIN sys.schemas sc
    ON t.schema_id = sc.schema_id
INNER JOIN sys.indexes i
    ON t.object_id = i.object_id
INNER JOIN sys.index_columns ic
    ON i.object_id = ic.object_id
   AND i.index_id = ic.index_id
INNER JOIN sys.columns c
    ON ic.object_id = c.object_id
   AND ic.column_id = c.column_id
WHERE t.is_ms_shipped = 0
  AND i.index_id > 0
ORDER BY sc.name, t.name, i.name, ic.is_included_column, ic.key_ordinal, c.name;
"@

        $columns = Invoke-SqlQuery -Database $dbName -Query $columnsQuery
        $indexes = Invoke-SqlQuery -Database $dbName -Query $indexesQuery

        $tables = @{}

        foreach ($col in $columns) {
            $schemaName = [string]$col.SchemaName
            $tableName  = [string]$col.TableName
            $tableKey   = "$schemaName.$tableName"

            if (-not $tables.ContainsKey($tableKey)) {
                $tables[$tableKey] = [ordered]@{
                    schema  = $schemaName
                    table   = $tableName
                    columns = @()
                    indexes = @()
                }
            }

            $tables[$tableKey]["columns"] += [ordered]@{
                column_id          = [int]$col.ColumnId
                name               = [string]$col.ColumnName
                data_type          = [string]$col.DataType
                max_length         = [int]$col.MaxLength
                precision          = [int]$col.Precision
                scale              = [int]$col.Scale
                is_nullable        = [bool]$col.IsNullable
                is_identity        = [bool]$col.IsIdentity
                is_computed        = [bool]$col.IsComputed
                default_definition = if ($null -eq $col.DefaultDefinition) { $null } else { [string]$col.DefaultDefinition }
            }
        }

        $groupedIndexes = @{}

        foreach ($ix in $indexes) {
            $schemaName = [string]$ix.SchemaName
            $tableName  = [string]$ix.TableName
            $indexName  = [string]$ix.IndexName

            $tableKey = "$schemaName.$tableName"
            $indexKey = "$tableKey|$indexName"

            if (-not $tables.ContainsKey($tableKey)) {
                $tables[$tableKey] = [ordered]@{
                    schema  = $schemaName
                    table   = $tableName
                    columns = @()
                    indexes = @()
                }
            }

            if (-not $groupedIndexes.ContainsKey($indexKey)) {
                $groupedIndexes[$indexKey] = [ordered]@{
                    schema               = $schemaName
                    table                = $tableName
                    index_name           = $indexName
                    index_type           = [string]$ix.IndexType
                    is_primary_key       = [bool]$ix.IsPrimaryKey
                    is_unique            = [bool]$ix.IsUnique
                    is_unique_constraint = [bool]$ix.IsUniqueConstraint
                    columns              = @()
                }
            }

            $groupedIndexes[$indexKey]["columns"] += [ordered]@{
                name               = [string]$ix.ColumnName
                key_ordinal        = [int]$ix.KeyOrdinal
                is_included_column = [bool]$ix.IsIncludedColumn
            }
        }

        foreach ($indexEntry in $groupedIndexes.Values) {
            $tableKey = "$($indexEntry.schema).$($indexEntry.table)"
            $tables[$tableKey]["indexes"] += $indexEntry
        }

        $tableList = @($tables.Values | Sort-Object schema, table)

        $snapshot["databases"] += [ordered]@{
            name   = $dbName
            tables = $tableList
        }
    }
    catch {
        Write-Warning "Failed to process database [$dbName]: $($_.Exception.Message)"
        $snapshot["failed_databases"] += [ordered]@{
            name  = $dbName
            error = $_.Exception.Message
        }
    }
}

$snapshot | ConvertTo-Json -Depth 12 | Set-Content -Path $OutputFile -Encoding UTF8

Write-Host ""
Write-Host "Extraction finished."
Write-Host "Output file: $OutputFile"
Write-Host "Reminder: this output contains STRUCTURE ONLY, not actual data."
Write-Host "Processed databases: $($snapshot['databases'].Count)"
Write-Host "Failed databases   : $($snapshot['failed_databases'].Count)"
