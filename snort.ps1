$Log = Get-Content "D:\snort.log" -Tail 1
$table = "snort"
[string]$db = "d:\snort.db" # Path to DB

#################### DATABASE SETUP AREA ###################
############################################################

Import-Module -Name "PSSQLite"

if (Test-Path -Path $db -PathType leaf) {
    Write-Output ""
    Write-Output "[OK] Database '$db' found! Proceed ..."
}
elseif (!(Test-Path -Path $db -PathType leaf)) {

    try {
        
        Write-Output ""
        Write-Warning "Database not found! Creating '$db' ..." -WarningAction Continue

        $query = "CREATE TABLE $table (
            Id INTEGER,
            Timestamp TEXT,
            Event TEXT,
            Classification TEXT,
            IP TEXT,
            Provider TEXT,
            Protocol TEXT,
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
        [Parameter(Position = 1)][string]$Event,
        [Parameter(Position = 2)][string]$Classification,
        [Parameter(Position = 3)][string]$IP,
        [Parameter(Position = 4)][string]$Provider,
        [Parameter(Position = 5)][string]$Protocol
    )

    [int]$Id = Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT MAX(Id) FROM suricata" | Select-Object -ExpandProperty 'MAX(Id)'
    [int]$Id++ | Out-Null

    Invoke-SqliteQuery -SQLiteConnection $conn -Query "INSERT INTO suricata (
        Timestamp,
        Event,
        Classification,
        IP,
        Provider,
        Protocol
        )
    VALUES (
        '$Timestamp',
        '$Event',
        '$Classification',
        '$IP',
        '$Provider',
        '$Protocol'
        );"
}

##### OPEN DATABASE CONNECTION ######
#####################################

try {
    $conn = New-SQLiteConnection @Verbose -DataSource $db
    if ($?) {
        Write-Output "[OK] Database Connection established!"
    }
}
catch {
    throw "[ERROR] Can't open Database Connection $($_.Exception.Message)!"
}

while ($Run) {

    Get-Content "D:\snort.log" -Tail 1 -Wait

    $obj = [PSCustomObject]@{
        Timestamp      = [datetime]::ParseExact($Log.Split("[")[0].Trim(), 'MM/dd-HH:mm:ss.ffffff', $null)
        Event          = $Log.Split("[")[2].Split("]")[1].Trim()
        Classification = $Log.Split("[")[4].Split(":")[1].Trim().TrimEnd("]")
        IP             = $Log.Split("[")[5].Split("}")[1].Split(" - ")[0].Split(":")[0].Trim()
        Provider       = $null
        Protocol       = $Log.Split("{ ")[1].Split(" }")[0]
    }
    
}

Set-sqlIpRecord -hostIp $ClassBIp -ASN $($ipInfo.as) -ISP $($ipInfo.isp) -Country $($ipInfo.country) -Region $($ipInfo.regionName) -City $($ipInfo.City) -timestampBan $(Get-Date)