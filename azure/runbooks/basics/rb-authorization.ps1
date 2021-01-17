<#
.SYNOPSIS
.DESCRIPTION Azure Automation Authorization. Use this Code to connect your Runbook with Azure Automation.
.LINK https://github.com/Gill-Bates/powershell
.NOTES Powered by Gill-Bates. Last Update: 17.01.2021
#>

#Requires -Module Az.Accounts

#region Authorization
try {
    Write-Output "Logging in into Azure Automation ..."
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
            if ($?) { Write-Output -InputObject "[$(Get-Logtime)] [OK] Login was successfull!" }

        Start-Sleep -Seconds 15 # Don't remove the wait! It can cause strange error messages.
    }
}
catch {
    $ErrorMsg = "[ERROR] while logging in into Azure: $($_.Exception.Message)"
    Write-Error -Message $ErrorMsg
    Exit
}
#endregion