# Script to Block malicious IPs
# Last Update: 29.12.2021

#region StaticVariables
[string]$EveJsonPath = "/var/log/suricata/eve.json"
[string]$db = "/root/powershell/suricata.sqlite" # Path to DB
[int]$Bantime = 24 # Timespan to look back for
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
    Write-Output "[OK] Database found! Proceed ..."
}

if (!(Test-Path -Path $db -PathType leaf)) {

    try {
        Write-Warning "Database not found! Creating '$db' ..." -WarningAction Continue

        $query = "CREATE TABLE suricata (
            Id INTEGER(6) PRIMARY KEY,
            hostIp NVARCHAR(250),
            timestamp NVARCHAR(250)
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
    Write-Output "Open Database Connection '$db' ..."
    $conn = New-SQLiteConnection @Verbose -DataSource $db
    $conn.ConnectionString | Out-Null
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
Write-Output "Loading eve.json. Please wait a moment ..."
$EveJson = Get-Content $EveJsonPath | ConvertFrom-Json |  Where-Object { $_.event_type -Like "anomaly" -or $_.event_type -Like "alerts" } 

if (!$EveJson) {

    Write-Output "No Alerts and Anomalies found! Exit here."
    Write-Output ""
    Exit
}

Write-Warning "'$($EveJson.Count)' malicious Events in the past '$TimeSpan' hours found!" -WarningAction Continue

$EveJsonGroup = $EveJson | Group-Object -Property "src_ip" | Where-Object { $ignoreIPs -notcontains $_.Name }

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
        sudo ufw deny from $_.Name to any | Out-Null
        $count++

        # Adding IPs to Database
        [int]$Id = Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT Id FROM suricata;" | Select-Object -ExpandProperty Id | Sort-Object -Descending | Select-Object -First 1
        [int]$Id++ | Out-Null

        Invoke-SqliteQuery -SQLiteConnection $conn -Query "INSERT INTO suricata ( Id, hostIp, timestamp )
        VALUES ( '$Id', '$($_.Name)', '$(Get-Date)');"
    
    }
}

# Remove expired Hosts depending on Bantime

# $dbRecords = Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT * FROM suricata;"

# $dbRecords | ForEach-Object {

#     if (  $_.timestamp -gt (Get-Date).AddHours(-$Bantime) ) {

#         $Command = "ufw show added `\ `| awk -v myip`=`"$($_.hostIp)`" '`$0 `~ myip`{ gsub(`"ufw`"`,`"ufw delete`"`,`$0`)`; system(`$0) `}'"
#         bash $Command
#     }
# }

if ($?) {
    
    Write-Output ""
    if ($ClearEveJson) {

        Write-Warning "Empty 'eve.json' now ..." -WarningAction Continue
        Clear-Content -Path $EveJsonPath -Force
    }

    [System.GC]::Collect() # Garbage Collection
    Write-Output "[OK] All Tasks completed. Bye!"
}
$conn.Close()
$conn.State
Write-Output ""
Exit
