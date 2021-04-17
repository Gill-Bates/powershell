<# 
.SYNOPSIS Runbook for creating a new Subscription
.DESCRIPTION 
.NOTES Author: Tobias Steiner, Date: 15.03.2021
#>

#Requires -Modules Az.Account
#Requires -Modules Az.Billing
#Requires -Modules Az.Subscription
#Requires -Modules Az.Resources
#Requires -Modules Az.KeyVault

[CmdletBinding()]
param(
    [parameter(Mandatory = $true)]
    [string]$SubscriptionName = "",
    [parameter(Mandatory = $true)]
    [string]$Environment = "prd", # dev, prd, etc...
    [parameter(Mandatory = $true)]
    [string]$Owner = "tobias.steiner@gothaer.de",
    [parameter(Mandatory = $false)]
    [string]$ManagementGroup = ""
)

#region StaticVariables
[String]$KeyVaultName = 'got-newsubscription-kv'
[String]$TechnicalUserName = 'TUAZUP06@gothaer.onmicrosoft.com'
[String]$KeyVaultName = 'got-newsubscription-kv'
[string]$OfferType = "MS-AZR-0017P"
[String]$TechnicalUserName = 'TUAZUP06@gothaer.onmicrosoft.com'
[string]$MailUserName = "azrunbook" #SMTP Credential
[string]$AdditionalContact = "tobias@steiner.rs"
[string]$EmailSenderAddress = "Azure Automation <azrunbook@gomail.westeurope.cloudapp.azure.com>"
#endregion StaticVariables

#region functions
function Get-Logtime {
    # This function is optimzed for Azure Automation!
    $Timeformat = "yyyy-MM-dd HH:mm:ss" #yyyy-MM-dd HH:mm:ss.fff
    if ((Get-TimeZone).Id -ne "W. Europe Standard Time") {
        try {
            $tDate = (Get-Date).ToUniversalTime()
            $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("W. Europe Standard Time")
            $TimeZone = [System.TimeZoneInfo]::ConvertTimeFromUtc($tDate, $tz)
            return $(Get-Date -Date $TimeZone -Format $Timeformat)
        }
        catch {
            return "$(Get-Date -Format $Timeformat) UTC"
        }
    }
    else { return $(Get-Date -Format $Timeformat) }
}

#### CONNECTION AREA ####
#########################

try {
    Write-Output -InputObject "[$(Get-Logtime)] Logging in into Azure Automation ..."
    # Ensures you do not inherit an AzContext in your runbook
    Disable-AzContextAutosave –Scope Process
    $connection = Get-AutomationConnection -Name AzureRunAsConnection

    while (!($connectionResult) -and ($logonAttempt -le 10)) {
        $LogonAttempt++
        # Logging in to Azure...
    
        $connectionResult = Connect-AzAccount `
            -ServicePrincipal `
            -Tenant $connection.TenantID `
            -ApplicationId $connection.ApplicationID `
            -CertificateThumbprint $connection.CertificateThumbprint

        Start-Sleep -Seconds 30
    }
}
catch {
    $ErrorMsg = "[$(Get-Logtime)] ERROR while logging in into Azure: $($_.Exception.Message)"
    Write-Error -Message $ErrorMsg
    exit
}

#region Retrieving KeyVault Credentials for technical User
try {
    Write-Output -InputObject "[$(Get-Logtime)] Retrieving Credentials from Azure KeyVault for technical User '$($TechnicalUserName.Split('@')[0])' ..."
    $SecurePassword = Get-AzKeyVaultSecret -VaultName $KeyVaultName -Name $TechnicalUserName.Split('@')[0]
    $TUCredential = New-Object System.Management.Automation.PSCredential($TechnicalUserName, $SecurePassword.SecretValue)
}
catch {
    $ErrorMsg = "[$(Get-Logtime)] ERROR while generating connection credential: $($_.Exception.Message)"
    Write-Error -Message $ErrorMsg
    exit
}
#endregion

