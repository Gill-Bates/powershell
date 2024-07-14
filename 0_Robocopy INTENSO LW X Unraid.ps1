<#
.SYNOPSIS
    Backup Tool for Robocopy by Fother Mucker
.NOTES
    Last Update: 30.05.2024
#>

#region staticVariables
[string]$source = "\\10.10.0.10\share"
[string]$dest = "X:\_Unraid"
[int]$multiThread = 3 # MultiThread
[string]$logFolder = $dest.Split("_")[0] + "_Logs"
[string]$gitReposLocation = "D:\_Repo"
#endregion

#region functions
function Get-Logtime {
  $Timeformat = "yyyy-MM-dd HH:mm:ss"
  return $(Get-Date -Format $Timeformat)
}
#endregion

Clear-Host
Write-Output "`n  ______            _"            
Write-Output "  | ___ \          | |               "
Write-Output "  | |_/ / __._  ___| | ___   _ _ __  "
Write-Output "  | ___ \/ _`  |/ __| |/ / | | | '_ \ "
Write-Output "  | |_/ / (_| | (__|   <| |_| | |_) |"
Write-Output "  \____/ \__,_|\___|_|\_\\__,_| .__/ "
Write-Output "                                | |    "
Write-Output "VeraCrypt Backuptool 2021-2024  |_|  pwsh v$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"
Write-Output "        Running on Host: '$((hostname).ToUpper())'`n"

# Start Procere
[string]$Question = Read-Host "[$(Get-Logtime)] [INFO] Drive already mounted with Letter 'X' (y/n)?"

if ($Question -notlike "y") {
  Write-Output "[$(Get-Logtime)] Bye!"
  Exit
}

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
  Write-Output "[$(Get-Logtime)] [OK]   Drive '$($Drive.Label)' found with max. Capacity of '$([math]::round($Drive.Capacity /1TB,1)) TB'!"
}

Write-Output "[$(Get-Logtime)] [INFO] Starting Robocopy with '$multiThread' parallel Threads now ..."

#region Unraid Backup
Robocopy.exe $source $dest /MIR /TEE /COPY:DAT /DCOPY:T /MT:$mt /LOG+:"$logFolder\$(Get-Date -Format yyyy-MM-dd)`_Backup.log"
if ($?) {
  Write-Output "[$(Get-Logtime)] [OK] Robocopy Backup finished successfully!"
}
#endregion


#region Create Backup from Git Repos
$allRepos = Get-ChildItem -Path $gitReposLocation
Write-Output "[$(Get-Logtime)] [INFO] Starting git Backup of '$(($allRepos).Count)' Repositories ..."
[int]$count = 1
$allRepos | ForEach-Object {

  Write-Output "[$(Get-Logtime)] [$count/$(($allRepos).Count)] [INFO] Backing up '$($_.Name)' ..."
  Set-Location $_.Fullname
  git bundle create ("X:\_Repos\" + $(Get-Date -Format yyyy-MM-dd) + "_" + $($_.Name) + ".bundle") --all
  $count++
}
#endregion

if ($?) {
  Write-Output "`n[$(Get-Logtime)] [OK] All Backup Operations done. Exit here!"
}
#Exit