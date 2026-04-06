<#
.SYNOPSIS
    Moves the mouse cursor randomly between 1 and 10 pixels to keep the system active.

.DESCRIPTION
    The 'Move-MousePointer' function uses Win32 API calls to simulate periodic mouse movements.
    Moves the cursor right and left every 10 seconds to prevent screen lock/sleep mode.
    Supports optional stealth mode for silent operation without console output.
    Includes -Install parameter to register the function in the PowerShell profile for auto-loading.

.PARAMETER StealthMode
    Suppresses console output messages when enabled.

.PARAMETER Install
    Installs the module into the PowerShell profile for automatic loading.
    Creates Microsoft.PowerShell_profile.ps1 if it doesn't exist (idempotent).

.AUTHOR
    Gill Bates.

.LICENSE
    This script is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability,
    fitness for a particular purpose, and noninfringement. In no event shall the authors or copyright holders be liable for any claim, damages, or other liability,
    whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the script or the use or other dealings in the script.

.COPYRIGHT 
    (c) 2026 Gill Bates. All rights reserved.

.EXAMPLE
    Move-MousePointer
    Move-MousePointer -StealthMode
    Move-MousePointer -Install

#>

# Cached P/Invoke type for better performance
$Script:MouseTypeDefined = $false

function Initialize-MouseType {
    if ($Script:MouseTypeDefined) { return }
    
    try {
        Add-Type -TypeDefinition @"
        using System;
        using System.Runtime.InteropServices;
        public class MousePointerUtil {
            [DllImport("user32.dll", CharSet=CharSet.Auto, CallingConvention=CallingConvention.StdCall, SetLastError=true)]
            public static extern void mouse_event(long dwFlags, long dx, long dy, long cButtons, long dwExtraInfo);
            private const int MOUSEEVENTF_MOVE = 0x0001;

            public static void MoveMouse(int dx, int dy) {
                mouse_event(MOUSEEVENTF_MOVE, dx, dy, 0, 0);
            }
        }
"@ -ErrorAction Stop
        $Script:MouseTypeDefined = $true
    }
    catch {
        Write-Error "Failed to initialize Mouse type: $_"
        throw
    }
}

function Install-MousePointerModule {
    <#
    .SYNOPSIS
        Idempotently installs the Move-MousePointer function into the PowerShell profile.
    #>
    
    $profilePath = $PROFILE
    $profileDir = Split-Path -Parent $profilePath
    
    # Ensure profile directory exists
    if (-not (Test-Path $profileDir)) {
        try {
            New-Item -ItemType Directory -Path $profileDir -Force | Out-Null
            Write-Host "Created profile directory: $profileDir" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to create profile directory: $_"
            return $false
        }
    }
    
    # Import statement to add to profile
    $importStatement = "Import-Module '$PSScriptRoot\Move-MousePointer.ps1' -Force"
    
    # Check if profile exists
    if (Test-Path $profilePath) {
        # Check if import already exists (idempotent)
        $profileContent = Get-Content $profilePath -Raw
        if ($profileContent -like "*Move-MousePointer*") {
            Write-Host "Move-MousePointer is already installed in profile." -ForegroundColor Cyan
            return $true
        }
        
        # Append import statement
        try {
            Add-Content -Path $profilePath -Value "`n# Load Move-MousePointer module`n$importStatement" -Encoding UTF8
            Write-Host "Updated profile: $profilePath" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to update profile: $_"
            return $false
        }
    }
    else {
        # Create new profile with import statement
        try {
            $profileTemplate = @"
# Microsoft PowerShell Profile
# Auto-loaded modules and functions

# Load Move-MousePointer module
$importStatement
"@
            Set-Content -Path $profilePath -Value $profileTemplate -Encoding UTF8 -Force
            Write-Host "Created profile: $profilePath" -ForegroundColor Green
        }
        catch {
            Write-Error "Failed to create profile: $_"
            return $false
        }
    }
    
    Write-Host "Installation completed. Profile will be loaded on next PowerShell session." -ForegroundColor Green
    return $true
}

function Move-MousePointer {
    [CmdletBinding()]
    param (
        [switch]$StealthMode,
        [switch]$Install
    )
    
    # Handle install mode
    if ($Install) {
        return Install-MousePointerModule
    }
    
    # Initialize P/Invoke type
    Initialize-MouseType
    
    Clear-Host
    
    if (-not $StealthMode) {
        Write-Host "MousePointer Motion Active" -ForegroundColor Cyan
        Write-Host "The pointer moves randomly by 1-10 pixels every 10 seconds."
        Write-Host "Script running since $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
    }

    Write-Host "Press 'CTRL + C' to stop the script." -ForegroundColor Yellow
    
    try {
        while ($true) {
            $moveDistance = Get-Random -Minimum 1 -Maximum 11
            
            try {
                [MousePointerUtil]::MoveMouse($moveDistance, 0)
                Start-Sleep -Seconds 10
                [MousePointerUtil]::MoveMouse(-$moveDistance, 0)
                Start-Sleep -Seconds 10
            }
            catch {
                Write-Error "Mouse operation failed: $_" -ErrorAction Continue
                Start-Sleep -Seconds 10
            }
        }
    }
    catch [System.OperationCanceledException] {
        if (-not $StealthMode) {
            Write-Host "`nScript stopped by user." -ForegroundColor Yellow
        }
    }
}