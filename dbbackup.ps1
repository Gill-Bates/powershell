<# 
.SYNOPSIS Script to perform mariaDB Backups over FTP
.DESCRIPTION 
.NOTES Author: Gill Bates, Last Update: 24.01.2022
#>

# Dump Database every Morning 3 a.m.
# 0 3 * * * pwsh -File /root/powershell/dbbackup.ps1 > /dev/null 2>&1

# apt install p7zip-full  # install 7zip

# Backup
[string]$workingDir = "/root/pwsh/dbbackup"
[string]$BackupPath = "$workingDir/backup"
[string]$pwFile = "$workingDir/pw_dbbackup.txt"
[string]$date = (Get-Date).ToString('yyy-MM-dd')
[int]$retentionDays = 7
[bool]$EncryptArchive = $false

# Start Logging
Get-ChildItem -Path "$workingDir/*.log" | Remove-Item -Force # Delete previous Logs
Start-Transcript -Path "$workingDir\dbbackup_$((Get-Date).ToString('yyyyMMdd-HHmmss')).log" -UseMinimalHeader | Out-Null

if (!(Test-Path -Path $BackupPath)) {

    Write-Output "Creating Backup-Folder '$BackupPath' ..."
    New-Item -Path $BackupPath -ItemType Directory | Out-Null
}

############################################ FUNCTION AREA ##################################################################
#############################################################################################################################

function Get-Password {

    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$File,
        [Parameter(Mandatory = $false)]
        [switch]$AsPlainText
    )

    if ($AsPlainText) {
        $SecurePassword = Get-Content $File | ConvertTo-SecureString
        return ConvertFrom-SecureString -SecureString $SecurePassword -AsPlainText
    }
    else {
        return Get-Content $File | ConvertTo-SecureString
    }
}

############################################# PROGRAM AREA ##################################################################
#############################################################################################################################

# Perform Backup
mysqldump --all-databases | Out-File -Path "$BackupPath/dbbackup_$date.sql"

# Compress Backup
if ($EncryptArchive) {

    $pw = "-p" + (Get-Password -File "$workingDir/pw_dbbackup.txt" -AsPlainText)
    7za a $pw "$BackupPath/dbbackup_$date.sql.7z" "$BackupPath/dbbackup_$date.sql"
}
else {

    Write-Warning "*** Running in UNENCRYPTED MODE ***" -WarningAction Continue
    7za a "$BackupPath/dbbackup_$date.sql.7z" "$BackupPath/dbbackup_$date.sql"
}

# Remove Dump
Remove-Item -Path "$BackupPath/dbbackup_$date.sql" -Force

# Housekeeping
Get-ChildItem -Path $BackupPath -Recurse | Sort-Object CreationTime | ForEach-Object {

    $KillDate = ([datetime]$_.CreationTime).AddDays(+$retentionDays)
    if ( (Get-Date) -gt $KillDate ) {
        Write-Output "Remove old Backup '$($_.Name)' ..."
        Remove-Item -Path $_.FullName -Force
    }
}
if ($?) {
    Write-Output "[OK] Backup successfully created!"
}
Stop-Transcript | Out-Null # Stop Logging
Exit
# End of Script