![Project Logo](https://raw.githubusercontent.com/Gill-Bates/powershell/main/threema/img/logo.png)

# Threema Powershell Functions
With this Toolset I want to provide you functions to use the awesome [Threema-Gateway](https://gateway.threema.ch/) with Powershell. You need a paid Threema-Basic ID to use the Gateway. **The free trial ID will not work.**

## Send-ThreemaBasic
Just type `Send-ThreemaBasic -SenderId <ID> -Recieptient <ID> -Message <MYMESSAGE> -Secret <MYSECRET>` to send a Message.

### Features
🔥 Checks for UTF-8  
🔥 Checks for maximal Message lenght  
🔥 Multiple Reciepients  
🔥 Checks for enough Credits  
🔥 Print the remaining Credits

### Multiple Recipients
Sending Messages to multiple Recipients are straight forward:
```powershell
$reciepientList = @(
    "*ID1" # Alice
    "*ID2" # Bob
    # etc ...
)
```
Just use
```powershell
-Recieptient $reciepientList
```

## Get-ThreemaCredits
Just enter `Get-ThreemaCredits -Id <ID> -Secret <MYSECRET>` to receive the Integer.
