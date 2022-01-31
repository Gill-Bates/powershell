<#
.SYNOPSIS
.DESCRIPTION Script to send Confirmation E-Mails
.LINK https://github.com/Gill-Bates/powershell
.NOTES Last Update: 31.01.2022
#>

# Install-Module -Name SimplySql -Force
Import-Module SimplySql

# Select Database Mode!
$databaseMode = "postgres" # or "mysql"

#region staticVariables
[string]$mailUser = "web253p7"
[string]$sender = "deinebibel.eu <noreply@deinebibel.eu>"
[string]$smtpServer = "server4.webgo24.de"
[string]$bcc = "tobias@steiner.rs"
[string]$workingDir = "/root/pwsh/deinebibel"
[string]$confirmMailBody = "./mail_confirm.htm"
[string]$denyMailBody = "./mail_deny.htm"
[string]$database = "deinebibel"
[string]$dbtable = "bestellungen"

### DATABASE CONFIG ###
if ($databaseMode -Like "mysql") {

    # Database Setup mySQL
    [string]$username = "deinebibel"
    [string]$server = "localhost"
    [int]$port = 3333
    [string]$database = "deinebibel"
    [string]$dbtable = "bestellungen"
    #endregion
}
elseif ($databaseMode -Like "postgres") {
    # Database Setup postgres
    [string]$username = "deinebibel"
    [string]$server = "localhost"
    [int]$port = 5555
    #endregion
}
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

################## DATABASE AREA ##################

Write-Output ""
Write-Warning "*** Running in Database-Mode '$databaseMode'! ***" -WarningAction Continue
Write-Output ""
$dbpasswd = Get-Password -File "$workingDir/pw_deinebibel.txt"
$dbcredential = New-Object System.Management.Automation.PSCredential ($username, $dbpasswd)

# Open SQL Connection
if ($databaseMode -Like "mysql") {

    Open-mySqlConnection -SSLMode Required -Server $server -Database $database -Credential $dbcredential -Port $port
}
elseif ($databaseMode -Like "postgres") {

    Open-PostGreConnection -Server $server -Port $port -Credential $Credential -TrustSSL -Database $database
}
else {
    throw "No valid Database-Mode selected! Check your config!"
}

# Check Connection
if (!($conn = Get-SqlConnection)) {
    throw "[ERROR] Can't open SQL-Connection!"
}
else {
    Write-Output "[OK] SQL-Connection to '$($conn.DataSource)' successfully established!"
}

################## CONFIRM ODERS ##################

$query = "SELECT * FROM $dbtable WHERE sent = '1'"
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
    $mailPasswd = Get-Password -File "$workingDir/pw_web253p7.txt"
    [pscredential]$MailCredential = New-Object System.Management.Automation.PSCredential ($mailUser, $mailPasswd)
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

$query = "SELECT * FROM $dbtable WHERE sent = '2'"
$recipients = Invoke-Sqlquery -Query $query

if (!$recipients) { 
    Write-Output "[OK] No bad Orders found to deny! Exit here."
    Write-Output ""
    Exit
}
else {
    Write-Output "Found '$($recipients.Count)' bad Orders!"
    Write-Output ""
}

$count = 1
$recipients | ForEach-Object {

    Write-Output "[$count/$($recipients.Count)] Send Mail to '$($_.Email)' ..."
    $mailpasswd = Get-Password -File "$workingDir/pw_web253p7.txt"
    [pscredential]$MailCredential = New-Object System.Management.Automation.PSCredential ($mailuser, $mailpasswd)
    Send-MailNotification -Credential $MailCredential -UserPrincipalName $_.userPrincipalName -NotificationSend $notificationSend -Deny

    # Update Database
    if ($?) {
        $timestamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $query = "UPDATE $dbtable SET sent = 'DENY! ($timestamp)' WHERE id = $($_.id);"
        Invoke-SqlUpdate -Query $query | Out-Null

        # Block E-Mail address for further orders
        $query = "UPDATE $dbtable SET block = '1' WHERE id = $($_.id);"
        Invoke-SqlUpdate -Query $query | Out-Null

        # Revoke Confirmation-Token
        $query = "UPDATE $dbtable SET ConfirmToken = NULL WHERE id = $($_.id);"
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