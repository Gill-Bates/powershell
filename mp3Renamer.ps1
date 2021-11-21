# Mp3-Renamer
# Last Update: 07.11.2021

[string]$Path = "C:\Users\Tobias\Desktop\facklet\VA_-_Hardstyle_The_Annual_2022-(BYMD158)-WEB-2021-SRG"
[int]$leadingNumbers = 4

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

            $newCamelCase = $TextInfo.ToTitleCase($_)
        }
        Write-Information "[$Count/$($allMp3.Count)] Renaming '$newCamelCase' ..." - -InformationAction Continue
        Rename-Item -Path "$output\$($_.PSChildName)" -NewName ($newCamelCase + $_.Extension)
        $count++
    }

}