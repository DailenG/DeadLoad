function Invoke-DeadLoadCleanup
{
    <#
        .SYNOPSIS
            Clean step of the user's cleanup review (D23): deletes only the reviewed items of the
            named categories that a fresh plan still selects. Writes last-cleanup.json beside the
            analysis and returns it.

        .DESCRIPTION
            The request is refused as a whole (Result Refused, nothing deleted) when the analysis
            is missing, unreadable or not the one named by -AnalysisId, or when a named category
            is not in it as available, or is now disabled, Restricted, machine-wide or not
            deleting. Otherwise one User run over the named categories deletes the intersection
            of the analysis items and the fresh plan through the engine's own deletion primitive;
            every reviewed item that was not deleted is reported with its reason. Shape:
            docs/design/ENGINE-UI-CONTRACT.md.

        .PARAMETER Category
            Category ids (a comma-separated single string is split, as powershell.exe -File
            passes it).

        .PARAMETER AnalysisPath
            The analysis to clean from (default: <DataRoot>\analysis.json).

        .PARAMETER AnalysisId
            When given, the analysis file must carry this id (the one the user reviewed).

        .PARAMETER Configuration
            Test seam: settings that override every source; registry is not read.

        .PARAMETER DataRoot
            Test seam: the user's data folder (default: the folder of -AnalysisPath, else
            %LOCALAPPDATA%\DeadLoad).

        .EXAMPLE
            Invoke-DeadLoadCleanup -Category user.temp, autodesk.cer
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('DeadLoad.Cleanup')]
    param
    (
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Category,

        [string]$AnalysisPath,

        [string]$AnalysisId,

        [hashtable]$Configuration,

        [string]$DataRoot,

        [switch]$NoEventLog
    )

    if (-not $DataRoot)
    {
        if ($AnalysisPath) { $DataRoot = Split-Path -Path $AnalysisPath -Parent }
        else { $DataRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DeadLoad' }
    }
    if (-not $AnalysisPath) { $AnalysisPath = Join-Path $DataRoot 'analysis.json' }
    $reportPath = Join-Path (Split-Path -Path $AnalysisPath -Parent) 'last-cleanup.json'

    $ids = New-Object 'System.Collections.Generic.List[string]'
    foreach ($value in $Category)
    {
        foreach ($part in ([string]$value -split ','))
        {
            $id = $part.Trim()
            if ($id -and -not $ids.Contains($id)) { $ids.Add($id) }
        }
    }

    $start = Get-DLUtcNow
    $report = [pscustomobject][ordered]@{
        schemaVersion  = 1
        product        = 'DeadLoad'
        version        = $script:DLVersion
        cleanupId      = $null
        analysisId     = $null
        startUtc       = $start.ToString('o')
        endUtc         = $null
        result         = 'Refused'
        reason         = $null
        categories     = $ids.ToArray()
        estimatedBytes = [int64]0
        freedBytes     = [int64]0
        deletedCount   = 0
        skippedCount   = 0
        failedCount    = 0
        volume         = $null
        deleted        = @()
        skipped        = @()
    }

    $finish = {
        $report.endUtc = (Get-DLUtcNow).ToString('o')
        # A refusal deleted nothing: last-cleanup.json keeps the last real cleanup.
        $written = $null
        if ($report.result -ne 'Refused')
        {
            Write-DLJsonFile -Path $reportPath -InputObject $report
            $written = $reportPath
        }
        $report | Add-Member -NotePropertyName Path -NotePropertyValue $written
        $report.PSObject.TypeNames.Insert(0, 'DeadLoad.Cleanup')
        return $report
    }

    # Refusals: nothing is deleted and the engine is not run.
    $analysis = $null
    if ($ids.Count -eq 0) { $report.reason = 'No category was named.' }
    elseif (-not [System.IO.File]::Exists($AnalysisPath)) { $report.reason = 'No analysis found; run Analyze first.' }
    else
    {
        try { $analysis = [System.IO.File]::ReadAllText($AnalysisPath) | ConvertFrom-Json }
        catch { $report.reason = 'The analysis could not be read; run Analyze again.' }
        if ($analysis -and ([int]$analysis.schemaVersion -ne 1 -or -not $analysis.analysisId)) { $report.reason = 'The analysis is not in a known format; run Analyze again.'; $analysis = $null }
        elseif ($analysis -and $AnalysisId -and [string]$analysis.analysisId -ne $AnalysisId) { $report.reason = 'The analysis changed since it was reviewed; run Analyze again.'; $analysis = $null }
    }
    if (-not $analysis)
    {
        if (-not $report.reason) { $report.reason = 'The analysis could not be read; run Analyze again.' }
        return (& $finish)
    }
    $report.analysisId = [string]$analysis.analysisId

    if ($Configuration) { $config = Get-DLConfiguration -Override $Configuration -NoRegistry }
    else { $config = Get-DLConfiguration }

    $byPath = @{}
    $reviewed = @{}
    foreach ($id in $ids)
    {
        $record = @($analysis.categories | Where-Object { $_.id -eq $id }) | Select-Object -First 1
        $refusal = $null
        if (-not $config.Categories.Contains($id)) { $refusal = 'not a category on this computer' }
        else
        {
            $entry = $config.Categories[$id]
            $refusal = Test-DLReviewCategory -Entry $entry
            if (-not $refusal -and [int]$entry.Settings.Enabled -ne 1) { $refusal = 'turned off' }
        }
        if (-not $refusal -and (-not $record -or -not $record.available)) { $refusal = 'not available in the analysis' }
        if ($refusal)
        {
            $report.reason = ('Category {0} cannot be cleaned here: {1}.' -f $id, $refusal)
            return (& $finish)
        }
        foreach ($item in @($record.items))
        {
            $report.estimatedBytes += [int64]$item.bytes
            $byPath[[string]$item.path] = [pscustomobject]@{ Category = $id; Item = $item }
            $reviewed[[string]$item.path] = [string]$item.fingerprint
            foreach ($file in @($item.files)) { if ($file) { $reviewed[[string]$file.path] = [string]$file.fingerprint } }
        }
    }

    if ($reviewed.Count -eq 0)
    {
        $report.result = 'Success'
        $report.reason = 'Nothing to clean in the selected categories.'
        return (& $finish)
    }

    $parameters = @{ Mode = 'User'; Category = $ids.ToArray(); IncludePlan = $true; ReviewedItem = $reviewed; DataRoot = $DataRoot }
    if ($Configuration) { $parameters.Configuration = $Configuration }
    if ($NoEventLog) { $parameters.NoEventLog = $true }
    $summary = @(Invoke-DeadLoad @parameters) | Select-Object -Last 1
    $report.cleanupId = [string]$summary.RunId
    $report.reason = $null
    if ($summary.Reason) { $report.reason = [string]$summary.Reason }
    if ($summary.Volume) { $report.volume = [pscustomobject][ordered]@{ drive = $summary.Volume.Drive; freeBytesBefore = [int64]$summary.Volume.FreeBytesBefore; freeBytesAfter = [int64]$summary.Volume.FreeBytesAfter } }
    $budget = ($summary.Budget -and ($summary.Budget.TimeExhausted -or $summary.Budget.BytesExhausted -or $summary.Budget.ItemsExhausted))
    $engineResult = [string]$summary.Result

    $fresh = @{}
    # Not $category: names are case-insensitive and $Category is the typed [string[]] parameter.
    if ($summary.PSObject.Properties['Plan']) { foreach ($planCategory in @($summary.Plan)) { foreach ($item in @($planCategory.Items)) { $fresh[$item.Path] = $item } } }

    $deleted = New-Object 'System.Collections.Generic.List[object]'
    $skipped = New-Object 'System.Collections.Generic.List[object]'
    foreach ($path in @($byPath.Keys | Sort-Object))
    {
        # A disabled engine scanned nothing; there is nothing to report per item.
        if ($engineResult -eq 'Disabled') { break }
        $reviewedItem = $byPath[$path]
        $bytes = [int64]$reviewedItem.Item.bytes
        $reason = $null
        $freed = [int64]0
        $item = $fresh[$path]
        if (-not $item)
        {
            $reason = 'Missing'
            if ($engineResult -eq 'Failed') { $reason = 'Failed' }
        }
        else
        {
            switch ([string]$item.Outcome)
            {
                'Acted' { $freed = [int64]$item.FreedBytes }
                'Partial' { $freed = [int64]$item.FreedBytes; $reason = [string]$item.OutcomeReason }
                'WhatIf' { $reason = 'ReportOnly' }
                'Budget' { $reason = 'Budget' }
                'Skipped' { $reason = [string]$item.OutcomeReason }
                'Failed' { $reason = 'Failed' }
                default
                {
                    if ($item.Selected) { if ($budget) { $reason = 'Budget' } else { $reason = 'NotSelected' } }
                    elseif ($item.ProtectReason) { $reason = [string]$item.ProtectReason }
                    else { $reason = 'NotSelected' }
                }
            }
            if ([string]$item.Outcome -in 'Partial', 'Skipped' -and -not $reason) { $reason = 'Changed' }
        }
        if ($freed -gt 0 -or ($item -and [string]$item.Outcome -eq 'Acted'))
        {
            $deleted.Add([pscustomobject][ordered]@{ category = $reviewedItem.Category; path = $path; kind = [string]$reviewedItem.Item.kind; bytes = $freed })
        }
        if ($reason)
        {
            if ($reason -eq 'Failed') { $report.failedCount++ }
            $skipped.Add([pscustomobject][ordered]@{ category = $reviewedItem.Category; path = $path; kind = [string]$reviewedItem.Item.kind; bytes = ($bytes - $freed); reason = $reason; reasonText = (Get-DLReasonText -Reason $reason) })
        }
    }

    $report.deleted = $deleted.ToArray()
    $report.skipped = $skipped.ToArray()
    $report.deletedCount = $deleted.Count
    $report.skippedCount = $skipped.Count
    foreach ($entry in $deleted) { $report.freedBytes += [int64]$entry.bytes }

    switch ([string]$summary.Result)
    {
        'Failed' { $report.result = 'Failed' }
        'Disabled' { $report.result = 'Disabled' }
        default
        {
            if ($summary.ReportOnly -or $summary.WhatIf) { $report.result = 'ReportOnly' }
            elseif ($skipped.Count -gt 0) { $report.result = 'Partial' }
            else { $report.result = 'Success' }
        }
    }
    return (& $finish)
}
