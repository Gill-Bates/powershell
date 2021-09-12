
#region staticVariables
$path = "C:\Users\Tobias\Desktop\facklet\test"
$csv = Import-Csv -Path "C:\Users\Tobias\Desktop\facklet\test\bpm.csv" -Delimiter ';'
#endregion


# Load DLL for manipulating MP3-Tags
if (!(Test-Path -Path "$PSScriptRoot\taglib-sharp.dll")) {
    # Download: https://www.nuget.org/packages/taglib/
    throw "Required file 'taglib-sharp.dll' missing! Add the file to the directory and try again!"
}
else {
    [Reflection.Assembly]::LoadFrom("$PSScriptRoot\taglib-sharp.dll")
}

# DEBUG
[Reflection.Assembly]::LoadFrom("D:\_Repo\powershell\bpm2mp3\taglib-sharp.dll")
#### PROGRAM AREA ####




# Get a list of files in your path.  Skip directories.
$files = Get-ChildItem -Path $path | Where-Object { (-not $_.PSIsContainer) }


foreach ($i in $files) {
    $count = 1
    Write-Output "[$count/$($files.count)] Loading '$($i.Name)' "
    $media = [TagLib.File]::Create(($i.FullName))
    $count++


    $media
}






 
# Loop through the files
foreach ($i in $files) {

    # Load up the MP3 file.
    $media = [TagLib.File]::Create(($path + $i))

    # Load up the tags we know
    $albumartists = [string]$media.Tag.AlbumArtists
    $title = $media.Tag.Title
    $artists = [string]$media.Tag.Artists
    $extension = $filename.Extension
    # A few files had no title.  Lets just save them with an artist name
    if ([string]::IsNullOrEmpty($title)) {
        $title = “missing title”
        $media.Tag.Title = $title
    }
    # If the artists tag has info in it, use that, then reset albumartists tag to match
    if ($artists) {
        $name = $artists + ”-“ + $title.Trim() + $extension
        $media.Tag.AlbumArtists = $artists
    }
    # If the artists tag is empty, use the albumartists field, and set artists to match
    else {
        $name = $albumartists + ”-“ + $title.Trim() + $extension
        $media.Tag.Artists = $albumartists
    }
    # Save the tag changes back
    $media.Save()
    #remove any carriage returns in what will be the new filename
    $name = [string]$name -replace “`t|`n|`r”, ””
    #remove illegal characters, replace with a hyphen
    [System.IO.Path]::GetInvalidFileNameChars() | % { $name = $name.replace($_, ’ ‘) }
    # There could be duplicate MP3 files with this name, so check if the new filename already exists
    If (Test-Path $path$name) {
        [int]$i = 1
        #if the file already exists, re-name it with an incrementing value after it, for example: Artist-Song Title-2.mp3
        While (Test-Path $path$newname) {
            $newname = $name
            $justname = [System.IO.Path]::GetFileNameWithoutExtension($path + $newname)
            $newname = $justname + ”-“ + $i + $extension
            $i++
        }
        $name = $newname
    }
    #rename the file per those tags
    Rename-Item  $path$filename $path$name
 
}