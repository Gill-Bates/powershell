<#
.SYNOPSIS
.DESCRIPTION Script to send Confirmation E-Mails
.LINK https://github.com/Gill-Bates/powershell
.NOTES Last Update: 25.01.2022
#>

#Requires -Module SimplySql
#Requires -Module Send-MailKitMessage

# Modules
# Install-Module -Name SimplySql -Force
# Install-Module Send-MailKitMessage -Force

#region staticVariables
[string]$workingDir = "/root/pwsh/deinebibel"
[string]$pwFile = "$workingDir/pw_web253p7.txt"
[string]$confirmMailBody = "$workingDir/mail_confirm.htm"
[string]$denyMailBody = "$workingDir/mail_deny.htm"
[string]$mailuser = "web253p7"
[string]$sender = "deinebibel.eu <noreply@deinebibel.eu>"
[string]$smtpServer = "server4.webgo24.de"
[string]$bcc = "tobias@steiner.rs"

# Database
[string]$username = "deinebibel"
[string]$pwDbFile = "$workingDir/pw_deinebibel.txt"
[string]$server = "localhost"
[int]$port = 3333
[string]$database = "deinebibel"
[string]$dbtable = "Bestellungen"
#endregion

############################################ FUNCTION AREA ##################################################################
#############################################################################################################################

function Set-Password {

    Read-host "Enter Password for SMTP" -asSecureString | ConvertFrom-SecureString | Out-File -Path $pwFile
    Read-host "Enter Password for DB" -asSecureString | ConvertFrom-SecureString | Out-File -Path $pwDbFile
}

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

function Send-MailNotification {
    param (
        [System.Management.Automation.PSCredential]$Credential,
        [switch]$Confirm,
        [switch]$Deny
    )

    $OrderId = $_.OrderID
    $NameFirst = $_.NameFirst
    $OrderMailDate = ([datetime]$_.Datestamp).ToString('dd.MM.yyyy')
    $OrderTime = $_.Timestamp
    

    if ($Confirm) {

        $Subject = "Deine Bestellung Nr. $OrderId ist auf dem Weg!"
        $MailBody = Get-Content -Path $confirmMailBody -Raw
    }
    elseif ($Deny) {

        $Subject = "Deine Bestellung Nr. $OrderId wurde storniert!"
        $MailBody = Get-Content -Path $denyMailBody -Raw
    }

    $MailMessageParam = @{
        "UseSecureConnectionIfAvailable" = $true
        "Credential"                     = $MailCredential
        "SMTPServer"                     = $smtpServer
        "Port"                           = "587"
        "From"                           = $sender
        "RecipientList"                  = "$($_.NameFirst) $($_.NameLast) <$($_.Email)>"
        "BCCList"                        = $bcc
        "Subject"                        = $Subject
        "HTMLBody"                       = $ExecutionContext.InvokeCommand.ExpandString($MailBody) # TextBody
        "ErrorAction"                    = "Stop"     
    }
    try {
        Send-MailKitMessage @MailMessageParam
    }
    catch {
        throw "[ERROR] while sending E-Mail: $($_.Exception).Message)"
    }
}

############################################# PROGRAM AREA ##################################################################
#############################################################################################################################

# Start Logging
Get-ChildItem -Path "$workingDir/*.log" | ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force } # Delete previous Logs
Start-Transcript -Path "$workingDir\sendmail_$((Get-Date).ToString('yyyyMMdd-HHmmss')).log" -UseMinimalHeader | Out-Null

$dbpasswd = Get-Password -File $pwDbFile
$dbcredential = New-Object System.Management.Automation.PSCredential ($username, $dbpasswd)

# Open SQL Connection
Open-mySqlConnection -SSLMode Required -Server $server -Database $database -Credential $dbcredential -Port $port
Write-Output ""

if (!($conn = Get-SqlConnection)) {
    throw "[ERROR] Can't open SQL-Connection!"
}
else {
    Write-Output "[OK] SQL-Connection to '$($conn.DataSource)' successful established!"
    Write-Output ""
}

################## CONFIRM ODERS ##################

$query = "SELECT * FROM $dbtable WHERE Sent = 1"
$recipients = Invoke-Sqlquery -Query $query

if (!$recipients) { 
    Write-Output "[OK] No Orders found to notify!"
}
else {
    Write-Output "Found '$($recipients.Count)' Orders!"
}

$count = 1
$recipients | ForEach-Object {

    Write-Output "[$count/$($recipients.Count)] Send Mail to '$($_.Email)' ..."
    $mailpasswd = Get-Password -File $pwFile
    [pscredential]$MailCredential = New-Object System.Management.Automation.PSCredential ($mailuser, $mailpasswd)
    Send-MailNotification -Credential $MailCredential -Confirm

    # Update Database
    if ($?) {
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $query = "UPDATE $dbtable SET Sent = '$timestamp' WHERE Id = $($_.Id);"
        Invoke-SqlUpdate -Query $query | Out-Null
    }
    $count++
}

################## DENY ODERS ##################

$query = "SELECT * FROM $dbtable WHERE Sent = 2"
$recipients = Invoke-Sqlquery -Query $query

if (!$recipients) { 
    Write-Output "[OK] No bad Orders found to deny! Exit here."
    Write-Output ""
    Exit
}
else {
    Write-Output "Found '$($recipients.Count)' bad Orders!"
}

$count = 1
$recipients | ForEach-Object {

    Write-Output "[$count/$($recipients.Count)] Send Mail to '$($_.Email)' ..."
    $mailpasswd = Get-Password -File $pwFile
    [pscredential]$MailCredential = New-Object System.Management.Automation.PSCredential ($mailuser, $mailpasswd)
    Send-MailNotification -Credential $MailCredential -Deny

    # Update Database
    if ($?) {
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $query = "UPDATE $dbtable SET Sent = 'DENY! ($timestamp)' WHERE Id = $($_.Id);"
        Invoke-SqlUpdate -Query $query | Out-Null

        # Block E-Mail address for further orders
        $query = "UPDATE $dbtable SET Block = '1' WHERE Id = $($_.Id);"
        Invoke-SqlUpdate -Query $query | Out-Null

        # Revoke Confirmation-Token
        $query = "UPDATE $dbtable SET ConfirmToken = NULL WHERE Id = $($_.Id);"
        Invoke-SqlUpdate -Query $query | Out-Null
    }
    $count++
}

if ($?) {
    Write-Output ""
    Write-Output "[OK] All operations done. Exit here!"
    Write-Output ""
}
Stop-Transcript | Out-Null # Stop Logging
Exit
# End of Script