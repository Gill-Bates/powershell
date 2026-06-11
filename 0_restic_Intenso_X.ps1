<#
.SYNOPSIS
    Restic backup script for the Intenso/VeraCrypt X: backup drive.
.DESCRIPTION
    Runs a Restic backup from Z:\ to the repository on X:\ with validation,
    explicit restic.exe path, non-interactive safe mode, repository checks,
    mutex protection, retry handling, and safe prune gating.
.PARAMETER Force
    Skip the manual mount verification prompt. Required together with -Silent.
.PARAMETER Silent
    Suppress console output. File logging remains active.
.EXAMPLE
    .\0_restic_Intenso_X_fixed_dry.ps1 -Force
.EXAMPLE
    .\0_restic_Intenso_X_fixed_dry.ps1 -Force -Silent
#>

#Requires -PSEdition Core
#Requires -Version 7.0

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Silent
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$config = [ordered]@{
    Source                  = "Z:\"
    ResticExe               = "X:\_Restic\restic.exe"
    ResticRepo              = "X:\_Restic\Repository\unraid"
    RepoPasswordFile        = "X:\_Restic\Password\unraid.txt"
    ResticCacheDir          = "X:\_Restic\cache"
    LogFolder               = "X:\_Logs"
    MinimumFreeGB           = 5
    RetentionKeepWithinDays = 365
    ExcludeDirectories      = @("\_CCTV") | Sort-Object

    # Optional: set to e.g. "X:\.restic-intenso-unraid.marker" to verify the correct drive.
    ExpectedMarkerFile      = $null

    MaxRetries              = 3
    RetryBaseDelaySeconds   = 5

    # Safer default: a backup with unreadable source files blocks prune.
    AllowIncompleteBackup   = $false
}

$script:AbortRequested = $false
$script:LogPath = $null
$script:ExitCode = 1
$script:Mutex = $null
$script:CancelHandler = $null

function Get-LogTime {
    Get-Date -Format "yyyy-MM-dd HH:mm:ss"
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "OK", "CMD", "RESTIC", "RESTIC-ERR")]
        [string]$Level = "INFO",
        [ConsoleColor]$Color = [ConsoleColor]::Gray,
        [switch]$NoConsole
    )

    $line = "[$(Get-LogTime)] [$Level] $Message"

    if ($script:LogPath) {
        try {
            Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8
        }
        catch {
            if (-not $Silent -and -not $NoConsole) {
                Write-Host "[$(Get-LogTime)] [WARN] Could not write log: $($_.Exception.Message)" -ForegroundColor Yellow
            }
        }
    }

    if (-not $Silent -and -not $NoConsole) {
        Write-Host $line -ForegroundColor $Color
    }
}

function Initialize-Logging {
    $fileName = "restic_unraid_{0}.log" -f (Get-Date -Format "yyyy-MM-dd")

    try {
        New-Item -ItemType Directory -Path $config.LogFolder -Force | Out-Null
        $script:LogPath = Join-Path $config.LogFolder $fileName
        if (-not (Test-Path -LiteralPath $script:LogPath -PathType Leaf)) {
            New-Item -ItemType File -Path $script:LogPath -Force | Out-Null
        }
    }
    catch {
        $fallbackFolder = Join-Path $env:TEMP "restic-unraid-logs"
        New-Item -ItemType Directory -Path $fallbackFolder -Force | Out-Null
        $script:LogPath = Join-Path $fallbackFolder $fileName
        if (-not (Test-Path -LiteralPath $script:LogPath -PathType Leaf)) {
            New-Item -ItemType File -Path $script:LogPath -Force | Out-Null
        }
        Write-Log "Configured log folder unavailable. Using fallback log '$script:LogPath'. Error: $($_.Exception.Message)" "WARN" Yellow
    }

    Write-Log "Logging initialized: $script:LogPath" "INFO" DarkCyan
}

