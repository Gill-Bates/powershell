# https://blueforcer.github.io/awtrix3/#/api?id=custom-apps-and-notifications

# GET
$Params = @{
    "Uri"    = "http://10.40.0.44/api/stats"
    "Method" = "GET"
}

return Invoke-RestMethod @Params


#POST
$Body = @{
    text     = "Hi Sven!"
    duration = 10
} | ConvertTo-Json -Depth 10

$Params = @{
    Uri         = "http://10.40.0.44/api/custom"
    Method      = "POST"
    Body        = $Body
    ContentType = "application/json"
}

Invoke-RestMethod @Params


