<#
.SYNOPSIS
    Backup Tool for Robocopy by Fother Mucker
.NOTES
    Last Mdified: 30.12.2024
#>

#Requires -RunAsAdministrator
#Requires -Modules ConfigDefender
#Requires -PSEdition Core

#region staticVariables
[string]$source = "\\10.10.0.10\share"
[string]$dest = "X:\_Unraid"
[string]$logFolder = $dest.Split("_")[0] + "_Logs"
[string]$gitReposLocation = "D:\_Repo" # Backup Location
[array]$excludeDirectories = @(
  $source + "\_CCTV"
)
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

# Start Procere

#region Asking for Mouting
[string]$Question = Read-Host "[$(Get-Logtime)] [INFO] Drive already mounted with Letter 'X' [Y/n]?"

if ($Question -and $Question -notlike "y") {
  Write-Output "[$(Get-Logtime)] Wrong Answer! Bye!"
  Exit
}
#endregion

#region Asking for Multithread
[int]$multiThread = Read-Host "[$(Get-Logtime)] [INFO] How many Threads should be used? [3]"
if (!$multiThread) { [int]$multiThread = 3 }
#endregion

#region Asking for Shutdown
[string]$shutdown = Read-Host "[$(Get-Logtime)] [INFO] Shutdown after finishing? [y/N]?"

if ($shutdown -notlike "y" -or $shutdown -notlike "n") {
  Write-Output "[$(Get-Logtime)] [INFO] Ignoring Shutdown!"
}
#endregion

# Check for Logfile Folder
if (!(Test-Path -Path $logFolder)) {
  try {
    Write-Output "[$(Get-Logtime)] [INFO] Folder for Logfiles missing! Creating Folder '$logFolder' now ..."
    $null = New-Item -Path $logFolder -ItemType "directory"
  }
  catch {
    throw "[ERROR] Can't create Folder '$logFolder': $($_.Exception.Message)!"
  }
}
else {
  Write-Output "[$(Get-Logtime)] [OK]   Folder exist! Proceed ..."
}

# Checking for Backup Drive
$Drive = Get-WmiObject Win32_Volume -Filter ("DriveType={0}" -f [int][System.IO.DriveType]::Removable) | Where-Object { $_.Name -Like $dest.Split("_")[0] }
if (!$Drive) {
  throw "[ERROR] Drive not found or is not mounted as removable Drive. Check your Settings and try again!"
}
else {
  Write-Output "[$(Get-Logtime)] [OK]   Removable Drive '$($Drive.Label)' found with max. Capacity of '$([math]::round($Drive.Capacity /1TB,1)) TB'!"
}

# Disable Defender because of Cracks ...
Write-Host "[$(Get-Logtime)] --------> Disable Defender now ..." -BackgroundColor Gray -ForegroundColor Black
Set-DefenderSettings -Off

Write-Host "`n[$(Get-Logtime)] [INFO] Starting Robocopy with '$multiThread' parallel Threads now ..." -ForegroundColor Green
Write-Warning "[$(Get-Logtime)] Ignoring Directories: '$($excludeDirectories -join ", ")'!" -WarningAction Continue

#region Unraid Backup
Robocopy.exe $source $dest /MIR /TEE /COPY:DAT /DCOPY:T /MT:$mt /XD $excludeDirectories /LOG+:"$logFolder\$(Get-Date -Format yyyy-MM-dd)`_Backup.log"

if ($?) {
  Write-Output "[$(Get-Logtime)] [OK] Robocopy Backup finished successfully!"
}
#endregion

#region Create Backup from Git Repos
$allRepos = Get-ChildItem -Path $gitReposLocation
Write-Host "[$(Get-Logtime)] [INFO] Starting git Backup of '$(($allRepos).Count)' Repositories ..." -ForegroundColor Green
[int]$count = 1
$allRepos | ForEach-Object {

  Write-Output "[$(Get-Logtime)] [$count/$(($allRepos).Count)] [INFO] Backing up '$($_.Name)' ..."
  Set-Location $_.Fullname
  git bundle create ("X:\_Repos\" + $(Get-Date -Format yyyy-MM-dd) + "_" + $($_.Name) + ".bundle") --all
  $count++
}
#endregion

# Enable Defender back again
Write-Host "[$(Get-Logtime)] --------> Enable Defender now ..." -BackgroundColor Gray -ForegroundColor Black
Set-DefenderSettings -On

if ($?) {
  Write-Host "`n[$(Get-Logtime)] [OK] All Backup Operations done. Exit here!`n" -ForegroundColor Green
}

if ($shutdown -like "y") {
  Write-Output "[$(Get-Logtime)] Shutdown Computer now ..."
  Stop-Computer -Force
}
#Exit