<#
    .SYNOPSIS
        Scheduled task entry point: one DeadLoad run as SYSTEM.

    .DESCRIPTION
        Runs Invoke-DeadLoad in the given mode, then (Maintenance and PressureCheck) re-applies
        the task triggers from the effective schedule policy (D15). The output stream carries
        the run summary only; the exit code is what Task Scheduler records as the last result:
        0 Success, Skipped or Disabled; 2 Partial; 1 Failed.

    .PARAMETER Mode
        Maintenance (weekly), PressureCheck (daily and on low-disk events) or OnDemand (users
        may start it; runs the policy's OnDemandMode).

    .EXAMPLE
        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Program Files\DeadLoad\engine\Start-DeadLoad.ps1" -Mode Maintenance
#>
[CmdletBinding()]
param
(
    [ValidateSet('Maintenance', 'PressureCheck', 'OnDemand')]
    [string]$Mode = 'Maintenance'
)

$ErrorActionPreference = 'Stop'
$exitCode = 1
try
{
    Import-Module (Join-Path $PSScriptRoot 'DeadLoad\DeadLoad.psd1') -Force
    $summary = Invoke-DeadLoad -Mode $Mode
    switch ($summary.Result)
    {
        'Partial' { $exitCode = 2 }
        'Failed' { $exitCode = 1 }
        default { $exitCode = 0 }
    }

    if ($Mode -ne 'OnDemand')
    {
        try { Sync-DeadLoadSchedule | Out-Null }
        catch { Write-Warning ('Schedule not re-applied: {0}' -f $_.Exception.Message) }
    }
    $summary
}
catch
{
    Write-Error -ErrorRecord $_ -ErrorAction Continue
    $exitCode = 1
}
exit $exitCode
