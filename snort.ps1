<# 
.SYNOPSIS Script to import Snort-Logs into SQLight DB
.DESCRIPTION 
.NOTES Author: Tobias Steiner, Date: 10.02.2022
#>

# region staticVariables
[string]$SnortLog = "/var/log/snort/snort.alert.fast"
[string]$table = "snort"
[string]$db = "/etc/grafana/snortdb.sqlite" # Path to Log DB
[int]$throttle = 2 # Seconds
#endregion

#################### DATABASE SETUP AREA ###################
############################################################

# Install-Module -Name "PSSQLite" -Force
Import-Module -Name "PSSQLite"

if (Test-Path -Path $db -PathType leaf) {
    Write-Output ""
    Write-Output "[OK] Database '$db' found! Proceed ..."
}
elseif (!(Test-Path -Path $db -PathType leaf)) {

    try {
        
        Write-Output ""
        Write-Warning "Database not found! Creating '$db' ..." -WarningAction Continue

        # Create Log DB
        $query = "CREATE TABLE $table (
            Id INTEGER,
            Timestamp TEXT,
            EventType TEXT,
            Classification TEXT,
            IP TEXT,
            Protocol TEXT,
            ASN TXT,
            City TXT,
            Country TXT,
            Lat TXT,
            Lon TXT,
            PRIMARY KEY(Id AUTOINCREMENT)
        );"
          
        Invoke-SqliteQuery -Query $query -DataSource $db            
        if ($?) { Write-Output "[OK] Database successfully created!" }
    }
    catch {
        throw "[ERROR] Can't initialize Database: $($_.Exception.Message)!"
    }
}

function Set-sqlIpRecord {
    param (
        [Parameter(Position = 0)][string]$Timestamp,
        [Parameter(Position = 1)][string]$EventType,
        [Parameter(Position = 2)][string]$Classification,
        [Parameter(Position = 3)]$Priority,
        [Parameter(Position = 4)][string]$Protocol,
        [Parameter(Position = 5)][string]$IP,
        [Parameter(Position = 6)][string]$ASN,
        [Parameter(Position = 7)][string]$City,
        [Parameter(Position = 8)][string]$Country,
        [Parameter(Position = 9)][string]$lat,
        [Parameter(Position = 9)][string]$lon,
        [Parameter(Position = 10)][string]$Provider
    )

    $ipInfo = Invoke-RestMethod -Method "GET" -Uri "http://ip-api.com/json/$([IPAddress]$IP)"

    Invoke-SqliteQuery -SQLiteConnection $conn -Query "INSERT INTO $table (
        Timestamp,
        EventType,
        Classification,
        IP,
        Protocol,
        ASN,
        City,
        Country,
        Lat,
        Lon
        )
    VALUES (
        '$Timestamp',
        '$EventType',
        '$Classification',
        '$IP',
        '$Protocol',
        '$($ipInfo.as)',
        '$($ipInfo.City)',
        '$($ipInfo.Country)',
        '$($ipInfo.Lat)',
        '$($ipInfo.Lon)'
        );"

    # Vaccum
    Invoke-SqliteQuery -SQLiteConnection $conn -Query "VACUUM;"
}

##### OPEN DATABASE CONNECTION ######
#####################################

try {
    $conn = New-SQLiteConnection @Verbose -DataSource $db
    if ($?) {
        $count = Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT COUNT(*) FROM $table;" | Select-Object -ExpandProperty "COUNT(*)"
        Write-Output "[OK] Database Connection established ('$count' Records found)!"
    }
}
catch {
    throw "[ERROR] Can't open Database Connection $($_.Exception.Message)!"
}

Write-Output "[INFO] Loading '$SnortLog'! Please wait a Moment ..."

$Report = @()
$count = 1

# Import Log into Powershell Object

$Logs = Get-Content $SnortLog 

Write-Output "[INFO] Processing '$($Logs.Count)' Records (Throttling: '$throttle' Seconds) ..."

$Logs | ForEach-Object {

    $obj = [PSCustomObject]@{
        Timestamp      = [datetime]::ParseExact($_.Split("[")[0].Trim(), 'MM/dd-HH:mm:ss.ffffff', $null)
        EventType      = $_.Split("[")[2].Split("]")[1].Trim()
        Classification = $_.Split("[")[4].Split(":")[1].Trim().TrimEnd("]")
        IP             = $_.Split("[")[5].Split("}")[1].Split("->")[0].Trim().Split(":")[0]
        Protocol       = $_.Split("{")[1].Split("}")[0]
    }

    # Adding DB-Records
    Set-sqlIpRecord `
        -Timestamp $obj.Timestamp `
        -EventType $obj.EventType `
        -Classification $obj.Classification `
        -IP $obj.IP `
        -Protocol $obj.Protocol
        
    $Report += $obj

    # Throttling
    Start-Sleep -seconds $throttle
    $count++
}

if (!$Report) {

    Write-Output "[OK] No Alerts or Anomalies found!"
}

# Clear Logfile
Clear-Content -Path $SnortLog -Force

# Close Database Connection
$conn.Close()
if ($?) {

    # Garbage Collection
    [System.GC]::Collect()
    Write-Output "[OK] All Tasks completed. Bye!"
}
Write-Output ""
Exit