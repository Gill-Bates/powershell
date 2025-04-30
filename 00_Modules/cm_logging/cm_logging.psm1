function Write-CustomLog {

    [CmdletBinding()]
    param (       
        [Parameter(Mandatory = $false, Position = 0)]
        [ValidateSet("INFO", "OK", "WARNING", "ERROR")]
        [string]$Level,
        
        [Parameter(Mandatory = $true, Position = 1)]
        [string]$Message,
        
        [Parameter(Mandatory = $false, Position = 2)]
        [string]$LogFile,
        
        [Parameter(Mandatory = $false, Position = 3)]
        [switch]$ForceNew
    )
    
    # Get timestamp
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # Create aligned level label
    $levelLabel = switch ($Level) {
        "OK" { "[OK]      " }
        "INFO" { "[INFO]    " }
        "WARNING" { "[WARNING] " }
        "ERROR" { "[ERROR]   " }
    }
    
    # Format the complete message
    $logMessage = "[$timestamp]  $levelLabel -> $Message"
    
    # Write to appropriate output stream
    switch ($Level) {
        "INFO" { Write-Host $logMessage -ForegroundColor Gray } # DarkGray will be black in Linux!
        "OK" { Write-Host $logMessage -ForegroundColor Green }
        "WARNING" { Write-Host $logMessage -ForegroundColor Yellow }
        "ERROR" { 
            Write-Host $logMessage -ForegroundColor Red
        } # Not as Write-Error! Will double up the error message when used in combination with throw!
    }

    # Write to file if specified
    if ($LogFile) {
        try {
            $logDir = Split-Path -Path $LogFile -Parent
            if (!(Test-Path -Path $logDir)) {
                New-Item -ItemType Directory -Path $logDir -Force | Out-Null
            }

            if ($ForceNew -or -not (Test-Path -Path $LogFile)) {
                # Overwrite or create new
                $logMessage | Out-File -FilePath $LogFile -Encoding UTF8 -Force
            }
            else {
                # Append
                $logMessage | Out-File -FilePath $LogFile -Encoding UTF8 -Append
            }
        }
        catch {
            $errorMessage = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')]  [ERROR]   -> Failed to write to log file: $_"
            Write-Host $errorMessage -ForegroundColor Red
            Write-Error $errorMessage -ErrorAction Continue
        }
    }
}

Export-ModuleMember -Function Write-CustomLog
Export-ModuleMember -Alias Write-Log