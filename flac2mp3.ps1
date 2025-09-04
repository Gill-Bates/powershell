<# 
.SYNOPSIS 
    FLAC to MP3 Converter using ffmpeg with cover art support
.NOTES 
    Author: Gill Bates
    Last Update: 2025-09-04
    Requires: ffmpeg in PATH
#>

function Convert-FlacToMp3 {
    param (
        [string]$inputFolder = $(Get-Location).Path,
        [string]$outputFolder = $(Join-Path (Get-Location).Path "_MP3")
    )

    if (!(Test-Path $outputFolder)) {
        New-Item -ItemType Directory -Path $outputFolder | Out-Null
    }

    $flacFiles = Get-ChildItem -Path $inputFolder -Filter *.flac -File -Recurse

    if (!$flacFiles) {
        Write-Host "No FLAC files found in $inputFolder"
        return
    }

    $coverArt = Get-ChildItem -Path (Join-Path $inputFolder '*') -Include *.jpg, *.jpeg -File | Select-Object -First 1

    if ($coverArt) {
        Write-Host "Found cover art: $($coverArt.Name)"
    }
    else {
        Write-Host "No cover art found in folder."
    }

    foreach ($file in $flacFiles) {

        $outputPath = Join-Path $outputFolder ($file.BaseName + ".mp3")
        Write-Host "Converting '$($file.Name)'..." -ForegroundColor Cyan

        $ffmpegArgs = @("-i", $file.FullName)

        if ($coverArt) {
            $ffmpegArgs += @(
                "-i", $coverArt.FullName,
                "-map", "0:a",
                "-map", "1:v",
                "-c:v", "mjpeg",
                "-pix_fmt", "yuvj420p",
                "-c:a", "libmp3lame",
                "-b:a", "320k",
                "-c:v", "mjpeg",
                "-id3v2_version", "3",
                "-metadata:s:v", "title=Album cover",
                "-metadata:s:v", "comment=Cover (front)"
            )
        }
        else {
            $ffmpegArgs += @(
                "-map_metadata", "0",
                "-c:a", "libmp3lame",
                "-b:a", "320k",
                "-id3v2_version", "3"
            )
        }

        $ffmpegArgs += @(
            "-loglevel", "warning",
            "-hide_banner",
            "-nostats",
            $outputPath
        )

        & ffmpeg @ffmpegArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Convert-FlacToMp3: Failed to convert '$($file.Name)' (Exit code: $LASTEXITCODE)"
        }
    }
}

# Alias für Kompatibilität
Set-Alias -Name Flac2Mp3 -Value Convert-FlacToMp3 -Description "FLAC to MP3 converter with cover art support"