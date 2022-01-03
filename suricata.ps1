#!/pwsh

# Script to Block malicious IPs
# Last Update: 03.01.2022

#region StaticVariables
[string]$EveJsonPath = "/var/log/suricata/eve.json"
[string]$db = "/root/powershell/suricata.sqlite" # Path to DB
[int]$Bantime = 168 # Timespan to block
[bool]$ClearEveJson = $true # Clear eve.json after every run to save time during loading?
#endregion

######## IGNORE IPs ########
[array]$ignoreIPs = @(

    "$((Invoke-WebRequest ifconfig.me/ip).Content.Trim())" # Ignore own IP
    "194.126.228.13"
)

#################### DATABASE SETUP AREA ###################
############################################################

Import-Module -Name "PSSQLite"

if (Test-Path -Path $db -PathType leaf) {
    Write-Output ""
    Write-Output "[OK] Database '$db' found! Proceed ..."
}

if (!(Test-Path -Path $db -PathType leaf)) {

    try {
        Write-Warning "Database not found! Creating '$db' ..." -WarningAction Continue

        $query = "CREATE TABLE suricata (
            Id INTEGER(6) PRIMARY KEY,
            hostIp NVARCHAR(250),
            ASN NVARCHAR(250),
            ISP NVARCHAR(250),
            Country NVARCHAR(250),
            Region NVARCHAR(250),
            City NVARCHAR(250),
            EventType NVARCHAR(250),
        	timestampBan NVARCHAR(250),
            timestampUnban NVARCHAR(250)
          )"
          
        Invoke-SqliteQuery -Query $query -DataSource $db
    
        if ($?) { Write-Output "[OK] Database successfully created!" }
    }
    catch {
        throw "[ERROR] Can't initialize Database: $($_.Exception.Message)!"
    }
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

####################### PROGRAM AREA #######################
############################################################

# Test for valid JSON
if (!(Test-Path -Path $EveJsonPath)) {

    throw "'eve.json' not found! Check your config. Bye!"
}

# Parse JSON
Write-Output ""
Write-Output "Loading 'eve.json'! Please wait a moment ..."

if ($ClearEveJson) {

    $EveJson = Get-Content $EveJsonPath | ConvertFrom-Json | Where-Object { $_.event_type -Like "anomaly" -or $_.event_type -Like "alerts" } 
}
else {

    $EveJson = Get-Content $EveJsonPath | ConvertFrom-Json | Where-Object { $_.timestamp -gt (Get-Date).AddHours(-$Bantime) } | Where-Object { $_.event_type -Like "anomaly" -or $_.event_type -Like "alerts" } 
}

if (!$EveJson) {

    Write-Output "[OK] No Alerts or Anomalies found!"
}

# Blocking Hosts (if found)
if ($EveJson) {

    Write-Warning "'$($EveJson.Count)' malicious Events in the past '$Bantime' hours found!" -WarningAction Continue

    $EveJsonGroup = $EveJson | Group-Object -Property "src_ip" | Where-Object { $ignoreIPs -notcontains $_.Name }

    if ($EveJsonGroup) {
    
        # Fetching already Blocked IPs
        $ufw = ufw status

        # Blocking IPs
        Write-Warning "Blocking '$($EveJsonGroup.Count)' Hosts now ..." -WarningAction Continue

        $count = 1
        $EveJsonGroup | ForEach-Object {

            # Blocking now
            if ($ufw -match $_.Name) {

                Write-Output "[$count] Host '$($_.Name)' already blocked!"
                $count++
            }
            else {
                Write-Output "[$count] Blocking '$($_.Name)' now ..."
                sudo ufw reject from $_.Name to any | Out-Null
                $count++

                # Adding IPs to Database
                [int]$Id = Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT Id FROM suricata;" | Select-Object -ExpandProperty Id | Sort-Object -Descending | Select-Object -First 1
                [int]$Id++ | Out-Null

                $ipInfo = Invoke-RestMethod -Method "GET" -Uri "http://ip-api.com/json/$([IPAddress]$_.Name)"

                Invoke-SqliteQuery -SQLiteConnection $conn -Query "INSERT INTO suricata (
                    Id,
                    hostIp,
                    ASN,
                    ISP,
                    Country,
                    Region,
                    City,
                    EventType
                    timestampBan,
                    timestampUnban
                    )
                VALUES (
                    '$Id',
                    '$([IPAddress]$_.Name)',
                    '$($ipInfo.as)',
                    '$($ipInfo.isp)',
                    '$($ipInfo.country)',
                    '$($ipInfo.regionName)',
                    '$($ipInfo.City)',
                    '$($_.event_type)',
                    '$(Get-Date)'
                    );"
            }
        }
    }
}

# Remove expired Hosts depending on the defined Bantime
Write-Output ""
Write-Output "Checking for blockend Hosts longer than '$Bantime' hours ..."

$dbRecords = Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT * FROM suricata;"

if ($dbRecords) {

    [int]$count = 1
    $dbRecords | ForEach-Object {
        if ( (Get-Date).AddHours(-$Bantime) -gt $_.timestamp  ) {
            
            Write-Output "[OK] [$count] Host '$($_.hostIp)' removed!"
            sh /root/powershell/suricata_unban.sh $_.hostIp | Out-Null

            # Update Database
            Invoke-SqliteQuery -SQLiteConnection $conn -Query "UPDATE suricata SET timestampUnban = '$(Get-Date)' WHERE Id = $($_.Id);"
            $count++
        }
    }
}

# Finishing Tasks
if ($?) {
    
    Write-Output ""
    if ($ClearEveJson) {

        Write-Warning "Empty 'eve.json' now ..." -WarningAction Continue
        Clear-Content -Path $EveJsonPath -Force
    }
    
    # Garbage Collection
    [System.GC]::Collect()
}

# Close Database Connection
$conn.Close()
Write-Output "[OK] All Tasks completed. Bye!"
Write-Output ""
Exit