#region Connect-AzAccount to AzureAD with Technical User
try {
    Write-Output -InputObject "[$(Get-Logtime)] Connecting to AzureAD with User: $($TUCredential.UserName)"
    # Ensures you do not inherit an AzContext in your runTUCredentialbook
    Disable-AzContextAutosave –Scope Process
    $null = Connect-AzAccount -Credential $TUCredential   
}
catch {
    $ErrorMsg = "[$(Get-Logtime)] ERROR while logging in with Technical User: $($_.Exception.Message)" 
    Write-Error -Message $ErrorMsg
    exit
}
#endregion

#region Connect-AzureAD Connecting to AzureAD for RBAC Changes
try {
    Write-Output -InputObject "[$(Get-Logtime)] Connecting to Microsoft AzureAD ..."
    $null = Connect-AzureAD `
        -TenantId $connection.TenantId `
        -ApplicationId $connection.ApplicationId `
        -CertificateThumbprint  $connection.CertificateThumbprint | Out-Null
}
catch {
    $ErrorMsg = "[$(Get-Logtime)] ERROR while connecting to AzureAD: $($_.Exception.Message)"
    Write-Error -Message $ErrorMsg
    exit
}
#endregion

#region Getting the Enterprise Enrollment Account
try {
    Write-Output -InputObject "[$(Get-Logtime)] Getting Azure Enrollment Account"
    $EnrollmentAccountObjectId = (Get-AzEnrollmentAccount)[0].ObjectId
    Write-Output -InputObject "[$(Get-Logtime)] Selected EA-Account: $EnrollmentAccountObjectId"
}
catch {
    $ErrorMsg = "[$(Get-Logtime)] ERROR while getting Enrollment Account $($_.Exception.Message)!"
    Write-Error -Message $ErrorMsg
    exit
}
#endregion

#region Mail Notification
function Send-SuccessNotfication {
    param (
        [System.Management.Automation.PSCredential]$Credential
    )

    if (!$ManagementGroup) {
        $ManagementGroup = "Tenant Root Group"
    }

    $MailBody = @"
    *******************************************************
        AUTOMATISCH ERZEUGTE E-MAIL - NICHT ANTWORTEN!
    Bei Fragen wenden Sie sich an den IPS-CSI-INT Verteiler
    *******************************************************
    
    Guten Tag $($UPNcheck.GivenName) $($UPNcheck.Surname),
    
    soeben wurde eine neue Subscription in Azure bereitgestellt:

    Subscription ........... $($NewSub.Name)
    Subscription-ID ........ $($NewSub.Id)
    Management-Group ....... $ManagementGroup
    Eigentümer: ............ $($UPNcheck.GivenName) $($UPNcheck.Surname) ($Owner)


    Mit freundlichen Grüßen aus der Wolke
    Azure Automation - im Auftrag von GSY-IPS-CSI

    -----
    [OK] All operations done in '$(Get-StopWatch)'.
"@

    $MailMessageParam = @{
        "From"        = $EmailSenderAddress
        "To"          = $Owner
        "CC"          = $AdditionalContact
        "Subject"     = "Ihre neue Subscription in Azure steht bereit! ($($NewSub.Name))"
        "SmtpServer"  = "gomail.westeurope.cloudapp.azure.com"
        "Credential"  = $MailCredential
        "Port"        = "587"
        "Encoding"    = "UTF8"
        "Body"        = $MailBody
        "BodyAsHtml"  = $false #$true
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

##### VALIDATION AREA #####
###########################

# Rewrite Owner
$Owner = $Owner.ToLower()

# UPN-Check
try {
    Write-Output "[$(Get-Logtime)] Asking AAD for existance of User '$Owner' ..."
    $UPNcheck = Get-AzADUser -UserPrincipalName $Owner
    if ($UPNcheck -and $UPNcheck.AccountEnabled) {
        Write-Output -InputObject "[$(Get-Logtime)] [OK] User exists and is enabled! Proceed  ..."
    }
    else {
        throw "[$(Get-Logtime)] AAD-User '$Owner' unknown or User is disabled. Exit here!"
        Exit
    }
}
catch {
    throw "[$(Get-Logtime)] ERROR while checking User '$Owner' inside AzureAD: $($_.Exception.Message)!"
}

# Check Environment
Write-Output "[$(Get-Logtime)] Validating Variables ..."

# Check for special Characters
if (!$Environment -or $Environment.Length -ne 3) {
    throw "Environment does not match Naming-Convention. Try again!"
}
elseif ($SubscriptionName -match '[^a-zA-Z0-9]') {
    throw "Special-Characters in SubscriptionName are not allowed! Try again!"
}

# Check ManagementGroup
$MgMGroupCheck = Get-AzManagementGroup
if ($ManagementGroup -and $ManagementGroup -notin $MgMGroupCheck.Name) {
    throw "Defined Management-Group '$ManagementGroup' does not exist! Check your Parameters and try again."
}

##### PROGRAM AREA #####
########################

$SubName = ($SubscriptionName + "-" + $Environment).ToLower()

try {
    Write-Output -InputObject "[$(Get-Logtime)] Creating new Subscription '$SubName' ..."
    $NewSub = New-AzSubscription -OfferType $OfferType -Name $SubName -EnrollmentAccountObjectId $EnrollmentAccountObjectId -OwnerSignInName $Owner
    if ($?) { Write-Output "[$(Get-Logtime)] [OK] Subscription '$($NewSub.Name)' ($($NewSub.Id)) has been created!" }
}
catch {
    throw "[$(Get-Logtime)] ERROR while creating Subscription: $($Error[0].Exception)!"
}

# Assigning Management Group
try {
    if ($ManagementGroup) {
        Write-Output "[$(Get-Logtime)] Assigning Subscription to Management-Group '$ManagementGroup' ..."
        New-AzManagementGroupSubscription -GroupName $ManagementGroup -SubscriptionId $NewSub.Id
        if ($?) { Write-Output "[$(Get-Logtime)] [OK] Subscription '$($NewSub.Name)' successful!y assigned to '$ManagementGroup'!" }
    }
    else {
        Write-Warning "[$(Get-Logtime)] No Management-Group defined! Assigning to 'Tenant Root Group'!" -WarningAction Continue
    }
}
catch {
    throw "[$(Get-Logtime)] ERROR while assigning Subscription to Management-Group '$ManagementGroup': $($Error[0].Exception)!"
}

# Adding RBAC-Role
try {
    # Check RBAC-Assignment first
    $RBACcheck = Get-AzRoleAssignment -Scope "/subscriptions/$($NewSub.Id)" -RoleDefinitionName Owner

    if ($UPNcheck.Id -notcontains $RBACcheck.ObjectId) {
        Write-Output "[$(Get-Logtime)] Adding RBAC-Ower for User '$Owner' ..." 
        New-AzRoleAssignment -ObjectId $UPNcheck.Id -RoleDefinitionName "Owner" -Scope "/subscriptions/$($NewSub.Id)"
        if ($?) { Write-Output "[$(Get-Logtime)] [OK]: User '$Owner' is now 'Owner' of the Subscription '$($NewSub.Name)'!" }
    }
    else  {
        Write-Warning "User '$Owner' already Owner of the Subscription '$($NewSub.Name)'! Skip Process ..." -WarningAction Continue
    }
}
catch {
    throw "[$(Get-Logtime)] ERROR while adding new Owner to Subscription '$($UpdateSandbox.Name)': $($_.Exception.Message)!"
    Exit
}

# Send E-Mail
Write-Output "[$(Get-Logtime)] Sending E-Mail Notification to '$Owner' ..."
try {
    # Execute
    $MailCredential = Get-AutomationPSCredential -Name $MailUserName
    Send-SuccessNotfication -Credential $MailCredential
    if ($?) { Write-Output "[$(Get-Logtime)] [OK] E-Mail has successfully been send!" }
}
catch {
    throw "[$(Get-Logtime)] Error while sending E-Mail Notification: $($_.Exception.Message)!"
}

if ($?) { Write-Output "[$(Get-Logtime)] [OK] All operations done in '$(Get-StopWatch)'. Exit here!" }
$Stopwatch.Stop()
Exit
# End of Script