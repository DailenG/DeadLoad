# Category definitions are hashtables whose optional fields are simply absent; strict mode
# would turn every absent field into an error, so the module runs without it.
Set-StrictMode -Off

$script:DLModuleRoot = $PSScriptRoot
$script:DLVersion = '0.0.0'
if ((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'DeadLoad.psd1') -Raw) -match "ModuleVersion\s*=\s*'([\d.]+)'") { $script:DLVersion = $Matches[1] }

foreach ($folder in 'Private', 'Public')
{
    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot $folder) -Filter '*.ps1' | Sort-Object -Property Name))
    {
        . $file.FullName
    }
}

Export-ModuleMember -Function @(
    'Invoke-DeadLoad'
    'Get-DeadLoadConfiguration'
    'Get-DeadLoadStatus'
    'Export-DeadLoadSupportBundle'
    'Sync-DeadLoadSchedule'
)
