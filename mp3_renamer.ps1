<# 
.SYNOPSIS Mp3-Renamer
.DESCRIPTION 
.NOTES Author: Gill Bates, Last Update: 2025-09-04
#>

function Rename-Mp3 {
    Param(
        [parameter()]
        [string]$Path = (Get-Location).Path
    )

    $allMp3 = Get-ChildItem -Path $Path -Filter *.mp3 -Recurse
    Write-Information "[OK] Fetched total '$($allMp3.Count)' MP3-Files!" -InformationAction Continue

    $output = New-Item -Path $Path -Name "_Rename" -ItemType "directory" -Force
    $TextInfo = (Get-Culture).TextInfo

    [int]$count = 1
    foreach ($mp3 in $allMp3) {
        Copy-Item $mp3.FullName -Destination $output.FullName -Force

        $base = $mp3.BaseName
        # Führende Zahlen + optionaler Unterstrich entfernen
        $newNameBase = $base -replace '^\d+_?', '' -replace '_', ' ' -replace '\band\b', '&'

        $newCamelCase = $TextInfo.ToTitleCase($newNameBase).Trim()

        Write-Information "[$count/$($allMp3.Count)] Renaming '$($mp3.Name)' to '$newCamelCase$($mp3.Extension)'" -InformationAction Continue
        Rename-Item -Path (Join-Path $output.FullName $mp3.Name) -NewName ($newCamelCase + $mp3.Extension) -Force
        $count++
    }
}