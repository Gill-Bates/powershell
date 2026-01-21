#!/usr/bin/env pwsh
#
# bundle_code.ps1
# PowerShell version of the Python script for bundling code
#
# Author: Gill-Bates
# Last Update: 2026-01-21

param(
    [string]$Root = (Get-Location).Path,
    [string]$Output,
    [switch]$IncludeSecrets,
    [switch]$StrictExtensions  # Only known extensions, otherwise all text files
)

# Configuration (only used with -StrictExtensions)
$INCLUDE_EXTS = @(
    ".py", ".ps1", ".psm1", ".psd1",
    ".txt", ".md", ".yaml", ".yml", 
    ".json", ".toml", ".ini", ".cfg", 
    ".sql", ".sh", ".bat", ".cmd",
    ".js", ".ts", ".html", ".htm", ".css",
    ".xml", ".config", ".go", ".rs", ".java",
    ".c", ".cpp", ".h", ".hpp", ".cs",
    ".tf", ".hcl", ".gradle", ".properties",
    ".rb", ".php", ".swift", ".kt", ".scala",
    ".lua", ".r", ".m", ".pl", ".pm"
)

$INCLUDE_NAMES = @(
    "Dockerfile", "Makefile",
    "docker-compose.yml", "docker-compose.yaml",
    ".env.example", ".env.template",
    ".gitignore", ".dockerignore", ".editorconfig"
)

$EXCLUDE_DIRS = @(
    ".git", ".hg", ".svn",
    "__pycache__", ".venv", "venv",
    ".mypy_cache", ".pytest_cache", ".ruff_cache",
    ".idea", ".vscode", "node_modules",
    "dist", "build", "bin", "obj"
)

$SECRET_PATTERNS = @(
    "*.pyc", "*.pyo", "*.so", "*.dll", "*.exe", "*.bin",
    "*.pem", "*.key", "*.p12", "*.pfx", "*.crt", "*.csr",
    "id_rsa", "id_rsa.pub", "id_ed25519", "id_ed25519.pub",
    "*kubeconfig*", "*secret*", "*secrets*",
    ".env", ".env.*", "*.env",
    "full_codebase_*.txt", "*_codebase_*.txt", "*bundle*.txt"
)

function Test-SecretFile {
    param([string]$FileName)
    foreach ($pattern in $SECRET_PATTERNS) {
        if ($FileName -like $pattern) {
            return $true
        }
    }
    return $false
}

function Test-IncludedFile {
    param([string]$FilePath)
    
    # Without -StrictExtensions: allow all (binary check comes later)
    if (-not $StrictExtensions) {
        return $true
    }
    
    $fileName = Split-Path -Leaf $FilePath
    $ext = [System.IO.Path]::GetExtension($FilePath).ToLower()
    
    if ($INCLUDE_NAMES -contains $fileName) {
        return $true
    }
    return $INCLUDE_EXTS -contains $ext
}

function Test-BinaryFile {
    param([string]$FilePath)
    
    try {
        $stream = [System.IO.File]::OpenRead($FilePath)
        $buffer = New-Object byte[] 4096
        $bytesRead = $stream.Read($buffer, 0, 4096)
        $stream.Close()
        
        if ($bytesRead -eq 0) { return $false }
        
        $sample = $buffer[0..($bytesRead - 1)]
        
        # Detect UTF-16 BOM (not binary)
        if ($bytesRead -ge 2) {
            # UTF-16 LE
            if ($sample[0] -eq 0xFF -and $sample[1] -eq 0xFE) { return $false }
            # UTF-16 BE
            if ($sample[0] -eq 0xFE -and $sample[1] -eq 0xFF) { return $false }
            # UTF-8 BOM
            if ($bytesRead -ge 3 -and $sample[0] -eq 0xEF -and $sample[1] -eq 0xBB -and $sample[2] -eq 0xBF) { return $false }
        }
        
        # Count non-printable bytes (except Tab, LF, CR)
        $nonPrintable = 0
        foreach ($b in $sample) {
            if ($b -lt 9 -or ($b -gt 13 -and $b -lt 32)) {
                $nonPrintable++
            }
        }
        
        # More than 30% non-printable -> Binary
        return ($nonPrintable / $bytesRead) -gt 0.3
    }
    catch {
        return $true
    }
}

