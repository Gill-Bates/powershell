<# 
.SYNOPSIS Script to extract the Windows Product Key (aka Activation Key)
.DESCRIPTION 
.NOTES Author: Gill Bates, Last Update: 2025-10-30
#>

function Get-WinActivationKey {

    try {
        $dpid = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name DigitalProductId).DigitalProductId
    }
    catch {
        throw "[ERROR] while fetching Digital Product ID: $($_.Exception.Message)"
    }
   
    $map = "BCDFGHJKMPQRTVWXY2346789"
    $start = 52
    $keyChars = New-Object System.Collections.Generic.List[char]
    for ($i = 0; $i -lt 25; $i++) {
        $acc = 0
        for ($j = 14; $j -ge 0; $j--) {
            $acc = ($acc * 256) -bxor $dpid[$start + $j]
            $dpid[$start + $j] = [math]::Floor($acc / 24)
            $acc = $acc % 24
        }
        $keyChars.Insert(0, $map[$acc])
    }
    $key = -join ($keyChars)
    $finalKey = $key -replace '(.{5})(?=.)', '$1-'

    Write-Host "`nWindows Product Key:" -ForegroundColor Cyan
    Write-Host $finalKey -ForegroundColor Green
    return
}

