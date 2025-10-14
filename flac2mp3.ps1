<#
.SYNOPSIS
    FLAC → MP3 Converter (with MP3 cover tagging and capitalization)
.DESCRIPTION
    • Converts .flac files (recursively) to MP3 (320 kbps)
    • Processes existing .mp3 files without re-encoding (bitstream copy)
    • Uses per-folder cover art (jpg/jpeg/png)
    • All output files collected flat into one folder
    • English capitalization correction via wordlist.txt
    • Normalizes feat./ft./vs. usage
    • Optional parallel execution
.NOTES
    Author  : Gill Bates
    Updated : 2025-10-14
    Requires: ffmpeg, ffprobe in PATH
#>

function Convert-FlacToMp3 {
    [CmdletBinding()]
    param (
        [string]$inputFolder = (Get-Location).Path,
        [string]$outputFolder = (Join-Path (Get-Location).Path "_MP3"),
        [string]$dictionaryPath = 
        [switch]$Parallel,
        [int]$ThrottleLimit = 5
    )

    # ──────────────────────────────────────────────────────────────
    # 1. Validation
    # ──────────────────────────────────────────────────────────────
    if (-not (Test-Path $inputFolder)) { throw "Input folder not found: $inputFolder" }
    if (-not (Get-Command ffmpeg  -ErrorAction SilentlyContinue)) { throw "ffmpeg not found in PATH" }
    if (-not (Get-Command ffprobe -ErrorAction SilentlyContinue)) { throw "ffprobe not found in PATH" }

    # ──────────────────────────────────────────────────────────────
    # 2. Load Dictionary
    # ──────────────────────────────────────────────────────────────
    $Dictionary = @{}
    if (Test-Path $dictionaryPath) {
        Get-Content -Path $dictionaryPath -Encoding UTF8 | ForEach-Object {
            $w = $_.Trim().ToLower()
            if ($w) { $Dictionary[$w] = $true }
        }
        Write-Host "📘 Loaded dictionary: $($Dictionary.Count) entries" -ForegroundColor DarkGray
    }
    else {
        Write-Warning "Dictionary not found: $dictionaryPath"
    }

    # ──────────────────────────────────────────────────────────────
    # 3. Helper Functions
    # ──────────────────────────────────────────────────────────────

    function Capitalize([string]$w) {
        if (-not $w) { return $w }
        $lw = $w.ToLower()
        return ($lw.Substring(0, 1).ToUpper() + $lw.Substring(1))
    }

    function Normalize-Title([string]$text) {
        if (-not $text) { return $text }
        $t = $text -replace '_', ' '
        $parts = [regex]::Split($t, '(\W+)')

        $firstWordIdx = $null
        for ($i = 0; $i -lt $parts.Count; $i++) {
            if ($parts[$i] -match "^[A-Za-z0-9']+$") { $firstWordIdx = $i; break }
        }

        for ($i = 0; $i -lt $parts.Count; $i++) {
            $p = $parts[$i]
            if ($p -notmatch "^[A-Za-z0-9']+$") { continue }
            $lw = $p.ToLower()

            switch ($true) {
                { $lw -in @('feat', 'ft') } { $parts[$i] = 'feat.'; continue }
                { $lw -eq 'vs' } { $parts[$i] = 'vs.'; continue }
                { $i -eq $firstWordIdx } { $parts[$i] = Capitalize($lw); continue }
                { $Dictionary.ContainsKey($lw) } { $parts[$i] = $lw; continue }
                default { $parts[$i] = Capitalize($lw) }
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

    function Build-OutputPath($artist, $title, $folder) {
        $fileName = "$artist - $title.mp3" -replace '[\\\/:*?"<>|]', ''
        $outputPath = Join-Path $folder $fileName
        $counter = 1
        while (Test-Path $outputPath) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
            $outputPath = Join-Path $folder ("$base ($counter).mp3")
            $counter++
        }
        return $outputPath
    }

    function Invoke-FfmpegConversion($file, $outPath, $artist, $title, $cover) {
        $args = @("-i", $file.FullName)
        if ($cover) {
            $args += @(
                "-i", $cover.FullName,
                "-map", "0:a", "-map", "1:v",
                "-c:v", "mjpeg", "-pix_fmt", "yuvj420p",
                "-c:a", "libmp3lame", "-b:a", "320k",
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
                "-c:a", "libmp3lame", "-b:a", "320k",
                "-id3v2_version", "3",
                "-metadata", "artist=$artist",
                "-metadata", "title=$title"
            )
        }
        $args += @("-loglevel", "error", "-hide_banner", "-nostats", $outPath)
        & ffmpeg @args
        if ($LASTEXITCODE -ne 0) { Write-Warning "ffmpeg failed for: $($file.Name)" }
    }

    # ──────────────────────────────────────────────────────────────
    # 4. Preparation
    # ──────────────────────────────────────────────────────────────
    $files = Get-ChildItem -Path $inputFolder -Include *.flac, *.mp3 -File -Recurse
    if (!$files) { Write-Host "No audio files found." -ForegroundColor Red; return }
    if (!(Test-Path $outputFolder)) { New-Item -ItemType Directory -Path $outputFolder | Out-Null }

    Write-Host "──────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "🎧  Starting Conversion" -ForegroundColor Cyan
    Write-Host "Input : $inputFolder"
    Write-Host "Output: $outputFolder"
    Write-Host "──────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "🖼  Using per-folder cover lookup" -ForegroundColor DarkGray

    $total = $files.Count
    $index = 0

    # ──────────────────────────────────────────────────────────────
    # 5. Conversion Action
    # ──────────────────────────────────────────────────────────────
    $convertAction = {
        param($file, $total, $Dictionary, $outputFolder)

        # Per-folder cover detection
        $coverArt = Get-ChildItem -Path (Join-Path $file.DirectoryName '*') -Include *.jpg, *.jpeg, *.png -File | Select-Object -First 1

        $meta = Get-FileMetadata $file
        $artist = if ($meta.artist) { $meta.artist } else { "Unknown Artist" }
        $title = if ($meta.title) { $meta.title }  else { [System.IO.Path]::GetFileNameWithoutExtension($file.Name) }

        $artist = Normalize-Title $artist
        $title = Normalize-Title $title
        $outPath = Build-OutputPath $artist $title $outputFolder

        # ─── FLAC → MP3 ──────────────────────────────────────────────
        if ($file.Extension -ieq ".flac") {
            Invoke-FfmpegConversion $file $outPath $artist $title $coverArt
            $msg = if ($coverArt) { "(cover: $($coverArt.Name))" } else { "(no cover)" }
            Write-Host "✓ $artist - $title  $msg" -ForegroundColor Green
        }

        # ─── MP3 (bitstream copy, add cover) ─────────────────────────
        elseif ($file.Extension -ieq ".mp3") {
            if ($coverArt) {
                $args = @(
                    "-i", $file.FullName,
                    "-i", $coverArt.FullName,
                    "-map", "0:a", "-map", "1:v",
                    "-c:a", "copy",
                    "-c:v", "mjpeg", "-pix_fmt", "yuvj420p",
                    "-id3v2_version", "3",
                    "-metadata", "artist=$artist",
                    "-metadata", "title=$title",
                    "-metadata:s:v", "title=Album cover",
                    "-metadata:s:v", "comment=Cover (front)",
                    "-y",
                    "-loglevel", "error", "-hide_banner", "-nostats",
                    $outPath
                )
                & ffmpeg @args
                if ($LASTEXITCODE -ne 0) {
                    Write-Warning "ffmpeg remux failed for: $($file.Name)"
                    Copy-Item $file.FullName $outPath -Force
                }
                else {
                    Write-Host "→ MP3 tagged with cover: $artist - $title" -ForegroundColor Cyan
                }
            }
            else {
                Copy-Item -Path $file.FullName -Destination $outPath -Force
                Write-Host "→ Copied existing MP3: $artist - $title (no cover)" -ForegroundColor Yellow
            }
        }
    }

    # ──────────────────────────────────────────────────────────────
    # 6. Execution (Parallel or Sequential)
    # ──────────────────────────────────────────────────────────────
    if ($Parallel) {
        $files | ForEach-Object -Parallel {
            & $using:convertAction $_ $using:total $using:Dictionary $using:outputFolder
        } -ThrottleLimit $ThrottleLimit
    }
    else {
        foreach ($file in $files) {
            $index++
            $percent = [math]::Round(($index / $total) * 100, 2)
            Write-Progress -Activity "Processing audio files" -Status "$index/$total ($percent%)" -PercentComplete $percent
            & $convertAction $file $total $Dictionary $outputFolder
        }
    }

    # ──────────────────────────────────────────────────────────────
    # 7. Summary
    # ──────────────────────────────────────────────────────────────
    Write-Progress -Activity "Processing audio files" -Completed
    Write-Host "──────────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "✅ Conversion complete. Files saved in: $outputFolder" -ForegroundColor Green
}

# ──────────────────────────────────────────────────────────────
# Alias for convenience
# ──────────────────────────────────────────────────────────────
Set-Alias -Name Flac2Mp3 -Value Convert-FlacToMp3 -Description "FLAC→MP3 converter with capitalization & per-folder covers"
