#!/usr/bin/env powershell
# Cron every 15 Min
# */15 * * * * pwsh -File "/opt/phl/phl.ps1"

<# 
.SYNOPSIS Phl Waitingtime Processor
.DESCRIPTION 
.NOTES Author: Gill Bates, Last Update: 28.06.2024
#>

#Requires -Module Influx

[string]$logPath = "/var/log/phlapi.log"
[string]$bucket = "phl"
[string]$org = "myOrg"
[string]$iflxServer = "https://iflx2.cloudheros.de" # InfluxDB v2
[string]$iflxToken = "ikLgCOW3aSXKFeZbssM11Lnc0G9c6XmoIMfQkFA8PvLmwIwOAc7BYki2M1_ur0xH-lGHiMrrru-oecXGItTJRw=="

# Only required if secure Password Store is used
# [string]$scriptPath = (Get-Location).Path
# [string]$iflxTokenFile = "iflxToken.xml"

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

    Write-Information "[$(Get-Logtime)] [INFO] Received Data of '$(($obj).Count)' Rides!" -InformationAction Continue
    return $obj | Sort-Object ride
}

function Write-ParkState {

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 # Set TLS Version

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
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 # Set TLS Version

#region currentlyBroken
# Checking for iflxTokenFile
# Write-Output "[$(Get-Logtime)] [INFO] Checking if Password File for Influxdb-Token exists ..."

# if (!(Test-Path -Path (Join-Path -Path $scriptPath $iflxTokenFile))) {
    
#     Write-Warning "*** iflxTokenFile '$iflxTokenFile' missing! ***" -WarningAction Continue
#     $bucketToken = Read-Host -AsSecureString -Prompt "Enter Bucket Token for '$bucket'" 
#     $Credential = New-Object -TypeName System.Management.Automation.PSCredential -ArgumentList $bucket, $bucketToken
#     $Credential | Export-Clixml $iflxTokenFile

#     if ($?) {
#         Write-Output "[$(Get-Logtime)] [OK]   iflxTokenFile successfully created! Proceed ..."
#     }
# }
# Loading Password
# $influxCredential = Import-Clixml -Path $iflxTokenFile
# $BSTR = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($($influxCredential.Password))
# $UnsecurePassword = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($BSTR)
# [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($BSTR)
#endregion

# Check if the Park is open and processing Park Status Result
$parkStatus = Get-ParkStatus

if (!($parkStatus.isOpen)) {

    Write-Warning "Park is currently CLOSED :-( (Closed at '$([datetime]$parkStatus.close)')" -WarningAction Continue
    
    Write-ParkState
    
    if ($?) { Write-Output "[$(Get-Logtime)] [OK]   Scan completed. Bye!" }
    $null = Stop-Transcript
    Exit
}
else {
    Write-Output "[$(Get-Logtime)] [INFO] Park is OPEN :-) Write parkState Data into InfluxDB: '$iflxServer' ..."
    Write-ParkState
}

# Fetch current WaitingTime for all available Rides
$apiResult = Get-PhlWaitTime2

# Processing Records
Write-Output "[$(Get-Logtime)] [INFO] Writing Data into InfluxDB '$iflxServer' ...`n"

[int]$count = 1
$apiResult | ForEach-Object {

    Write-Output "[$(Get-Logtime)] [$count/$($apiResult.count)] ---> '$($_.ride)' ---> | Status: $([string]$_.status) | WaitTime: $([int]$_.waitTime) Min."

    Write-Influx -Server $iflxServer `
        -Bucket $bucket `
        -Organisation $org `
        -Token $iflxToken `
        -Timestamp $_.lastUpdated `
        -Measure waitTime `
        -Metrics @{
        status  = [string]$_.status
        $_.ride = [int]$_.waitTime
    }

    Write-Influx -Server $iflxServer `
        -Bucket $bucket `
        -Organisation $org `
        -Token $iflxToken `
        -Timestamp $_.lastUpdated `
        -Measure rideState `
        -Metrics @{
        $_.ride = [string]$_.status
    }
    $count++
}

# Finishing
if ($?) { Write-Output "[$(Get-Logtime)] [OK]   Scan completed. Bye!" }
$null = Stop-Transcript
Exit
# End of Script