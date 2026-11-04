<#
    .SYNOPSIS
        Chocolatey install and upgrade script for DeadLoad (FR-21, FR-23).

    .DESCRIPTION
        Runs elevated under Windows PowerShell 5.1 through choco. Every step is idempotent: an
        upgrade re-runs this same script. Package parameters:
            /NoTray              do not start the tray at sign-in (removes the Run value on upgrade)
            /ReportOnly          set HKLM\SOFTWARE\DeadLoad ReportOnly = 1 (plan and report, delete nothing)
            /InstallAdmxLocally  copy the ADMX/ADML into %SystemRoot%\PolicyDefinitions
            /PurgeData           uninstall only; ignored here
        Never touches %ProgramData%\DeadLoad content or HKLM\SOFTWARE\Policies\DeadLoad.
#>

$ErrorActionPreference = 'Stop'
$toolsDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
Import-Module (Join-Path $toolsDir 'DeadLoad.Install.psm1') -Force

# A 32-bit host on 64-bit Windows would write the WOW6432Node registry view and the x86
# Program Files folder, where neither the engine nor the tasks look.
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess)
{
    throw 'DeadLoad must be installed from a 64-bit PowerShell host on 64-bit Windows.'
}

$packageParameters = @{}
if (Get-Command -Name Get-PackageParameters -ErrorAction SilentlyContinue) { $packageParameters = Get-PackageParameters }
$options = Get-DLPackageOptions -Parameters $packageParameters
if ($options.PurgeData) { Write-Host '/PurgeData applies to uninstall only; ignored.' }

$payload = Join-Path $toolsDir 'payload'
$installDir = Join-Path $env:ProgramFiles 'DeadLoad'
$dataDir = Join-Path $env:ProgramData 'DeadLoad'
$manifest = Join-Path $payload 'engine\DeadLoad\DeadLoad.psd1'
$version = [string](Get-DLManifestData -Path $manifest).ModuleVersion

# 1. Retire the legacy Get-FreeSpace product first, so its tasks cannot run against a
#    half-installed DeadLoad.
foreach ($entry in @(Find-DLLegacyInstall))
{
    Write-Host ('Removing legacy {0} {1} ({2})' -f $entry.DisplayName, $entry.DisplayVersion, $entry.ProductCode)
    $msiLog = Join-Path $env:TEMP 'DeadLoad-legacy-msi-uninstall.log'
    $result = Uninstall-DLLegacyMsi -ProductCode $entry.ProductCode -LogPath $msiLog -Confirm:$false
    Write-Host ('Legacy MSI: {0} (log {1})' -f $result, $msiLog)
    break
}
$legacyFolders = @(Join-Path $env:ProgramFiles 'Get-FreeSpace')
if (${env:ProgramFiles(x86)}) { $legacyFolders += Join-Path ${env:ProgramFiles(x86)} 'Get-FreeSpace' }
foreach ($folder in $legacyFolders)
{
    $result = Remove-DLLegacyFolder -Path $folder -Confirm:$false
    if ($result -ne 'Absent') { Write-Host ('Legacy folder {0}: {1}' -f $folder, $result) }
}
$legacyTasks = @(Get-DLLegacyTask)
if ($legacyTasks.Count -gt 0)
{
    foreach ($removed in @(Remove-DLLegacyTask -Task $legacyTasks -Confirm:$false)) { Write-Host ('Legacy task removed: {0}' -f $removed) }
}
# The product is gone; drop Chocolatey's record of a package that installed it, or choco upgrade
# all would put it back beside DeadLoad.
foreach ($package in @(Find-DLLegacyChocolateyPackage))
{
    $result = Remove-DLLegacyChocolateyPackage -Id $package.Id -Confirm:$false
    Write-Host ('Legacy Chocolatey package {0} {1} (matched by {2}): {3}' -f $package.Id, $package.Version, $package.MatchedBy, $result)
}

# 2. Program files: engine, tray, policy swapped in folder by folder.
foreach ($row in @(Install-DLPayload -Source $payload -Destination $installDir -Confirm:$false))
{
    Write-Host ('{0}: {1}' -f $row.Folder, $row.Mode)
}

# 3. Data folder with the protected ACL (re-applied on every upgrade; content is kept).
Set-DLDataAcl -Path $dataDir -Confirm:$false

# 4. Event source for the monitoring contract (Application log, source DeadLoad).
Write-Host ('Event source DeadLoad: {0}' -f (Register-DLEventSource -Confirm:$false))

# 5. Local registry values the engine and support read.
Set-DLLocalRegistry -Version $version -InstallPath $installDir -ReportOnly:$options.ReportOnly -Confirm:$false
if ($options.ReportOnly) { Write-Host 'ReportOnly = 1 set in HKLM\SOFTWARE\DeadLoad.' }

# 6. Tray at sign-in. A running tray is never stopped: it keeps the old image until the
#    user signs in again.
$trayExe = Join-Path $installDir 'tray\DeadLoadTray.exe'
if ($options.NoTray)
{
    Write-Host ('Tray Run value: {0}' -f (Remove-DLTrayRunKey -Confirm:$false))
}
elseif (Test-Path -LiteralPath $trayExe)
{
    Set-DLTrayRunKey -ExePath $trayExe -Confirm:$false
}
else
{
    Write-Warning ('{0} is not in this package; the tray is not started at sign-in.' -f $trayExe)
}

# 7. Optional local policy templates (domains normally use the central store).
if ($options.InstallAdmxLocally)
{
    foreach ($file in @(Install-DLAdmx -Source (Join-Path $installDir 'policy') -Confirm:$false)) { Write-Host ('Policy template: {0}' -f $file) }
}

# 8. Scheduled tasks, created or replaced by the engine itself.
Import-Module (Join-Path $installDir 'engine\DeadLoad\DeadLoad.psd1') -Force
foreach ($row in @(Sync-DeadLoadSchedule -Register -InstallPath $installDir -Confirm:$false))
{
    Write-Host ('Task {0}: {1}' -f $row.Name, $row.Action)
}

Write-Host ('DeadLoad {0} installed in {1}.' -f $version, $installDir)
