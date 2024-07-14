<# 
.SYNOPSIS SecretStore like Keepass for handling Credentials
.DESCRIPTION 
.NOTES Author: Gill Bates, Last Update: 11.07.2024
#>

# First Install required Modules (are not Part of the Default)
# Docs: https://learn.microsoft.com/en-us/powershell/utility-modules/secretmanagement/get-started/using-secretstore?view=ps-modules
# 

Install-Module Microsoft.PowerShell.SecretManagement -Force -Scope AllUsers
Install-Module Microsoft.PowerShell.SecretStore -Force -Scope AllUsers

Import-Module Microsoft.PowerShell.SecretManagement
Import-Module Microsoft.PowerShell.SecretStore

# Create a Default Vault
Register-SecretVault -Name cloudheros -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault

# Create a Secret
[string]$iflxToken = "ikLgCOW3aSXKFeZbssM11Lnc0G9c6XmoIMfQkFA8PvLmwIwOAc7BYki2M1_ur0xH-lGHiMrrru-oecXGItTJRw=="
Set-Secret -Name iflxTokenPhl -Secret $iflxToken

# Get your Secret as Plain text
Get-Secret -Name iflxTokenPhl -AsPlainText

# Vault Location:
cd $HOME/.secretmanagement/secretvaultregistry

# Using in Automation
# https://learn.microsoft.com/en-us/powershell/utility-modules/secretmanagement/how-to/using-secrets-in-automation?view=ps-modules

$credential = Get-Credential -UserName 'SecureStore'
$securePasswordPath = 'C:\automation\passwd.xml'
$credential.Password | Export-Clixml -Path $securePasswordPath
$password = Import-CliXml -Path $securePasswordPath

$storeConfiguration = @{
    Authentication  = 'Password'
    PasswordTimeout = 3600 # 1 hour
    Interaction     = 'None'
    Password        = $password
    Confirm         = $false
}
Set-SecretStoreConfiguration @storeConfiguration