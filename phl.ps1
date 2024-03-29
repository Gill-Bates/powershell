#!/usr/bin/env powershell
# Cron 0 * * * * pwsh -File "/root/phl.ps1"

<# 
.SYNOPSIS Phl Waitingtime Processor
.DESCRIPTION 
.NOTES Author: Gill Bates, Last Update: 26.01.2024
#>
#Requires -Module Influx

[string]$iflxServer = "https://iflx.cloudheros.de"
[string]$logPath = "/var/log/phlapi.log"
[string]$database = "phl"
[string]$measureGroupName = "phlapi"
[string]$credentialFile = "./phlcredentials.xml"
[bool]$skipParkOpeningCheck = $true

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
            lastUpdated = [datetime]$lastUpdated
            name        = $_.name | Select-Object -First 1
            status      = ($_.Group.status).ToLower() | Select-Object -First 1
            waitTime    = [int]($_.Group.waitingtime | Select-Object -First 1)
        }
    }

    Write-Information "[$(Get-Logtime)] [INFO] Received Data of '$(($obj).Count)' Rides!" -InformationAction Continue
    return $obj | Sort-Object Name
}

###################### PROGRAM AREA ###################### 
########################################################## 

$null = Start-Transcript -Path $logPath -UseMinimalHeader

# Checking for Password
if ( !(Test-Path -Path $credentialFile) ) {
    Write-Warning "`n*** Password-File '$credentialFile' missing! Please provide InfluxDB-Credentails! ***" -WarningAction Continue
    Get-Credential | Export-Clixml $credentialFile
    $influxCredentials = Import-Clixml -Path $credentialFile
}
else {
    $influxCredentials = Import-Clixml -Path $credentialFile
    if ($?) {
        Write-Output "`n[$(Get-Logtime)] [OK] InfluxDB-Credentails successfully loaded!"
    }
}

# Check if the Park is open
if (! ((Get-ParkStatus).isOpen) -and !$skipParkOpeningCheck ) {
    throw "[ERROR] Sorry, but the Park is currently closed!"
}

# Fetch current WaitingTime for all available Rides
$apiResult = Get-PhlWaitTime2

# Processing Records
Write-Output "[$(Get-Logtime)] [INFO] Writing Data into InfluxDB '$iflxServer' ...`n"

[int]$count = 1
$apiResult | ForEach-Object {

    Write-Output "[$(Get-Logtime)] [$count/$($apiResult.count)] ---> '$($_.name)' ---> | Status: $([string]$_.status) | WaitTime: $([int]$_.waitTime) Min"
    
    Write-Influx -Database $database `
        -Server $iflxServer `
        -Credential $influxCredentials `
        -Measure $measureGroupName `
        -Tags @{ride = $_.name } `
        -Timestamp $_.lastUpdated `
        -Metrics @{

        ride     = $_.name
        status   = [string]$_.status
        waitTime = [int]$_.waitTime

    }
    $count++
}

if ($?) { Write-Output "`n[$(Get-Logtime)] [OK] Scan completed. Bye!" }
$null = Stop-Transcript
Exit