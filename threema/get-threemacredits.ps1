<#
.SYNOPSIS
    This Function gets the Credits from Basic Accounts with REST
.DESCRIPTION
.EXAMPLE
    PS C:\> Send-Threema -Reciepient <*MYID> -Message <MYMESSAGE>
.INPUTS
    Inputs (if any)
.OUTPUTS
    Output (if any)
.NOTES
#>
function Get-ThreemaCredits {
    param (
        [parameter(Mandatory = $true)][String]$Id,
        [parameter(Mandatory = $true)][String]$Secret
    )
    try {
        $Id = $Id.ToUpper()
        $RestBody = "from=$Id&secret=$Secret"
        $RestCommand = Invoke-RestMethod `
            -Headers $Header `
            -Uri https://msgapi.threema.ch/credits?$RestBody `
            -Method GET
        if ($?) { return $RestCommand }
    }
    catch {
        $ErrorMsg = "[ERROR] while getting Threema-Credits for Id '$Id': $($_.Exception.Message)!"
        Write-Error -Message $ErrorMsg
        Exit
    }
}
