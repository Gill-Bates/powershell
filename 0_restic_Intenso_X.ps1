<#
.SYNOPSIS
    Enhanced Restic Backup Script with better error handling and Ctrl+C support
.DESCRIPTION
    Performs backups using Restic with comprehensive error handling, logging and Ctrl+C interrupt support
.NOTES
    Last Modified: 2025-04-30
    Author: Fother Mucker (enhanced)
#>

#Requires -PSEdition Core

#region Configuration
[string]$source = "Z:\"
[string]$resticRepo = "X:\_Restic\Repository\unraid"
[string]$repoPasswordFile = "X:\_Restic\Password\unraid.txt"
[string]$logFolder = $resticRepo.Split("_")[0] + "_Logs"
[string]$logPath = Join-Path $logFolder ("restic_backup_" + (Get-Date -Format "yyyy-MM-dd") + ".log")
[array]$excludeDirectories = @(
    "\_CCTV"
) | Sort-Object

# Restic environment settings
$resticEnv = @{
    "RESTIC_REPOSITORY"       = $resticRepo
    "RESTIC_PASSWORD_FILE"    = $repoPasswordFile
    "RESTIC_COMPRESSION"      = "auto"
    "RESTIC_CACHE_DIR"        = "X:\_Restic\cache"
    "RESTIC_READ_CONCURRENCY" = 10
}
#endregion

