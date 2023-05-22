<# 
.SYNOPSIS Flac to Mp3 Converter. Requires ffmpeg
.DESCRIPTION 
.NOTES Author: Gill Bates, Last Update: 22.05.2023
#>
function Flac2Mp3 {
    param (
        [string]$Path,
        [switch]$Recurse,
        [switch]$Sanitize
    )

    # Check Installation
    $ErrorActionPreference = 'SilentlyContinue'
    $ffmpegCheck = ffmpeg.exe -version
    $ErrorActionPreference = 'Continue'

    if (!$ffmpegCheck) {
        
        throw "[ERROR] ffmpeg binary is missing! Install Binary and try again. Download latest Binary here: https://www.gyan.dev/ffmpeg/builds"
    }

    if ($Recurse) { $AllFiles = Get-ChildItem -Path $Path -Recurse } else {
        $AllFiles = Get-ChildItem -Path $Path | Where-Object { $_.Extension -like ".flac" }
    }

    # Do the Magic ...
    Write-Information "Found $($AllFiles.Count) FLAC-Files to convert!" -InformationAction Continue

    $AllFiles | ForEach-Object -Parallel {

        $OutputDir = "$($_.Directory)\_Flac2Mp3"
        
        if ($using:Sanitize) {

            $TextInfo = (Get-Culture).TextInfo
            $FileName = $_.BaseName.substring(2) -replace '_', ' ' -replace "and", "&"
            $newCamelCase = ($TextInfo.ToTitleCase($FileName)).Trim("-") -replace "Feat ", "feat. "
            $OutputFileName = "$OutputDir\" + ($newCamelCase).Trim() + ".mp3"
        }
        else {
            $OutputFileName = "$OutputDir\$($_.BaseName).mp3"
        }
           
        if (!(Test-Path -Path $OutputDir)) {
            New-Item -Path $OutputDir -ItemType "directory" -Force
        }

        Write-Output "Converting '$($_.PSChildName)' now ..."
        ffmpeg -i $_.FullName -ab 320k -map_metadata 0 -id3v2_version 3 $OutputFileName
    }
}