function Get-SafeFileContent {
    param(
        [string]$FilePath
    )
    
    try {
        $fileInfo = Get-Item -LiteralPath $FilePath -ErrorAction Stop
        
        if ($fileInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            return @{ Content = ""; Reason = "symlink" }
        }
        
        if (Test-BinaryFile -FilePath $FilePath) {
            return @{ Content = ""; Reason = "binary" }
        }
        
        # Encoding-Fallback: UTF-8 → Unicode → Default
        $content = $null
        try {
            $content = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 -ErrorAction Stop
        } catch {
            try {
                $content = Get-Content -LiteralPath $FilePath -Raw -Encoding Unicode -ErrorAction Stop
            } catch {
                try {
                    $content = Get-Content -LiteralPath $FilePath -Raw -ErrorAction Stop
                } catch {
                    return @{ Content = ""; Reason = "encoding_error" }
                }
            }
        }
        
        if ($null -eq $content) { $content = "" }
        return @{ Content = $content; Reason = $null }
        
    } catch [System.UnauthorizedAccessException] {
        return @{ Content = ""; Reason = "permission_denied" }
    } catch {
        return @{ Content = ""; Reason = "read_error: $($_.Exception.GetType().Name)" }
    }
}

function Get-TreeLines {
    param([string[]]$Files)
    
    # Build tree structure
    $tree = @{ _files = [System.Collections.ArrayList]::new(); _dirs = @{} }
    
    foreach ($file in $Files) {
        $parts = $file -split '[/\\]'
        $node = $tree
        
        for ($i = 0; $i -lt $parts.Count - 1; $i++) {
            $part = $parts[$i]
            if (-not $node._dirs.ContainsKey($part)) {
                $node._dirs[$part] = @{ _files = [System.Collections.ArrayList]::new(); _dirs = @{} }
            }
            $node = $node._dirs[$part]
        }
        
        [void]$node._files.Add($parts[-1])
    }
    
    $lines = [System.Collections.ArrayList]::new()
    
    function Write-Tree {
        param(
            [hashtable]$Node,
            [string]$Prefix = ""
        )
        
        $dirs = $Node._dirs.Keys | Sort-Object
        $files = $Node._files | Sort-Object
        $allItems = @($dirs | ForEach-Object { @{ Name = $_; IsDir = $true } }) + 
                    @($files | ForEach-Object { @{ Name = $_; IsDir = $false } })
        
        for ($i = 0; $i -lt $allItems.Count; $i++) {
            $item = $allItems[$i]
            $isLast = ($i -eq $allItems.Count - 1)
            
            if ($isLast) {
                $connector = "└── "
                $childPrefix = "$Prefix    "
            } else {
                $connector = "├── "
                $childPrefix = "$Prefix│   "
            }
            
            if ($item.IsDir) {
                [void]$lines.Add("$Prefix$connector$($item.Name)/")
                Write-Tree -Node $Node._dirs[$item.Name] -Prefix $childPrefix
            } else {
                [void]$lines.Add("$Prefix$connector$($item.Name)")
            }
        }
    }
    
    [void]$lines.Add(".")
    Write-Tree -Node $tree
    return $lines
}

function Get-Banner {
    param([string]$Title)
    $line = "=" * $Title.Length
    return "$line`n$Title`n$line`n"
}

# Main logic
$rootPath = (Resolve-Path $Root).Path
if (-not (Test-Path -LiteralPath $rootPath -PathType Container)) {
    Write-Error "Error: $rootPath is not a directory"
    exit 1
}

$projectName = (Split-Path -Leaf $rootPath) -replace '[^A-Za-z0-9._-]+', '_'
if ([string]::IsNullOrEmpty($projectName)) { $projectName = "workspace" }

if ($Output) {
    $outFile = $Output
} else {
    $ts = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd_HH-mm-ss")
    $outFile = Join-Path $rootPath "full_codebase_${projectName}_${ts}.txt"
}

