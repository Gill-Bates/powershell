#!/usr/bin/env powershell
# Cron every 15 Min
# */15 * * * * pwsh -File "/opt/phl/phl.ps1"

<# 
.SYNOPSIS Phl Waitingtime Processor
.DESCRIPTION 
.NOTES Author:  Gill Bates, Last Update: 2025-04-29
#>

#Requires -PSEdition Core
#Requires -Module Influx

[string]$modules = "./modules"
[string]$logPath = "/var/log/phlapi.log"
[string]$configPath = "/etc/logrotate.d/phlapi"
[string]$bucket = "phl"
[string]$org = "myOrg"
[string]$iflxServer = "https://iflx2.cloudheros.de" # InfluxDB v2
[string]$tokenFile = "iflxToken.txt" # InfluxDB v2 Token

#region ##################### FUNCTIONS AREA ###################### 
################################################################### 

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
    Write-CustomLog -Level "INFO" -Message "Fetching Waiting Time from 'wartezeiten.app' ..." -LogFile $logPath

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

        $query = (Invoke-RestMethod @Params) | Group-Object Name  | Sort-Object Name
    }
    catch {

        $msg = "while fetching Waiting Time from '$($Params.Uri)'! $(($_.Exception).Message)"
        throw $(Write-CustomLog -Level "ERROR" -Message $msg -LogFile $logPath)
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

    Write-CustomLog -Level "OK" -Message "Received Data of '$($obj.Count)' Rides!" -LogFile $logPath
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

function Write-RideMetricsToInflux {
    <#
    .SYNOPSIS
    Writes theme park ride metrics to InfluxDB with dynamic ride names as tags.
    #>
    param (
        [Parameter(Mandatory = $true, ValueFromPipeline = $true)]
        [PSObject[]]$RideData,
        [string]$Bucket,
        [string]$Org,
        [string]$Token,
        [string]$ServerUrl
    )

    begin {
        $headers = @{
            "Authorization" = "Token $Token"
            "Content-Type"  = "text/plain; charset=utf-8"
        }
        $uri = "$ServerUrl/api/v2/write?org=$Org&bucket=$Bucket&precision=s"
        $batch = [System.Collections.Generic.List[string]]::new()
    }

    process {
        foreach ($ride in $RideData) {
            try {
                $timestamp = if ($ride.lastUpdated -is [string]) {
                    [DateTime]::Parse($ride.lastUpdated, [System.Globalization.CultureInfo]::InvariantCulture)
                }
                else {
                    $ride.lastUpdated
                }
                $timestamp = [int]([datetimeoffset]$timestamp).ToUnixTimeSeconds()
    
                $escapedRide = $ride.ride -replace '([ ,="])', '\$1'
                $escapedStatus = ($ride.status -replace '"', '\"')
                $waitTime = [int]$ride.waitTime  # Optional: validieren
                $line = "ride_metrics,ride=$escapedRide status=""$escapedStatus"",waitTime=${waitTime}i $timestamp"
                $batch.Add($line)
            }
            catch {
                Write-Warning "Failed to process ride '$($ride.ride)': $_"
            }
        }
    }
    
    end {
        if ($batch.Count -eq 0) { return }

        try {
            $response = Invoke-RestMethod -Uri $uri -Method Post -Headers $headers -Body ($batch -join "`n")
            Write-Host "Successfully wrote $($batch.Count) records." -ForegroundColor Green
        }
        catch {
            $errorMessage = $_.Exception.Message
            $statusCode = $_.Exception.Response.StatusCode.value__
            $statusDesc = $_.Exception.Response.StatusDescription

            # Read error details SAFELY without async/stream disposal issues
            $errorDetails = try {
                $_.ErrorDetails.Message
            } 
            catch { 
                "Could not retrieve additional error details" 
            }

            Write-Error @"
Failed to write to InfluxDB:
Status: $statusCode ($statusDesc)
Message: $errorMessage
Details: $errorDetails
"@

            # Debugging help
            Write-Warning "Verify these settings:"
            Write-Host "URL: $uri"
            Write-Host "Bucket: $Bucket (must exist)"
            Write-Host "Org: $Org (case-sensitive)"
            Write-Host "Token: $(if($Token) {'***'} else {'MISSING'})"
        }
    }
}
#endregion

#region ##################### PROGRAM AREA ###################### 
################################################################# 

# Import Modules
[int]$count = 1
(Get-ChildItem $modules) | ForEach-Object {

    Write-Host "[INFO] [$count] Importing Module '$($_.Name)' ..."
    Import-Module $_.FullName
    $count++
}

# Load InfluxDB Token
try {
    Write-CustomLog -Level "INFO" -Message "Loading InfluxDB Token from '$tokenFile' ..." -LogFile $logPath
    [string]$iflxToken = Get-Content (Join-Path (Get-Location).Path $tokenFile) -Raw
}
catch {

    $msg = "[ERROR] while reading InfluxDB-Token from File ''! $(($_.Exception).Message)"
    throw $(Write-CustomLog -Level "ERROR" -Message $msg -LogFile $logPath)
}


# Set TLS Version
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

# Enable Logrotate
Enable-Logrotate -LogPath $logPath -ConfigPath $configPath

Write-CustomLog -Level "INFO" -Message "Requesting Park Status ..." -LogFile $logPath
$parkStatus = Get-ParkStatus

if ($parkStatus.isOpen) {
    Write-CustomLog -Level "OK" -Message "Park is OPEN!" -LogFile $logPath
}
else {
    Write-CustomLog -Level "WARNING" -Message "Park is CLOSED!" -LogFile $logPath
}

Write-ParkState -parkStatus $parkStatus

$rides = Get-PhlWaitTime

Write-CustomLog -Level "INFO" -Message "Writing Data to InfluxDB '$iflxServer' ..." -LogFile $logPath

Write-RideMetricsToInflux -Bucket "phl" -Org "myOrg" -Token $iflxToken -ServerUrl $iflxServer -RideData $rides

Write-CustomLog -Level "OK" -Message "Script finished successfully. Bye!" -LogFile $logPath
#endregion