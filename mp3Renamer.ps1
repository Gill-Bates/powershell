<# 
.SYNOPSIS Mp3-Renamer
.DESCRIPTION 
.NOTES Author: Gill Bates, Last Update: 07.11.2021
#>

[string]$Path = "C:\Users\Tobias\Downloads\BENGR_-_Blow_The_Speakers_(Extended_Mix)-(DWX1507)-WEB-2023"
[int]$leadingNumbers = 3

function Rename-Mp3 {
    Param(
        [parameter(Mandatory = $true)]
        [String]$Path,
        [parameter(Mandatory = $true)]
        [int]$leadingNumbers
    )

    $allMp3 = Get-ChildItem -Path $Path -Filter *.mp3 -Recurse
    Write-Information "[OK] Fetched total '$($allMp3.Count)' MP3-Files!" -InformationAction Continue

    $output = New-Item -Path $Path -Name "_Rename" -ItemType "directory" -Force
    $TextInfo = (Get-Culture).TextInfo

    $count = 1
    $allMp3 | ForEach-Object {
    
        Copy-Item $_.FullName -Destination $output -Force
        $_.BaseName.substring($leadingNumbers) -replace '_', ' ' -replace "and", "&" | ForEach-Object {

            $newCamelCase = $TextInfo.ToTitleCase($_).Trim()
        }
        Write-Information "[$Count/$($allMp3.Count)] Renaming '$newCamelCase' ..." - -InformationAction Continue
        Rename-Item -Path "$output\$($_.PSChildName)" -NewName ($newCamelCase + $_.Extension)
        $count++
    }
}