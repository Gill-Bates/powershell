#!/pwsh

# Script to Block malicious IPs
# Last Update: 03.01.2022

#region StaticVariables
[string]$EveJsonPath = "/var/log/suricata/eve.json"
[string]$db = "./suricata.sqlite" # Path to DB
[int]$Bantime = 168 # Timespan to block in Hours
[bool]$ClearEveJson = $false # Clear eve.json after every run to save time during loading?
[bool]$BlockClassBNetwork = $true # Blocks the full /16 Network of an malicious Host (65.534 IP addresses)
#endregion

######## IGNORE IPs ########
[array]$ignoreIPs = @(

    "$((Invoke-WebRequest ifconfig.me/ip).Content.Trim())" # Ignore own IP
    "194.126.228.13" # Gothaer
    "185.30.32.4" # Webgo24
)

###################### FUNCTIONS AREA ######################
############################################################

function Set-sqlIpRecord {
    param (
        [Parameter(Position = 0)][string]$hostIp,
        [Parameter(Position = 1)][string]$ASN,
        [Parameter(Position = 2)][string]$ISP,
        [Parameter(Position = 3)][string]$Country,
        [Parameter(Position = 4)][string]$Region,
        [Parameter(Position = 5)][string]$City,
        [Parameter(Position = 6)][string]$timestampBan
    )

    [int]$Id = Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT MAX(Id) FROM suricata" | Select-Object -ExpandProperty 'MAX(Id)'
    [int]$Id++ | Out-Null

    Invoke-SqliteQuery -SQLiteConnection $conn -Query "INSERT INTO suricata (
        Id,
        hostIp,
        ASN,
        ISP,
        Country,
        Region,
        City,
        timestampBan,
        timestampUnban
        )
    VALUES (
        '$Id',
        '$hostIP',
        '$ASN',
        '$ISP',
        '$Country',
        '$Region',
        '$City',
        '$timestampBan',
        '$null'
        );"
}

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

        $query = "CREATE TABLE suricata (
            Id INTEGER(6) PRIMARY KEY NULL,
            hostIp NVARCHAR(250) NULL,
            ASN NVARCHAR(250) NULL,
            ISP NVARCHAR(250) NULL,
            Country NVARCHAR(250) NULL,
            Region NVARCHAR(250) NULL,
            City NVARCHAR(250) NULL,
        	timestampBan NVARCHAR(250) NULL,
            timestampUnban NVARCHAR(250) NULL
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
Write-Output "Loading 'eve.json'! Please wait a Moment ..."
Write-Output "[INFO] Ignoring '$($ignoreIPs.Count)' IPs: $($ignoreIPs -join ", ")"

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
            if ($BlockClassBNetwork) {

                $hostIP = $_.Name.Split('.')[0] + "." + $_.Name.Split('.')[1] + ".0." + "0/16" 
            }
            else {
                $hostIp = $_.Name
            }

            if ($ufw -match $hostIp) {

                Write-Output "[$count] Host '$hostIp' already blocked!"
                $count++
            }
            else {

                # Blocking entire Class-B Network Range
                if ($BlockClassBNetwork) {

                    $ClassBIp = $_.Name.Split('.')[0] + "." + $_.Name.Split('.')[1] + ".0." + "0/16" 
                    Write-Output "[$count] Blocking Class-B Network '$ClassBIp' now ..."
                    
                    sudo ufw reject from $ClassBIp to any | Out-Null

                    # Adding IPs to Database
                    $ipInfo = Invoke-RestMethod -Method "GET" -Uri "http://ip-api.com/json/$([IPAddress]$_.Name)"
                    Set-sqlIpRecord -hostIp $ClassBIp -ASN $($ipInfo.as) -ISP $($ipInfo.isp) -Country $($ipInfo.country) -Region $($ipInfo.regionName) -City $($ipInfo.City) -timestampBan $(Get-Date)
                    $count++

                }
                else {

                    Write-Output "[$count] Blocking '$($_.Name)' now ..."
                    sudo ufw reject from $_.Name to any | Out-Null

                    # Adding IPs to Database
                    [string]$ipInfo = Invoke-RestMethod -Method "GET" -Uri "http://ip-api.com/json/$([IPAddress]$_.Name)"
                    Set-sqlIpRecord -hostIp $([IPAddress]$_.Name) -ASN $($ipInfo.as) -ISP $($ipInfo.isp) -Country $($ipInfo.country) -Region $($ipInfo.regionName) -City $($ipInfo.City) -timestampBan $(Get-Date)
                    $count++
                }
            }
        }
    }
}

# Remove expired Hosts depending on the defined Bantime
$dbRecords = Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT * FROM suricata WHERE timestampUnban IS NULL;"
Write-Output ""
if ($dbRecords) {

    Write-Output "Checking '$($dbRecords.Count)' DB-Records for blockend Hosts longer than '$Bantime' hours ..."
    [datetime]$UnbanTimeStamp = (Get-Date).AddHours(-$Bantime) 
    [int]$count = 1

    $dbRecords | ForEach-Object {
        if ( $UnbanTimeStamp -gt $_.timestampBan ) {
            
            Write-Output "[OK] [$count] Host '$($_.hostIp)' removed!"
            sh ./suricata_unban.sh $_.hostIp | Out-Null

            # Update Database
            Invoke-SqliteQuery -SQLiteConnection $conn -Query "UPDATE suricata SET timestampUnban = '$(Get-Date)' WHERE Id = $($_.Id);"
            $count++
        }
    }
}
else {
    
    Write-Output "[OK] No DB-Records found to unblock in the past '$Bantime' hours ..."
}

# Finishing Tasks
if ($?) {
       
    if ($ClearEveJson) {

        Write-Warning "Empty 'eve.json' now ..." -WarningAction Continue
        Clear-Content -Path $EveJsonPath -Force
        Write-Output ""
    }
    
    # Garbage Collection
    [System.GC]::Collect()
}

# Close Database Connection
$conn.Close()
Write-Output "[OK] All Tasks completed. Bye!"
Write-Output ""
Exit