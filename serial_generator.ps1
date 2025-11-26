### USAGE ###

# Generate signature
Invoke-SerialSignature -BaseSerial "ABC123" -Secret "supersecret"

# Validate existing signature  
Invoke-SerialSignature -FullSerial "ABC123-9EE3"  -Secret "supersecret"

# Generate signature witth custom length
Invoke-SerialSignature -BaseSerial "ABC123" -Secret "supersecret" -SignatureLength 6

function Invoke-SerialSignature {
    [CmdletBinding(DefaultParameterSetName = "Generate")]
    param(
        # Parameter for generation mode
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "Generate")]
        [ValidateNotNullOrEmpty()]
        [string]$BaseSerial,

        # Parameter for validation mode
        [Parameter(Mandatory = $true, Position = 0, ParameterSetName = "Validate")]
        [ValidateNotNullOrEmpty()]
        [string]$FullSerial,

        # Secret key (optional, has default for demos)
        [Parameter(Mandatory = $false)]
        [ValidateNotNullOrEmpty()]
        [string]$Secret = "supersecretkey",

        # Configurable signature length
        [Parameter(Mandatory = $false)]
        [ValidateRange(1, 8)]
        [int]$SignatureLength = 4
    )

    $hmac = $null
    try {
        # 1. Initialize HMAC object (needed for both modes)
        $hmac = [System.Security.Cryptography.HMACSHA256]::new()
        $hmac.Key = [System.Text.Encoding]::UTF8.GetBytes($Secret)

        # Calculate how many bytes we need for the desired signature length
        $bytesNeeded = [math]::Ceiling($SignatureLength / 2)

        # Process based on parameter set
        switch ($PSCmdlet.ParameterSetName) {
            "Validate" {
                return Test-SerialSignature -FullSerial $FullSerial -Hmac $hmac -BytesNeeded $bytesNeeded -SignatureLength $SignatureLength
            }
            "Generate" {
                return New-SerialSignature -BaseSerial $BaseSerial -Hmac $hmac -BytesNeeded $bytesNeeded -SignatureLength $SignatureLength
            }
        }
    }
    catch {
        throw "Error initializing HMAC object: $($_.Exception.Message). Please check the secret key."
    }
    finally {
        # Proper cleanup - only dispose if hmac was successfully created
        if ($null -ne $hmac) {
            $hmac.Dispose()
        }
    }
}

#region Helper Functions
function New-SerialSignature {
    param(
        [string]$BaseSerial,
        [System.Security.Cryptography.HMACSHA256]$Hmac,
        [int]$BytesNeeded,
        [int]$SignatureLength
    )

    Write-Verbose "Generating signature for: '$BaseSerial'"
    
    # Calculate hash
    $hashBytes = $Hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($BaseSerial))
    
    # Format signature - take required bytes and convert to uppercase hex
    $signatureBytes = $hashBytes[0..($BytesNeeded - 1)]
    $calculatedSignature = ($signatureBytes | ForEach-Object { $_.ToString("X2") }) -join ""
    
    # Trim if we have more characters than needed (when SignatureLength is odd)
    if ($calculatedSignature.Length -gt $SignatureLength) {
        $calculatedSignature = $calculatedSignature.Substring(0, $SignatureLength)
    }
    
    # Return combined serial number
    return "${BaseSerial}-${calculatedSignature}"
}

function Test-SerialSignature {
    param(
        [string]$FullSerial,
        [System.Security.Cryptography.HMACSHA256]$Hmac,
        [int]$BytesNeeded,
        [int]$SignatureLength
    )

    # Expect format "BASE-SIGN" where SIGN is SignatureLength characters
    $lastHyphenIndex = $FullSerial.LastIndexOf('-')

    # Validate format: must have hyphen and characters after it
    if ($lastHyphenIndex -eq -1 -or $lastHyphenIndex -eq $FullSerial.Length - 1) {
        Write-Verbose "Invalid FullSerial format: no signature part found"
        return $false
    }

    # Extract base part (everything before last hyphen)
    $serialToHash = $FullSerial.Substring(0, $lastHyphenIndex)
    
    # Extract provided signature (everything after last hyphen)
    $providedSignature = $FullSerial.Substring($lastHyphenIndex + 1)

    # Validate signature length
    if ($providedSignature.Length -ne $SignatureLength) {
        Write-Verbose "Provided signature has incorrect length. Expected: $SignatureLength, Got: $($providedSignature.Length)"
        return $false
    }

    Write-Verbose "Validating base: '$serialToHash' against signature: '$providedSignature'"

    # Calculate expected signature
    $hashBytes = $Hmac.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($serialToHash))
    $signatureBytes = $hashBytes[0..($BytesNeeded - 1)]
    $calculatedSignature = ($signatureBytes | ForEach-Object { $_.ToString("X2") }) -join ""
    
    # Trim if we have more characters than needed
    if ($calculatedSignature.Length -gt $SignatureLength) {
        $calculatedSignature = $calculatedSignature.Substring(0, $SignatureLength)
    }

    # Compare (case-sensitive since we're using uppercase hex)
    return $calculatedSignature -ceq $providedSignature
}
#endregion