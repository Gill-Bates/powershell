<#
.SYNOPSIS
.DESCRIPTION Place this function in the beginning of your Runbook to print the Logime in your Output. Use the example.
.EXAMPLE Write-Output -InputObject "[$(Get-Logtime)] My Message to tell ..."
.LINK https://github.com/Gill-Bates/powershell
.NOTES Powered by Gill-Bates. Last Update: 17.01.2021
#>

function Get-Logtime {
    # This function is optimzed for Azure Automation!
    $Timeformat = "yyyy-MM-dd HH:mm:ss" #yyyy-MM-dd HH:mm:ss.fff
    if ((Get-TimeZone).Id -ne "W. Europe Standard Time") { # Adapt the TimeZone depending on your needs: (Get-TimeZone).Id
        try {
            $tDate = (Get-Date).ToUniversalTime()
            $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("W. Europe Standard Time")
            $TimeZone = [System.TimeZoneInfo]::ConvertTimeFromUtc($tDate, $tz)
            return $(Get-Date -Date $TimeZone -Format $Timeformat)
        }
        catch {
            return "$(Get-Date -Format $Timeformat) UTC"
        }
    }
    else { return $(Get-Date -Format $Timeformat) }
}