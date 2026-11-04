function New-DLRunContext
{
    <#
        .SYNOPSIS
            The state of one run: configuration, clock, budgets, counters, skips, failures,
            decision log, and the profile alias map used to keep user names out of reports.
    #>
    param
    (
        [Parameter(Mandatory)] [hashtable]$Configuration,
        [Parameter(Mandatory)] [string]$Mode,
        [Parameter(Mandatory)] [string]$DataRoot,
        [bool]$ReportOnly,
        [bool]$WhatIf
    )

    $now = Get-DLUtcNow
    $runId = '{0}-{1}' -f $now.ToString('yyyyMMddTHHmmssZ'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
    $logDirectory = Join-Path $DataRoot 'logs'

    return @{
        RunId          = $runId
        Mode           = $Mode
        Config         = $Configuration
        DataRoot       = $DataRoot
        LogPath        = (Join-Path $logDirectory ('deadload-{0}.log' -f $now.ToString('yyyyMMdd')))
        LogLines       = (New-Object 'System.Collections.Generic.List[string]')
        StartTime      = $now
        Deadline       = $now.AddMinutes([double]$Configuration.General.TimeBudgetMinutes)
        ReportOnly     = $ReportOnly
        WhatIf         = $WhatIf
        Skips          = (New-Object 'System.Collections.Generic.List[object]')
        SkipCounts     = @{}
        Failures       = (New-Object 'System.Collections.Generic.List[object]')
        Events         = (New-Object 'System.Collections.Generic.List[object]')
        Aliases        = (New-Object 'System.Collections.Generic.List[object]')
        Categories     = [ordered]@{}
        Budget         = @{ TimeExhausted = $false; BytesExhausted = $false; ItemsExhausted = $false }
        ActedCount     = 0
        ActedBytes     = [int64]0
        Totals         = [ordered]@{
            ScannedCount = 0; ScannedBytes = [int64]0; ProtectedCount = 0; CandidateCount = 0
            CandidateBytes = [int64]0; DeletedCount = 0; CompressedCount = 0; CopiedCount = 0
            MovedCount = 0; FreedBytes = [int64]0; SkippedCount = 0; FailedCount = 0
        }
        AccessFallbackLogged = $false
    }
}

function Register-DLProfileAlias
{
    # P1, P2, ... in ProfileList order; reports and logs show the alias, never the folder.
    param ([hashtable]$Run, [pscustomobject]$UserProfile)

    foreach ($entry in $Run.Aliases)
    {
        if ($entry.Sid -eq $UserProfile.Sid) { return $entry.Alias }
    }
    $alias = 'P{0}' -f ($Run.Aliases.Count + 1)
    $Run.Aliases.Add([pscustomobject]@{ Alias = $alias; Sid = $UserProfile.Sid; Path = (ConvertTo-DLFullPath -Path $UserProfile.Path) })
    return $alias
}

function ConvertTo-DLReportPath
{
    # Replaces a profile folder prefix with {P<n>} so a report path carries no user name.
    param ([hashtable]$Run, [string]$Path)

    if (-not $Path) { return $Path }
    foreach ($entry in $Run.Aliases)
    {
        if (Test-DLPathUnder -Path $Path -Parent $entry.Path)
        {
            return ('{' + $entry.Alias + '}') + (ConvertTo-DLFullPath -Path $Path).Substring($entry.Path.Length)
        }
    }
    return $Path
}

function Write-DLLog
{
    param ([hashtable]$Run, [string]$Message)

    $line = '{0} {1}' -f (Get-DLUtcNow).ToString('yyyy-MM-ddTHH:mm:ss.fffZ'), $Message
    $Run.LogLines.Add($line)
    Write-Verbose $Message
}

function Write-DLDecision
{
    <#
        .SYNOPSIS
            FR-7: one line per item decision, naming the rule that caused it.
    #>
    param
    (
        [hashtable]$Run,
        [string]$Category,
        [string]$Decision,
        [string]$Rule,
        [string]$Path,
        [string]$Detail
    )

    $message = 'DECISION {0} {1} rule={2} path={3}' -f $Category, $Decision, $Rule, (ConvertTo-DLReportPath -Run $Run -Path $Path)
    if ($Detail) { $message += ' ' + $Detail }
    Write-DLLog -Run $Run -Message $message
}

function Add-DLSkip
{
    param ([hashtable]$Run, [string]$Path, [string]$Category, [string]$Reason, [string]$Detail)

    $Run.Totals.SkippedCount++
    if (-not $Run.SkipCounts.ContainsKey($Reason)) { $Run.SkipCounts[$Reason] = 0 }
    $Run.SkipCounts[$Reason]++
    if ($Run.Categories.Contains($Category)) { $Run.Categories[$Category].SkippedCount++ }
    $reportPath = ConvertTo-DLReportPath -Run $Run -Path $Path
    if ($Run.Skips.Count -lt 200)
    {
        $Run.Skips.Add([pscustomobject][ordered]@{ Path = $reportPath; Category = $Category; Reason = $Reason; Detail = $Detail })
    }
    Write-DLLog -Run $Run -Message ('SKIP {0} reason={1} path={2} {3}' -f $Category, $Reason, $reportPath, $Detail)
}

function Add-DLFailure
{
    param ([hashtable]$Run, [string]$Path, [string]$Category, [string]$Message)

    $Run.Totals.FailedCount++
    if ($Run.Categories.Contains($Category)) { $Run.Categories[$Category].FailedCount++ }
    $reportPath = ConvertTo-DLReportPath -Run $Run -Path $Path
    if ($Run.Failures.Count -lt 200)
    {
        $Run.Failures.Add([pscustomobject][ordered]@{ Path = $reportPath; Category = $Category; Message = $Message })
    }
    Write-DLLog -Run $Run -Message ('FAIL {0} path={1} {2}' -f $Category, $reportPath, $Message)
}

function Test-DLBudget
{
    <#
        .SYNOPSIS
            SR-4: true while the run may act on another item of NextBytes; sets the flag of
            the budget that stops it. Checked between items, never mid-item.
    #>
    [OutputType([bool])]
    param ([hashtable]$Run, [int64]$NextBytes = 0)

    $general = $Run.Config.General
    if ((Get-DLUtcNow) -ge $Run.Deadline)
    {
        $Run.Budget.TimeExhausted = $true
        return $false
    }
    if ([int]$general.MaxItemsPerRun -gt 0 -and $Run.ActedCount -ge [int]$general.MaxItemsPerRun)
    {
        $Run.Budget.ItemsExhausted = $true
        return $false
    }
    if ([int64]$general.MaxDeleteMBPerRun -gt 0 -and ($Run.ActedBytes + $NextBytes) -gt ([int64]$general.MaxDeleteMBPerRun * 1MB))
    {
        $Run.Budget.BytesExhausted = $true
        return $false
    }
    return $true
}

function Test-DLBudgetExhausted
{
    [OutputType([bool])]
    param ([hashtable]$Run)
    return ($Run.Budget.TimeExhausted -or $Run.Budget.BytesExhausted -or $Run.Budget.ItemsExhausted)
}
