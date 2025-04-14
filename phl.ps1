#!/usr/bin/env powershell
# Cron every 15 Min
# */15 * * * * pwsh -File "/opt/phl/phl.ps1"

<# 
.SYNOPSIS Phl Waitingtime Processor
.DESCRIPTION 
.NOTES Author: Gill Bates, Last Update: 2025-04-13
#>

#Requires -Module Influx

[string]$logPath = "/var/log/phlapi.log"
[string]$bucket = "phl"
[string]$org = "myOrg"
[string]$iflxServer = "https://iflx2.cloudheros.de" # InfluxDB v2
[string]$iflxToken = "Xh3FS2OrhouwIUXmycGYtcHx1QdQ-kOZWC8zbImdW6TOsXFj-9KZD3lJeZAzQGNBvHTUecDnntCPoZHHT40-Ng=="

# Set TLS Version
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

###################### FUNCTIONS AREA ###################### 
############################################################ 

function Get-Logtime {
    # This function is optimzed for Azure Automation!
    $Timeformat = "yyyy-MM-dd HH:mm:ss" #yyyy-MM-dd HH:mm:ss.fff
    if ((Get-Timezone).Id -ne "W. Europe Standard Time") {
        try {
            $tDate = (Get-Date).ToUniversalTime()
            $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("W. Europe Standard Time")
            $TimeZone = [System.TimeZoneInfo]::ConvertTimeFromUtc($tDate, $tz)
            return $(Get-Date -Date $TimeZone -Format $Timeformat)
        }
        catch {
            return $(Get-Date -Format $Timeformat)
        }
    }
    return $(Get-Date -Format $Timeformat)
}

function Get-ParkStatus {
    try {
        return Invoke-RestMethod -Method GET -Uri "https://api.phlsys.de/api/park-infos"
    }
    catch {
        throw "[ERROR] while fetching Park Status from 'https://api.phlsys.de': $(($_.Exception).Message))!"
    }
}

# wartezeiten.app
function Get-PhlWaitTime {

    Write-Information "[INFO] Fetching Data from 'wartezeiten.app' ..." -InformationAction Continue

    try {
        $Header = @{
            "park"     = "phantasialand"
            "language" = "de"
        }
          
        $Params = @{
            "URI"     = "https://api.wartezeiten.app/v1/waitingtimes"
            "Method"  = "GET"
            "Headers" = $Header
        }
        $query = (Invoke-RestMethod @Params) | Group-Object Name  
    }
    catch {
        throw "[ERROR] while fetching Waiting Time from 'wartezeiten.app': $(($_.Exception).Message)!"
    } 

    $lastUpdated = (Get-Date (($query.Group.date | Select-Object -First 1) + " " + ($query.Group.time | Select-Object -First 1 )))
    $obj = @()
    $query | ForEach-Object {
        
        $obj += [PSCustomObject]@{
            ride        = $_.name | Select-Object -First 1
            status      = ($_.Group.status).ToLower() | Select-Object -First 1
            waitTime    = [int]($_.Group.waitingtime | Select-Object -First 1)
            lastUpdated = [datetime]$lastUpdated
        }
    }

    Write-Information "[INFO] Received Data of '$(($obj).Count)' Rides!" -InformationAction Continue
    return $obj | Sort-Object ride
}

function Write-ParkState {

    try {
        Write-Influx -Server $iflxServer `
            -Bucket $bucket `
            -Organisation $org `
            -Token $iflxToken `
            -Timestamp $parkStatus.updatedAt  `
            -Measure parkState `
            -Metrics @{

            "isOpen"              = $parkStatus.isOpen
            "closeAt"             = $parkStatus.close
            "manuallyForceClosed" = $parkStatus.manuallyForceClosed
        }
    }
    catch {
        throw "[ERROR] while writing parkState into InfluxDB '$iflxServer': $(($_.Exception).Message)"
    }
}

###################### PROGRAM AREA ###################### 
########################################################## 

$null = Start-Transcript -Path $logPath -UseMinimalHeader

# Check if the Park is open and processing Park Status Result
$parkStatus = Get-ParkStatus

if (!($parkStatus.isOpen)) {

    Write-Warning "Park is currently CLOSED :-( (Closed at '$([datetime]$parkStatus.close)')" -WarningAction Continue
        
    if ($?) { Write-Output "[OK]   Scan completed. Bye!" }
    $null = Stop-Transcript
    Exit
}
else {
    Write-Output "[INFO] Park is OPEN :-) Write parkState Data into InfluxDB: '$iflxServer' ..."
    Write-ParkState
}

# Fetch current WaitingTime for all available Rides
$apiResult = Get-PhlWaitTime

# Processing Records
Write-Output "[INFO] Writing Data into InfluxDB '$iflxServer' ...`n"

[int]$count = 1
$apiResult | ForEach-Object {

    $rideName = $_.name
    $status = $_.status
    $wait = try { [int]$_.waitingtime } catch { $null }

    Write-Output "---> '$rideName' | Status: $status | WaitTime: $wait Min."

    # 1️⃣ Write Status (open, closed, etc.)
    Write-Influx -Server $iflxServer `
        -Bucket $bucket `
        -Organisation $org `
        -Token $iflxToken `
        -Timestamp $_.lastUpdated `
        -Measure "rideState" `
        -Tags @{ ride = $rideName } `
        -Metrics @{ status = $status }

    # 2️⃣ Write WaitTime (in minutes)
    if ($wait -ne $null) {
        Write-Influx -Server $iflxServer `
            -Bucket $bucket `
            -Organisation $org `
            -Token $iflxToken `
            -Timestamp $_.lastUpdated `
            -Measure "waitTime" `
            -Tags @{ ride = $rideName } `
            -Metrics @{ waitTime = $wait }
    }

    $count++
}

# Finishing
if ($?) { Write-Output "[OK]   Scan completed. Bye!" }
$null = Stop-Transcript

Exit
# End of Script