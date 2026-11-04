<#
    .SYNOPSIS
        Chocolatey uninstall script for DeadLoad (FR-21).

    .DESCRIPTION
        Removes the scheduled tasks, the tray Run value, the event source, the program folder
        and the package's local registry values. %ProgramData%\DeadLoad (reports, logs) and
        any other local settings stay unless /PurgeData is given. HKLM\SOFTWARE\Policies\DeadLoad
        belongs to Group Policy and is never touched.
#>

$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Import-Module (Join-Path $toolsDir 'DeadLoad.Install.psm1') -Force

$packageParameters = @{}
if (Get-Command -Name Get-PackageParameters -ErrorAction SilentlyContinue) { $packageParameters = Get-PackageParameters }
$options = Get-DLPackageOptions -Parameters $packageParameters

$installDir = Join-Path $env:ProgramFiles 'DeadLoad'
$dataDir = Join-Path $env:ProgramData 'DeadLoad'

# Tasks first, so no run starts while files are removed. The engine owns the task layout.
$engineManifest = Join-Path $installDir 'engine\DeadLoad\DeadLoad.psd1'
if (Test-Path -LiteralPath $engineManifest)
{
    Import-Module $engineManifest -Force
    foreach ($row in @(Sync-DeadLoadSchedule -Remove -Confirm:$false)) { Write-Host ('Task {0}: {1}' -f $row.Name, $row.Action) }
    Remove-Module -Name DeadLoad -Force -ErrorAction SilentlyContinue
}
else
{
    Write-Warning ('{0} not found; scheduled tasks in \DeadLoad\ were not removed.' -f $engineManifest)
}

Write-Host ('Tray Run value: {0}' -f (Remove-DLTrayRunKey -Confirm:$false))
Write-Host ('Event source DeadLoad: {0}' -f (Unregister-DLEventSource -Confirm:$false))

# A tray still running in a user session holds its exe open; it is never stopped (that would
# interrupt the user). The rest goes and the leftover is reported.
try
{
    if (Remove-DLProductTree -Path $installDir -Confirm:$false) { Write-Host ('Removed {0}' -f $installDir) }
}
catch
{
    Write-Warning ('{0} not fully removed ({1}). Remove it after the users sign out.' -f $installDir, $_.Exception.Message)
}

Write-Host ('HKLM\SOFTWARE\DeadLoad: {0}' -f (Remove-DLLocalRegistry -Purge:$options.PurgeData -Confirm:$false))

if ($options.PurgeData)
{
    if (Remove-DLProductTree -Path $dataDir -Confirm:$false) { Write-Host ('Removed {0}' -f $dataDir) }
}
else
{
    Write-Host ('{0} kept (reports and logs). Uninstall with /PurgeData to remove it.' -f $dataDir)
}
