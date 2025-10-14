<#
.SYNOPSIS
    Enhanced Restic Backup Script with validation, retry, and graceful interrupt handling.
.DESCRIPTION
    Executes Restic backups with configuration validation, system resource checks,
    automatic retries, structured logging, and clean shutdown on Ctrl+C.
.PARAMETER Force
    Skip mount verification prompt. Use with caution.
.PARAMETER Silent
    Suppress console output (log file still created).
.EXAMPLE
    .\restic-backup.ps1 -Force
.EXAMPLE
    .\restic-backup.ps1 -Silent
.NOTES
    Last Modified: 2025-10-14
    Author: Fother Mucker (Enterprise Edition)
#>

param(
    [switch]$Force,
    [switch]$Silent
)


#Requires -PSEdition Core
#Requires -Version 7.0

#region ════════════════════════════════════════ CONFIGURATION ════════════════════════════════════════
$config = @{
    Source             = "Z:\"
    ResticRepo         = "X:\_Restic\Repository\unraid"
    RepoPasswordFile   = "X:\_Restic\Password\unraid.txt"
    DaysBeforePrune    = 365
    LogFolder          = "X:\_Logs"
    ExcludeDirectories = @("\_CCTV") | Sort-Object
    ResticEnv          = @{
        RESTIC_REPOSITORY    = "X:\_Restic\Repository\unraid"
        RESTIC_PASSWORD_FILE = "X:\_Restic\Password\unraid.txt"
        RESTIC_COMPRESSION   = "auto"
        RESTIC_CACHE_DIR     = "X:\_Restic\cache"
    }
}

$logPath = Join-Path $config.LogFolder ("restic_unraid_" + (Get-Date -Format "yyyy-MM-dd") + ".log")
$script:abortRequested = $false
#endregion

#region ════════════════════════════════════════ UTILITY FUNCTIONS ════════════════════════════════════════
function Get-Logtime { (Get-Date -Format "yyyy-MM-dd HH:mm:ss") }

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR", "OK", "CMD", "RESTIC", "RESTIC-ERR")]
        [string]$Level = "INFO",
        [ConsoleColor]$Color = [ConsoleColor]::Gray,
        [switch]$NoConsole
    )
    if (-not $script:abortRequested -and -not $NoConsole) {
        Write-Host "[$(Get-Logtime)] [$Level] $Message" -ForegroundColor $Color
    }
}

function Handle-CtrlC {
    Write-Log "Ctrl+C detected. Graceful shutdown..." "WARN" Yellow
    $script:abortRequested = $true
    try { Stop-Transcript | Out-Null } catch {}
    Write-Log "Backup aborted by user." "ERROR" Red
    exit 130
}
$null = Register-EngineEvent -SourceIdentifier ConsoleCancel -Action { Handle-CtrlC } -ErrorAction SilentlyContinue
#endregion

