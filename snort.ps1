
# region staticVariables
[string]$SnortLog = "/var/log/snort/snort.alert.fast"
#[string]$SnortLog = "C:\Users\td9\Downloads\snort.log"
[string]$table = "snort"
[string]$tableBan = "snort_ban"
[string]$db = "./snortdb.sqlite" # Path to DB
#[string]$db = "C:\Users\td9\Downloads\snortdb.sqlite" # Path to DB
[int]$Bantime = 168 # Timespan to block in Hours
[string]$unbanScript = "./snort_unban.sh"
#endregion

######## IGNORE IPs ########
[array]$ignoreIPs = @(

    "$((Invoke-WebRequest ifconfig.me/ip).Content.Trim())" # Ignore own IP
    "194.126.228.13" # Gothaer
    "185.30.32.4" # Webgo24
)

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
            ASN TXT,
            City TXT,
            Country TXT,
            Protocol TEXT,
            PRIMARY KEY(Id AUTOINCREMENT)
        );"
          
        Invoke-SqliteQuery -Query $query -DataSource $db
    
        $query = "CREATE TABLE $tableBan (
            Id INTEGER,
            IPClassB TEXT,
            BanTime TEXT,
            UnbanTime TEXT,
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

    $ipInfo = Invoke-RestMethod -Method "GET" -Uri "http://ip-api.com/json/$([IPAddress]$IP)"

    Invoke-SqliteQuery -SQLiteConnection $conn -Query "INSERT INTO $table (
        Timestamp,
        Event,
        Classification,
        IP,
        ASN,
        City,
        Country,
        Protocol
        )
    VALUES (
        '$Timestamp',
        '$Event',
        '$Classification',
        '$IP',
        '$($ipInfo.as)',
        '$($ipInfo.City)',
        '$($ipInfo.Country)',
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

Write-Output "Loading '$SnortLog'! Please wait a Moment ..."

Write-Output "[INFO] Ignoring '$($ignoreIPs.Count)' IPs: $($ignoreIPs -join ", ")"

$Report = @()
$count = 1

# Import Log into Powershell Object
Get-Content $SnortLog | ForEach-Object {

    $obj = [PSCustomObject]@{
        Timestamp      = [datetime]::ParseExact($_.Split("[")[0].Trim(), 'MM/dd-HH:mm:ss.ffffff', $null)
        Event          = $_.Split("[")[2].Split("]")[1].Trim()
        Classification = $_.Split("[")[4].Split(":")[1].Trim().TrimEnd("]")
        IP             = $_.Split("[")[5].Split("}")[1].Split("->")[0].Trim().Split(":")[0]
        Protocol       = $_.Split("{")[1].Split("}")[0]
    }

    # Adding DB-Records
    Set-sqlIpRecord `
        -Timestamp $obj.Timestamp `
        -Event $obj.Event`
        -Classification $obj.Classification `
        -IP $obj.IP `
        -Protocol $obj.Protocol
        
    $Report += $obj
    $count++
}

if (!$Report) {

    Write-Output "[OK] No Alerts or Anomalies found!"
}
elseif ($Report) {
    Write-Warning "'$($Report.Count)' malicious Events in the past '$Bantime' hours found!" -WarningAction Continue

    Write-Warning "Empty '$SnortLog' now ..." -WarningAction Continue
    Clear-Content -Path $SnortLog -Force
    Write-Output ""
}

############################ BLOCKING AREA ############################

$allHosts = Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT IP FROM $table;" | Group-Object -Property IP | Sort-Object Count -Descending

$ufw = ufw status
$count = 1
$allHosts | ForEach-Object {

    # Creating Class-B CIDR
    $ClassBIp = $_.Name.Split('.')[0] + "." + $_.Name.Split('.')[1] + ".0." + "0/16" 

    if ($ClassBIp -match $ufw) {

        Write-Output "[$count] Host '$hostIp' already blocked!"
    }
    else {

        Write-Warning "[$count] Blocking Host '$ClassBIp' now ..." -WarningAction Continue
        sudo ufw reject from $ClassBIp to any | Out-Null

        Invoke-SqliteQuery -SQLiteConnection $conn -Query "INSERT INTO $tableBan (
        IPClassB,
        BanTime
        )
    VALUES (
        '$ClassBIp',
        '$(Get-Date)'
        );"
    }
    $count++
}

# Close Database Connection
$conn.Close()
if ($?) {

    # Garbage Collection
    [System.GC]::Collect()
    Write-Output "[OK] All Tasks completed. Bye!"
}
Write-Output ""
Exit