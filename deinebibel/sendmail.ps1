<#
.SYNOPSIS
.DESCRIPTION Script to send Confirmation E-Mails
.LINK https://github.com/Gill-Bates/powershell
.NOTES Last Update: 17.01.2022
#>

# Install-Module -Scope CurrentUser -Name SimplySql -Force
Import-Module SimplySql

#region staticVariables
[string]$mailuser = "web253p7"
[string]$sender = "deinebibel.eu <noreply@deinebibel.eu>"
[string]$smtpServer = "server4.webgo24.de"
[string]$bcc = "tobias@steiner.rs"
[string]$workingDir = "/root/powershell"
[string]$confirmMailBody = "./mail_confirm.htm"
[string]$denyMailBody = "./mail_deny.htm"

# Database Setup
[string]$username = "deinebibel"
[string]$server = "localhost"
[int]$port = 3333
[string]$database = "deinebibel"
[string]$dbtable = "Bestellungen"
#endregion

##### Function #######

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
        $MailBody = Get-Content -Path "$workingDir/$confirmMailBody" -Raw
    }
    elseif ($Deny) {

        $Subject = "Deine Bestellung Nr. $OrderId wurde storniert!"
        $MailBody = Get-Content -Path "$workingDir/$denyMailBody" -Raw
    }

    $MailMessageParam = @{
        "From"        = $sender
        "To"          = "$($_.NameFirst) $($_.NameLast) <$($_.Email)>"
        "BCC"         = $bcc
        "Subject"     = $Subject
        "SmtpServer"  = $smtpServer
        "Credential"  = $MailCredential
        "Port"        = "587"
        "Encoding"    = "UTF8"
        "Body"        = $ExecutionContext.InvokeCommand.ExpandString($MailBody)
        "BodyAsHtml"  = $true
        "UseSsl"      = $true
        "ErrorAction" = "Stop"
    }
    
    try {
        Send-MailMessage @MailMessageParam
    }
    catch {
        throw "$($_.Exception).Message)"
    }
}

##### PROGRAM AREA #####

$dbpasswd = Get-Password -File "$workingDir/pw_deinebibel.txt"
$dbcredential = New-Object System.Management.Automation.PSCredential ($username, $dbpasswd)

# Open SQL Connection
Open-mySqlConnection -SSLMode Required -Server $server -Database $database -Credential $dbcredential -Port $port

if (!($conn = Get-SqlConnection)) {
    throw "[ERROR] Can't open SQL-Connection!"
}
else {
    Write-Output "[OK] SQL-Connection to '$($conn.DataSource)' successful established!"
}

################## CONFIRM ODERS ##################

$query = "SELECT * FROM $dbtable WHERE Sent = 1"
$recipients = Invoke-Sqlquery -Query $query

if (!$recipients) { 
    Write-Output "[OK] No Orders found to notify!"
    Write-Output ""
}
else {
    Write-Output "Found '$($recipients.Count)' Orders!"
}

$count = 1
$recipients | ForEach-Object {

    Write-Output "[$count/$($recipients.Count)] Send Mail to '$($_.Email)' ..."
    $mailpasswd = Get-Password -File "$workingDir/pw_noreply.txt"
    [pscredential]$MailCredential = New-Object System.Management.Automation.PSCredential ($mailuser, $mailpasswd)
    Send-MailNotification -Credential $MailCredential -UserPrincipalName $_.userPrincipalName -NotificationSend $notificationSend -Confirm

    # Update Database
    if ($?) {
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $query = "UPDATE $dbtable SET Sent = '$timestamp' WHERE ID = $($_.ID);"
        Invoke-SqlUpdate -Query $query | Out-Null
    }
    $count++
}

################## DENY ODERS ##################

$query = "SELECT * FROM $dbtable WHERE Sent = 2"
$recipients = Invoke-Sqlquery -Query $query

if (!$recipients) { 
    Write-Output "[OK] No bad Orders found to deny! Exit here."
    Exit
}
else {
    Write-Output "Found '$($recipients.Count)' bad Orders!"
}

$count = 1
$recipients | ForEach-Object {

    Write-Output "[$count/$($recipients.Count)] Send Mail to '$($_.Email)' ..."
    $mailpasswd = Get-Password -File "$workingDir/pw_noreply.txt"
    [pscredential]$MailCredential = New-Object System.Management.Automation.PSCredential ($mailuser, $mailpasswd)
    Send-MailNotification -Credential $MailCredential -UserPrincipalName $_.userPrincipalName -NotificationSend $notificationSend -Deny

    # Update Database
    if ($?) {
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $query = "UPDATE $dbtable SET Sent = 'DENY! ($timestamp)' WHERE ID = $($_.ID);"
        Invoke-SqlUpdate -Query $query | Out-Null

        # Block E-Mail address for further orders
        $query = "UPDATE $dbtable SET Block = '1' WHERE ID = $($_.ID);"
        Invoke-SqlUpdate -Query $query | Out-Null

        # Revoke Confirmation-Token
        $query = "UPDATE $dbtable SET ConfirmToken = NULL WHERE ID = $($_.ID);"
        Invoke-SqlUpdate -Query $query | Out-Null
    }
    $count++
}

if ($?) {
    Write-Output "[OK] All operations done. Exit here!"
    Write-Output ""
}
Exit
# End of Script