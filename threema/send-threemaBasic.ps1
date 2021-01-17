<#
.SYNOPSIS
    This Function sends Messages from Basic Accounts with REST.
    Source: https://github.com/Gill-Bates/threema
    Last Update: 15.01.2021
.EXAMPLE
    PS C:\> Send-ThreemaBasic -SenderId <ID> -Recieptient <ID> -Message <MYMESSAGE> -Secret <MYSECRET>
#>

function Send-ThreemaBasic {
    [CmdletBinding()]
    param (
        [parameter(Mandatory = $true)][String]$SenderId, # Include leading Asterisk!
        [parameter(Mandatory = $true)][String[]]$Reciepient,
        [parameter(Mandatory = $true)][String]$Message,
        [parameter(Mandatory = $true)][String]$Secret
    )
    $SenderId = $SenderId.ToUpper()
    $Reciepient = $Reciepient.ToUpper()
    # Set Encoding
    if ($OutputEncoding.BodyName -ne "UTF-8") { $OutputEncoding = [System.Text.Encoding]::UTF8 }
    # Check for Filesize
    if ([System.Text.Encoding]::UTF8.GetByteCount($Message) -gt 3500) {
        $ErrorMsg = "[ERROR] Message size exceed the limit of 3500 Bytes! $($_.Exception.Message)!"
        Write-Error -Message $ErrorMsg
        Exit
    }
    # Check for enough Credis
    try {
        $RestBody = "from=$SenderId&secret=$Secret"
        $RestCommand = Invoke-RestMethod `
            -Headers $Header `
            -Uri https://msgapi.threema.ch/credits?$RestBody `
            -Method GET
        if ($?) { 
            if (!($Reciepient.Count -lt ($RestCommand - $Reciepient.Count))) {
                $ErrorMsg = "[ERROR] Sender-Id '$SenderId' has not enough Credits to send the Message!"
                Write-Error -Message $ErrorMsg
            }
        }
    }
    catch {
        $ErrorMsg = "[ERROR] while getting Threema-Credits for Id '$SenderId': $($_.Exception.Message)!"
        Write-Error -Message $ErrorMsg
        Exit
    }
    # Send Messages
    $Counter = 1
    foreach ($Rec in $Reciepient) {
        Write-Information "[$Counter/$($Reciepient.Count)] Sending Message to '$Rec' ..." -InformationAction Continue
        try {
            $RestBody = "from=$SenderId&secret=$Secret&to=$Rec&text=$Message"
            Invoke-RestMethod `
                -Headers $Header `
                -Uri https://msgapi.threema.ch/send_simple?$RestBody `
                -Method POST `
                -ContentType 'application/x-www-form-urlencoded'
            if ($?) {
                Write-Information "[OK] Threema-Message has been send successfully!" -InformationAction Continue
                $Counter += 1
            }
        }
        catch {
            $ErrorMsg = "[ERROR] while sending Threema-Message to '$Reciepient': $($_.Exception.Message)!"
            Write-Error -Message $ErrorMsg
            Exit
        }
    }
    # Check for remaining Credits
    try {
        $RestBody = "from=$SenderId&secret=$Secret"
        $RestCommand = Invoke-RestMethod `
            -Headers $Header `
            -Uri https://msgapi.threema.ch/credits?$RestBody `
            -Method GET
            if ($?) { 
                Write-Information "[OK] Remaining Credits for '$SenderId' ($('{0:N0}' -f $RestCommand))" -InformationAction Continue
            }
    }
    catch {
        $ErrorMsg = "[ERROR] while getting Threema-Credits for Id '$SenderId': $($_.Exception.Message)!"
        Write-Error -Message $ErrorMsg
        Exit
    }
}
#End of Script