<#
    .SYNOPSIS
        Runs the Pester suite under Windows PowerShell 5.1 and PowerShell 7 (NFR-5) and
        returns one result row per host. Exit code 0 only when both hosts pass.

    .PARAMETER Path
        Test files or folders (default: this folder).

    .PARAMETER Host
        Which hosts to run (default both).

    .EXAMPLE
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Invoke-Tests.ps1
#>
[CmdletBinding()]
param
(
    [string[]]$Path = @($PSScriptRoot),

    [ValidateSet('5.1', '7')]
    [string[]]$PowerShellHost = @('5.1', '7'),

    [string]$TestName
)

$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'Invoke-PesterHost.ps1'
$executables = @{
    '5.1' = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    '7'   = (Get-Command -Name pwsh -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty Source)
}

$failed = 0
foreach ($version in $PowerShellHost)
{
    $exe = $executables[$version]
    if (-not $exe) { Write-Warning ('PowerShell {0} not found' -f $version); $failed++; continue }
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $runner, '-Path', ($Path -join ';'))
    if ($TestName) { $arguments += @('-TestName', $TestName) }
    & $exe @arguments
    if ($LASTEXITCODE -ne 0) { $failed++ }
}
exit $failed
