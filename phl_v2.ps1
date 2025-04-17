#!/usr/bin/env powershell
# Cron every 15 Min
# */15 * * * * pwsh -File "/opt/phl/phl.ps1"

<# 
.SYNOPSIS Phl Waitingtime Processor
.DESCRIPTION 
.NOTES Author:  Gill Bates, Last Update: 2025-04-17
.NOTES          Tuned by ChatGPT 4-o on 2023-10-17
#>

#Requires -Module Influx

[string]$logPath = "/var/log/phlapi.log"
[string]$configPath = "/etc/logrotate.d/phlapi"
[string]$bucket = "phl"
[string]$org = "myOrg"
[string]$iflxServer = "https://iflx2.cloudheros.de" # InfluxDB v2
[string]$tokenFile = "iflxToken.txt" # InfluxDB v2 Token

# Load InfluxDB Token

[string]$iflxToken = Get-Content "$(Split-Path -Path $MyInvocation.MyCommand.Path)/$tokenFile" -Raw

# Set TLS Version
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

###################### FUNCTIONS AREA ###################### 
############################################################ 

function Enable-Logrotate {
    param (
        [parameter(Mandatory = $true)]
        [string]$LogPath,
        [parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    # Check if config already exists
    if (-Not (Test-Path $ConfigPath)) {
        Write-Host "Creating logrotate configuration for $LogPath..." -ForegroundColor Green

        $configContent = @"
$LogPath {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
}
"@

        # Write to temporary file and move with root privileges
        $tempFile = "/tmp/phlapi_logrotate.conf"
        $configContent | Out-File -Encoding ASCII -NoNewline $tempFile
        sudo mv $tempFile $ConfigPath
        sudo chown root:root $ConfigPath
        sudo chmod 644 $ConfigPath

        Write-Host "Logrotate configuration created at: $ConfigPath" -ForegroundColor Cyan
    }
    else {
        Write-Host "Logrotate configuration for $LogPath already exists at $ConfigPath." -ForegroundColor Gray
    }
}

function Get-ParkStatus {
    try {
        return Invoke-RestMethod -Method GET -Uri "https://api.phlsys.de/api/park-infos"
    }
    catch {
        throw "[ERROR] while fetching Park Status from 'https://api.phlsys.de': $(($_.Exception).Message)!"
    }
}

function Get-PhlWaitTime {

    # wartezeiten.app
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
            ride        = $_.Name
            status      = ($_.Group.status).ToLower() | Select-Object -First 1
            waitTime    = [int]($_.Group.waitingtime | Select-Object -First 1)
            lastUpdated = [datetime]$lastUpdated
        }
    }

    Write-Information "[INFO] Received Data of '$($obj.Count)' Rides!" -InformationAction Continue
    return $obj | Sort-Object ride
}

function Write-ParkState ($parkStatus) {
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

Write-Output "[$((Get-Date).ToString("yyyy-MM-dd HH:mm:ss"))] [INFO] Writing Logs into '$logPath' ..."

$null = Start-Transcript -Path $logPath -UseMinimalHeader -Append -Force

Enable-Logrotate -LogPath $logPath -ConfigPath $configPath

try {
    $parkStatus = Get-ParkStatus
    Write-ParkState -parkStatus $parkStatus

    $rides = Get-PhlWaitTime

    Write-Output "[INFO] Writing Data to InfluxDB '$iflxServer' ..."

    foreach ($ride in $rides) {
        try {
            Write-Influx -Server $iflxServer `
                -Bucket $bucket `
                -Organisation $org `
                -Token $iflxToken `
                -Timestamp $ride.lastUpdated `
                -Measure rideStatus `
                -Tags @{ ride = $ride.ride } `
                -Metrics @{
                "waitTime" = $ride.waitTime
                "status"   = $ride.status
            }
        }
        catch {
            Write-Warning "[WARNING] Could not write ride '$($ride.ride)' to InfluxDB: $(($_.Exception).Message)"
        }
    }

    Write-Information "[OK]   Script finished successfully." -InformationAction Continue
}
catch {
    Write-Error "[FATAL] Unhandled exception: $(($_.Exception).Message)"
}
finally {
    $null = Stop-Transcript
}
