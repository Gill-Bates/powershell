#!/usr/bin/env powershell
# Cron every 15 Min
# */15 * * * * pwsh -File "/opt/phl/phl.ps1"

<# 
.SYNOPSIS Phl Waitingtime Processor
.DESCRIPTION 
.NOTES Author: Gill Bates, Last Update: 06.06.2024
#>

#Requires -Module Influx

[string]$logPath = "/var/log/phlapi.log"
[string]$credentialFile = "/opt/phl/phlcredentials.xml"
[bool]$skipParkOpeningCheck = $false
[int]$influxdbVersion = 2 # Select v1 or v2

# Influx v1 Parameters
# [string]$database = "phl"
# [string]$iflxServer = "https://iflx.cloudheros.de"

# Influx v2 Parameters
[string]$bucket = "phl"
[string]$org = "myOrg"
[string]$iflxServer = "https://iflx2.cloudheros.de"
[string]$token = "<token>"

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
        throw "[ERROR] while fetching Park Status from 'https://api.phlsys.de': $($_.Exception.Message)!"
    }
}

# themeparks.wiki
function Get-PhlWaitTime1 {

    Write-Information "[$(Get-Logtime)] [INFO] Fetching Data from 'themeparks.wiki' ..." -InformationAction Continue

    try {
        $query = (Invoke-RestMethod -Method GET -Uri "https://api.themeparks.wiki/v1/entity/phantasialand/live").liveData | Where-Object { $_.entityType -like "attraction" }
    }
    catch {
        throw "[ERROR] while fetching Waiting Time from 'themeparks.wiki': $($_.Exception.Message)!"
    } 

    $obj = @()
    $query | ForEach-Object {

        $obj += [PSCustomObject]@{
            lastUpdated = [datetime](Get-Date -Format o ($_.lastUpdated ))
            name        = $_.name
            status      = ($_.status).ToLower()
            waitTime    = [int]$_.queue.standby.waitTime
        }
    }
    Write-Information "[$(Get-Logtime)] [INFO] Received Data of '$(($obj).Count)' Rides!" -InformationAction Continue
    return $obj | Sort-Object Name
}

# wartezeiten.app
function Get-PhlWaitTime2 {

    Write-Information "[$(Get-Logtime)] [INFO] Fetching Data from 'wartezeiten.app' ..." -InformationAction Continue

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
        $query = (Invoke-RestMethod @Params -SslProtocol Tls12) | Group-Object Name  
    }
    catch {
        throw "[ERROR] while fetching Waiting Time from 'wartezeiten.app': $($_.Exception.Message)!"
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

    Write-Information "[$(Get-Logtime)] [INFO] Received Data of '$(($obj).Count)' Rides!" -InformationAction Continue
    return $obj | Sort-Object ride
}

###################### PROGRAM AREA ###################### 
########################################################## 

# Check if the Park is open
if (! ((Get-ParkStatus).isOpen) -and !$skipParkOpeningCheck ) {
    throw "[ERROR] Sorry, but the Park is currently closed!"
}

Write-Output "`n[$(Get-Logtime)] [INFO] Running in Mode for InfluxDB v$influxdbVersion!"

# Checking for Password
if ( $influxdbVersion -eq 1 -and !(Test-Path -Path $credentialFile) ) {
    Write-Warning "`n*** Password-File '$credentialFile' missing! Please provide InfluxDB-Credentails! ***" -WarningAction Continue
    Get-Credential | Export-Clixml $credentialFile
    $influxCredentials = Import-Clixml -Path $credentialFile
}
elseif ($influxdbVersion -eq 1 -and (Test-Path -Path $credentialFile)) {
    $influxCredentials = Import-Clixml -Path $credentialFile
    if ($?) {
        Write-Output "[$(Get-Logtime)] [OK]   InfluxDB-Credentails successfully loaded!"
    }
}

$null = Start-Transcript -Path $logPath -UseMinimalHeader

# Fetch current WaitingTime for all available Rides
$apiResult = Get-PhlWaitTime2

# Processing Records
Write-Output "[$(Get-Logtime)] [INFO] Writing Data into InfluxDB '$iflxServer' ..."

[int]$count = 1
$apiResult | ForEach-Object {
   
    if ($influxdbVersion -eq 1) {

        Write-Output "[$(Get-Logtime)] [$count/$($apiResult.count)] ---> '$($_.ride)' ---> | Status: $([string]$_.status) | WaitTime: $([int]$_.waitTime) Min"

        Write-Influx -Database $database `
            -Server $iflxServer `
            -Credential $influxCredentials `
            -Measure phlapi `
            -Tags @{ "ride" = $_.ride } `
            -Timestamp $_.lastUpdated `
            -Metrics @{

            status   = [string]$_.status
            waitTime = [int]$_.waitTime
        }
    }
    elseif ($influxdbVersion -eq 2) {

        Write-Influx -Server $iflxServer `
            -Bucket $bucket `
            -Organisation $org `
            -Token $token  `
            -Timestamp $_.lastUpdated `
            -Measure phlapi `
            -Tags @{ "ride" = $_.ride } `
            -Metrics @{

            status   = [string]$_.status
            waitTime = [int]$_.waitTime
        }
    }
    $count++
}

if ($?) { Write-Output "[$(Get-Logtime)] [OK]   Scan completed. Bye!" }
$null = Stop-Transcript
Exit