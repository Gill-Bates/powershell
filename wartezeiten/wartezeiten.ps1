#Requires -PSEdition Core
<#
.SYNOPSIS
  Wartezeiten.APP client that fetches park data and writes opening times + waiting times to InfluxDB 2.x.
  Last Update: 2025-09-24

.DESCRIPTION
  - All configuration is done via the global variables at the top of this file.
  - InfluxDB writes respect the global certificate-validation toggle.
  - Backoff / retry logic for the API is implemented.
  - Output banner (ASCII-art) retained as requested.
#>

# ==============================
# Global Configuration Variables
# ==============================
[string]$API_ENDPOINT = "https://api.wartezeiten.app"
[int]$API_BACKOFF = 2
[string]$LANGUAGE = "en"

# INFLUXDB SETTINGS (global)
$INFLUXDB_ENABLED = $true
$INFLUXDB_URL = "iflx2.cloudheros.de"
$INFLUXDB_PORT = 443
$INFLUXDB_USE_HTTPS = $true
$INFLUXDB_VALIDATE_CERTIFICATE = $true
$INFLUXDB_ORGANIZATION = "myOrg"
$INFLUXDB_BUCKET = "wartezeiten"
$INFLUXDB_TOKEN = "q-tVkYxGtopazibH3Hvzpgb7G7J6O-J0n9L5frQmDDOSu0s7wcTrB8lWo7ApsYyFhAWfH2beERwpTRe3jp344w=="

# PARKS TO QUERY (use park IDs from the API)
[array]$LIST_OF_PARK_IDS = @(
    "phantasialand"
    "europapark"
    "universalepicuniverse"
    "universalislandsofadventure"
    "universalstudiosflorida"
) | Sort-Object

# Global park cache for ID to name mapping
$Global:ParkCache = @{}

# Enforce TLS 1.2 or better
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
Write-Host "✅ [INFO] Security protocol set to: $([Net.ServicePointManager]::SecurityProtocol)" -ForegroundColor Green

#region functions

function Invoke-WartezeitenAPI {
    <#
    .SYNOPSIS
      Lightweight GET with exponential backoff for the wartezeiten.app API using native PowerShell 7 parameters.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        [Parameter(Mandatory = $false)]
        [hashtable]$Headers = @{}
    )

    $irmParams = @{
        Uri               = $Uri
        Method            = 'GET'
        Headers           = $Headers
        MaximumRetryCount = 5
        RetryIntervalSec  = $API_BACKOFF
        ErrorAction       = 'Stop'
    }

    try {
        return Invoke-RestMethod @irmParams
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        
        if ($statusCode -eq 429) {
            Write-Host "⚠️ [WARNING] 429 Too Many Requests - Rate limited, waiting before retry..." -ForegroundColor Yellow
            # Let PowerShell handle the retry automatically via MaximumRetryCount
            throw $_
        }
        elseif ($statusCode -eq 404) {
            Write-Host "❌ [ERROR] 404 Not Found - $Uri" -ForegroundColor Red
            return $null
        }
        else {
            Write-Host "❌ [ERROR] API call failed: $($_.Exception.Message)" -ForegroundColor Red
            throw $_
        }
    }
}

function Get-ParkFriendlyName {
    <#
    .SYNOPSIS
      Get friendly name for a park ID from the global cache.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParkId
    )
    
    if ($Global:ParkCache.ContainsKey($ParkId)) {
        return $Global:ParkCache[$ParkId]
    }
    
    $matchingPark = $Global:AvailableParks | Where-Object { $_.id -eq $ParkId -or $_.uuid -eq $ParkId }
    if ($matchingPark) {
        $friendlyName = $matchingPark.name
        $Global:ParkCache[$ParkId] = $friendlyName
        return $friendlyName
    }
    
    Write-Host "⚠️ [WARNING] Friendly name not found for park ID '$ParkId', using ID as fallback" -ForegroundColor Yellow
    return $ParkId
}

