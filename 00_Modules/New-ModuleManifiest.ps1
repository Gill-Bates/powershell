$path = "C:\_Repos\Github\powershell\00_Modules\CustomLog"
$module = (Get-CHildItem $path | Where-Object { $_.Name -like "$($path.Split("\")[-1]).psm1" }).FullName -replace (".psm1", ".psd1")
New-ModuleManifest -Path $module