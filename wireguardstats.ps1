<# 
.SYNOPSIS Script for converting Wireguard into HTML-Report
.DESCRIPTION 
.NOTES Author: Gill Bates, Last Update: 22.08.2021
#>

[string]$db = ".\wireguard.SQLite" # Path to DB


###### FUNCTION AREA ######
###########################

function Get-Traffic {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$TrafficinBytes,
        [Parameter(Mandatory = $false)]
        [switch]$Unit = $false
    )

    if (($TrafficinBytes / 1MB) -lt 1024) {

        if ($Unit) {
            return ([math]::Round($TrafficinBytes / 1MB, 2)).ToString() + (" (MB)").ToString()
        }
        else {
            return [math]::Round($TrafficinBytes / 1MB, 2)
        }
        
        
    }
    elseif (($TrafficinBytes / 1MB) -gt 1024) {
        if ($Unit) {
            return ([math]::Round($TrafficinBytes / 1GB, 2)).ToString() + (" (GB)").ToString()
        }
        else {
            return [math]::Round($TrafficinBytes / 1GB, 2)
        }
    }
}

function Get-ClientName {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$PreSharedKey
    )

    $Files = Get-ChildItem -Path "/etc/wireguard/clients" -Filter *.conf
    foreach ($i in $Files) {

        $tmp = Get-Content -Path $i.FullName
        if ($tmp -Like "*$PreSharedKey*") {
            return $i.BaseName
        }
    }
}

###### PROGRAM AREA #######
###########################

##### DATABASE SETUP ######
###########################

#region Database Check
if (Test-Path -Path $db -PathType leaf) {
    Write-Output "[OK] Database found! Proceed ..."
}

if (!(Test-Path -Path $db -PathType leaf)) {

    try {
        Write-Warning "Database not found! Creating '$db' ..." -WarningAction Continue

        $query = "CREATE TABLE wireguard (
            Id INTEGER(6) PRIMARY KEY,
            Client NVARCHAR(250),
            PreSharedKey NVARCHAR(250),
            LastSeen NVARCHAR(250),
            RemoteIP NVARCHAR(250),
            TrafficRX NVARCHAR(250),
            TrafficTX NVARCHAR(250),
            TrafficTotal NVARCHAR(250)
          )"
          
        Invoke-SqliteQuery -Query $query -DataSource $db
    
        if ($?) { Write-Output "[OK] Database successfully created!" }
    }
    catch {
        throw "[ERROR] Can't initialize Database: $($_.Exception.Message)!"
    }
}

# Running on Linux
$OutputPath = "/var/www/html/admin/traffic.html"

$Json = /usr/local/bin/wg-json.sh | ConvertFrom-Json -AsHashtable

if (!$Json) {

    throw "[ERROR] Don't get any Data from Wireguard Server!"
}

$Report = @()

($Json.wg0.peers).GetEnumerator() | ForEach-Object {

    if ($_.Value.latestHandshake) {

        [datetime]$latestHandshake = (Get-Date 01.01.1970) + ([System.TimeSpan]::fromseconds($_.Value.latestHandshake))
    }
    else {

        [int]$latestHandshake = 0
    }

    $obj = [PSCustomObject]@{
        Client       = (Get-ClientName -PreSharedKey $_.Value.presharedKey)
        PreSharedKey = $_.Value.presharedKey
        LastSeen     = $latestHandshake
        RemoteIP     = if ($_.Value.endpoint) { ($_.Value.endpoint) }
        TrafficRX    = if ($_.Value.transferRx) { Get-Traffic -TrafficinBytes $_.Value.transferRx }
        TrafficTX    = if ($_.Value.transferTx) { Get-Traffic -TrafficinBytes $_.Value.transferTx }
        TrafficTotal = if ($_.Value.transferTx -and $_.Value.transferRx) { Get-Traffic -TrafficinBytes ($_.Value.transferTx + $_.Value.transferRx) -Unit }
    }
    $Report += $obj
}

$Report | Sort-Object -Property "TrafficTX" -Descending | Convertto-HTML -Title (Get-Date) | Out-File -FilePath $OutputPath

$Report | Sort-Object -Property "TrafficTX" -Descending | ft * -AutoSize

# Database & Restart
$Uptime = New-TimeSpan -Start (Get-Process | Where-Object { $_.Name -eq "wg-crypt-wg0" }).StartTime -End (Get-Date)

# Reset Statistic by Restaring Service

if ($Uptime.Minutes -ge 1440) {

    # Open Database Connection
    try {
        Write-Output "Open Database Connection '$db' ..."
        $conn = New-SQLiteConnection @Verbose -DataSource $db
        $conn.ConnectionString | Out-Null
    }
    catch {
        throw "[ERROR] Can't open Database Connection $($_.Exception.Message)!"
    }
    #endregion
    Write-Output "Storing Records into Database ..."
    $Report | ForEach-Object {

        [int]$Id = Invoke-SqliteQuery -SQLiteConnection $conn -Query "SELECT Id FROM wireguard;" | Select-Object -ExpandProperty Id | Sort-Object -Descending | Select-Object -First 1
        [int]$Id++ | Out-Null
        Invoke-SqliteQuery -SQLiteConnection $conn -Query "INSERT INTO wireguard (
        Id, Client, PreSharedKey, LastSeen, RemoteIP, TrafficRX, TrafficTX, TrafficTotal)
    VALUES (
        '$Id', '$($_.Client)', '$($_.PreSharedKey)', '$($_.LastSeen)', '$($_.RemoteIP)', '$($_.TrafficRX)', '$($_.TrafficTX)', '$($_.TrafficTotal)');"
    }

    # Closing Database
    Write-Output "Closing Database Connection ..."
    $conn.Close()
    $conn.State

    Write-Output "Restarting Wireguard Service ..."
    systemctl restart wg-quick@wg0.service
}
else {
    Write-Output "Wireguard Service is running since '$($Uptime.Hours)' hours. No Restart needed!"
}
Write-Output "[OK] All Jobs done! Exit here."
Write-Output ""
Exit
#End of Script