function Initialize-ParkCache {
    <#
    .SYNOPSIS
      Initialize the park cache with friendly names from the API.
    #>
    Write-Host "🔍 [INFO] Initializing park cache..." -ForegroundColor Cyan
    
    $Headers = @{
        accept   = "application/json"
        language = "$LANGUAGE"
    }
    
    try {
        $allParks = Invoke-WartezeitenAPI -Uri "$API_ENDPOINT/v1/parks" -Headers $Headers
        if ($allParks) {
            $Global:AvailableParks = $allParks | Sort-Object land, name
            
            foreach ($park in $Global:AvailableParks) {
                $Global:ParkCache[$park.id] = $park.name
                if ($park.uuid) {
                    $Global:ParkCache[$park.uuid] = $park.name
                }
            }
            
            Write-Host "✅ [SUCCESS] Park cache initialized with $($Global:AvailableParks.Count) parks" -ForegroundColor Green
            return $true
        }
    }
    catch {
        Write-Host "❌ [ERROR] Failed to initialize park cache: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
    
    return $false
}

function Get-InfluxBaseUrl {
    <#
    .SYNOPSIS
      Build base InfluxDB URL from the global settings.
    #>
    if ($INFLUXDB_USE_HTTPS) {
        return "https://$INFLUXDB_URL`:$INFLUXDB_PORT"
    }
    else {
        return "http://$INFLUXDB_URL`:$INFLUXDB_PORT"
    }
}

function Write-InfluxOpeningHours {
    <#
    .SYNOPSIS
      Write opening hours for a park to InfluxDB using line protocol.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$ParkId,
        [Parameter(Mandatory = $true)]
        [string]$ParkName,
        [Parameter(Mandatory = $true)]
        [bool]$OpenedToday,
        [Parameter(Mandatory = $true)]
        [string]$OpenFrom,    # ISO 8601 String von der API
        [Parameter(Mandatory = $true)]
        [string]$ClosedFrom   # ISO 8601 String von der API
    )

    if (-not $INFLUXDB_ENABLED) {
        Write-Host "🔕 [INFO] InfluxDB disabled - skipping opening times for '$ParkName'" -ForegroundColor Gray
        return
    }

    if ([string]::IsNullOrWhiteSpace($INFLUXDB_TOKEN)) {
        Write-Host "⚠️ [WARNING] No InfluxDB token provided - skipping opening times for '$ParkName'" -ForegroundColor Yellow
        return
    }

    try {
        $OpenFromDT = [datetimeoffset]::Parse($OpenFrom)
        $ClosedFromDT = [datetimeoffset]::Parse($ClosedFrom)

        $openTs = [int]$OpenFromDT.ToUnixTimeSeconds()
        $closeTs = [int]$ClosedFromDT.ToUnixTimeSeconds()

        $measurement = "opening_times"
        $tagParkName = $ParkName -replace "([,= ])", '\$1'
        $tags = "park_name=$tagParkName"
        $fields = "opened_today=$OpenedToday,open_from=$openTs,closed_from=$closeTs"
        $line = "$measurement,$tags $fields"

        $baseUrl = Get-InfluxBaseUrl
        $uri = "$baseUrl/api/v2/write?org=$INFLUXDB_ORGANIZATION&bucket=$INFLUXDB_BUCKET&precision=s"

        $irmParams = @{
            Method      = 'Post'
            Uri         = $uri
            Headers     = @{
                "Authorization" = "Token $INFLUXDB_TOKEN"
                "Content-Type"  = "text/plain; charset=utf-8"
            }
            Body        = $line
            ErrorAction = 'Stop'
        }

        if (-not $INFLUXDB_VALIDATE_CERTIFICATE) {
            $irmParams['SkipCertificateCheck'] = $true
        }

        Invoke-RestMethod @irmParams
        Write-Host "✅ [SUCCESS] Opening times for '$ParkName' written to InfluxDB." -ForegroundColor Green
    }
    catch {
        Write-Host "❌ [ERROR] Failed to write opening times for '$ParkName': $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Write-InfluxWaitingTimes {
    <#
    .SYNOPSIS
      Write waiting times array to InfluxDB using line protocol.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [array]$WaitTimes,
        [Parameter(Mandatory = $true)]
        [string]$ParkId,
        [Parameter(Mandatory = $true)]
        [string]$ParkName
    )

    if (-not $INFLUXDB_ENABLED) {
        Write-Host "🔕 [INFO] InfluxDB disabled - skipping waiting times for '$ParkName'" -ForegroundColor Gray
        return
    }

    if ([string]::IsNullOrWhiteSpace($INFLUXDB_TOKEN)) {
        Write-Host "⚠️ [WARNING] No InfluxDB token provided - skipping waiting times for '$ParkName'" -ForegroundColor Yellow
        return
    }

    if ($null -eq $WaitTimes -or $WaitTimes.Count -eq 0) {
        Write-Host "ℹ️ [INFO] No waiting times data to write for park '$ParkName'" -ForegroundColor Yellow
        return
    }

    $measurement = "waiting_times"
    $lines = New-Object System.Collections.Generic.List[string]
    $invalidCount = 0
    $validCount = 0

    foreach ($wt in $WaitTimes) {
        try {
            $hasName = -not [string]::IsNullOrWhiteSpace($wt.name)
            $hasDateTime = -not [string]::IsNullOrWhiteSpace($wt.datetime) -or -not [string]::IsNullOrWhiteSpace($wt.date)
            $hasWaitingTime = ($null -ne $wt.waitingtime) -or ($null -ne $wt.waiting_time)

            if (-not $hasName -or -not $hasDateTime -or -not $hasWaitingTime) {
                $invalidCount++
                continue
            }

            $tagParkName = $ParkName -replace "([,= ])", '\$1'
            $tagRide = ($wt.name) -replace "([,= ])", '\$1'
            $tagStatus = if (-not [string]::IsNullOrEmpty($wt.status)) { 
                $wt.status -replace "([,= ])", '\$1' 
            }
            else { 
                "unknown" 
            }

            $tags = "park_name=$tagParkName,attraction=$tagRide,status=$tagStatus"

            $fields = New-Object System.Collections.Generic.List[string]
            $waitingValue = if ($null -ne $wt.waitingtime) { $wt.waitingtime } elseif ($null -ne $wt.waiting_time) { $wt.waiting_time } else { 0 }
            $fields.Add("waiting_time=$waitingValue")

            if ($wt.code) {
                $fields.Add("code=`"$($wt.code)`"")
            }
            elseif ($wt.uuid) {
                $fields.Add("code=`"$($wt.uuid)`"")
            }

            if ($wt.time) {
                $fields.Add("time=`"$($wt.time)`"")
            }

            $fieldString = ($fields -join ",")

            try {
                $timestamp = [int][double]::Parse((Get-Date $wt.datetime -UFormat %s))
            }
            catch {
                $timestamp = [int][double]::Parse((Get-Date -UFormat %s))
            }

            $line = "$measurement,$tags $fieldString $timestamp"
            [void]$lines.Add($line)
            $validCount++
        }
        catch {
            $invalidCount++
        }
    }

    Write-Host "📊 [DEBUG] Valid entries: $validCount, Invalid entries: $invalidCount, Total received: $($WaitTimes.Count)" -ForegroundColor Gray

    if ($lines.Count -eq 0) {
        Write-Host "⚠️ [WARNING] No valid waiting time lines to write for park '$ParkName'" -ForegroundColor Yellow
        return
    }

    $bulkData = ($lines -join "`n")

    try {
        $baseUrl = Get-InfluxBaseUrl
        $uri = "$baseUrl/api/v2/write?org=$INFLUXDB_ORGANIZATION&bucket=$INFLUXDB_BUCKET&precision=s"

        $irmParams = @{
            Method      = 'Post'
            Uri         = $uri
            Headers     = @{
                "Authorization" = "Token $INFLUXDB_TOKEN"
                "Content-Type"  = "text/plain; charset=utf-8"
            }
            Body        = $bulkData
            ErrorAction = 'Stop'
        }

        if (-not $INFLUXDB_VALIDATE_CERTIFICATE) {
            $irmParams['SkipCertificateCheck'] = $true
        }

        Invoke-RestMethod @irmParams
        Write-Host "✅ [SUCCESS] $($lines.Count) waiting times for park '$ParkName' written to InfluxDB." -ForegroundColor Green
    }
    catch {
        Write-Host "❌ [ERROR] Failed to write waiting times for park '$ParkName': $($_.Exception.Message)" -ForegroundColor Red
    }
}

function Format-ColumnOutput {
    <#
    .SYNOPSIS
      Pretty-print a small table to the console.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [array]$Data,
        [Parameter(Mandatory = $true)]
        [string[]]$Properties,
        [Parameter(Mandatory = $true)]
        [string[]]$Headers,
        [int[]]$Widths = @(30, 20, 15)
    )
    
    $formatString = ""
    for ($i = 0; $i -lt $Widths.Count; $i++) {
        $formatString += "{${i},-$($Widths[$i])}"
    }
    
    $headerLine = $formatString -f $Headers
    $separator = "-" * $headerLine.Length
    
    Write-Host $separator -ForegroundColor Yellow
    Write-Host $headerLine -ForegroundColor Cyan
    Write-Host $separator -ForegroundColor Yellow
    
    foreach ($item in $Data) {
        $values = @()
        foreach ($property in $Properties) {
            $values += $item.$property
        }
        Write-Host ($formatString -f $values) -ForegroundColor White
    }
    
    Write-Host $separator -ForegroundColor Yellow
}

function Test-WaitingTimeEntry {
    <#
    .SYNOPSIS
      Basic validation of API waiting time entry object.
    #>
    param($Entry)
    
    if ($null -eq $Entry) {
        return $false
    }
    
    $hasName = ![string]::IsNullOrWhiteSpace($Entry.name)
    $hasDateTime = ![string]::IsNullOrWhiteSpace($Entry.datetime) -or ![string]::IsNullOrWhiteSpace($Entry.date)
    $hasWaitingTime = $null -ne $Entry.waitingtime -or $null -ne $Entry.waiting_time
    
    return $hasName -and $hasDateTime -and $hasWaitingTime
}


function Get-PhlStatus {
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

#endregion functions

# ------------ MAIN PROGRAM

Write-Host "`n░█░█░█▀█░█▀▄░▀█▀░█▀▀░▀▀█░█▀▀░▀█▀░▀█▀░█▀▀░█▀█░░░░█▀█░█▀█░█▀█" -ForegroundColor Cyan
Write-Host "░█▄█░█▀█░█▀▄░░█░░█▀▀░▄▀░░█▀▀░░█░░░█░░█▀▀░█░█░░░░█▀█░█▀▀░█▀▀" -ForegroundColor Cyan
Write-Host "░▀░▀░▀░▀░▀░▀░░▀░░▀▀▀░▀▀▀░▀▀▀░▀▀▀░░▀░░▀▀▀░▀░▀░▀░░▀░▀░▀░░░▀░░" -ForegroundColor Cyan

Write-Host "`n🎢=================== AVAILABLE PARKS ===================🎢`n" -ForegroundColor Green

# Initialize park cache with friendly names
$cacheInitialized = Initialize-ParkCache

if ($cacheInitialized -and $Global:AvailableParks) {
    Write-Host "📊------------- LIST OF AVAILABLE PARKS -------------" -ForegroundColor Yellow
    Format-ColumnOutput -Data $Global:AvailableParks -Properties @("name", "land", "id") -Headers @("Park Name", "Country", "ID") -Widths @(35, 20, 25)
}

# Validate requested park IDs
$validParkIds = @()
$invalidParkIds = @()

foreach ($parkId in $LIST_OF_PARK_IDS) {
    $friendlyName = Get-ParkFriendlyName -ParkId $parkId

    if ([string]::IsNullOrEmpty($friendlyName)) {
        $invalidParkIds += $parkId
        Write-Host "❌ [INVALID] Park ID '$parkId' not found in available parks" -ForegroundColor Red
    }
    else {
        $validParkIds += $parkId
        Write-Host "✅ [VALID] Park ID '$parkId' resolved to '$friendlyName'" -ForegroundColor Green
    }
}

if ($invalidParkIds.Count -gt 0) {
    Write-Host "⚠️ [WARNING] The following park IDs are invalid and will be skipped: $($invalidParkIds -join ', ')" -ForegroundColor Yellow
}

if ($validParkIds.Count -eq 0) {
    Write-Host "❌ [ERROR] No valid park IDs to process. Exiting." -ForegroundColor Red
    exit 1
}

#region opening times
Write-Host "`n⏰=================== OPENING TIMES ===================⏰`n" -ForegroundColor Green

foreach ($parkId in $validParkIds) {
    $friendlyName = Get-ParkFriendlyName -ParkId $parkId
    Write-Host "🔍 [INFO] Checking opening times for '$friendlyName' ($parkId)..."

    $Headers = @{
        accept = "application/json"
        park   = $parkId
    }

    try {
        $parkData = Invoke-WartezeitenAPI -Uri "$API_ENDPOINT/v1/openingtimes" -Headers $Headers
        
        if ($parkData -and $parkData.opened_today -ne $null) {
            $openedToday = $parkData.opened_today
            $openFrom = [datetime]$parkData.open_from
            $closedFrom = [datetime]$parkData.closed_from

            Write-Host "ℹ️ [INFO] $friendlyName - Open Today: $openedToday, From: $($openFrom.ToString('HH:mm')), Until: $($closedFrom.ToString('HH:mm')) UTC" -ForegroundColor Cyan
            
            Write-InfluxOpeningHours -ParkId $parkId -ParkName $friendlyName -OpenedToday $openedToday -OpenFrom $openFrom -ClosedFrom $closedFrom
        }
        else {
            Write-Host "⚠️ [WARNING] No opening times data available for '$friendlyName'" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "❌ [ERROR] Failed to get opening times for '$friendlyName': $($_.Exception.Message)" -ForegroundColor Red
    }
}
#endregion

#region waitingtimes
Write-Host "`n🎯=================== WAITING TIMES ===================🎯`n" -ForegroundColor Green

foreach ($parkId in $validParkIds) {
    $friendlyName = Get-ParkFriendlyName -ParkId $parkId
    Write-Host "🔍 [INFO] Checking waiting times for '$friendlyName' ($parkId)..." -ForegroundColor Cyan

    $Headers = @{
        accept   = "application/json"
        park     = $parkId
        language = $LANGUAGE
    }

    try {
        $waitingTimes = Invoke-WartezeitenAPI -Uri "$API_ENDPOINT/v1/waitingtimes" -Headers $Headers
        
        if ($waitingTimes -and $waitingTimes.Count -gt 0) {
            $validWaitingTimes = @()
            $invalidCount = 0
            
            foreach ($wt in $waitingTimes) {
                if (Test-WaitingTimeEntry -Entry $wt) {
                    $validWaitingTimes += $wt
                }
                else {
                    $invalidCount++
                }
            }
            
            Write-Host "ℹ️ [INFO] Found $($waitingTimes.Count) total entries, $($validWaitingTimes.Count) valid, $invalidCount invalid for '$friendlyName'" -ForegroundColor Cyan
            
            if ($validWaitingTimes.Count -gt 0) {
                $openAttractions = ($validWaitingTimes | Where-Object { $_.status -eq 'opened' }).Count
                $closedAttractions = ($validWaitingTimes | Where-Object { $_.status -ne 'opened' }).Count
                
                Write-Host "📈 [STATS] Open: $openAttractions, Closed/Maintenance: $closedAttractions" -ForegroundColor Cyan
                Write-InfluxWaitingTimes -WaitTimes $validWaitingTimes -ParkId $parkId -ParkName $friendlyName
            }
            else {
                Write-Host "⚠️ [WARNING] No valid waiting times data available for '$friendlyName'" -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "ℹ️ [INFO] No waiting times data available for '$friendlyName'" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "❌ [ERROR] Failed to get waiting times for '$friendlyName': $($_.Exception.Message)" -ForegroundColor Red
    }
}
#endregion

Write-Host "`n🎉=================== COMPLETED ===================🎉`n" -ForegroundColor Green
Write-Host "✅ [INFO] Script execution finished successfully!" -ForegroundColor Cyan

# Summary
$successCount = $validParkIds.Count
Write-Host "📊 [SUMMARY] Processed $successCount parks:" -ForegroundColor Gray
foreach ($parkId in $validParkIds) {
    $friendlyName = Get-ParkFriendlyName -ParkId $parkId
    Write-Host "   🎠 $friendlyName ($parkId)" -ForegroundColor White
}