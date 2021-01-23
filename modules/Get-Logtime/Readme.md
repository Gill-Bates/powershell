# Create your own Powershell Module

You need two Files:

1. Your Powershell-Script, endig with .psm1
2. Your Manifest-File, endig with .psd1

**Make sure, that your Folder has exact the same Name like your .psm1-File**

## Import-Module
Will only import the Module during the Session

## Install-Module
Will install the Module permanent into the Modules-Folder

```powershell
New-ModuleManifest -Path '.\Get-Logtime.psd1' -Author 'Gill-Bates' -CompanyName 'Umbrella Inc.' -RootModule '.\Get-Logtime.psm1' -ModuleVersion 1.1
```