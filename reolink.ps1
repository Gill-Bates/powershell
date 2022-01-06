<# 
.SYNOPSIS Housekeeping for Reolink Videos
.DESCRIPTION 
.NOTES Author: Gill Bates, Last Update: 08.08.2021
#>

#region staticVariables
$homeDir = "/home/reolink/records"
$DeleteDays = 14
$Logfile = "/root/reolink.log"
#endregion

#region Cronjob
# Setup Cron every Midnight!
# Delete Reolink Videos every Midnight
#0 0 * * * pwsh -File "/root/reolink.ps1" > /dev/null 2>&1
#endregion

############################################ FUNCTION AREA ##################################################################
#############################################################################################################################

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

############################################# PROGRAM AREA ##################################################################
#############################################################################################################################
Start-Transcript -Path $Logfile -UseMinimalHeader

$KillDate = (Get-Date).AddDays(-$DeleteDays)
$KillFiles = Get-ChildItem -Path $homeDir -Recurse -Force | Where-Object { $_.CreationTime -lt $KillDate }

if ($KillFiles) {
    if ($?) { Write-Output "[$(Get-Logtime)] [OK] Found '$($KillFiles.Count) Items' to delete ..." }

    $KillFiles | ForEach-Object {

        Write-Output "[$(Get-Logtime)] Remove '$($_.PSChildName)' ..."
        Remove-Item -Path $_.FullName -Recurse -Force
    }
}
else {
    Write-Output "[$(Get-Logtime)] [OK] No Items found to delete! Exit here."
    exit
}
Write-Output "[$(Get-Logtime)] [OK] Job is done! Exit here."
Stop-Transcript
exit