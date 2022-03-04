#!/pwsh

# Script to Block malicious IPs
# Last Update: 09.02.2022
# https://www.lukasthiel.de/wiki/Blacklist_mit_Fail2Ban

#region staticVariables
[string]$blacklistUrl = "https://lists.blocklist.de/lists/all.txt"
[string]$outputFile = "/etc/fail2ban/blacklist.txt"
[bool]$ClassB = $false
#endregion

Write-Output "[INFO] Downloading Blacklist ..."

$rawBlacklist = Invoke-RestMethod -Uri $blacklistUrl
$blacklist = $rawBlacklist -Split ("`n")
Write-Output "[OK] Fetched '$('{0:N0}' -f $blacklist.Count)' blacklisted IPs!"

$finalBlacklist = [System.Collections.Concurrent.ConcurrentBag[psobject]]::new()
$datestamp = (Get-Date)

if ($ClassB) {
    Write-Output "[INFO] Converting IPs now to Class-B Networks! Please wait ..."

    $ipv4Pattern = "^([1-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])(\.([0-9]|[1-9][0-9]|1[0-9][0-9]|2[0-4][0-9]|25[0-5])){3}$"
    $blacklist | ForEach-Object -Parallel {

        $localfinalBlacklist = $using:finalBlacklist
    
        if ($_ -match $using:ipv4Pattern) {
    
            $hostIP = $_.Split('.')[0] + "." + $_.Split('.')[1] + ".0." + "0/16"
        }
        else {
            $hostIP = $_
        }
            
        $localfinalBlacklist.Add($hostIP + " [" + ($using:datestamp).ToString("dd/MM/yyyy HH:mm:ss") + "]")
    }
    
    $finalBlacklistGroup = ($finalBlacklist | Group-Object | Sort-Object -Descending).Name

    # Export Blacklist
    $finalBlacklistGroup | Out-File -Path $outputFile

    if ($?) {
        Write-Output "[OK] Added '$('{0:N0}' -f $finalBlacklistGroup.Count)' Ip-ClassB Networks to Fail2ban! Bye."
    }
}
else {

    Write-Output "[INFO] Converting IPs now! Please wait ..."

    $blacklist | ForEach-Object -Parallel {

        $localfinalBlacklist = $using:finalBlacklist
        $localfinalBlacklist.Add($_ + " [" + ($using:datestamp).ToString("dd/MM/yyyy HH:mm:ss") + "]")
    }

    $finalBlacklist | Out-File -Path $outputFile

    if ($?) {
        Write-Output "[OK] Added '$('{0:N0}' -f $finalBlacklist.Count)' Ip-Addresses to Fail2Ban! Bye."
    }
}

Write-Output ""
# GC
[System.GC]::Collect()
Exit
#End of Script