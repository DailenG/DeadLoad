<#
    .SYNOPSIS
        Runs Pester 5+ in the current host. Called by Invoke-Tests.ps1 once per host.
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory)] [string]$Path,
    [string]$TestName
)

$ErrorActionPreference = 'Stop'
$pester = Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]'5.0' } | Sort-Object -Property Version -Descending | Select-Object -First 1
if (-not $pester) { throw 'Pester 5 or later is required.' }
Import-Module $pester.Path -Force

$configuration = New-PesterConfiguration
$configuration.Run.Path = @($Path -split ';')
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Normal'
if ($TestName) { $configuration.Filter.FullName = @('*' + $TestName + '*') }

$result = Invoke-Pester -Configuration $configuration
'PowerShell {0}, Pester {1}: {2} passed, {3} failed, {4} skipped' -f $PSVersionTable.PSVersion, $pester.Version, $result.PassedCount, $result.FailedCount, $result.SkippedCount
if ($result.FailedCount -gt 0 -or $result.Result -ne 'Passed') { exit 1 }
exit 0
