<#
.SYNOPSIS
    Enhanced Restic Backup Script with optimized performance and error handling
.DESCRIPTION
    Performs backups using Restic with comprehensive error handling, logging and performance optimizations
.NOTES
    Last Modified: 2025-05-03
    Author: Fother Mucker
#>

#Requires -PSEdition Core
#Requires -Version 7.0

#region Configuration
$config = @{
    Source             = "Z:\"
    ResticRepo         = "X:\_Restic\Repository\unraid"
    RepoPasswordFile   = "X:\_Restic\Password\unraid.txt"
    DaysBeforePrune    = 365
    LogFolder          = "X:\_Logs"  # Fixed path instead of string manipulation
    ExcludeDirectories = @(
        "\_CCTV"
    ) | Sort-Object
    
    ResticEnv          = @{
        RESTIC_REPOSITORY       = "X:\_Restic\Repository\unraid"
        RESTIC_PASSWORD_FILE    = "X:\_Restic\Password\unraid.txt"
        RESTIC_COMPRESSION      = "auto"
        RESTIC_CACHE_DIR        = "X:\_Restic\cache"
        RESTIC_READ_CONCURRENCY = 10
    }
}

$logPath = Join-Path $config.LogFolder ("restic_unraid_" + (Get-Date -Format "yyyy-MM-dd") + ".log")
#endregion