#region ════════════════════════════════════════ VALIDATION & CHECKS ════════════════════════════════════════
function Test-Configuration {
    param($Config)
    $errors = @()
    if (-not (Test-Path $Config.Source)) { $errors += "Source path '$($Config.Source)' not found" }
    if (-not (Test-Path $Config.RepoPasswordFile)) { $errors += "Password file '$($Config.RepoPasswordFile)' not found" }
    if ($Config.DaysBeforePrune -le 0) { $errors += "DaysBeforePrune must be positive" }
    if ($errors) { throw "Configuration errors:`n$($errors -join "`n")" }
    Write-Log "Configuration validated." "OK" Green
}

function Test-DiskSpace {
    param($Path, [double]$RequiredGB = 1)
    $drive = Get-PSDrive -Name (Split-Path -Path $Path -Qualifier).TrimEnd(':')
    $freeGB = [math]::Round($drive.Free / 1GB, 2)
    if ($freeGB -lt $RequiredGB) { throw "Insufficient disk space on $($drive.Name): $freeGB GB available, $RequiredGB GB required" }
    Write-Log "Disk space OK: $freeGB GB free on $($drive.Name)`n" "INFO" Green
}

function Get-SystemResources {
    $cpu = (Get-CimInstance -ClassName Win32_Processor |
        Measure-Object -Property LoadPercentage -Average).Average
    $memory = Get-CimInstance -ClassName Win32_OperatingSystem |
    Select-Object @{Name = "MemoryUsage"; Expression = { (($_.TotalVisibleMemorySize - $_.FreePhysicalMemory) / $_.TotalVisibleMemorySize) * 100 } }
    return @{
        CPU    = [math]::Round($cpu, 2)
        Memory = [math]::Round($memory.MemoryUsage, 2)
    }
}
#endregion

#region ════════════════════════════════════════ CORE FUNCTIONS ════════════════════════════════════════
function Initialize-BackupEnvironment {
    Write-Log "Initializing environment..." "INFO" DarkCyan
    if (-not (Test-Path $config.LogFolder)) { New-Item -ItemType Directory -Path $config.LogFolder -Force | Out-Null }
    if (-not ($env:Path -match [regex]::Escape("X:\_Restic"))) { $env:Path = "X:\_Restic;" + $env:Path }
    foreach ($key in $config.ResticEnv.Keys) { Set-Item -Path "env:$key" -Value $config.ResticEnv[$key] }
}

function Invoke-ResticCommand {
    param(
        [string]$Command,
        [string[]]$Arguments = @(),
        [string]$OperationName = "Operation",
        [switch]$SuppressOutput
    )

    if ($script:abortRequested) { return $false }

    $maxRetries = 3; $retryCount = 0
    do {
        $tempOut = New-TemporaryFile; $tempErr = New-TemporaryFile; $process = $null
        try {
            Write-Log "Starting $OperationName..." "INFO" DarkCyan
            $processInfo = @{
                FilePath               = "restic"
                ArgumentList           = @($Command) + $Arguments
                RedirectStandardOutput = $tempOut.FullName
                RedirectStandardError  = $tempErr.FullName
                NoNewWindow            = $true
                PassThru               = $true
            }
            $process = Start-Process @processInfo
            while (-not $process.HasExited) {
                Start-Sleep -Milliseconds 300
                if ($script:abortRequested) {
                    Write-Log "Terminating Restic process..." "WARN" Yellow
                    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
                    throw "Aborted by user"
                }
            }
            $stdout = Get-Content $tempOut.FullName -Raw -ErrorAction SilentlyContinue
            $stderr = Get-Content $tempErr.FullName -Raw -ErrorAction SilentlyContinue
            if (-not $SuppressOutput) {
                $stdout -split "`n" | ForEach-Object {
                    if ($_ -match "error|warn|failed") { Write-Log $_ "RESTIC" Red }
                    elseif ($_ -match "snapshot|repository|added") { Write-Log $_ "RESTIC" DarkCyan }
                    elseif ($_ -match "\S") { Write-Log $_ "RESTIC" DarkGray }
                }
                if ($stderr) { $stderr -split "`n" | ForEach-Object { Write-Log $_ "RESTIC-ERR" Red } }
            }
            if ($process.ExitCode -ne 0) { throw "Restic $OperationName failed with exit code $($process.ExitCode)." }
            Write-Log "$OperationName completed successfully." "OK" Green
            return $true
        }
        catch {
            $retryCount++
            if ($retryCount -ge $maxRetries -or $script:abortRequested) {
                Write-Log "Operation failed after $retryCount attempts: $_" "ERROR" Red
                return $false
            }
            Write-Log "Retry $retryCount/$maxRetries after error: $_" "WARN" Yellow
            Start-Sleep -Seconds (5 * $retryCount)
        }
        finally {
            if ($process) { try { if (-not $process.HasExited) { $process.Kill() } $process.Dispose() } catch {} }
            Remove-Item $tempOut, $tempErr -Force -ErrorAction SilentlyContinue
        }
    } while ($retryCount -lt $maxRetries)
}

function Get-SnapshotInfo {
    try {
        $output = & restic snapshots --json 2>$null
        if ($LASTEXITCODE -eq 0 -and $output) {
            $snapshots = $output | ConvertFrom-Json
            $count = $snapshots.Count
            $last = ($snapshots | Sort-Object time -Descending | Select-Object -First 1).time
            Write-Log "Found $count snapshots (Last: $last)" "INFO" DarkCyan
            return $true
        }
        else {
            Write-Log "No snapshots found (new repository?)" "INFO" DarkCyan
            return $false
        }
    }
    catch {
        Write-Log "Unable to retrieve snapshot info: $_" "WARN" Yellow
        return $false
    }
}

function Show-Header {
    Clear-Host
    $hostname = (hostname).ToUpper()
    $psVersion = "$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"
    @"
██████╗ ███████╗███████╗████████╗██╗ ██████╗    ██████╗  █████╗  ██████╗██╗  ██╗██╗   ██╗██████╗ 
██╔══██╗██╔════╝██╔════╝╚══██╔══╝██║██╔════╝    ██╔══██╗██╔══██╗██╔════╝██║ ██╔╝██║   ██║██╔══██╗
██████╔╝█████╗  ███████╗   ██║   ██║██║         ██████╔╝███████║██║     █████╔╝ ██║   ██║██████╔╝
██╔══██╗██╔══╝  ╚════██║   ██║   ██║██║         ██╔══██╗██╔══██║██║     ██╔═██╗ ██║   ██║██╔═══╝ 
██║  ██║███████╗███████║   ██║   ██║╚██████╗    ██████╔╝██║  ██║╚██████╗██║  ██╗╚██████╔╝██║     
╚═╝  ╚═╝╚══════╝╚══════╝   ╚═╝   ╚═╝ ╚═════╝    ╚═════╝ ╚═╝  ╚═╝ ╚═════╝╚═╝  ╚═╝ ╚═════╝ ╚═╝     
VeraCrypt Restic Backup Tool 2021 - 2025 | pwsh v$psVersion
Host: $hostname`n
"@ | Write-Host -ForegroundColor Green
}
#endregion

#region ════════════════════════════════════════ MAIN EXECUTION ════════════════════════════════════════

try {
    Start-Transcript -UseMinimalHeader -Path $logPath -ErrorAction Stop | Out-Null
    Initialize-BackupEnvironment
    Test-Configuration -Config $config
    Test-DiskSpace -Path $config.ResticRepo -RequiredGB 5

    Show-Header

    $resources = Get-SystemResources
    Write-Log "System resources - CPU: $($resources.CPU)%, Memory: $($resources.Memory)%" "INFO" Gray

    Invoke-ResticCommand -Command "version" -OperationName "Version Check" -SuppressOutput:$Silent | Out-Null
    if ($script:abortRequested) { throw "Aborted by user" }

    if (-not $Force) {
        $response = Read-Host "`n[$(Get-Logtime)] [INFO] Drive mounted as 'X'? [Y/n]"
        if ($response -and $response -notlike "y*") { throw "Mount verification failed. Aborting." }
    }

    $hasSnapshots = Get-SnapshotInfo
    if ($hasSnapshots) {
        Invoke-ResticCommand -Command "check" -OperationName "Repository Health Check" -SuppressOutput:$Silent | Out-Null
    }

    Write-Log "Starting backup..." "INFO" DarkCyan
    Write-Log "Excluding: $($config.ExcludeDirectories -join ', ')" "INFO" DarkCyan
    $excludeArgs = $config.ExcludeDirectories | ForEach-Object { "--exclude=$_" }
    $backupArgs = @($config.Source, "--cleanup-cache", "--verbose") + $excludeArgs

    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $backupSuccess = Invoke-ResticCommand -Command "backup" -Arguments $backupArgs -OperationName "Backup" -SuppressOutput:$Silent
    $timer.Stop()
    if (-not $backupSuccess) { throw "Backup failed." }

    Write-Log "Backup completed in $([math]::Round($timer.Elapsed.TotalMinutes,2)) minutes." "INFO" DarkCyan

    Test-DiskSpace -Path $config.ResticRepo -RequiredGB 5
    Write-Log "Starting prune (keep last $($config.DaysBeforePrune) days)..." "INFO" DarkCyan
    $pruneArgs = @("--keep-within", "$($config.DaysBeforePrune)d", "--prune")
    $pruneSuccess = Invoke-ResticCommand -Command "forget" -Arguments $pruneArgs -OperationName "Prune Operation" -SuppressOutput:$Silent
    if (-not $pruneSuccess) { throw "Prune operation failed." }

    Write-Log "All operations completed successfully." "OK" Green
    exit 0
}
catch {
    if ($script:abortRequested) { exit 130 }
    Write-Log "FATAL ERROR: $_" "ERROR" Red
    Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR" DarkRed
    exit 1
}
finally {
    try { Stop-Transcript | Out-Null } catch {}
    Unregister-Event -SourceIdentifier ConsoleCancel -ErrorAction SilentlyContinue
}
#endregion