function Register-CancelHandler {
    try {
        $script:CancelHandler = [System.ConsoleCancelEventHandler] {
            param($Sender, $EventArgs)
            $EventArgs.Cancel = $true
            $script:AbortRequested = $true
            Write-Log "Ctrl+C detected. Requesting graceful shutdown..." "WARN" Yellow
        }
        [System.Console]::CancelKeyPress += $script:CancelHandler
    }
    catch {
        Write-Log "Could not register Ctrl+C handler: $($_.Exception.Message)" "WARN" Yellow
        $script:CancelHandler = $null
    }
}

function Enter-BackupMutex {
    $createdNew = $false
    $script:Mutex = [System.Threading.Mutex]::new($true, "Global\Restic_Intenso_X_Unraid_Backup", [ref]$createdNew)
    if (-not $createdNew) {
        throw "Another backup run is already active."
    }
    Write-Log "Backup mutex acquired." "INFO" DarkCyan
}

function Close-BackupRuntime {
    if ($script:CancelHandler) {
        try { [System.Console]::CancelKeyPress -= $script:CancelHandler } catch {}
        $script:CancelHandler = $null
    }

    if ($script:Mutex) {
        try { $script:Mutex.ReleaseMutex() } catch {}
        try { $script:Mutex.Dispose() } catch {}
        $script:Mutex = $null
    }
}

