#!/usr/bin/env pwsh
# Cron every 15 Min
# */15 * * * * pwsh -File "/opt/phl/phl_mqtt.ps1"

<# 
.SYNOPSIS Phl Waitingtime Processor (MQTT Version)
.DESCRIPTION Sends park status and ride wait times to MQTT broker
.NOTES Author: Gill Bates, Last Update: 2025-04-27
.NOTES Optimized for MQTTnet by ChatGPT
#>

# MQTT Configuration
[string]$mqttServer = "10.20.0.110"
[int]$mqttPort = 1883
[string]$baseTopic = "phantasialand"
#[string]$dllPath = "D:\_Repos\powershell\phl_mqtt\MQTTnet.dll"
[string]$dllPath = "/opt/phl-mqtt/MQTTnet.dll"

# Logging Configuration
[string]$logPath = "/var/log/phlapi_mqtt.log"

###################### FUNCTIONS ###################### 

function Get-ParkStatus {
    try {
        return Invoke-RestMethod -Method GET -Uri "https://api.phlsys.de/api/park-infos"
    }
    catch {
        throw "[ERROR] Park Status API: $($_.Exception.Message)"
    }
}

function Get-PhlWaitTime {
    Write-Information "[INFO] Fetching data from 'wartezeiten.app'" -InformationAction Continue

    try {
        $headers = @{
            "park"     = "phantasialand"
            "language" = "de"
        }

        $params = @{
            URI     = "https://api.wartezeiten.app/v1/waitingtimes"
            Method  = "GET"
            Headers = $headers
        }

        $query = Invoke-RestMethod @params | Group-Object Name
    }
    catch {
        throw "[ERROR] Waiting Time API: $($_.Exception.Message)"
    }

    $lastUpdated = Get-Date (($query.Group.date | Select-Object -First 1) + " " + ($query.Group.time | Select-Object -First 1))
    
    $rides = $query | ForEach-Object {
        [PSCustomObject]@{
            ride        = $_.Name
            status      = ($_.Group.status | Select-Object -First 1).ToLower()
            waitTime    = [int]($_.Group.waitingtime | Select-Object -First 1)
            lastUpdated = [datetime]$lastUpdated
        }
    }

    Write-Information "[INFO] Received data for $($rides.Count) rides" -InformationAction Continue
    return $rides | Sort-Object ride
}

function Connect-MQTT {

    param (
        [Parameter(Mandatory = $true)]
        [string]$MqttServer,
        [Parameter()][int]$MqttPort = 1883,
        [Parameter(Mandatory = $true)]
        [string]$DllPath
    )

    try {
        Add-Type -Path $DllPath
        $logger = New-Object MQTTnet.Diagnostics.Logger.MqttNetEventLogger -ArgumentList "PowerShellLogger"
        $clientFactory = New-Object MQTTnet.MqttClientFactory($logger)
        $client = $clientFactory.CreateMqttClient()
        $options = New-Object MQTTnet.MqttClientOptionsBuilder
        $options = $options.WithTcpServer("10.20.0.110", 1883).Build()
        $connectResult = $client.ConnectAsync($options).GetAwaiter().GetResult()

        if ($connectResult.ResultCode -like "Success") {
            Write-Information "[INFO] Connected successfully to MQTT broker $MqttServer" -InformationAction Continue
            return $client
        }
        else {
            throw "[ERROR] MQTT Connect: $($connectResult.ResultCode)"
        }    
    }
    catch {
        throw "[ERROR] MQTT Connect: $($_.Exception.Message)"
    }
}

function Send-MQTTMessage {
    param (
        [Parameter(Mandatory = $true)][object]$Client,
        [Parameter(Mandatory = $true)][string]$Topic,
        [Parameter(Mandatory = $true)][string]$Message,
        [Parameter()][bool]$Retain = $false
    )

    try {
        $messageBuilder = [MQTTnet.MqttApplicationMessageBuilder]::new()
        $messageBuilder = $messageBuilder.WithTopic($Topic)
        $messageBuilder = $messageBuilder.WithPayload($Message)
        $messageBuilder = $messageBuilder.WithQualityOfServiceLevel([MQTTnet.Protocol.MqttQualityOfServiceLevel]::AtLeastOnce)
        $messageBuilder = $messageBuilder.WithRetainFlag($Retain)

        $mqttMessage = $messageBuilder.Build()

        $publishResult = $Client.PublishAsync($mqttMessage).GetAwaiter().GetResult()

        return $publishResult.ReasonCode
    }
    catch {
        Write-Warning "[WARNING] Publish to $Topic failed: $($_.Exception.Message)"
    }
}

function Disconnect-MQTT {
    param(
        [Parameter(Mandatory = $true)]
        [MQTTnet.Internal.Disposable]$Client
    )

    try {
        if ($Client.IsConnected) {

            $disconnectOptions = New-Object MQTTnet.MqttClientDisconnectOptionsBuilder
            $disconnectOptions = $disconnectOptions.WithReason([MQTTnet.MqttClientDisconnectOptionsReason]::NormalDisconnection)
            $disconnectOptions = $disconnectOptions.Build()


            $disconnectStatus = $Client.DisconnectAsync($disconnectOptions).GetAwaiter().GetResult()

            if ($disconnectStatus -like "System.Threading.Tasks.VoidTaskResult") {
                Write-Information "[OK]   Disconnected from MQTT broker" -InformationAction Continue
            }
            else {
                throw "[ERROR] MQTT Disconnect: $($disconnectStatus)"
            }
        }
        else {
            Write-Information "[OK]   MQTT client already disconnected" -InformationAction Continue
        }
    }
    catch {
        throw "[ERROR] Failed to disconnect MQTT client: $($_.Exception.Message)"
    }
    finally {
        if ($Client) {
            try {
                $Client.Dispose()
            }
            catch {
                throw "[ERROR] Failed to dispose MQTT client: $($_.Exception.Message)"
            }
        }
    }
}

###################### PROGRAM START ###################### 

$null = Start-Transcript -Path $logPath -UseMinimalHeader -Append -Force

Write-Output "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [INFO] Starting MQTT export..."

try {
    $mqttClient = Connect-MQTT -MqttServer $mqttServer -MqttPort $mqttPort -dllPath $dllPath

    # Get and send park status
    $parkStatus = Get-ParkStatus

    if ($parkStatus) {

        $parkData = $parkStatus | ConvertTo-Json -Depth 3
        Send-MQTTMessage -Client $mqttClient -Topic "$baseTopic/park/status" -Message $parkData -Retain $true
    }
    else {
        throw "[WARNING] No park status data received."
    }

    # Get and send ride wait times
    $rides = Get-PhlWaitTime
    $rideData = $rides | ConvertTo-Json -Depth 3

    if (!$rideData.ride) {

        Write-Warning "[WARNING] Park is closed! No rides available."
    }
    else {
        $topicName = "$baseTopic/rides/$($ride.ride -replace '[^a-zA-Z0-9]', '_')"
        Send-MQTTMessage -Client $mqttClient -Topic $topicName -Message $rideData

        if ($?) {
            Write-Information "[OK]   Data successfully sent to MQTT broker" -InformationAction Continue
        }
    }
}
catch {
    Write-Error "[FATAL] Unhandled exception: $($_.Exception.Message)"
}
finally {
    if ($mqttClient.IsConnected) {
        Disconnect-MQTT -Client $mqttClient
    }

    if ($?) {
        Write-Output "[OK]   MQTT export completed successfully. Bye!"
    }
    $null = Stop-Transcript
}
#End of Script