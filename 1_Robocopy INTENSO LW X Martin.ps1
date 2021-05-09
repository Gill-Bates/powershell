<#
.SYNOPSIS
    Backup Tool for Robocopy by Fother Mucker
.NOTES
    Last Update: 09.05.2021
#>

#region variables
[string]$Logpath = "_Logfiles"
[string]$DestDrive = "X:"
[int]$MultiTreaths = 3
$PSDefaultParameterValues['*:Encoding'] = 'utf8'
$hostname = hostname
#endregion

#region BackupItems
$BackupItems = @(
    "Z:\_ACDSee"
    "Z:\_Musik"
    "Z:\_iTunes"
    "Z:\_Dokumente"
    "Z:\_Videos"
    "Z:\_Portable"
    "Z:\_Programme"
    "Z:\_Robocopy"
    "D:\_Repo"
)
#endregion

Clear-Host
Write-Host "`n"
Write-Host "______            _"            
Write-Host "| ___ \          | |               "
Write-Host "| |_/ / __._  ___| | ___   _ _ __  "
Write-Host "| ___ \/ _`  |/ __| |/ / | | | '_ \ "
Write-Host "| |_/ / (_| | (__|   <| |_| | |_) |"
Write-Host "\____/ \__,_|\___|_|\_\\__,_| .__/ "
Write-Host "                            | |    "
Write-Host "VeraCrypt Backuptool 2021   |_| PS v$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) "
Write-Host "Running on $hostname"
Write-Host "`n"

#region functions
function Get-Logtime {
    $Timeformat = "yyyy-MM-dd HH:mm:ss"
    return $(Get-Date -Format $Timeformat)
}
#endregion

$Question = Read-Host "[$(Get-Logtime)] Drive already mounted with Letter 'X' (y/n)?"

if ($Question.ToLower() -ne "y") {
    Write-Host "[$(Get-Logtime)] Bye!"
    Write-Host "`n"
    Exit
}

# Checking Prerequisits
$Drive = Get-WmiObject Win32_Volume -Filter ("DriveType={0}" -f [int][System.IO.DriveType]::Removable) | Where-Object -Property Name -eq "$DestDrive\"
if (!$Drive) {
    throw "[$(Get-Logtime)] Drive not found or is not mounted as removable Drive: $($_.Exception.Message)"
}
elseif (!(Test-Path -Path $DestDrive\$Logpath)) {
    try {
        New-Item -Path "$DestDrive\" -Name $Logpath -ItemType "Directory" -Force
    }
    catch {
        throw "[$(Get-Logtime)] Can't create Logpath '$DestDrive\$Logpath'! Check your Enviornment: $($_.Exception.Message)!"
    }   
}

$Count = 1
$BackupItems | Sort-Object | ForEach-Object { 
    Write-Host "[$Count/$($BackupItems.Count)] Checking Source-Path '$_' before starting Backup ..."
    Test-Path -Path $_ -PathType Container | Out-Null
    if ($?) { $Count++ | Out-Null }
    else {
        Write-Error "[$(Get-Logtime)] [$Count/$($BackupItems.Count)] ERROR: Backup-Source '$_' not found! Skip Backup for this Path!" -ErrorAction Continue
    }
}

if ($?) {
    Write-Host "[$(Get-Logtime)] [OK] Drive ($($Drive.FileSystem)) and LogPath '$LogPath' found! Proceed with Backup ..." -ForegroundColor White -BackgroundColor DarkGreen
    Write-Host "`n"
}

# Perform Backup
$Count = 1
foreach ($Item in $BackupItems | Sort-Object) {
    try {
        $BackupName = $Item.Split("_")[1]
        Start-Transcript -LiteralPath "$DestDrive\$Logpath\$(Get-Date -Format yyyy-MM-dd)`_$BackupName.log" -Force | Out-Null
        Write-Host "[$(Get-Logtime)] [$Count/$($BackupItems.Count)] Starting Backup of '$Item' ..." -ForegroundColor White -BackgroundColor DarkGreen
        Write-Host "[$(Get-Logtime)] Running with '$MultiTreaths' simultaneous Threats!" -ForegroundColor White -BackgroundColor DarkGreen
        Robocopy.exe $Item $DestDrive\`_$BackupName /MIR /TEE /FFT /DCOPY:T /MT`:$MultiTreaths # Preserve existing Timestamp!

        if ($?) {
            Write-Host "[$(Get-Logtime)] [$Count/$($BackupItems.Count)] [OK] Backup of '$Item' was successfull!" -ForegroundColor White -BackgroundColor DarkGreen
            Write-Host "`n"
        }
        Stop-Transcript | Out-Null
        $Count++ | Out-Null
    }
    catch {
        throw "[$(Get-Logtime)] [$Count/$($BackupItems.Count)] ERROR while running Robocopy: $($_.Exception.Message)!"
        Stop-Transcript
    }
}

if ($?) { Write-Host "[$(Get-Logtime)] [OK] All '$($BackupItems.Count)' Backup-Operations done. Exit here!" -ForegroundColor White -BackgroundColor DarkGreen }
Exit
# End of Script