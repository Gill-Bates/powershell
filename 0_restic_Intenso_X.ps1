<#
.SYNOPSIS
    Backup Tool for Restic by Fother Mucker
.NOTES
    Last Mdified: 2025-04-25
#>

#Requires -PSEdition Core

#region staticVariables
[string]$source = "Z:\" # Don't use \\10.10.0.10\share - will not work with the Restic GUI
[string]$resticRepo = "X:\_Restic\Repository\unraid" # Root Folder for all Repositories managed by restic
[string]$repoPasswordFile = "X:\_Restic\Password\unraid.txt"
[string]$logFolder = $resticRepo.Split("_")[0] + "_Logs"
[string]$logPath = Join-Path $logFolder ("restic_backup_" + (Get-Date -Format "yyyyMMdd_HHmmss") + ".log")
[string]$gitReposLocation = "X:\_Repos" # Backup Target Location
[array]$excludeDirectories = @(
    "\_CCTV"
) | Sort-Object
#endregion

# Start Logging
$null = Start-Transcript -UseMinimalHeader -Path $logPath

#region ENV Variables
Write-Host "[INFO] Setting Env-Variables ..." -ForegroundColor DarkCyan
$env:Path = "X:\_Restic;" + $env:Path # Path to Restic
[string]$Env:RESTIC_REPOSITORY = $resticRepo
[string]$Env:RESTIC_PASSWORD_FILE = $repoPasswordFile
[string]$Env:RESTIC_COMPRESSION = "auto"
[string]$Env:RESTIC_CACHE_DIR = (Join-Path $env:TEMP "Restic")
[string]$Env:RESTIC_READ_CONCURRENCY = 10 # Default: 2
#endregion

#region functions
function Get-Logtime {
    $Timeformat = "yyyy-MM-dd HH:mm:ss"
    return $(Get-Date -Format $Timeformat)
}
#endregion  

#region header
Clear-Host
Write-Host "`n  ______            _"            -ForegroundColor Green
Write-Host "  | ___ \          | |               " -ForegroundColor Green
Write-Host "  | |_/ / __._  ___| | ___   _ _ __  " -ForegroundColor Green
Write-Host "  | ___ \/ _`  |/ __| |/ / | | | '_ \ " -ForegroundColor Green
Write-Host "  | |_/ / (_| | (__|   <| |_| | |_) |" -ForegroundColor Green
Write-Host "  \____/ \__,_|\___|_|\_\\__,_| .__/ " -ForegroundColor Green
Write-Host "                                | |    " -ForegroundColor Green
Write-Host "VeraCrypt Backuptool 2021-2025  |_|  pwsh v$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"
Write-Host "        Running on Host: '$((hostname).ToUpper())'`n" -ForegroundColor Green
#endregion

restic version

#region Asking for Mouting
[string]$Question = Read-Host "`n[$(Get-Logtime)] [INFO] Drive already mounted with Letter 'X' [Y/n]?"

if ($Question -and $Question -notlike "y") {
    Write-Host "[$(Get-Logtime)] [INFO] Wrong Answer! Bye!" -ForegroundColor DarkCyan
    Exit
}
#endregion

#region Snapshots
$allSnapshots = Get-ChildItem (Join-Path $resticRepo "snapshots")

if ($allSnapshots) {
    Write-Host "[$(Get-Logtime)] [INFO] Found total '$($allSnapshots.Count)' Snapshots (Last Backup from: $((($allSnapshots.LastWriteTime | Sort-Object -Descending)[0]).ToString("yyyy-MM-dd HH:mm:ss")))" -ForegroundColor DarkCyan
}
else {
    Write-Host "[$(Get-Logtime)] [INFO] No Snapshot found! Maybe a new Repository?" -ForegroundColor DarkCyan
}
#endregion

#region Check Repo Health
Write-Host "[$(Get-Logtime)] [INFO] Checking Health of Repo. Please wait ...`n" -ForegroundColor DarkCyan
restic check
#endregion

#region Backup
Write-Host "`n[$(Get-Logtime)] [INFO] Starting Backup now ..." -ForegroundColor DarkCyan
Write-Host "[$(Get-Logtime)] [INFO] Ignoring Directories: '$($excludeDirectories -join ", ")'!`n" -ForegroundColor DarkCyan

try {

    $measure = Measure-Command {

        $excludeArgs = @()
        foreach ($dir in $excludeDirectories) {
            $excludeArgs += "--exclude=$dir"
        }

        restic backup $source `
            $excludeArgs `
            --cleanup-cache `
            --verbose
    }

    if (LASTEXITCODE -eq 0) {
        Write-Host "[$(Get-Logtime)] [OK]   Backup completed successfully in '$($measure.TotalMinutes)' Minutes!" -ForegroundColor Green
    }
    else {
        throw "Backup failed with exit code $LASTEXITCODE"
    }
    
    # Prune
    Write-Host "`n[$(Get-Logtime)] [INFO] Performing Cleanup Tasks ..." -ForegroundColor DarkCyan
    
    restic forget `
        --keep-daily 365 `
        --prune
    
    if (LASTEXITCODE -eq 0) {
        Write-Host "[$(Get-Logtime)] [OK]   Prune completed successfully in '$($measure.TotalMinutes)' Minutes!" -ForegroundColor Green
    }
    else {
        throw "Prune failed with exit code $LASTEXITCODE"
    }
    
    Write-Host "[OK]   All Tasks completed successfully! Bye.`n" -ForegroundColor Green
}
catch {
    Write-Host "ERROR: $_" -ForegroundColor Red
    exit 1
}
finally {
    if ($?) {
        Write-Host "`n[$(Get-Logtime)] [OK]   All Backup Jobs done. Exit here. Bye!" -ForegroundColor Green
        $null = Stop-Transcript
    }
}
#endregion
# End of Script