if ($IncludeSecrets) {
    Write-Warning "WARNING: Including secrets/credentials in bundle!"
    Write-Warning "   Do NOT share this file publicly!"
}

# Collect files (excluding symlink directories and reparse points)
$allFiles = [System.Collections.ArrayList]::new()

Get-ChildItem -LiteralPath $rootPath -Recurse -File -Attributes !ReparsePoint -ErrorAction SilentlyContinue | ForEach-Object {
    $file = $_
    
    # Skip files in symlink directories
    if ($file.Directory.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { return }
    
    $relativePath = $file.FullName.Substring($rootPath.Length).TrimStart('\', '/')
    
    # Check if in excluded directory
    $inExcludedDir = $false
    $pathParts = $relativePath -split '[/\\]'
    foreach ($part in $pathParts[0..($pathParts.Count - 2)]) {
        if ($EXCLUDE_DIRS -contains $part) {
            $inExcludedDir = $true
            break
        }
    }
    if ($inExcludedDir) { return }
    
    # Secret check
    if (-not $IncludeSecrets -and (Test-SecretFile -FileName $file.Name)) { return }
    
    # Include check
    if (-not (Test-IncludedFile -FilePath $file.FullName)) { return }
    
    [void]$allFiles.Add($relativePath)
}

$allFiles = $allFiles | Sort-Object

# Create tree
$treeLines = Get-TreeLines -Files $allFiles

# Write bundle (streaming instead of RAM buffer)
$skippedCount = 0
$totalBytes = 0

# Write header
$header = [System.Text.StringBuilder]::new()
[void]$header.Append((Get-Banner "PROJECT: $projectName"))
[void]$header.AppendLine("# FULL CODEBASE BUNDLE")
[void]$header.AppendLine("# Root: $rootPath")
[void]$header.AppendLine("# Date: $((Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC")
[void]$header.AppendLine("# Files: $($allFiles.Count)")
[void]$header.AppendLine("# Secrets included: $IncludeSecrets")
[void]$header.AppendLine("# Strict extensions: $StrictExtensions")
[void]$header.AppendLine()
[void]$header.AppendLine("CODE ORGANIZATION / DIRECTORY STRUCTURE")
[void]$header.AppendLine("---------------------------------------")
foreach ($line in $treeLines) {
    [void]$header.AppendLine($line)
}
[void]$header.AppendLine()
[void]$header.AppendLine("FILE CONTENTS")
[void]$header.AppendLine("-------------")

# Initialize file with header
$header.ToString() | Out-File -LiteralPath $outFile -Encoding UTF8 -NoNewline

# Stream files
foreach ($rel in $allFiles) {
    $absPath = Join-Path $rootPath $rel
    
    $result = Get-SafeFileContent -FilePath $absPath
    
    $fileHeader = "`n==================== FILE: $rel ====================`n"
    $fileHeader | Add-Content -LiteralPath $outFile -Encoding UTF8 -NoNewline
    
    if ($result.Reason) {
        "<<SKIPPED: $($result.Reason)>>`n" | Add-Content -LiteralPath $outFile -Encoding UTF8 -NoNewline
        $skippedCount++
    } else {
        $content = $result.Content
        if ($null -eq $content) { $content = "" }
        
        $content | Add-Content -LiteralPath $outFile -Encoding UTF8 -NoNewline
        if (-not $content.EndsWith("`n")) {
            "`n" | Add-Content -LiteralPath $outFile -Encoding UTF8 -NoNewline
        }
        $totalBytes += [System.Text.Encoding]::UTF8.GetByteCount($content)
    }
    
    "==================== END: $rel ====================`n" | Add-Content -LiteralPath $outFile -Encoding UTF8 -NoNewline
}

$bundledCount = $allFiles.Count - $skippedCount
$sizeMB = [math]::Round($totalBytes / 1MB, 2)

Write-Host "✓ Bundle created: $(Split-Path -Leaf $outFile)" -ForegroundColor Green
Write-Host "  Files bundled: $bundledCount"
Write-Host "  Files skipped: $skippedCount"
Write-Host "  Total size: $sizeMB MB"
