<#
    .SYNOPSIS
        Builds the DeadLoad Chocolatey package: tray build, policy templates, stage, sign,
        verify, pack (ARCHITECTURE section 13, PRD FR-21 and FR-22).

    .DESCRIPTION
        1. Builds src\tray\DeadLoadTray.csproj with dotnet (skipped with -SkipTray).
        2. Generates the policy templates with build\New-DeadLoadAdmx.ps1 straight into the
           stage, so the package always matches the settings catalog and the repository's
           policy\ folder is never rewritten by a build (the committed copy is the fallback
           when the generator is absent).
        3. Stages <OutputPath>\stage: engine\DeadLoad (the module), engine\Start-DeadLoad.ps1,
           engine\Invoke-DeadLoadUserAction.ps1, tray\DeadLoadTray.exe (+ .config and any
           dll), policy\. With -StageOnly the build stops here.
        4. Assembles <OutputPath>\pack (a working copy of packaging\chocolatey with the stage
           as tools\payload) so the repository is never dirtied.
        5. Signs every .ps1, .psm1, .psd1, .exe and .dll in the package (payload AND the
           Chocolatey scripts, FR-22) with the TrustedSigning module when it is installed and
           configured, then verifies each one twice (Test-TrustedSigningSignature and
           Get-AuthenticodeSignature Status Valid, one signer subject for all); any mismatch
           fails the build. Otherwise, or with -NoSign, it says UNSIGNED development build.
           Signing credentials are read by the module from the environment only; this script
           never reads, prints or passes one.
        6. Runs choco pack into <OutputPath> when choco is on PATH.

        Returns one summary object: Version, Signed, FileCount, StagePath, Package, Missing.
        Runs under PowerShell 7; also under Windows PowerShell 5.1 where the tools allow.

    .PARAMETER Configuration
        dotnet build configuration for the tray (default Release).

    .PARAMETER OutputPath
        Build output folder (default <repo>\out, gitignored).

    .PARAMETER NoSign
        Skip signing even when the signing module is configured.

    .PARAMETER SkipTray
        Do not build or stage the tray (for machines without the .NET SDK, or before the tray
        project exists). The installer then leaves the tray out.

    .PARAMETER StageOnly
        Stop after staging: no signing, no package.

    .EXAMPLE
        pwsh -NoProfile -File build\Build.ps1 -NoSign -SkipTray -StageOnly
#>
[CmdletBinding()]
param
(
    [string]$Configuration = 'Release',
    [string]$OutputPath,
    [switch]$NoSign,
    [switch]$SkipTray,
    [switch]$StageOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
if (-not $OutputPath) { $OutputPath = Join-Path $repoRoot 'out' }
# Against the PowerShell location, not the process directory GetFullPath would use.
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$packagingRoot = Join-Path $repoRoot 'packaging\chocolatey'
$nuspecPath = Join-Path $packagingRoot 'deadload.nuspec'
$engineSource = Join-Path $repoRoot 'src\engine'
$trayProject = Join-Path $repoRoot 'src\tray\DeadLoadTray.csproj'
$admxGenerator = Join-Path $PSScriptRoot 'New-DeadLoadAdmx.ps1'
$stage = Join-Path $OutputPath 'stage'
$pack = Join-Path $OutputPath 'pack'
$trayBuild = Join-Path $OutputPath 'tray'
$signableExtensions = @('.ps1', '.psm1', '.psd1', '.exe', '.dll')

Import-Module (Join-Path $packagingRoot 'tools\DeadLoad.Install.psm1') -Force

function Get-DLBuildFiles
{
    # Files under a folder, by full path; the stage and pack are build output with no links.
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$Path)

    return @([System.IO.Directory]::GetFiles($Path, '*', [System.IO.SearchOption]::AllDirectories) | Sort-Object)
}

function Reset-DLBuildFolder
{
    # Build output folders are recreated from scratch so nothing stale reaches a package.
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$Path)

    [void](Remove-DLProductTree -Path $Path -Confirm:$false)
    [void][System.IO.Directory]::CreateDirectory($Path)
}

