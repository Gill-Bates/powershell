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
$env:TZ = "Europe/Berlin"

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
    [CmdletBinding()]
    param()

    try {
        # Daten von der API abrufen
        $query = Invoke-RestMethod -Method GET -Uri "https://api.phlsys.de/api/park-infos"

        # Funktion zur Konvertierung der Zeitstempel
        function Convert-Timestamps {
            param(
                [PSObject]$InputObject
            )
            
            $result = @{}
            $InputObject.PSObject.Properties | ForEach-Object {
                $name = $_.Name
                $value = $_.Value
                
                # Erweiterte Prüfung auf Zeitformate
                if ($value -and $value -match '^(\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})?|\d{2}\.\d{2}\.\d{4} \d{2}:\d{2}:\d{2}|\d{2}/\d{2}/\d{4} \d{2}:\d{2}:\d{2})$') {
                    try {
                        # Explizite Kultur für verschiedene Formate
                        $culture = [System.Globalization.CultureInfo]::InvariantCulture
                        if ($value -match '^\d{2}/\d{2}/\d{4}') {
                            $culture = [System.Globalization.CultureInfo]::GetCultureInfo('en-US')
                        }
                        elseif ($value -match '^\d{2}\.\d{2}\.\d{4}') {
                            $culture = [System.Globalization.CultureInfo]::GetCultureInfo('de-DE')
                        }
                        
                        $date = [datetime]::Parse($value, $culture)
                        $result[$name] = $date.ToString("o")  # ISO 8601 Format
                    }
                    catch {
                        $result[$name] = $value
                    }
                }
                else {
                    $result[$name] = $value
                }
            }
            return [PSCustomObject]$result
        }

        # Verarbeitung der API-Antwort
        if ($query -is [Array]) {
            return $query | ForEach-Object { Convert-Timestamps -InputObject $_ }
        }
        else {
            return Convert-Timestamps -InputObject $query
        }
    }
    catch {
        $msg = "while fetching Park Status from 'https://api.phlsys.de'! $(($_.Exception).Message)!"
        throw $(Write-CustomLog -Level "ERROR" -Message $msg -LogFile $logPath)
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
        # Convert the parkStatus object to a hashtable
        $metrics = @{}
        foreach ($property in $parkStatus.PSObject.Properties) {
            $metrics[$property.Name] = $property.Value
        }

        Write-Influx -Server $iflxServer `
            -Bucket $bucket `
            -Organisation $org `
            -Token $iflxToken `
            -Timestamp $parkStatus.updatedAt `
            -Measure parkState `
            -Metrics $metrics
    }
    catch {

        $msg = "[ERROR] while writing parkState into InfluxDB '$iflxServer'"
        throw $(Write-CustomLog -Level "ERROR" -Message $msg -LogFile $logPath)
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
                -Timestamp ($ride.lastUpdated.ToUniversalTime().ToString("o")) `
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