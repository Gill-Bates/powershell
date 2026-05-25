<#
.SYNOPSIS
    FLAC - MP3 Converter (with MP3 cover tagging and capitalization)
.DESCRIPTION
    - Converts .flac files (recursively) to MP3 (320 kbps)
    - Processes existing .mp3 files without re-encoding (bitstream copy)
    - Uses per-folder cover art (jpg/jpeg/png)
    - All output files collected flat into one folder
    - Normalizes feat./ft./vs. usage
.NOTES
    Author  : Gill Bates
    Updated : 2026-05-13
    Requires: ffmpeg, ffprobe in PATH
#>

function Convert-FlacToMp3 {
    [CmdletBinding()]
    param (
        [string]$InputFolder = (Get-Location).Path,
        [string]$OutputFolder = (Join-Path ([Environment]::GetFolderPath("Desktop")) "MP3"),
        [int]$Bitrate = 320,
        [ValidateSet('libmp3lame', 'libshine')]
        [string]$Codec = 'libmp3lame',
        [switch]$Overwrite
    )

    # [SECTION] ============================================================================
    # 1. FFMPEG SETUP & VALIDATION
    # [SECTION] ============================================================================
    
    function Test-FFmpeg {
        $ffmpegOk = Get-Command ffmpeg -ErrorAction SilentlyContinue
        $ffprobeOk = Get-Command ffprobe -ErrorAction SilentlyContinue
        return ($ffmpegOk -and $ffprobeOk)
    }

    # [SECTION] Validate FFmpeg
    if (-not (Test-FFmpeg)) { 
        throw "FFmpeg is required. Please install ffmpeg/ffprobe and add them to PATH." 
    }

    if (-not (Test-Path $InputFolder)) { 
        throw "Input folder not found: $InputFolder" 
    }

    # [SECTION] Test if we can create the output folder
    try {
        if (!(Test-Path -LiteralPath $OutputFolder)) { 
            New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null 
        }
        # [SECTION] Test write permissions
        $testFile = Join-Path $OutputFolder ([System.IO.Path]::GetRandomFileName())
        try {
            [System.IO.File]::WriteAllText($testFile, "test")
        }
        finally {
            Remove-Item -LiteralPath $testFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        throw "Cannot write to output folder: $OutputFolder - $($_.Exception.Message)"
    }

    # [SECTION] ============================================================================
    # 2. HELPER FUNCTIONS
    # [SECTION] ============================================================================

    function Capitalize([string]$word) {
        if (-not $word) { return $word }
        return [regex]::Replace($word.ToLower(), '^.', { $args[0].Value.ToUpper() })
    }

    function Normalize-Title([string]$text) {
        if (-not $text) { return $text }
        
        # [SECTION] Replace underscores with spaces
        $normalizedText = $text -replace '_', ' '
        $parts = [regex]::Split($normalizedText, '(\W+)')

        # - Process each word part
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $part = $parts[$i]
            if ($part -notmatch "^[A-Za-z0-9']+$") { continue }
            $lowerPart = $part.ToLower()

            # [SECTION] Normalize common music prefixes
            switch ($lowerPart) {
                "feat" { $parts[$i] = 'feat.'; continue }
                "ft" { $parts[$i] = 'feat.'; continue }
                "vs" { $parts[$i] = 'vs.'; continue }
                default { $parts[$i] = Capitalize($lowerPart) }
            }
        }

        return (($parts -join '') -replace '\.\.', '.')
    }

    function Get-FileMetadata($file) {
        try {
            $jsonText = & ffprobe -v error -show_entries format_tags=artist,title,album,date -of json -- "$($file.FullName)" 2>$null
            if ($LASTEXITCODE -ne 0) { return @{} }
            $json = $jsonText | ConvertFrom-Json
            $tags = $json.format.tags
            return @{
                artist = $tags.artist
                title  = $tags.title
                album  = $tags.album
                year   = $tags.date
            }
        }
        catch {
            Write-Warning "ffprobe failed for: $($file.Name) - $($_.Exception.Message)"
            return @{}
        }
    }

    function Sanitize-Filename($name) {
        $invalidChars = [System.IO.Path]::GetInvalidFileNameChars() -join ''
        $pattern = "[{0}]" -f [regex]::Escape($invalidChars)
        $cleanName = $name -replace $pattern, ""
        # [SECTION] Remove extra spaces and trim
        $cleanName = $cleanName -replace '\s+', ' '
        return $cleanName.Trim()
    }

    function Build-OutputPath($artist, $title, $folder) {
        $baseName = Sanitize-Filename "$artist - $title"
        if ([string]::IsNullOrWhiteSpace($baseName)) { $baseName = "track_$((Get-Date).Ticks)" }
        
        $fileName = "$baseName.mp3"
        $outputPath = Join-Path $folder $fileName

        # [SECTION] Handle duplicates in current run and existing files
        $counter = 1
        while (($script:usedNames.Contains($outputPath)) -or ((-not $Overwrite) -and (Test-Path $outputPath))) {
            $outputPath = Join-Path $folder "$baseName ($counter).mp3"
            $counter++
        }
        [void]$script:usedNames.Add($outputPath)
        return $outputPath
    }

    function Get-CoverArt($directory) {
        if (-not $script:coverCache.ContainsKey($directory)) {
            # [SECTION] Simple search for image files
            $coverFiles = Get-ChildItem -Path $directory -File | Where-Object {
                $_.Extension.ToLower() -in '.jpg', '.jpeg', '.png', '.bmp'
            }
            
            # - Prefer standard cover names
            $preferredCover = $coverFiles | Where-Object {
                $_.Name -match '^(folder|cover|front|album)'
            } | Select-Object -First 1
            
            $script:coverCache[$directory] = if ($preferredCover) { $preferredCover } else { $coverFiles | Select-Object -First 1 }
        }
        return $script:coverCache[$directory]
    }

    function Build-FFmpegArguments {
        param(
            [Parameter(Mandatory)][System.IO.FileInfo]$Source,
            [Parameter(Mandatory)][string]$OutputPath,
            [hashtable]$Meta,
            [System.IO.FileInfo]$Cover,
            [switch]$CopyAudio,
            [int]$Bitrate,
            [string]$Codec
        )

        $args = @(
            "-hide_banner", "-nostats", "-loglevel", "error",
            "-y", "-i", $Source.FullName
        )

        # Cover mapping
        if ($Cover) {
            $args += @("-i", $Cover.FullName, "-map", "0:a", "-map", "1:v", "-c:v", "mjpeg")
        } else {
            $args += @("-map", "0:a")
        }

        # Audio codec
        if ($CopyAudio) {
            $args += @("-c:a", "copy")
        } else {
            $args += @("-c:a", $Codec, "-b:a", "${Bitrate}k")
        }

        # Metadata
        $args += @("-map_metadata", "0", "-id3v2_version", "3")
        foreach ($key in @('artist','title','album','date')) {
            if ($Meta.$key) { $args += @("-metadata", "$key=$($Meta.$key)") }
        }

        # Cover disposition
        if ($Cover) {
            $args += @(
                "-metadata:s:v", "title=Album cover",
                "-metadata:s:v", "comment=Cover (front)",
                "-disposition:v", "attached_pic"
            )
        }

        $args += $OutputPath
        return $args
    }

    function Assert-SafeOutputPath {
        param(
            [Parameter(Mandatory)][System.IO.FileInfo]$Source,
            [Parameter(Mandatory)][string]$OutputPath
        )

        $sourceFull = [System.IO.Path]::GetFullPath($Source.FullName)
        $outputFull = [System.IO.Path]::GetFullPath($OutputPath)

        if ([string]::Equals($sourceFull, $outputFull, [System.StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to overwrite source file: $sourceFull"
        }
    }

    function Invoke-FFmpeg {
        param([array]$Arguments, [string]$OutputPath, [string]$Label, [string]$SourcePath)
        try {
            & ffmpeg @Arguments
            if ($LASTEXITCODE -ne 0) { throw "Exit code $LASTEXITCODE" }
            return $true
        }
        catch {
            if (
                $OutputPath -and
                (Test-Path -LiteralPath $OutputPath) -and
                -not [string]::Equals(
                    [System.IO.Path]::GetFullPath($OutputPath),
                    [System.IO.Path]::GetFullPath($SourcePath),
                    [System.StringComparison]::OrdinalIgnoreCase
                )
            ) {
                Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
            }
            Write-Warning "ffmpeg failed for '$Label': $_"
            return $false
        }
    }



    # [SECTION] ============================================================================
    # 3. PREPARATION & INITIALIZATION
    # [SECTION] ============================================================================
    
    # ?[SECTION] Cover Art Cache
    $script:coverCache = @{}
    $script:usedNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    
    $files = @(
        Get-ChildItem -LiteralPath $InputFolder -Filter '*.flac' -File -Recurse
        Get-ChildItem -LiteralPath $InputFolder -Filter '*.mp3' -File -Recurse
    ) | Sort-Object FullName
    if (!$files) { 
        Write-Host "- No audio files found." -ForegroundColor Red
        return 
    }
    
    if ($Overwrite) {
        Write-Host "[SECTION] Overwrite mode enabled - existing files will be replaced" -ForegroundColor Yellow
    }

    Write-Host "[SECTION] ============================================================================" -ForegroundColor DarkGray
    Write-Host "[SECTION] STARTING CONVERSION PROCESS" -ForegroundColor Cyan
    Write-Host "[SECTION] Input Folder : $InputFolder"
    Write-Host "[SECTION] Output Folder: $OutputFolder"
    Write-Host "- Bitrate: ${Bitrate}k | Codec: $Codec"
    Write-Host "[SECTION] Total Files: $($files.Count)"
    Write-Host "[SECTION] ============================================================================" -ForegroundColor DarkGray

    $totalFiles = $files.Count
    $processedCount = 0
    $successCount = 0
    $errorCount = 0

    # [SECTION] ============================================================================
    # 4. FILE PROCESSING LOOP
    # [SECTION] ============================================================================
    foreach ($file in $files) {
        $processedCount++
        $percentComplete = [math]::Round(($processedCount / $totalFiles) * 100, 2)
        
        # [SECTION] Progress Bar (bottom of console)
        Write-Progress -Activity "Processing Audio Files" -Status "$processedCount/$totalFiles ($percentComplete%) - $($file.Name)" -PercentComplete $percentComplete

        # [SECTION] Processing information (top of console)
        Write-Host "[SECTION] Processing: $($file.Name)" -ForegroundColor Gray

        # ?[SECTION] Per-folder cover detection (cached)
        $coverArt = Get-CoverArt $file.DirectoryName

        # [SECTION] Extract metadata
        $metadata = Get-FileMetadata $file
        $artist = if ($metadata.artist) { $metadata.artist } else { "Unknown Artist" }
        $title = if ($metadata.title) { $metadata.title }  else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }
        $album = $metadata.album
        $year = $metadata.year

        # - Normalize text
        $artist = Normalize-Title $artist
        $title = Normalize-Title $title
        $outputPath = Build-OutputPath $artist $title $OutputFolder
        Assert-SafeOutputPath -Source $file -OutputPath $outputPath

        # [SECTION] Build metadata hashtable
        $meta = @{
            artist = $artist
            title  = $title
            album  = $album
            date   = $year
        }

        $isMp3 = $file.Extension -ieq ".mp3"
        $ffmpegArgs = Build-FFmpegArguments -Source $file -OutputPath $outputPath `
            -Meta $meta -Cover $coverArt -CopyAudio:$isMp3 `
            -Bitrate $Bitrate -Codec $Codec

        $success = Invoke-FFmpeg -Arguments $ffmpegArgs -OutputPath $outputPath -Label $file.Name -SourcePath $file.FullName
        if ($success) {
            $action = if ($isMp3) { "REMUXED MP3" } else { "CONVERTED" }
            Write-Host "- $action`: $artist - $title" -ForegroundColor Green
            $successCount++
        }
        else {
            Write-Host "- FAILED: $artist - $title" -ForegroundColor Red
            $errorCount++
        }

        Write-Host ""
    }

    # [SECTION] ============================================================================
    # 5. FINAL SUMMARY & STATISTICS
    # [SECTION] ============================================================================
    Write-Progress -Activity "Processing Audio Files" -Completed
    
    Write-Host "[SECTION] ============================================================================" -ForegroundColor DarkGray
    if ($errorCount -eq 0) {
        Write-Host "[SECTION] CONVERSION COMPLETE! $successCount/$totalFiles files processed successfully." -ForegroundColor Green
    }
    else {
        Write-Host "[SECTION] CONVERSION COMPLETED WITH $errorCount ERRORS. $successCount/$totalFiles files processed successfully." -ForegroundColor Yellow
    }
    Write-Host "[SECTION] Output Location: $OutputFolder" -ForegroundColor Cyan
    Write-Host "[SECTION] ============================================================================" -ForegroundColor DarkGray
}

# [SECTION] ============================================================================
# ALIAS FOR CONVENIENCE (with duplicate check)
# [SECTION] ============================================================================
if (-not (Get-Alias -Name Flac2Mp3 -ErrorAction SilentlyContinue)) {
    Set-Alias -Name Flac2Mp3 -Value Convert-FlacToMp3 -Description "FLAC?MP3 converter with cover art support"
}
