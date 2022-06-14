<# 
.SYNOPSIS Script to convert Reolink Videos with ffmpeg
.NOTES Author: Tobias Steiner, Date: 13.06.2022
#>

#region staticVariables
[string]$workingDir = "/root/pwsh/reolink"
[string]$BaseDir = "/home/reolink/records/"
[string]$WatermarkFont = "$workingDir/Roboto/Roboto-Bold.ttf"
[string]$fontDownloadUrl = "https://fonts.google.com/download?family=Roboto"
[string]$TranscodingMode = "slow"
[int]$KillDays = 31 # Age of files to delete
#endregion

####### FUNCTIONS AREA #########
if ($?) { $StopWatch = [system.diagnostics.stopwatch]::StartNew() }

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

####### PROGRAM AREA #########

# Start Logging
Get-ChildItem -Path "$workingDir/*.log" | Remove-Item -Force # Delete previous Logs
Start-Transcript -Path "$workingDir\reolink_$((Get-Date).ToString('yyyyMMdd-HHmmss')).log" -UseMinimalHeader | Out-Null

# Check Font
if (!(Get-ChildItem $WatermarkFont -ErrorAction SilentlyContinue)) {

    Write-Warning "Watermark Font is missing! Trying to Install Font ..." -WarningAction Continue
    try {
        wget -c $fontDownloadUrl -O "$workingDir/Roboto.zip"
    }
    catch {
        throw "[ERROR] while downlading Font '': $($_.Exception).Message)"
    }
    
    if ($?) {
        Expand-Archive -Path "$workingDir/Roboto.zip" -DestinationPath "$workingDir/Roboto" -Force
        Remove-Item -Path "$workingDir/Roboto.zip" -Force
        Write-Output "[OK] Installation of Watermark-Font was successful!"
    }
}

#region KILL AREA
$KillDate = (Get-Date).AddDays(-$KillDays)
Write-Output "[HOUSEKEEPING] Searching for Files older than '$KillDays' Days ($($KilLDate.ToString('yyyy-MM-dd'))) ..."

$KillFiles = Get-ChildItem -Path $BaseDir -Recurse | Where-Object { $_.LastWriteTime -lt $KillDate }

if ($KillFiles) {
    Write-Output "[HOUSEKEEPING] Found '$($KillFiles.Count)' Files to remove!"

    $KillFiles | ForEach-Object -Parallel {

        Write-Output "Remove File '$($_.FullName)' ..."
        Remove-Item -Path $_.FullName -Force -Recurse
    }
}
else {
    Write-Output "[HOUSEKEEPING] [OK] No Files found to remove. Proceed ..."
    Write-Output ""
}
#endregion

#region CONVERT AREA
$AllItems = Get-ChildItem $BaseDir -Recurse -Force | Where-Object { $_.Extension -Like ".mp4" -and $_.FullName -notlike "*_low.mp4" }
Write-Output "[TRANSCODING] '$($AllItems.Count)' total Videos found to check!"

$AllItems | Sort-Object -Property Name | ForEach-Object -Parallel {

    # Generate Variables
    $OutputPath = $_.DirectoryName + "/_low/"
    $OutputFullPath = $_.DirectoryName + "/_low/" + $_.BaseName + "_low" + $_.Extension
    $Mediainfo = (mediainfo --output=JSON $OutputFullPath | ConvertFrom-Json).media.track
    $WatermarkText = "[LowRes] " + $_.FullName

    # Check for already converted Files
    if ( $Mediainfo.OverallBitRate ) {

        Write-Output "[TRANSCODING] [OK] Video '$OutputFullPath' already converted! Skip Process ..."
        Exit
    }
    elseif ( $Mediainfo -and !$Mediainfo.OverallBitRate) {
        
        Write-Warning "[TRANSCODING] '$OutputFullPath' exist, but corrupt! Encoding again!" -WarningAction Continue
    }

    Write-Output "[TRANSCODING] Start transcoding '$($_.FullName)' ..."

    if (!(Test-Path -Path $OutputPath)) {
        New-Item -ItemType Directory -Path ($_.DirectoryName + "/_low/") -Force | Out-Null
    }

    ffmpeg -i $($_.FullName) `
        -c:v libx264 `
        -vf scale=720:-1 `
        -vf "scale=720:-1, drawtext=fontfile='$WatermarkFont':text='$WatermarkText':x=10:y=H-th-10:fontsize='15':fontcolor=white:shadowcolor=black:shadowx=-3:shadowy=3:" `
        -preset $using:TranscodingMode `
        -crf 24 `
        -c:a aac `
        -b:a 32k `
        $OutputFullPath `
        -y `
        -loglevel error

    if ($?) { 
        $Mediainfo = (mediainfo --output=JSON $OutputFullPath | ConvertFrom-Json).media.track
        Write-Output "[TRANSCODING] [OK] Transcoding into '$($Mediainfo.Format)' was successful!" 
    }
}
#endregion

if ($?) {
    Write-Output "[OK] All operations done in '$(Get-StopWatch)'. Exit here!"
    Write-Output ""
}
$Stopwatch.Stop()
Stop-Transcript | Out-Null # Stop Logging
# End of Script