# Version: the package version is the engine version, and the nuspec must already say so
# (a silent rewrite here would let the committed nuspec drift).
$version = [string](Get-DLManifestData -Path (Join-Path $engineSource 'DeadLoad\DeadLoad.psd1')).ModuleVersion
[xml]$nuspec = [System.IO.File]::ReadAllText($nuspecPath)
$nuspecVersion = [string]$nuspec.package.metadata.version
if ($nuspecVersion -ne $version)
{
    throw ('deadload.nuspec version {0} does not match the engine ModuleVersion {1}.' -f $nuspecVersion, $version)
}
Write-Host ('DeadLoad {0}' -f $version)

$missing = New-Object 'System.Collections.Generic.List[string]'

# 1. Tray.
$trayFiles = @()
if ($SkipTray)
{
    Write-Host 'Tray: skipped (-SkipTray).'
}
else
{
    if (-not (Test-Path -LiteralPath $trayProject)) { throw ('{0} not found. Use -SkipTray to build without the tray.' -f $trayProject) }
    $dotnet = Get-Command -Name dotnet -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dotnet) { throw 'dotnet is not on PATH. Install the .NET SDK or use -SkipTray.' }
    Reset-DLBuildFolder -Path $trayBuild
    & $dotnet.Source build $trayProject -c $Configuration -o $trayBuild --nologo
    if ($LASTEXITCODE -ne 0) { throw ('dotnet build failed with exit code {0}.' -f $LASTEXITCODE) }
    $trayExe = Join-Path $trayBuild 'DeadLoadTray.exe'
    if (-not (Test-Path -LiteralPath $trayExe)) { throw ('dotnet build produced no {0}.' -f $trayExe) }
    # The exe, its .config and any dependency; never pdb or xml documentation.
    $trayFiles = @((New-Object System.IO.DirectoryInfo $trayBuild).GetFiles() | Where-Object { $_.Name -like '*.exe' -or $_.Name -like '*.exe.config' -or $_.Name -like '*.dll' })
}

# 2 and 3. Stage.
Reset-DLBuildFolder -Path $stage
$stageEngine = Join-Path $stage 'engine'
Copy-DLTree -Source (Join-Path $engineSource 'DeadLoad') -Destination (Join-Path $stageEngine 'DeadLoad')
foreach ($script in 'Start-DeadLoad.ps1', 'Invoke-DeadLoadUserAction.ps1')
{
    $from = Join-Path $engineSource $script
    if (Test-Path -LiteralPath $from) { [System.IO.File]::Copy($from, (Join-Path $stageEngine $script), $true) }
    else
    {
        Write-Warning ('{0} does not exist yet; it is not in the stage.' -f $from)
        $missing.Add(('engine\{0}' -f $script))
    }
}

if ($trayFiles.Count -gt 0)
{
    $stageTray = Join-Path $stage 'tray'
    [void][System.IO.Directory]::CreateDirectory($stageTray)
    foreach ($file in $trayFiles) { [System.IO.File]::Copy($file.FullName, (Join-Path $stageTray $file.Name), $true) }
}

$stagePolicy = Join-Path $stage 'policy'
if (Test-Path -LiteralPath $admxGenerator)
{
    [void](& $admxGenerator -OutputPath $stagePolicy)
}
elseif (Test-Path -LiteralPath (Join-Path $repoRoot 'policy\DeadLoad.admx'))
{
    Write-Warning ('{0} not found; staging the committed policy templates.' -f $admxGenerator)
    Copy-DLTree -Source (Join-Path $repoRoot 'policy') -Destination $stagePolicy
}
else
{
    Write-Warning 'No policy templates: neither the generator nor policy\DeadLoad.admx exists.'
    $missing.Add('policy\DeadLoad.admx')
}

$stagedFiles = @(Get-DLBuildFiles -Path $stage)
Write-Host ('Staged {0} files in {1}:' -f $stagedFiles.Count, $stage)
foreach ($file in $stagedFiles) { Write-Host ('  {0}' -f $file.Substring($stage.Length + 1)) }

if ($StageOnly)
{
    Write-Host 'Stopped after staging (-StageOnly): not signed, not packed.'
    return [pscustomobject]@{ Version = $version; Signed = $false; FileCount = $stagedFiles.Count; StagePath = $stage; Package = $null; Missing = @($missing) }
}

