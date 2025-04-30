function Enable-Logrotate {
    param (
        [parameter(Mandatory = $true)]
        [string]$LogPath,
        [parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    # Check if config already exists
    if (-Not (Test-Path $ConfigPath)) {

        Write-Log -Level "INFO" -Message "Creating logrotate configuration for $LogPath ..." -LogFile $logPath

        $configContent = @"
$LogPath {
    daily
    missingok
    rotate 7
    compress
    delaycompress
    notifempty
    copytruncate
}
"@

        # Write to temporary file and move with root privileges
        $tempFile = "/tmp/phlapi_logrotate.conf"
        $configContent | Out-File -Encoding ASCII -NoNewline $tempFile
        sudo mv $tempFile $ConfigPath
        sudo chown root:root $ConfigPath
        sudo chmod 644 $ConfigPath

        Write-CustomLog -Level "OK" -Message "Logrotate configuration successfully created at '$ConfigPath'" -LogFile $logPath
  
    }
    else {
        Write-CustomLog -Level "INFO" -Message "Logrotate configuration for $LogPath already exists at $ConfigPath" -LogFile $logPath
    }
}

Export-ModuleMember -Function Enable-Logrotate