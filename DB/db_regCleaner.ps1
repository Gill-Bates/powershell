<#
.SYNOPSIS
    This script unjail the Edge browser by removing the registry keys that enforce password manager policies.
    Last Update: 2025-05-21

.COPYRIGHT 
    (c) 2025 Gill Bates. All rights reserved.
#>

#Requires -PSEdition Core
#Requires -RunAsAdministrator

#region staticVariables
[string]$registryPath = "HKLM:\SOFTWARE\Policies\Microsoft\Edge"
[array]$valuesToRemove = @(
    "PasswordMonitorAllowed",
    "PasswordGeneratorEnabled",
    "PasswordManagerEnabled"
)
#endregion

function Get-LogTime {
    return (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
}

$null = Start-Transcript -UseMinimalHeader -Path "C:\_Tools\db_regCleaner.log" -Append -NoClobber

if (Test-Path $registryPath) {

    $valuesToRemove | ForEach-Object {

        if (Get-ItemProperty -Path $registryPath -Name $_ -ErrorAction SilentlyContinue) {

            try {
                Remove-ItemProperty -Path $registryPath -Name $_
                Write-Output "[$(Get-LogTime)] [OK]   Successfully removed: '$_'"
            }
            catch {
                Write-Warning "[$(Get-LogTime)] Error removing '$_': $($_.Exception.Message)" -WarningAction Continue
            }
        }
        else {
            Write-Output "[$(Get-LogTime)] [OK]   Value not found: '$_'"
        }
    }
}
else {
    Write-Warning "[$(Get-LogTime)] Registry path not found: '$registryPath'" -WarningAction Continue
}

Write-Output "[$(Get-LogTime)] [OK]   Operation completed. Bye!"
$null = Stop-Transcript