<#
.SYNOPSIS
    This script moves the mouse cursor randomly between 1 and 10 pixels to the right and left every 10 seconds.

.DESCRIPTION
    The 'Move-MouseBackAndForth' function uses Win32 API calls to simulate mouse movements.
    The script starts the mouse movement and allows for stopping it using a control switch parameter.
    When invoked without the '-Stop' parameter, the function will alternately move the mouse cursor right and left.
    Use the '-Stop' parameter to terminate the movement.

.AUTHOR
    Gill Bates.

.LICENSE
    This script is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability,
    fitness for a particular purpose, and noninfringement. In no event shall the authors or copyright holders be liable for any claim, damages, or other liability,
    whether in an action of contract, tort, or otherwise, arising from, out of, or in connection with the script or the use or other dealings in the script.

.COPYRIGHT 
    (c) 2025 Gill Bates. All rights reserved.

#>

function Move-MousePointer {

    param (
        [switch]$StealthMode
    )

    Add-Type -TypeDefinition @"
    using System;
    using System.Runtime.InteropServices;
    public class Mouse {
        [DllImport("user32.dll", CharSet=CharSet.Auto, CallingConvention=CallingConvention.StdCall)]
        public static extern void mouse_event(long dwFlags, long dx, long dy, long cButtons, long dwExtraInfo);
        private const int MOUSEEVENTF_MOVE = 0x0001;

        public static void MoveMouse(int dx, int dy) {
            mouse_event(MOUSEEVENTF_MOVE, dx, dy, 0, 0);
        }
    }
"@

    Clear-Host

    if (!$StealthMode) {

        Write-Information "`nThe pointer moves randomly by a few pixels every 10 seconds." -InformationAction Continue
        Write-Information "Script running since '$(Get-Date)'" -InformationAction Continue  
    }

    Write-Information "`nPress 'CTRL + C' to Stop the Script ...`n" -InformationAction Continue  
    while ($true) {
        $moveDistance = Get-Random -Minimum 1 -Maximum 11
        [Mouse]::MoveMouse($moveDistance, 0)
        Start-Sleep -Seconds 10
        [Mouse]::MoveMouse(-$moveDistance, 0)
        Start-Sleep -Seconds 10
    }
}