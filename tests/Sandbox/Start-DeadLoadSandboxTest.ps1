<#
    .SYNOPSIS
        Runs the phase 3 install acceptance (docs/OPERATIONS.md section 9) in Windows Sandbox.

    .DESCRIPTION
        On the host: builds an upgrade package one patch version above the current one from a
        temporary git worktree of HEAD (the repository is not modified), copies both packages,
        the local Chocolatey package and the in-sandbox scripts to out\sandbox\<stamp>\in, writes
        a .wsb that maps it read-only and maps out\sandbox\<stamp>\out writable, and opens the
        sandbox. Inside, Invoke-DeadLoadSandboxAcceptance.ps1 runs at logon and writes
        results.json, summary.txt and DONE to the out folder. Closing the sandbox discards it.

    .PARAMETER Package
        The package to install first. Default: out\deadload.<ModuleVersion>.nupkg.

    .PARAMETER NoSign
        Build the upgrade package unsigned (the AllSigned and signature checks then fail).

    .PARAMETER NoLaunch
        Prepare the run folder and .wsb only.
#>
[CmdletBinding()]
param
(
    [string]$Package,
    [switch]$NoSign,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$manifest = Join-Path $repo 'src\engine\DeadLoad\DeadLoad.psd1'
$version = [version](Test-ModuleManifest -Path $manifest).Version
$upgrade = '{0}.{1}.{2}' -f $version.Major, $version.Minor, ($version.Build + 1)
if (-not $Package) { $Package = Join-Path $repo ('out\deadload.{0}.nupkg' -f $version) }
if (-not (Test-Path -LiteralPath $Package)) { throw ('Package {0} not found; run build\Build.ps1 first.' -f $Package) }
$chocolatey = Join-Path $env:ProgramData 'chocolatey\lib\chocolatey\chocolatey.nupkg'
if (-not (Test-Path -LiteralPath $chocolatey)) { throw ('{0} not found: Chocolatey must be installed on the host.' -f $chocolatey) }
$sandbox = Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'
if (-not $NoLaunch -and -not (Test-Path -LiteralPath $sandbox)) { throw 'Windows Sandbox is not enabled on this machine.' }

$run = Join-Path $repo ('out\sandbox\{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$in = Join-Path $run 'in'
$out = Join-Path $run 'out'
New-Item -ItemType Directory -Path $in, $out -Force | Out-Null

# Upgrade package: HEAD in a detached worktree, version bumped in the two places Build.ps1
# requires to match, built straight into the run folder.
$worktree = Join-Path ([IO.Path]::GetTempPath()) ('deadload-upgrade-{0}' -f [guid]::NewGuid().ToString('N').Substring(0, 8))
& git -C $repo worktree add --detach $worktree HEAD
if ($LASTEXITCODE -ne 0) { throw 'git worktree add failed.' }
try
{
    $files = @(
        @{ Path = Join-Path $worktree 'src\engine\DeadLoad\DeadLoad.psd1'; Pattern = "(ModuleVersion\s*=\s*')[^']+(')" }
        @{ Path = Join-Path $worktree 'packaging\chocolatey\deadload.nuspec'; Pattern = '(<version>)[^<]+(</version>)' }
    )
    foreach ($file in $files)
    {
        $text = [IO.File]::ReadAllText($file.Path)
        $bumped = [regex]::Replace($text, $file.Pattern, ('${1}' + $upgrade + '${2}'))
        if ($bumped -eq $text) { throw ('Version not found in {0}.' -f $file.Path) }
        [IO.File]::WriteAllText($file.Path, $bumped, (New-Object Text.UTF8Encoding($false)))
    }
    $build = @{ OutputPath = (Join-Path $run 'build') }
    if ($NoSign) { $build['NoSign'] = $true }
    $summary = & (Join-Path $worktree 'build\Build.ps1') @build | Select-Object -Last 1
    if (-not $summary.Package) { throw 'The upgrade build made no package.' }
    Copy-Item -LiteralPath $summary.Package -Destination $in
}
finally
{
    & git -C $repo worktree remove --force $worktree
}

Copy-Item -LiteralPath $Package -Destination $in
Copy-Item -LiteralPath $chocolatey -Destination (Join-Path $in 'chocolatey.nupkg')
foreach ($name in 'Invoke-DeadLoadSandboxAcceptance.ps1', 'Invoke-DeadLoadSandboxStandardUser.ps1')
{
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $in
}

$command = 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File C:\DeadLoadTest\in\Invoke-DeadLoadSandboxAcceptance.ps1 -InstallVersion {0} -UpgradeVersion {1}' -f $version, $upgrade
$wsb = @"
<Configuration>
  <MemoryInMB>4096</MemoryInMB>
  <MappedFolders>
    <MappedFolder><HostFolder>$in</HostFolder><SandboxFolder>C:\DeadLoadTest\in</SandboxFolder><ReadOnly>true</ReadOnly></MappedFolder>
    <MappedFolder><HostFolder>$out</HostFolder><SandboxFolder>C:\DeadLoadTest\out</SandboxFolder><ReadOnly>false</ReadOnly></MappedFolder>
  </MappedFolders>
  <LogonCommand><Command>$command</Command></LogonCommand>
</Configuration>
"@
$wsbPath = Join-Path $run 'DeadLoad.wsb'
[IO.File]::WriteAllText($wsbPath, $wsb, (New-Object Text.UTF8Encoding($false)))

Write-Host ('Install {0}, upgrade {1}; run folder {2}' -f $version, $upgrade, $run)
if (-not $NoLaunch) { Start-Process -FilePath $sandbox -ArgumentList ('"{0}"' -f $wsbPath) }
[pscustomobject]@{ RunPath = $run; Results = $out; InstallVersion = [string]$version; UpgradeVersion = $upgrade; Wsb = $wsbPath }
