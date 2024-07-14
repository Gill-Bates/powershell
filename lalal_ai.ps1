<# 
.SYNOPSIS lalal.ai Powershell API Usage
.DESCRIPTION
# Docs: https://www.lalal.ai/api/help/
# Requires 3 Steps
# 1) Upload the File to obtain an FileId
# 2) Put the File into
#       a) the Preview or 
#       b) Splitting Cue
# 3) Check the Status if the file is ready to Download
.NOTES Author: Gill Bates, Last Update: 11.07.2024
#>

#Requires -PSEdition Core

param(
    [Parameter(Mandatory = $true)]
    [string]$licenseKey
)

Clear-Host

# region functions
function Get-LalalBilling {

    param(
        [Parameter(Mandatory = $true)]
        [string]$licenseKey
    )

    $Params = @{
        "Uri"                     = "https://www.lalal.ai/billing/get-limits/?key=$licenseKey"
        "Method"                  = "GET"
        "ResponseHeadersVariable" = "ResponseHeaders"
        "StatusCodeVariable"      = "StatusCode"
    }

    return Invoke-RestMethod @Params
}

function Start-LalalVoiceUpload {

    param(
        [Parameter(Mandatory = $true)]
        [string]$licenseKey,
        [Parameter(Mandatory = $true)]
        [string]$FilePath
    )

    $fileInfo = Get-Item -Path $FilePath

    $Headers = @{
        "Authorization"       = "license $licenseKey"
        "Content-Disposition" = "attachment; filename=$($fileInfo.name)"
    }

    
    $Params = @{
        "Uri"                     = "https://www.lalal.ai/api/upload/"
        "Method"                  = "POST"
        "Headers"                 = $Headers
        "InFile"                  = $fileInfo.FullName
        "AllowInsecureRedirect"   = $true
        "SkipHeaderValidation"    = $true
        "ResponseHeadersVariable" = "ResponseHeaders"
        "StatusCodeVariable"      = "StatusCode"
    }
 
    $query = Invoke-RestMethod @Params

    if ($query.status -like "success") {
        return $query
    }
    else {
        throw "[ERROR] while uploading File: $($query.error)"
    } 
}

function Start-LalalVoicePreview {

    param(
        [Parameter(Mandatory = $true)]
        [string]$licenseKey,
        [Parameter(Mandatory = $true)]
        [string]$trackId
    )

    $Headers = @{
        "Authorization" = "license $licenseKey"
    }
   
    $Params = @{
        "Uri"                     = "https://www.lalal.ai/api/preview/"
        "Method"                  = "POST"
        "Headers"                 = $Headers
        "ResponseHeadersVariable" = "ResponseHeaders"
        "StatusCodeVariable"      = "StatusCode"
        "Body"                    = @{
            "id" = "$trackId"
        }
    }

    $query = Invoke-RestMethod @Params

    if ($query.status -like "success") {
        return $query
    }
    else {
        throw "[ERROR] while starting Preview Job '$trackId': $($query.error)"
    } 
}

function Get-LalalVoicePreview {

    param(
        [Parameter(Mandatory = $true)]
        [string]$licenseKey,
        [Parameter(Mandatory = $true)]
        [string]$trackId
    )
 
    $Headers = @{
        "Authorization" = "license $licenseKey"
    }
   
    $Params = @{
        "Uri"                     = "https://www.lalal.ai/api/check/"
        "Method"                  = "POST"
        "Headers"                 = $Headers
        "ResponseHeadersVariable" = "ResponseHeaders"
        "StatusCodeVariable"      = "StatusCode"
        "Body"                    = @{
            "id" = $trackId
        }
    }

    [int]$count = 1
    do {
        
        $query = Invoke-RestMethod @Params
        Write-Information "[INFO] [$count/5] File not ready yet! Waiting 10 Seconds ..." -InformationAction Continue
        Start-Sleep -Seconds 10
        $count++
    } until (
        $query.result.$trackId.preview.stem_track -or $count -ge 5 # Giving up after 5 Tries!
    )

    if ( ($query.result.$trackId).Status -like "success") {

        $outputFile = (Join-Path $env:temp ($query.result.$trackId.name))
        Write-Information "[INFO] Output File located here: '$outputFile'!" -InformationAction Continue
        return Invoke-RestMethod -Uri $query.result.$trackId.preview.stem_track -OutFile $outputFile
    }
    else {
        throw "[ERROR] while downlading Job '$trackId': $($query.error)"
    }
}
# endregion

# Check if License is valid
$licenseCheck = Get-LalalBilling -licenseKey $licenseKey

if ($licenseCheck.status -like "success") {
    Write-Output "[OK] Provided License Key (registered to '$($licenseCheck.email)') is valid! Proceed ..."
}
else {
    throw "[ERROR] Provided License Key '$licenseKey' is invalid or unknown! Check your Code and try again!"
}

do {
    $trackPath = Read-Host "Enter full File Path of your Audio that you want to upload"
    $trackPath = $trackPath.Replace('"', '')
    $trackInfo = Get-ChildItem -Path  $trackPath
    if ( !(Test-Path -Path $trackInfo) ) { Write-Warning "Path is not valid! Try again!" -WarningAction Continue }
} until (
    (Test-Path -Path $trackInfo)
)

Write-Output "[INFO] Uploading Audio File ($([math]::round($trackInfo.Length/1MB,1)) MB) ..."
$upload = Start-LalalVoiceUpload -licenseKey $licenseKey -FilePath $trackPath

Write-Output "[INFO] Starting Preview Job ..."
$null = Start-LalalVoicePreview -licenseKey $licenseKey -trackId $upload.id

Get-LalalVoicePreview -licenseKey $licenseKey -trackId $upload.id

if ($?) {
    Write-Output "[OK] All Operations done! Exit here.`n"
}
Exit