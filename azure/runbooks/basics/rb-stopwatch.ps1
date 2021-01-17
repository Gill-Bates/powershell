<# 
.SYNOPSIS Use this function to track the timne of your Runbook
.DESCRIPTION Check "$StopWatch.Elapsed" for possible Output variants!
.LINK https://github.com/Gill-Bates/powershell
.NOTES Powered by Gill-Bates. Last Update: 17.01.2021
#>

# Initializing Stopwatch
if ($?) { $StopWatch = [system.diagnostics.stopwatch]::StartNew() }

# Your Code goes here ...

Write-Output "Your Runbook is running for '$($StopWatch.Elapsed.Seconds) seconds'!"

$Stopwatch.Stop()
Exit