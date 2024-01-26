#!/usr/bin/env powershell
# Cron 0 * * * * pwsh -File "/root/phl.ps1"
Import-Module -Name Influx
[string]$iflxServer = "https://iflx.cloudheros.de"
[string]$database = "phl"
[string]$measureGroupName = "phlapi"
[int]$scanStartTime = 08
[int]$scanStopTime = 22


if ( (Get-Date).ToString("HH") -lt $scanStartTime -or (Get-Date).ToString("HH") -gt $scanStopTime ) {

    throw "[ERROR] Park is closed!"
}

function Get-PhlWaitTime {

    Write-Information "[INFO] Fetching Data from Phantasialand ..." -InformationAction Continue
    $phl = (Invoke-RestMethod -Method GET -Uri "https://api.themeparks.wiki/v1/entity/phantasialand/live").liveData | Where-Object { $_.entityType -like "attraction" }

    $obj = @()
    $phl | ForEach-Object {

        $obj += [PSCustomObject]@{
            lastUpdated = [datetime](Get-Date -Format o ($_.lastUpdated ))
            name        = $_.name
            status      = ($_.status).ToLower()
            waitTime    = [int]$_.queue.standby.waitTime
        }
    }
    Write-Information "[INFO] Received Data of '$(($obj).Count)' Rides!" -InformationAction Continue
    return $obj | Sort-Object Name
}

$apiResult = Get-PhlWaitTime

Write-Output "[INFO] Writing Data into InfluxDB '$iflxServer' ..."

$apiResult | ForEach-Object {

    Write-Influx -Measure $measureGroupName -Database $database -Server $iflxServer -Tags @{ride = $_.name } -Timestamp $_.lastUpdated -Metrics @{
        ride     = $_.name
        status   = [string]$_.status
        waitTime = [int]$_.waitTime
    }
}

if ($?) { Write-Output "[OK] Scan completed. Bye!" }
Exit