#region Functions
function Get-Logtime {
    return (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

function Invoke-ResticCommand {
    param (
        [string]$Command,
        [string[]]$Arguments,
        [string]$OperationName
    )

    Write-Host "[$(Get-Logtime)] [INFO] Starting $OperationName..." -ForegroundColor DarkCyan
    Write-Host "[$(Get-Logtime)] [CMD]  restic $Command $($Arguments -join ' ')" -ForegroundColor Gray

    try {
        # Start the process
        $processInfo = New-Object System.Diagnostics.ProcessStartInfo
        $processInfo.FileName = "restic"
        $processInfo.Arguments = "$Command $($Arguments -join ' ')"
        $processInfo.RedirectStandardOutput = $true
        $processInfo.RedirectStandardError = $true
        $processInfo.UseShellExecute = $false
        $processInfo.CreateNoWindow = $true

        $process = New-Object System.Diagnostics.Process
        $process.StartInfo = $processInfo

        # Setup Ctrl+C handler
        [console]::TreatControlCAsInput = $false
        $cancelRequested = $false

        # Register the handler
        $handler = [System.ConsoleCancelEventHandler] {
            Write-Host "[$(Get-Logtime)] [WARN] Ctrl+C detected, attempting graceful shutdown..." -ForegroundColor Yellow
            $cancelRequested = $true
            $_.Cancel = $true  # Prevent the process from being terminated immediately
        }
        [Console]::add_CancelKeyPress($handler)

        # Start the process
        $null = $process.Start()

        # Read output asynchronously
        $outputBuilder = New-Object System.Text.StringBuilder
        $errorBuilder = New-Object System.Text.StringBuilder

        $outputTask = $process.StandardOutput.ReadToEndAsync()
        $errorTask = $process.StandardError.ReadToEndAsync()

        # Wait for process to exit with timeout checks
        while (-not $process.WaitForExit(200)) {
            if ($cancelRequested) {
                Write-Host "[$(Get-Logtime)] [WARN] Sending interrupt to restic..." -ForegroundColor Yellow
                $process.Kill()
                throw "Operation cancelled by user"
            }
        }

        # Wait for output to complete
        $outputTask.Wait()
        $errorTask.Wait()

        # Process output
        $output = $outputTask.Result
        $error = $errorTask.Result

        $output -split "`n" | ForEach-Object {
            if ($_) { Write-Host "[$(Get-Logtime)] [RESTIC] $_" -ForegroundColor DarkGray }
        }

        $error -split "`n" | ForEach-Object {
            if ($_) { Write-Host "[$(Get-Logtime)] [RESTIC-ERR] $_" -ForegroundColor DarkRed }
        }

        if ($process.ExitCode -ne 0) {
            throw "Restic $OperationName failed with exit code $($process.ExitCode)"
        }

        Write-Host "[$(Get-Logtime)] [OK]   $OperationName completed successfully" -ForegroundColor Green
        return $true
    }
    catch {
        Write-Host "[$(Get-Logtime)] [ERROR] Failed to execute $OperationName" -ForegroundColor Red
        Write-Host "[$(Get-Logtime)] [ERROR] $_" -ForegroundColor Red
        return $false
    }
    finally {
        # Clean up the handler
        if ($handler) {
            try { [Console]::remove_CancelKeyPress($handler) } catch {}
        }
        # Ensure process is disposed
        if ($process) { $process.Dispose() }
    }
}

function Show-Header {
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
}
#endregion

try {
    # Start Logging
    if (!(Test-Path $logFolder)) {
        $null = New-Item -ItemType Directory -Path $logFolder -Force
    }

    $null = Start-Transcript -UseMinimalHeader -Path $logPath

    # Set environment variables
    $env:Path = "X:\_Restic;" + $env:Path

    foreach ($key in $resticEnv.Keys) {
        Set-Item -Path "env:$key" -Value $resticEnv[$key]
    }

    Show-Header
    
    # Check restic version
    Write-Host "`n[$(Get-Logtime)] [INFO] Restic Version:" -ForegroundColor DarkCyan
    restic version
    if ($LASTEXITCODE -ne 0) {
        throw "Restic is not available or failed to execute"
    }

    # Verify mount
    $question = Read-Host "`n[$(Get-Logtime)] [INFO] Drive already mounted with Letter 'X' [Y/n]?"
    if ($question -and $question -notlike "y") {
        throw "Mount verification failed. Aborting."
    }

    # Check existing snapshots
    $allSnapshots = Get-ChildItem (Join-Path $resticRepo "snapshots") -ErrorAction SilentlyContinue
    if ($allSnapshots) {
        Write-Host "[$(Get-Logtime)] [INFO] Found $($allSnapshots.Count) snapshots (Last: $(($allSnapshots.LastWriteTime | Sort-Object -Descending)[0].ToString('yyyy-MM-dd HH:mm:ss')))" -ForegroundColor DarkCyan
    }
    else {
        Write-Host "[$(Get-Logtime)] [INFO] No snapshots found - maybe new repository?" -ForegroundColor DarkCyan
    }

    # Repository health check
    $healthCheck = Invoke-ResticCommand -Command "check" -OperationName "Repository Health Check"
    if (-not $healthCheck) {
        throw "Repository health check failed"
    }

    # Backup operation
    Write-Host "`n[$(Get-Logtime)] [INFO] Starting backup..." -ForegroundColor DarkCyan
    Write-Host "[$(Get-Logtime)] [INFO] Excluding directories: $($excludeDirectories -join ', ')" -ForegroundColor DarkCyan

    $excludeArgs = $excludeDirectories | ForEach-Object { "--exclude=$_" }
    $backupArgs = @($source, "--cleanup-cache", "--verbose") + $excludeArgs

    $measure = Measure-Command {
        $backupSuccess = Invoke-ResticCommand -Command "backup" -Arguments $backupArgs -OperationName "Backup"
        if (!$backupSuccess) {
            throw "Backup failed"
        }
    }

    Write-Host "[$(Get-Logtime)] [INFO] Backup completed in $([math]::Round($measure.TotalMinutes, 2)) minutes" -ForegroundColor DarkCyan

    # Prune operation
    $pruneArgs = @("--keep-daily", "365", "--prune")
    $pruneSuccess = Invoke-ResticCommand -Command "forget" -Arguments $pruneArgs -OperationName "Prune Operation"
    if (-not $pruneSuccess) {
        throw "Prune operation failed"
    }

    Write-Host "`n[$(Get-Logtime)] [OK] All operations completed successfully" -ForegroundColor Green
}
catch {
    Write-Host "`n[$(Get-Logtime)] [ERROR] FATAL ERROR: $_" -ForegroundColor Red
    Write-Host "[$(Get-Logtime)] [ERROR] Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
}
finally {
    if ($?) {
        Write-Host "`n[$(Get-Logtime)] [OK] Script completed successfully" -ForegroundColor Green
    }
    $null = Stop-Transcript
}