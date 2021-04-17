#Requires -Modules Az.Account
#Requires -Modules Az.Billing

#region StaticVariables
[string]$CostTag = "AzCosts"
[string]$LM = (Get-Date).AddMonths(-1).ToString("yyyyMM")
[string]$LLM = (Get-Date).AddMonths(-2).ToString("yyyyMM")
[int]$HistoryInMonth = 12
#endregion

function Get-Logtime {
    # This function is optimzed for Azure Automation!
    $Timeformat = "yyyy-MM-dd HH:mm:ss" #yyyy-MM-dd HH:mm:ss.fff
    if ((Get-TimeZone).Id -ne "W. Europe Standard Time") {
        try {
            $tDate = (Get-Date).ToUniversalTime()
            $tz = [System.TimeZoneInfo]::FindSystemTimeZoneById("W. Europe Standard Time")
            $TimeZone = [System.TimeZoneInfo]::ConvertTimeFromUtc($tDate, $tz)
            return $(Get-Date -Date $TimeZone -Format $Timeformat)
        }
        catch {
            return "$(Get-Date -Format $Timeformat) UTC"
        }
    }
    else { return $(Get-Date -Format $Timeformat) }
}

function Get-TaggedCostItems {
    param (
        [Parameter(Mandatory = $true)]
        $BillingPeriodUsage,
        [Parameter(Mandatory = $true)]
        $CostTag
    )
    $AllTaggedCostItems = Get-AzConsumptionUsageDetail -BillingPeriodName $BillingPeriodUsage -Expand MeterDetails `
    | Where-Object { $null -ne $_.Tags -and $_.Tags["$CostTag"] }`
    
    return $AllTaggedCostItems
}

# Get all Subscriptions
Write-Output "[$(Get-Logtime)] Scanning for Subscriptions ..."
$AllSubs = Get-AzSubscription | Where-Object { $_.Name -notlike "*Directory*" }
Write-Output "[$(Get-Logtime)] [OK] '$($AllSubs.Count)' Subscriptions found! Proceed ..."

# Collecting CostItems
$AllCostItems = @()
$Count = 1
foreach ($Sub in $AllSubs) {
    Write-Output "[$(Get-Logtime)] [$Count/$($AllSubs.Count)] Collecting CostItems for Subscription '$($Sub.Name)' ..."
    Set-AzContext -SubscriptionId $Sub.Id
    $AllCostItems += Get-TaggedCostItems -BillingPeriodUsage $LM -CostTag $CostTag
    $AllCostItems += Get-TaggedCostItems -BillingPeriodUsage $LLM -CostTag $CostTag

    if ($?) { $Count += 1 }
}

# Generating Report
Write-Output "[$(Get-Logtime)] [$Count/$($AllSubs.Count)] Generating Report ..."
$AllCostItemsGroup = $AllCostItems | Group-Object -Property { $_.Tags["$CostTag"] }

$Report = @()

foreach ($Item in $AllCostItemsGroup) {
    $SumLLM = @()
    $SumLM = @()

    foreach ($CostItem in $Item.Group) {

        if ($CostItem.BillingPeriodName -eq "20210101") {
            $SumLLM += $CostItem.PretaxCost
        }
        elseif ($CostItem.BillingPeriodName -eq "20210201") {
            $SumLM += $CostItem.PretaxCost
        }
    }

    $TotalLM = $SumLM | Measure-Object -Sum
    $TotalLLM = $SumLLM | Measure-Object -Sum

    $myObject = [PSCustomObject]@{
        AzTag = $Item.Name
        $LM   = [math]::Round($TotalLM.Sum, 2) 
        $LLM  = [math]::Round($TotalLLM.Sum, 2)
    }
    $Report += $myObject
}

# Print Result
$Report | Sort-Object $LM -Descending | Where-Object { ($_.$LM -ge 1) -or ($_.$LLM -ge 1) }



# TotalCosts of last 12 Month
$HistoryItems = Get-AzConsumptionUsageDetail -StartDate (Get-Date).AddMonths(-$HistoryInMonth).ToString("yyyy-MM-01")  -EndDate (Get-Date).AddMonths(-1).ToString("yyyy-MM-28") `
| Where-Object { $null -ne $_.Tags -and $_.Tags["$CostTag"] } `
| Group-Object -Property BillingPeriodName `
| Sort-Object -Property BillingPeriodName -Descending


$HistoryReport = @()

foreach ($Item in $HistoryItems) {
    $Sum = @()

    foreach ($CostItem in $Item.Group) {

        $Sum += $CostItem.PretaxCost

    $Total = $Sum | Measure-Object -Sum

    $myObject = [PSCustomObject]@{
        Month       = $Item.Name
        PreTaxCost  = [math]::Round($Total.Sum, 2) 
    }
    $HistoryReport += $myObject
}
}

$LastMonth = (Get-Date).AddMonths(-1).ToString("yyyy,MM")
[datetime]::DaysInMonth($LastMonth)
