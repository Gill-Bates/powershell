<#
.SYNOPSIS
    FLAC → MP3 Converter (with MP3 cover tagging and capitalization)
.DESCRIPTION
    • Converts .flac files (recursively) to MP3 (320 kbps)
    • Processes existing .mp3 files without re-encoding (bitstream copy)
    • Uses per-folder cover art (jpg/jpeg/png)
    • All output files collected flat into one folder
    • Normalizes feat./ft./vs. usage
.NOTES
    Author  : Gill Bates
    Updated : 2025-10-14
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

    # 🎯 ============================================================================
    # 1. FFMPEG SETUP & VALIDATION
    # 🎯 ============================================================================
    
    function Install-FFmpeg {
        $downloadUrl = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"
        $system32Path = "C:\Windows\System32"
        
        # 🔐 Check if we have admin rights for System32
        $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
        
        if (-not $isAdmin) {
            Write-Host "⚠️  Administrative rights required to install FFmpeg to System32" -ForegroundColor Yellow
            Write-Host "   Please run PowerShell as Administrator" -ForegroundColor Red
            return $false
        }

        $tempZip = Join-Path $env:TEMP "ffmpeg-latest.zip"
        $tempExtract = Join-Path $env:TEMP "ffmpeg-extract"
        
        Write-Host "📥 Downloading FFmpeg..." -ForegroundColor Yellow
        
        try {
            # 🌐 Download FFmpeg
            Invoke-WebRequest -Uri $downloadUrl -OutFile $tempZip
            
            # 📦 Extract ZIP
            if (Test-Path $tempExtract) { Remove-Item $tempExtract -Recurse -Force }
            Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force
            
            # 🔍 Find FFmpeg binaries
            $ffmpegDir = Get-ChildItem $tempExtract -Recurse -Directory | Where-Object { $_.Name -eq "bin" } | Select-Object -First 1
            if (-not $ffmpegDir) { throw "FFmpeg bin directory not found" }
            
            # 💾 Copy to System32
            $binFiles = Get-ChildItem -Path $ffmpegDir.FullName -Include "ffmpeg.exe", "ffprobe.exe", "ffplay.exe" -File
            foreach ($binFile in $binFiles) {
                $destPath = Join-Path $system32Path $binFile.Name
                Copy-Item -Path $binFile.FullName -Destination $destPath -Force
                Write-Host "   → Copied $($binFile.Name) to System32" -ForegroundColor Green
            }
            
            # 🔄 Refresh PATH
            $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")
            
            Write-Host "✅ FFmpeg installed to System32" -ForegroundColor Green
            
            # 🧹 Cleanup
            Remove-Item $tempZip -Force -ErrorAction SilentlyContinue
            Remove-Item $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
            
            return $true
        }
        catch {
            Write-Error "Failed to install FFmpeg: $($_.Exception.Message)"
            return $false
        }
    }

    function Test-FFmpeg {
        $ffmpegOk = Get-Command ffmpeg -ErrorAction SilentlyContinue
        $ffprobeOk = Get-Command ffprobe -ErrorAction SilentlyContinue
        
        if (-not ($ffmpegOk -and $ffprobeOk)) {
            Write-Host "FFmpeg not found in PATH. Attempting to install..." -ForegroundColor Yellow
            return Install-FFmpeg
        }
        return $true
    }

    # 🔍 Validate FFmpeg
    if (-not (Test-FFmpeg)) { 
        throw "FFmpeg is required but could not be installed. Please install manually and add to PATH." 
    }

    if (-not (Test-Path $InputFolder)) { 
        throw "Input folder not found: $InputFolder" 
    }

    # 🔐 Test if we can create the output folder
    try {
        if (!(Test-Path $OutputFolder)) { 
            New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null 
        }
        # ✏️ Test write permissions
        $testFile = Join-Path $OutputFolder "write_test.tmp"
        "test" | Out-File -FilePath $testFile -ErrorAction Stop
        Remove-Item $testFile -Force -ErrorAction SilentlyContinue
    }
    catch {
        throw "Cannot write to output folder: $OutputFolder - $($_.Exception.Message)"
    }

    # 🎯 ============================================================================
    # 2. HELPER FUNCTIONS
    # 🎯 ============================================================================

    function Capitalize([string]$word) {
        if (-not $word) { return $word }
        $lowerWord = $word.ToLower()
        return ($lowerWord.Substring(0, 1).ToUpper() + $lowerWord.Substring(1))
    }

    function Normalize-Title([string]$text) {
        if (-not $text) { return $text }
        
        # 🔄 Replace underscores with spaces
        $normalizedText = $text -replace '_', ' '
        $parts = [regex]::Split($normalizedText, '(\W+)')

        # 🎯 Find first word for capitalization
        $firstWordIndex = $null
        for ($i = 0; $i -lt $parts.Count; $i++) {
            if ($parts[$i] -match "^[A-Za-z0-9']+$") { $firstWordIndex = $i; break }
        }

        # ✨ Process each word part
        for ($i = 0; $i -lt $parts.Count; $i++) {
            $part = $parts[$i]
            if ($part -notmatch "^[A-Za-z0-9']+$") { continue }
            $lowerPart = $part.ToLower()

            # 🎵 Normalize common music prefixes
            switch -Wildcard ($lowerPart) {
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
            return @{
                artist = (& ffprobe -v error -show_entries format_tags=artist -of default=nw=1:nk=1 -- "$($file.FullName)")
                title  = (& ffprobe -v error -show_entries format_tags=title  -of default=nw=1:nk=1 -- "$($file.FullName)")
                album  = (& ffprobe -v error -show_entries format_tags=album  -of default=nw=1:nk=1 -- "$($file.FullName)")
                year   = (& ffprobe -v error -show_entries format_tags=date   -of default=nw=1:nk=1 -- "$($file.FullName)")
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
        # 🧹 Remove extra spaces and trim
        $cleanName = $cleanName -replace '\s+', ' '
        return $cleanName.Trim()
    }

    function Build-OutputPath($artist, $title, $folder) {
        $fileName = "$artist - $title.mp3"
        $fileName = Sanitize-Filename $fileName
        
        # 🆘 Fallback if filename is too long or empty
        if ([string]::IsNullOrWhiteSpace($fileName) -or $fileName -eq ".mp3") {
            $hash = (Get-Date).Ticks.ToString()
            $fileName = "track_$hash.mp3"
        }
        
        $outputPath = Join-Path $folder $fileName
        
        # 🔢 Handle duplicates if not overwriting
        if ((-not $Overwrite) -and (Test-Path $outputPath)) {
            $counter = 1
            $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
            $extension = [System.IO.Path]::GetExtension($fileName)
            while (Test-Path $outputPath) {
                $outputPath = Join-Path $folder ("$baseName ($counter)$extension")
                $counter++
            }
        }
        return $outputPath
    }

    # 🖼️ Simplified Cover Art Search
    function Get-CoverArt($directory) {
        if (-not $coverCache.ContainsKey($directory)) {
            # 🔍 Simple search for image files
            $coverFiles = Get-ChildItem -Path $directory -File | Where-Object {
                $_.Extension -match '\.(jpg|jpeg|png|bmp)$'
            }
            
            # ⭐ Prefer standard cover names
            $preferredCover = $coverFiles | Where-Object {
                $_.Name -match '^(folder|cover|front|album)'
            } | Select-Object -First 1
            
            $coverCache[$directory] = if ($preferredCover) { $preferredCover } else { $coverFiles | Select-Object -First 1 }
        }
        return $coverCache[$directory]
    }

    function Add-CoverArt($inputFile, $outputFile, $coverArt, $artist, $title) {
        $args = @(
            "-i", $inputFile,
            "-i", $coverArt.FullName,
            "-map", "0:a", "-map", "1:v",
            "-map_metadata", "0",  # ✅ Preserve existing metadata
            "-c:a", "copy",
            "-c:v", "mjpeg", "-pix_fmt", "yuvj420p",
            "-id3v2_version", "3",
            "-metadata", "artist=$artist",
            "-metadata", "title=$title",
            "-metadata:s:v", "title=Album cover",
            "-metadata:s:v", "comment=Cover (front)",
            "-y", "-loglevel", "error", "-hide_banner", "-nostats",
            $outputFile
        )
        & ffmpeg @args
        return $LASTEXITCODE
    }

    function Convert-FlacToMp3WithCover($file, $outPath, $artist, $title, $cover) {
        try {
            $args = @("-i", $file.FullName)
            if ($cover) {
                $args += @(
                    "-i", $cover.FullName,
                    "-map", "0:a", "-map", "1:v",
                    "-c:v", "mjpeg", "-pix_fmt", "yuvj420p",
                    "-c:a", $Codec, "-b:a", "${Bitrate}k",
                    "-id3v2_version", "3",
                    "-metadata", "artist=$artist",
                    "-metadata", "title=$title",
                    "-metadata:s:v", "title=Album cover",
                    "-metadata:s:v", "comment=Cover (front)"
                )
            }
            else {
                $args += @(
                    "-map_metadata", "0",
                    "-c:a", $Codec, "-b:a", "${Bitrate}k",
                    "-id3v2_version", "3",
                    "-metadata", "artist=$artist",
                    "-metadata", "title=$title"
                )
            }
            $args += @("-loglevel", "error", "-hide_banner", "-nostats", $outPath)
            & ffmpeg @args
            
            if ($LASTEXITCODE -ne 0) { 
                Write-Warning "ffmpeg failed for '$($file.Name)' with exit code: $LASTEXITCODE" 
                return $false
            }
            return $true
        }
        catch {
            Write-Warning "ffmpeg exception for '$($file.Name)': $($_.Exception.Message)"
            return $false
        }
    }

    # 🎯 ============================================================================
    # 3. PREPARATION & INITIALIZATION
    # 🎯 ============================================================================
    
    # 🖼️ Cover Art Cache
    $coverCache = @{}
    
    $files = Get-ChildItem -Path $InputFolder -Include *.flac, *.mp3 -File -Recurse
    if (!$files) { 
        Write-Host "❌ No audio files found." -ForegroundColor Red
        return 
    }
    
    if ($Overwrite) {
        Write-Host "⚠️ Overwrite mode enabled - existing files will be replaced" -ForegroundColor Yellow
    }

    Write-Host "🎯 ============================================================================" -ForegroundColor DarkGray
    Write-Host "🎧  STARTING CONVERSION PROCESS" -ForegroundColor Cyan
    Write-Host "📁 Input Folder : $InputFolder"
    Write-Host "💾 Output Folder: $OutputFolder"
    Write-Host "⚡ Bitrate: ${Bitrate}k | Codec: $Codec"
    Write-Host "📊 Total Files: $($files.Count)"
    Write-Host "🎯 ============================================================================" -ForegroundColor DarkGray

    $totalFiles = $files.Count
    $processedCount = 0
    $successCount = 0
    $errorCount = 0

    # 🎯 ============================================================================
    # 4. FILE PROCESSING LOOP
    # 🎯 ============================================================================
    foreach ($file in $files) {
        $processedCount++
        $percentComplete = [math]::Round(($processedCount / $totalFiles) * 100, 2)
        
        # 📊 Progress Bar (bottom of console)
        Write-Progress -Activity "Processing Audio Files" -Status "$processedCount/$totalFiles ($percentComplete%) - $($file.Name)" -PercentComplete $percentComplete

        # ℹ️ Processing information (top of console)
        Write-Host "🔍 Processing: $($file.Name)" -ForegroundColor Gray

        # 🖼️ Per-folder cover detection (cached)
        $coverArt = Get-CoverArt $file.DirectoryName

        # 📝 Extract metadata
        $metadata = Get-FileMetadata $file
        $artist = if ($metadata.artist) { $metadata.artist } else { "Unknown Artist" }
        $title = if ($metadata.title) { $metadata.title }  else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }

        # ✨ Normalize text
        $artist = Normalize-Title $artist
        $title = Normalize-Title $title
        $outputPath = Build-OutputPath $artist $title $OutputFolder

        # 🎵 FLAC → MP3 Conversion
        if ($file.Extension -ieq ".flac") {
            $success = Convert-FlacToMp3WithCover $file $outputPath $artist $title $coverArt
            if ($success) {
                $coverInfo = if ($coverArt) { "(cover: $($coverArt.Name))" } else { "(no cover)" }
                Write-Host "✅ CONVERTED: $artist - $title  $coverInfo" -ForegroundColor Green
                $successCount++
            }
            else {
                Write-Host "❌ FAILED: $artist - $title" -ForegroundColor Red
                $errorCount++
            }
        }

        # 🔊 MP3 Processing (add cover if available)
        elseif ($file.Extension -ieq ".mp3") {
            if ($coverArt) {
                $exitCode = Add-CoverArt $file.FullName $outputPath $coverArt $artist $title
                if ($exitCode -eq 0) {
                    Write-Host "MP3 WITH COVER: $artist - $title" -ForegroundColor Cyan
                    $successCount++
                }
                else {
                    Write-Warning "ffmpeg remux failed for: $($file.Name)"
                    # 🆘 Fallback: copy without cover
                    try {
                        Copy-Item $file.FullName $outputPath -Force
                        Write-Host "📋 COPIED MP3: $artist - $title (cover failed)" -ForegroundColor Yellow
                        $successCount++
                    }
                    catch {
                        Write-Host "❌ FAILED: $artist - $title" -ForegroundColor Red
                        $errorCount++
                    }
                }
            }
            else {
                try {
                    Copy-Item -Path $file.FullName -Destination $outputPath -Force
                    Write-Host "📋 COPIED MP3: $artist - $title (no cover)" -ForegroundColor Yellow
                    $successCount++
                }
                catch {
                    Write-Host "❌ FAILED: $artist - $title" -ForegroundColor Red
                    $errorCount++
                }
            }
        }
        
        # 📝 Empty line for better readability
        Write-Host ""
    }

    # 🎯 =======================MP=====================================================
    # 5. FINAL SUMMARY & STATISTICS
    # 🎯 ============================================================================
    Write-Progress -Activity "Processing Audio Files" -Completed
    
    Write-Host "🎯 ============================================================================" -ForegroundColor DarkGray
    if ($errorCount -eq 0) {
        Write-Host "🎉 CONVERSION COMPLETE! $successCount/$totalFiles files processed successfully." -ForegroundColor Green
    }
    else {
        Write-Host "⚠️  CONVERSION COMPLETED WITH $errorCount ERRORS. $successCount/$totalFiles files processed successfully." -ForegroundColor Yellow
    }
    Write-Host "📁 Output Location: $OutputFolder" -ForegroundColor Cyan
    Write-Host "🎯 ============================================================================" -ForegroundColor DarkGray
}

# 🎯 ============================================================================
# ALIAS FOR CONVENIENCE (with duplicate check)
# 🎯 ============================================================================
if (-not (Get-Alias -Name Flac2Mp3 -ErrorAction SilentlyContinue)) {
    Set-Alias -Name Flac2Mp3 -Value Convert-FlacToMp3 -Description "FLAC→MP3 converter with cover art support"
}

Write-Host "🎧 Flac2Mp3 converter loaded successfully!" -ForegroundColor Green
Write-Host "💡 Usage: Flac2Mp3 -InputFolder 'C:\Music' -OutputFolder 'C:\Output' -Bitrate 320 -Overwrite" -ForegroundColor Cyan