#region Functions
function Get-Logtime {
    return (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

function Invoke-ResticCommand {
    param (
        [string]$Command,
        [string[]]$Arguments,
        [string]$OperationName,
        [switch]$SuppressOutput
    )

    Write-Host "[$(Get-Logtime)] [INFO] Starting $OperationName..." -ForegroundColor DarkCyan
    Write-Host "[$(Get-Logtime)] [CMD]  restic $Command $($Arguments -join ' ')" -ForegroundColor DarkGray

    # Spezialbehandlung für 'version' Befehl
    if ($Command -eq "version") {
        try {
            $versionOutput = & restic version 2>&1
            if (!$SuppressOutput) {
                $versionOutput | ForEach-Object {
                    Write-Host "[$(Get-Logtime)] [RESTIC] $_" -ForegroundColor DarkGray
                }
            }

            Write-Host "[$(Get-Logtime)] $versionOutput" -ForegroundColor DarkGray
            Write-Host "[$(Get-Logtime)] [OK]   $OperationName completed successfully" -ForegroundColor Green
            return $true
        }
        catch {
            Write-Host "[$(Get-Logtime)] [ERROR] Failed to get version" -ForegroundColor Red
            Write-Host "[$(Get-Logtime)] [ERROR] $_" -ForegroundColor Red
            return $false
        }
    }

    $tempOutputFile = $tempErrorFile = $null

    try {
        $tempOutputFile = New-TemporaryFile
        $tempErrorFile = New-TemporaryFile

        $processInfo = @{
            FilePath               = "restic"
            ArgumentList           = @($Command) + $Arguments
            RedirectStandardError  = $tempErrorFile.FullName
            RedirectStandardOutput = $tempOutputFile.FullName
            NoNewWindow            = $true
            PassThru               = $true
        }
        
        $process = Start-Process @processInfo
        $process.WaitForExit()
        
        $output = Get-Content $tempOutputFile.FullName -Raw -ErrorAction SilentlyContinue
        $errorOutput = Get-Content $tempErrorFile.FullName -Raw -ErrorAction SilentlyContinue

        if (!$SuppressOutput) {
            $output -split "`n" | Where-Object { $_ } | ForEach-Object {
                if ($_ -match "error|warn|failed") {
                    Write-Host "[$(Get-Logtime)] [RESTIC] $_" -ForegroundColor Red
                }
                else {
                    Write-Host "[$(Get-Logtime)] [RESTIC] $_" -ForegroundColor DarkGray
                }
            }

            if ($errorOutput) {
                $errorOutput -split "`n" | Where-Object { $_ } | ForEach-Object {
                    Write-Host "[$(Get-Logtime)] [RESTIC-ERROR] $_" -ForegroundColor Red
                }
            }
        }

        if ($process.ExitCode -ne 0) {
            throw "Restic $OperationName failed with exit code $($process.ExitCode)`n$errorOutput"
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
        try {
            if ($tempOutputFile) { Remove-Item $tempOutputFile.FullName -Force -ErrorAction SilentlyContinue }
            if ($tempErrorFile) { Remove-Item $tempErrorFile.FullName -Force -ErrorAction SilentlyContinue }
        }
        catch {
            Write-Host "[$(Get-Logtime)] [WARNING] Could not clean up temp files: $_" -ForegroundColor Yellow
        }
    }
}

function Show-Header {
    Clear-Host
    $hostname = (hostname).ToUpper()
    $psVersion = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"
    
    @"
  ______            _          
  | ___ \          | |         
  | |_/ / __._  ___| | ___   _ _ __  
  | ___ \/ _`  |/ __| |/ / | | | '_ \ 
  | |_/ / (_| | (__|   <| |_| | |_) |
  \____/ \__,_|\___|_|\_\\__,_| .__/ 
                                | |    
VeraCrypt Backuptool 2021-2025  |_|  pwsh v$psVersion
Running on Host: '$hostname'
"@ | Write-Host -ForegroundColor Green
    Write-Host "`n"
}

function Initialize-BackupEnvironment {
    # Create log directory if not exists
    if (-not (Test-Path $config.LogFolder)) {
        $null = New-Item -ItemType Directory -Path $config.LogFolder -Force -ErrorAction Stop
    }
    
    # Set environment variables
    $env:Path = "X:\_Restic;" + $env:Path
    foreach ($key in $config.ResticEnv.Keys) {
        Set-Item -Path "env:$key" -Value $config.ResticEnv[$key] -ErrorAction Stop
    }
}

function Get-SnapshotInfo {
    $snapshotDir = Join-Path $config.ResticRepo "snapshots"
    $snapshots = Get-ChildItem $snapshotDir -ErrorAction SilentlyContinue
    
    if ($snapshots) {
        $lastSnapshot = $snapshots | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        Write-Host "[$(Get-Logtime)] [INFO] Found $($snapshots.Count) snapshots (Last: $($lastSnapshot.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')))" -ForegroundColor DarkCyan
    }
    else {
        Write-Host "[$(Get-Logtime)] [INFO] No snapshots found - new repository?" -ForegroundColor DarkCyan
    }
    
    return [bool]$snapshots
}
#endregion

# Main execution
try {
    # Start logging
    $null = Start-Transcript -UseMinimalHeader -Path $logPath -ErrorAction Stop
    
    Initialize-BackupEnvironment
    Show-Header
    
    # Check restic version
    $null = Invoke-ResticCommand -Command "version" -OperationName "Version Check" -SuppressOutput
    
    # Verify mount
    $question = Read-Host "`n[$(Get-Logtime)] [INFO] Drive already mounted with Letter 'X' [Y/n]?"
    if ($question -and $question -notlike "y*") {
        throw "Mount verification failed. Aborting."
    }
    
    # Check existing snapshots
    $hasSnapshots = Get-SnapshotInfo
    
    # Repository health check
    if ($hasSnapshots) {
        $null = Invoke-ResticCommand -Command "check" -OperationName "Repository Health Check"
    }
    
    # Backup operation
    Write-Host "`n[$(Get-Logtime)] [INFO] Starting backup..." -ForegroundColor DarkCyan
    Write-Host "[$(Get-Logtime)] [INFO] Excluding directories: $($config.ExcludeDirectories -join ', ')" -ForegroundColor DarkCyan
    
    $excludeArgs = $config.ExcludeDirectories | ForEach-Object { "--exclude=$_" }
    $backupArgs = @($config.Source, "--cleanup-cache", "--verbose") + $excludeArgs
    
    $measure = Measure-Command {
        $backupSuccess = Invoke-ResticCommand -Command "backup" -Arguments $backupArgs -OperationName "Backup"
        if (-not $backupSuccess) {
            throw "Backup failed"
        }
    }
    
    Write-Host "[$(Get-Logtime)] [INFO] Backup completed in $([math]::Round($measure.TotalMinutes, 2)) minutes" -ForegroundColor DarkCyan
    
    # Prune operation
    Write-Host "[$(Get-Logtime)] [INFO] Starting Prune process (keep last '$($config.DaysBeforePrune)' Days) ..." -ForegroundColor DarkCyan
    $pruneArgs = @("--keep-daily", "$($config.DaysBeforePrune)", "--prune")
    $pruneSuccess = Invoke-ResticCommand -Command "forget" -Arguments $pruneArgs -OperationName "Prune Operation"
    if (-not $pruneSuccess) {
        throw "Prune operation failed"
    }
    
    Write-Host "`n[$(Get-Logtime)] [OK] All operations completed successfully" -ForegroundColor Green
    exit 0
}
catch {
    Write-Host "`n[$(Get-Logtime)] [ERROR] FATAL ERROR: $_" -ForegroundColor Red
    Write-Host "[$(Get-Logtime)] [ERROR] Stack trace: $($_.ScriptStackTrace)" -ForegroundColor Red
    exit 1
}
finally {
    $null = Stop-Transcript
}