<# 
.SYNOPSIS Script to perform mariaDB Backups over FTP
.DESCRIPTION 
.NOTES Author: Gill Bates, Last Update: 30.11.2021
#>

# Dump Database every Morning 3 a.m.
# 0 3 * * * pwsh -File /root/powershell/dbbackup.ps1

# apt install p7zip-full  # install 7zip

# Backup
[string]$workingDir = "/root/powershell"
[string]$BackupPath = "/root/dbbackup"
[string]$date = (Get-Date).ToString('yyy-MM-dd')
[int]$retentionDays = 7

if (!(Test-Path -Path $BackupPath)) {

    Write-Output "Creating Backup-Folder ..."
    New-Item -Path $BackupPath -ItemType Directory
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
$pw = "-p" + (Get-Password -File "$workingDir/pw_dbbackup.txt" -AsPlainText)
7za a $pw "$BackupPath/dbbackup_$date.sql.7z" "$BackupPath/dbbackup_$date.sql"

if ($?) {
    Remove-Item -Path "$BackupPath/dbbackup_$date.sql" -Force
}

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
Exit
# End of Script