function Test-WritableDirectory {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    $testFile = Join-Path $Path (".write-test-{0}.tmp" -f ([guid]::NewGuid().ToString("N")))

    try {
        Set-Content -LiteralPath $testFile -Value "write-test" -Encoding UTF8
    }
    catch {
        throw "$Name directory '$Path' is not writable: $($_.Exception.Message)"
    }
    finally {
        Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-DiskSpace {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][double]$RequiredGB
    )

    $qualifier = Split-Path -Path $Path -Qualifier
    if (-not $qualifier) {
        throw "Cannot determine drive for path '$Path'."
    }

    $driveName = $qualifier.TrimEnd([char[]]@(':', '\'))
    $drive = Get-PSDrive -Name $driveName -ErrorAction Stop
    $freeGB = [math]::Round($drive.Free / 1GB, 2)

    if ($freeGB -lt $RequiredGB) {
        throw "Insufficient disk space on $($drive.Name): $freeGB GB available, $RequiredGB GB required."
    }

    Write-Log "Disk space OK: $freeGB GB free on $($drive.Name)." "OK" Green
}

function Test-Configuration {
    $errors = [System.Collections.Generic.List[string]]::new()

    if ($Silent -and -not $Force) { $errors.Add("-Silent requires -Force to avoid blocking prompts.") }
    if (-not (Test-Path -LiteralPath $config.Source -PathType Container)) { $errors.Add("Source path '$($config.Source)' not found.") }
    if (-not (Test-Path -LiteralPath $config.ResticExe -PathType Leaf)) { $errors.Add("Restic executable '$($config.ResticExe)' not found.") }
    if (-not (Test-Path -LiteralPath $config.RepoPasswordFile -PathType Leaf)) { $errors.Add("Password file '$($config.RepoPasswordFile)' not found.") }
    elseif ((Get-Item -LiteralPath $config.RepoPasswordFile).Length -le 0) { $errors.Add("Password file '$($config.RepoPasswordFile)' is empty.") }
    if ([int]$config.RetentionKeepWithinDays -le 0) { $errors.Add("RetentionKeepWithinDays must be positive.") }
    if ([double]$config.MinimumFreeGB -le 0) { $errors.Add("MinimumFreeGB must be positive.") }
    if ([int]$config.MaxRetries -lt 1) { $errors.Add("MaxRetries must be at least 1.") }
    if ($config.ExpectedMarkerFile -and -not (Test-Path -LiteralPath $config.ExpectedMarkerFile -PathType Leaf)) {
        $errors.Add("Expected drive marker '$($config.ExpectedMarkerFile)' not found.")
    }

    if ($errors.Count -gt 0) {
        throw "Configuration errors:`n- $($errors -join "`n- ")"
    }

    Test-WritableDirectory -Path $config.ResticCacheDir -Name "Restic cache"
    Test-DiskSpace -Path $config.ResticRepo -RequiredGB ([double]$config.MinimumFreeGB)
    Write-Log "Configuration validated." "OK" Green
}

function Set-ResticEnvironment {
    $env:RESTIC_REPOSITORY = $config.ResticRepo
    $env:RESTIC_PASSWORD_FILE = $config.RepoPasswordFile
    $env:RESTIC_COMPRESSION = "auto"
    $env:RESTIC_CACHE_DIR = $config.ResticCacheDir
    Write-Log "Restic environment configured for repository '$($config.ResticRepo)'." "INFO" DarkCyan
}

function Confirm-MountReady {
    if ($config.ExpectedMarkerFile) {
        Write-Log "Drive marker verified: $($config.ExpectedMarkerFile)" "OK" Green
        return
    }

    if ($Force) {
        Write-Log "Manual mount verification skipped because -Force was specified." "WARN" Yellow
        return
    }

    $response = Read-Host "`n[$(Get-LogTime)] [INFO] Drive mounted as 'X:' and source mounted as 'Z:'? [Y/n]"
    if ($response -and $response -notlike "y*") {
        throw "Mount verification failed."
    }
}

function Get-ResticExitInfo {
    param([Parameter(Mandatory)][int]$ExitCode)

    switch ($ExitCode) {
        0 { @{ Message = "Success"; Retry = $false } }
        3 { @{ Message = "Some source data could not be read; backup snapshot may be incomplete."; Retry = $true } }
        10 { @{ Message = "Repository does not exist or is not initialized."; Retry = $false } }
        11 { @{ Message = "Repository is already locked."; Retry = $true } }
        12 { @{ Message = "Wrong repository password or password file."; Retry = $false } }
        130 { @{ Message = "Operation was cancelled."; Retry = $false } }
        default { @{ Message = "Restic failed with exit code $ExitCode."; Retry = $true } }
    }
}

function Write-ResticOutput {
    param(
        [AllowNull()][string]$StdOut,
        [AllowNull()][string]$StdErr,
        [switch]$SuppressOutput
    )

    if (-not $SuppressOutput -and $StdOut) {
        foreach ($line in ($StdOut -split '\r?\n')) {
            if ($line -notmatch '\S') { continue }
            if ($line -match '(?i)\b(error|failed|fatal)\b') { Write-Log $line "RESTIC" Red }
            elseif ($line -match '(?i)\b(warn|warning)\b') { Write-Log $line "RESTIC" Yellow }
            elseif ($line -match '(?i)\b(snapshot|repository|added|processed|files|dirs|backup)\b') { Write-Log $line "RESTIC" DarkCyan }
            else { Write-Log $line "RESTIC" DarkGray }
        }
    }

    if ($StdErr) {
        foreach ($line in ($StdErr -split '\r?\n')) {
            if ($line -match '\S') { Write-Log $line "RESTIC-ERR" Red }
        }
    }
}

function Invoke-ResticCommand {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [string]$OperationName = "Restic Operation",
        [switch]$SuppressOutput,
        [switch]$NoRetry
    )

    $attempt = 0
    $maxAttempts = if ($NoRetry) { 1 } else { [int]$config.MaxRetries }

    while ($attempt -lt $maxAttempts) {
        $attempt++
        $tempOut = New-TemporaryFile
        $tempErr = New-TemporaryFile
        $process = $null
        $exitCode = $null

        try {
            $allArgs = @($Command) + $Arguments
            Write-Log "Starting $OperationName (attempt $attempt/$maxAttempts): restic $($allArgs -join ' ')" "CMD" DarkCyan

            $process = Start-Process `
                -FilePath $config.ResticExe `
                -ArgumentList $allArgs `
                -RedirectStandardOutput $tempOut.FullName `
                -RedirectStandardError $tempErr.FullName `
                -NoNewWindow `
                -PassThru

            while (-not $process.HasExited) {
                Start-Sleep -Milliseconds 300
                if ($script:AbortRequested) {
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    throw "Aborted by user."
                }
            }

            $exitCode = [int]$process.ExitCode
            $stdout = Get-Content -LiteralPath $tempOut.FullName -Raw -ErrorAction SilentlyContinue
            $stderr = Get-Content -LiteralPath $tempErr.FullName -Raw -ErrorAction SilentlyContinue
            Write-ResticOutput -StdOut $stdout -StdErr $stderr -SuppressOutput:$SuppressOutput

            if ($exitCode -eq 0) {
                Write-Log "$OperationName completed successfully." "OK" Green
                return [pscustomobject]@{ Success = $true; ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr }
            }

            if ($Command -eq "backup" -and $exitCode -eq 3 -and [bool]$config.AllowIncompleteBackup) {
                Write-Log "$OperationName completed with unreadable files; continuing because AllowIncompleteBackup is enabled." "WARN" Yellow
                return [pscustomobject]@{ Success = $true; ExitCode = $exitCode; StdOut = $stdout; StdErr = $stderr }
            }

            $exitInfo = Get-ResticExitInfo -ExitCode $exitCode
            throw $exitInfo.Message
        }
        catch {
            $message = $_.Exception.Message

            if ($script:AbortRequested) {
                Write-Log "$OperationName aborted." "ERROR" Red
                return [pscustomobject]@{ Success = $false; ExitCode = 130; StdOut = $null; StdErr = $message }
            }

            $retry = $false
            if ($null -ne $exitCode) {
                $retry = (Get-ResticExitInfo -ExitCode $exitCode).Retry
            }

            if (-not $retry -or $attempt -ge $maxAttempts) {
                Write-Log "$OperationName failed after $attempt attempt(s): $message" "ERROR" Red
                return [pscustomobject]@{ Success = $false; ExitCode = $exitCode; StdOut = $null; StdErr = $message }
            }

            $delay = [int]$config.RetryBaseDelaySeconds * $attempt
            Write-Log "$OperationName failed: $message. Retrying in $delay seconds..." "WARN" Yellow
            Start-Sleep -Seconds $delay
        }
        finally {
            if ($process) {
                try {
                    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
                    $process.Dispose()
                }
                catch {}
            }
            Remove-Item -LiteralPath $tempOut.FullName, $tempErr.FullName -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-SnapshotInfo {
    $result = Invoke-ResticCommand -Command "snapshots" -Arguments @("--json") -OperationName "Snapshot Info" -SuppressOutput -NoRetry
    if (-not $result.Success) {
        throw "Unable to retrieve snapshot info: $($result.StdErr)"
    }

    if (-not $result.StdOut -or -not $result.StdOut.Trim()) {
        Write-Log "No snapshots found." "INFO" DarkCyan
        return @{ HasSnapshots = $false; Count = 0; Last = $null }
    }

    $snapshots = @($result.StdOut | ConvertFrom-Json)
    if ($snapshots.Count -eq 0) {
        Write-Log "No snapshots found." "INFO" DarkCyan
        return @{ HasSnapshots = $false; Count = 0; Last = $null }
    }

    $last = ($snapshots | Sort-Object time -Descending | Select-Object -First 1).time
    Write-Log "Found $($snapshots.Count) snapshot(s). Last snapshot: $last" "INFO" DarkCyan
    return @{ HasSnapshots = $true; Count = $snapshots.Count; Last = $last }
}

function Show-Header {
    if ($Silent) { return }

    Clear-Host
    $hostname = (hostname).ToUpperInvariant()
    $psVersion = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"

    @"
 ____           _   _           ____             _                
|  _ \ ___  ___| |_(_) ___     | __ )  __ _  ___| | ___   _ _ __  
| |_) / _ \/ __| __| |/ __|    |  _ \ / _` |/ __| |/ / | | | '_ \ 
|  _ <  __/\__ \ |_| | (__     | |_) | (_| | (__|   <| |_| | |_) |
|_| \_\___||___/\__|_|\___|    |____/ \__,_|\___|_|\_\\__,_| .__/ 
                                                           |_|    
VeraCrypt Restic Backup Tool | pwsh v$psVersion
Host: $hostname
"@ | Write-Host -ForegroundColor Green
}

function Write-SystemResourceLog {
    try {
        $cpu = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $memory = (($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) / $os.TotalVisibleMemorySize) * 100
        Write-Log "System resources - CPU: $([math]::Round([double]$cpu, 2))%, Memory: $([math]::Round([double]$memory, 2))%." "INFO" Gray
    }
    catch {
        Write-Log "Could not read system resources: $($_.Exception.Message)" "WARN" Yellow
    }
}

try {
    Initialize-Logging
    Register-CancelHandler
    Enter-BackupMutex
    Show-Header

    Set-ResticEnvironment
    Test-Configuration
    Confirm-MountReady
    Write-SystemResourceLog

    if (-not (Invoke-ResticCommand -Command "version" -OperationName "Version Check" -SuppressOutput).Success) {
        throw "Restic version check failed."
    }

    if (-not (Invoke-ResticCommand -Command "cat" -Arguments @("config") -OperationName "Repository Configuration Check" -SuppressOutput).Success) {
        throw "Repository configuration check failed. Repository may be missing, locked, or password may be wrong."
    }

    $snapshotInfo = Get-SnapshotInfo
    if ($snapshotInfo.HasSnapshots) {
        if (-not (Invoke-ResticCommand -Command "check" -OperationName "Repository Health Check" -SuppressOutput:$Silent).Success) {
            throw "Repository health check failed. Aborting backup and prune."
        }
    }
    else {
        Write-Log "Skipping repository health check because no snapshots exist yet." "INFO" DarkCyan
    }

    Write-Log "Starting backup from '$($config.Source)' to '$($config.ResticRepo)'." "INFO" DarkCyan
    Write-Log "Excluding: $($config.ExcludeDirectories -join ', ')" "INFO" DarkCyan

    $excludeArgs = foreach ($exclude in $config.ExcludeDirectories) { "--exclude=$exclude" }
    $backupArgs = @($config.Source, "--cleanup-cache", "--verbose") + @($excludeArgs)

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $backupResult = Invoke-ResticCommand -Command "backup" -Arguments $backupArgs -OperationName "Backup" -SuppressOutput:$Silent
    $timer.Stop()

    if (-not $backupResult.Success) {
        throw "Backup failed. Prune will not run."
    }

    Write-Log "Backup completed in $([math]::Round($timer.Elapsed.TotalMinutes, 2)) minute(s)." "OK" Green
    Test-DiskSpace -Path $config.ResticRepo -RequiredGB ([double]$config.MinimumFreeGB)

    Write-Log "Starting retention cleanup: keep snapshots within the last $($config.RetentionKeepWithinDays) day(s), then prune." "INFO" DarkCyan
    $pruneArgs = @("--keep-within", "$($config.RetentionKeepWithinDays)d", "--prune")

    if (-not (Invoke-ResticCommand -Command "forget" -Arguments $pruneArgs -OperationName "Retention Cleanup / Prune" -SuppressOutput:$Silent).Success) {
        throw "Prune operation failed."
    }

    Write-Log "All operations completed successfully." "OK" Green
    $script:ExitCode = 0
}
catch {
    if ($script:AbortRequested) {
        Write-Log "Backup aborted by user." "ERROR" Red
        $script:ExitCode = 130
    }
    else {
        Write-Log "FATAL ERROR: $($_.Exception.Message)" "ERROR" Red
        $script:ExitCode = 1
    }
}
finally {
    Close-BackupRuntime
    Write-Log "Script finished with exit code $script:ExitCode." "INFO" Gray
    exit $script:ExitCode
}