# 4. Package working copy: the nuspec, the Chocolatey scripts and the stage as tools\payload.
Reset-DLBuildFolder -Path $pack
[System.IO.File]::Copy($nuspecPath, (Join-Path $pack 'deadload.nuspec'), $true)
Copy-DLTree -Source (Join-Path $packagingRoot 'tools') -Destination (Join-Path $pack 'tools')
$payload = Join-Path $pack 'tools\payload'
Copy-DLTree -Source $stage -Destination $payload
# Chocolatey shims every exe in a package onto PATH unless a <name>.exe.ignore sits beside it;
# the tray must not be on PATH. The installer skips these markers.
foreach ($exe in @(Get-DLBuildFiles -Path $payload | Where-Object { $_ -like '*.exe' }))
{
    [System.IO.File]::WriteAllText(($exe + '.ignore'), '')
}

# 5. Sign and verify.
$signed = $false
$signable = @(Get-DLBuildFiles -Path (Join-Path $pack 'tools') | Where-Object { $signableExtensions -contains [System.IO.Path]::GetExtension($_).ToLowerInvariant() })
$signingReady = $false
if ($NoSign)
{
    Write-Host 'Signing: skipped (-NoSign).'
}
else
{
    $signingModule = $null
    try { $signingModule = Import-Module -Name TrustedSigning -PassThru -ErrorAction Stop }
    catch { Write-Host ('Signing: the TrustedSigning module is not available ({0}).' -f $_.Exception.Message) }
    if ($signingModule)
    {
        # Returns the NAMES of missing environment variables, never a value, as ONE array
        # (return , $missing): enumerating it first makes an empty array count as zero.
        $notConfigured = @(Test-TrustedSigningConfiguration | ForEach-Object { $_ } | Where-Object { $_ })
        if ($notConfigured.Count -eq 0) { $signingReady = $true }
        else { Write-Host ('Signing: not configured; missing {0}.' -f ($notConfigured -join ', ')) }
    }
}

if ($signingReady)
{
    Write-Host ('Signing {0} files.' -f $signable.Count)
    foreach ($file in $signable) { [void](Invoke-TrustedSigning -Path $file) }

    $subjects = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::Ordinal)
    $failures = New-Object 'System.Collections.Generic.List[string]'
    foreach ($file in $signable)
    {
        try { [void]$subjects.Add([string](Test-TrustedSigningSignature -Path $file)) }
        catch { $failures.Add(('{0}: {1}' -f $file, $_.Exception.Message)); continue }
        $signature = Get-AuthenticodeSignature -FilePath $file
        if ($signature.Status -ne 'Valid') { $failures.Add(('{0}: Get-AuthenticodeSignature {1}' -f $file, $signature.Status)) }
        else { [void]$subjects.Add([string]$signature.SignerCertificate.Subject) }
    }
    if ($subjects.Count -gt 1) { $failures.Add(('More than one signer subject: {0}' -f (@($subjects) -join ' | '))) }
    if ($failures.Count -gt 0) { throw ("Signature verification failed:`n  " + ($failures -join "`n  ")) }
    $signed = $true
    Write-Host ('Signed and verified {0} files; signer {1}.' -f $signable.Count, (@($subjects) -join ''))
}
else
{
    Write-Warning 'UNSIGNED development build: not for deployment (FR-22 requires every script and binary signed; AllSigned refuses it).'
}

# 6. Pack.
$packageFile = $null
$choco = Get-Command -Name choco -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($choco)
{
    & $choco.Source pack (Join-Path $pack 'deadload.nuspec') --outputdirectory $OutputPath --limit-output
    if ($LASTEXITCODE -ne 0) { throw ('choco pack failed with exit code {0}.' -f $LASTEXITCODE) }
    $packageFile = Join-Path $OutputPath ('deadload.{0}.nupkg' -f $version)
    if (-not (Test-Path -LiteralPath $packageFile)) { throw ('choco pack reported success but {0} is missing.' -f $packageFile) }
}
else
{
    Write-Warning ('choco is not on PATH; the package folder is ready at {0} but no .nupkg was made.' -f $pack)
}

$packFiles = @(Get-DLBuildFiles -Path $pack)
Write-Host ('Summary: version {0}; signed {1}; {2} files; package {3}' -f $version, $(if ($signed) { 'yes' } else { 'no' }), $packFiles.Count, $(if ($packageFile) { $packageFile } else { '(none)' }))
if ($missing.Count -gt 0) { Write-Host ('Missing from this build: {0}' -f ($missing -join ', ')) }

[pscustomobject]@{ Version = $version; Signed = $signed; FileCount = $packFiles.Count; StagePath = $stage; Package = $packageFile; Missing = @($missing) }
