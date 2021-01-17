<# 
.SYNOPSIS Runbook for Bulk-Change of mulitple VMs
.DESCRIPTION 
.LINK https://github.com/Gill-Bates/powershell
.NOTES Powered by Gill-Bates. Last Update: 17.01.2021
#>

#Requires -Module Az.Accounts
#Requires -Module Az.Resources
#Requires -Module Az.Subscription

[CmdletBinding()]
param(
    [parameter(Mandatory = $true)]
    [string]$DesiredSKU = "Standard_F8s_v2", # Desired SKU-Size
    [parameter(Mandatory = $true)]
    [string]$ResourceGroup = "myrg", # Name of the ResourceGroup
    [parameter(Mandatory = $true)]
    [string]$SubscriptionId = "", # Your Subscription-Id like XXXX-XXXXX-XXXX- ...
    [parameter(Mandatory = $true)]
    [string]$Location = "westeurope" # Location of the VMs
)

# Initializing Stopwatch
if ($?) { $StopWatch = [system.diagnostics.stopwatch]::StartNew() }

function Get-Logtime {
    # This function is optimzed for Azure Automation!
    $Timeformat = "yyyy-MM-dd HH:mm:ss" #yyyy-MM-dd HH:mm:ss.fff
    if ((Get-TimeZone).Id -ne "W. Europe Standard Time") { # Adapt the TimeZone depending on your needs: (Get-TimeZone).Id
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

function Get-StopWatch {
    if (!$StopWatch.IsRunning) {
        return "n/a"
    }
    if ($StopWatch.Elapsed.Days -ne 0) {
        return "$($StopWatch.Elapsed.Days) days !!!" 
    }
    if ($StopWatch.Elapsed.Hours -eq 0 -and $StopWatch.Elapsed.Minutes -ne 0) {
        $TimeResult = [math]::round($Stopwatch.Elapsed.TotalMinutes, 2)
        return "$TimeResult Minutes" 
    }
    if ($StopWatch.Elapsed.Hours -eq 0 -and $StopWatch.Elapsed.Minutes -eq 0) {
        $TimeResult = [math]::round($Stopwatch.Elapsed.TotalSeconds, 0)
        return "$TimeResult seconds" 
    }
}

function Get-Quota {
    $1 = ($($DesiredSKU.Split("_")[1])) -Replace ("\d", "")
    $2 = ($($DesiredSKU.Split("_")[2]))
    $SKU = -join ($1, $2)
    $Quota = Get-AzVMUsage -Location $Location `
    | Where-Object { $_.Name.Value -like "*$SKU*" }
    if ($Quota) {
        return $Quota
    }
    else {
        return $false
    }
}

#### CONNECTION AREA ####
#########################

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

#### PROGRAM AREA ####
######################

Write-Output -InputObject "[$(Get-Logtime)] ***** Performing VM Resize-Tasks *****"

# SKU Validation
Write-Output -InputObject "[$(Get-Logtime)] Checking first desired SKU '$DesiredSKU' for availability in '$Location' ..."
try {
    $ListofSKU = Get-AzVMSize -Location $Location | Where-Object -Property Name -eq $DesiredSKU

    if (!$ListofSKU) {

        Write-Warning "[$(Get-Logtime)] [WARNING] Desired SKU '$DesiredSKU' is not available or not written correctly. Check your SKU-Name!"
        Write-Output -InputObject "[$(Get-Logtime)] [OK] All operations done in '$(Get-StopWatch)'. Exit here!"
        $Stopwatch.Stop()
        Exit
    }
    else {
        if ($?) { Write-Output -InputObject "[$(Get-Logtime)] [OK] Looks good! Desired SKU is available! Proceed ..." }

        Write-Output -InputObject "[$(Get-Logtime)] Checking available CPU-Quota in your Region '$Location' now ..."
            
        if (Get-Quota -eq $false) {
            Write-Warning "[$(Get-Logtime)] [WARNING] Can't match your SKU-Size with the current Quota. Proceed ..."
        }
        elseif ((Get-Quota).CurrentValue -le 8) {
            Write-Warning "[$(Get-Logtime)] [WARNING] Not enough Cores available. Change your region!"
            if ($?) { Write-Output -InputObject "[$(Get-Logtime)] [OK] All operations done in '$(Get-StopWatch)'. Exit here!" }
            $Stopwatch.Stop()
            Exit
        }
        else {
            $FreeCores = (Get-Quota).Limit - (Get-Quota).CurrentValue
            if ($?) { Write-Output -InputObject "[$(Get-Logtime)] [OK] '$FreeCores Cores available'! Proceed ..." }
        }
    }
}
catch {
    $ErrorMsg = "[$(Get-Logtime)] [ERROR] while validating desired SKU '$DesiredSKU': $($_.Exception.Message)!"
    Write-Error -Message $ErrorMsg
}

Write-Output -InputObject "[$(Get-Logtime)] Switching into Subscription ..."

# Switch into Subscription
Set-AzContext -SubscriptionID $SubscriptionId

function Get-VMs {
    $VMCandidates = Get-AzVM -ResourceGroupName $ResourceGroup -Status | Where-Object { ( `
                $_.Name -notlike $MasterVM -and `
                $_.ProvisioningState -eq "Succeeded" -and `
                $_.HardwareProfile.VmSize -ne $DesiredSKU ) } `
    | Sort-Object -Property Name
    
    Write-Information "'$(($VMCandidates.Count))' VM-Candidates found for converting into desired SKU '$DesiredSKU'" -InformationAction Continue
    return $VMCandidates
}

Write-Output -InputObject "[$(Get-Logtime)] Searching for VMs. Please wait ..."
$VMs = Get-VMs

if (!$VMs) {
    Write-Output -InputObject "[$(Get-Logtime)] [OK] All VMs are already in desired SKU-Size '$DesiredSKU'! Nothing to do."
    if ($?) { Write-Output -InputObject "[$(Get-Logtime)] [OK] All operations done in '$(Get-StopWatch)'. Exit here!" }
    $Stopwatch.Stop()
    Exit
}
else {
    try {
        Write-Warning "[$(Get-Logtime)] [WARNING] '$(($VMs.Count)) Vms' does not match to desired SKU '$DesiredSKU'! Changing them now ..."
        $Count = 1
        foreach ($VM in $VMs) {
            Write-Output "[$(Get-Logtime)] [$Count/$(($VMs.Count))] Trying to convert '$($VM.Name)' now! This may take a while. Please wait ..."
            $VM.HardwareProfile.VmSize = $DesiredSKU
            Update-AzVM -VM $VM -ResourceGroupName $ResourceGroup
            $Count += 1
        }
    }
    catch {
        $ErrorMsg = "[$(Get-Logtime)] [ERROR] while updating VMs: $($_.Exception.Message)!"
        Write-Error -Message $ErrorMsg
    }
}

if ($?) { Write-Output -InputObject "[$(Get-Logtime)] [OK] All operations done in '$(Get-StopWatch)'. Exit here!" }
$Stopwatch.Stop()
Exit
#End of Script