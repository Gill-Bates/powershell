<#
.SYNOPSIS
    Backup Tool for Restic by Fother Mucker
.NOTES
    Last Mdified: 06.01.2025
#>

# Requires -RunAsAdministrator
# Requires -Modules ConfigDefender
#Requires -PSEdition Core

#region staticVariables
[string]$source = "Z:\" # Don't use \\10.10.0.10\share - will not work with the Restic GUI
[string]$resticRepo = "X:\_Restic\Repository\unraid" # Root Folder for all Repositories managed by restic
[string]$repoPasswordFile = "X:\_Restic\Password\unraid.txt"
[string]$logFolder = $dest.Split("_")[0] + "_Logs"
[string]$gitReposLocation = "D:\_Repo" # Backup Location
[array]$excludeDirectories = @(
    "\_CCTV"
) | Sort-Object
#endregion

#region functions
function Get-Logtime {
    $Timeformat = "yyyy-MM-dd HH:mm:ss"
    return $(Get-Date -Format $Timeformat)
}
  
function Set-DefenderSettings {
  
    Param
    (
        [Parameter(Mandatory, ParameterSetName = "On" )]
        [switch]$On,
        [Parameter(Mandatory, ParameterSetName = "Off" )]
        [switch]$Off
    )
    
    if ($On) {
        [bool]$bool = $false
        [string]$EnableControlledFolderAccess = "Enabled"
        [string]$MAPSReporting = "Disabled"
  
    }
    elseif ($Off) {
        [bool]$bool = $true
        [string]$EnableControlledFolderAccess = "Disabled"
        [string]$MAPSReporting = "Disabled"
    }
  
    try {
        Set-MpPreference `
            -DisableIntrusionPreventionSystem $bool `
            -DisableIOAVProtection $bool `
            -DisableRealtimeMonitoring $bool `
            -DisableScriptScanning $bool `
            -EnableControlledFolderAccess $EnableControlledFolderAccess `
            -EnableNetworkProtection AuditMode `
            -MAPSReporting $MAPSReporting `
            -SubmitSamplesConsent NeverSend `
            -Force
    }
    catch {
        throw "[ERROR] while changing Defender Settings: $($_.Exception.Message)"
    }
  
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
Write-Host "VeraCrypt Backuptool 2021-2024  |_|  pwsh v$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"
Write-Host "        Running on Host: '$((hostname).ToUpper())'`n" -ForegroundColor Green
#endregion

#region ENV Variables
Write-Host "[INFO] Setting Env-Variables ..." -ForegroundColor DarkCyan
[string]$env:Path += "X:\_Restic" # Path to restic.exe
[string]$Env:RESTIC_REPOSITORY = $resticRepo
[string]$Env:RESTIC_PASSWORD_FILE = $repoPasswordFile
[string]$Env:RESTIC_COMPRESSION = "auto"
[string]$Env:RESTIC_CACHE_DIR = (Join-Path $env:TEMP "Restic")
#[string]$Env:RESTIC_READ_CONCURRENCY = 10 # Default: 2
#endregion

#region Asking for Mouting
[string]$Question = Read-Host "[$(Get-Logtime)] [INFO] Drive already mounted with Letter 'X' [Y/n]?"

if ($Question -and $Question -notlike "y") {
    Write-Host "[$(Get-Logtime)] [INFO] Wrong Answer! Bye!" -ForegroundColor DarkCyan
    Exit
}
#endregion

#region Check Folder for Logfiles
# if (!(Test-Path -Path $logFolder)) {
#     try {
#         Write-Output "[$(Get-Logtime)] [INFO] Folder for Logfiles missing! Creating Folder '$logFolder' now ..." -ForegroundColor DarkCyan
#         $null = New-Item -Path $logFolder -ItemType "directory"
#     }
#     catch {
#         throw "[ERROR] Can't create Folder '$logFolder': $($_.Exception.Message)!"
#     }
# }
# else {
#     Write-Host "[$(Get-Logtime)] [OK]   Folder exist! Proceed ..." -ForegroundColor Green
# }
#endregion
  
#region Checking for Backup Drive
# $Drive = Get-WmiObject Win32_Volume -Filter ("DriveType={0}" -f [int][System.IO.DriveType]::Removable) | Where-Object { $_.Name -Like $dest.Split("_")[0] }
# if (!$Drive) {
#     throw "[ERROR] Drive not found or is not mounted as removable Drive. Check your Settings and try again!"
# }
# else {
#     Write-Host "[$(Get-Logtime)] [OK]   Removable Drive '$($Drive.Label)' found with max. Capacity of '$([math]::round($Drive.Capacity /1TB,1)) TB'!" -ForegroundColor Green
# }
#endregion

#region Snapshots
$allSnapshots = Get-ChildItem (Join-Path $resticRepo "snapshots")
Write-Host "[$(Get-Logtime)] [INFO] Found total '$($allSnapshots.Count)' Snapshots (Last Backup from: $((($allSnapshots.LastWriteTime | Sort-Object -Descending)[0]).ToString("yyyy-MM-dd HH:mm:ss")))" -ForegroundColor DarkCyan
#endregion

#region Check Repo Health
Write-Host "[$(Get-Logtime)] [INFO] Checking Health of Repo. Please wait ...`n" -ForegroundColor DarkCyan
restic check
restic prune
#endregion

#region Disable Defender
Write-Host "`n[$(Get-Logtime)] [INFO] --------> Disable Defender now ..." -ForegroundColor DarkCyan
#Set-DefenderSettings -Off
#endregion

#region Backup
Write-Host "[$(Get-Logtime)] [INFO] Starting Backup now ..." -ForegroundColor DarkCyan
Write-Host "[$(Get-Logtime)] [INFO] Ignoring Directories: '$($excludeDirectories -join ", ")'!`n" -ForegroundColor DarkCyan

restic backup $source `
    --exclude $excludeDirectories `
    --cleanup-cache `
    --verbose
#endregion

if ($?) {

    Write-Host "`n[$(Get-Logtime)] [OK]   All Backup Jobs done. Exit here. Bye!" -ForegroundColor Green
}
# End of Script