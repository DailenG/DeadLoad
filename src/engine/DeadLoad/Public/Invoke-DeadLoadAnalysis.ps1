function Invoke-DeadLoadAnalysis
{
    <#
        .SYNOPSIS
            Analyze step of the user's cleanup review (D22): a report-only User run over the
            current profile's reviewable categories. Writes analysis.json and returns it.

        .DESCRIPTION
            Every enabled category of the user's own profile is listed. Routine and Review
            categories that delete files are analyzed and carry their items (full path, size,
            write time, why selected); Routine ones are selected by default. Restricted,
            machine-wide and non-deleting categories are listed as not available, with the
            reason and no items. Nothing is changed on disk except the analysis file and the
            user's own run report. Shape: docs/design/ENGINE-UI-CONTRACT.md.

        .PARAMETER Path
            Where the analysis is written (default: <DataRoot>\analysis.json). Without -DataRoot,
            its folder also receives the user run's report and log.

        .PARAMETER Configuration
            Test seam: settings that override every source; registry is not read.

        .PARAMETER DataRoot
            Test seam: the user's data folder (default: the folder of -Path, else
            %LOCALAPPDATA%\DeadLoad).

        .EXAMPLE
            Invoke-DeadLoadAnalysis -Verbose
    #>
    [CmdletBinding()]
    [OutputType('DeadLoad.Analysis')]
    param
    (
        [string]$Path,

        [hashtable]$Configuration,

        [string]$DataRoot,

        [switch]$NoEventLog
    )

    if (-not $DataRoot)
    {
        if ($Path) { $DataRoot = Split-Path -Path $Path -Parent }
        else { $DataRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DeadLoad' }
    }
    if (-not $Path) { $Path = Join-Path $DataRoot 'analysis.json' }

    if ($Configuration) { $config = Get-DLConfiguration -Override $Configuration -NoRegistry }
    else { $config = Get-DLConfiguration }

    $records = New-Object 'System.Collections.Generic.List[object]'
    $ids = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in $config.Categories.Keys)
    {
        $entry = $config.Categories[$id]
        $definition = $entry.Definition
        if ($definition.Scope -ne 'User') { continue }
        if ([int]$entry.Settings.Enabled -ne 1) { continue }
        $risk = [string]$definition.Risk
        if ($risk -ne 'Routine' -and $risk -ne 'Review') { $risk = 'Restricted' }
        $refusal = Test-DLReviewCategory -Entry $entry
        $riskText = $null
        if ($config.RiskTiers) { $riskText = [string]$config.RiskTiers[$risk] }
        $record = [pscustomobject][ordered]@{
            id                = $id
            displayName       = $(if ($definition.DisplayName) { [string]$definition.DisplayName } else { $id })
            description       = [string]$definition.Description
            risk              = $risk
            riskText          = $riskText
            available         = (-not $refusal)
            unavailableReason = $refusal
            unavailableText   = $(if ($refusal) { Get-DLReasonText -Reason $refusal } else { $null })
            defaultSelected   = (-not $refusal -and $risk -eq 'Routine')
            ageDays           = $null
            ageBasis          = $null
            itemCount         = 0
            estimatedBytes    = [int64]0
            guardedSkipped    = $null
            items             = @()
        }
        $records.Add($record)
        if (-not $refusal) { $ids.Add($id) }
    }

    $summary = $null
    if ($ids.Count -gt 0)
    {
        $parameters = @{ Mode = 'User'; Category = $ids.ToArray(); ReportOnly = $true; IncludePlan = $true; DataRoot = $DataRoot }
        if ($Configuration) { $parameters.Configuration = $Configuration }
        if ($NoEventLog) { $parameters.NoEventLog = $true }
        $summary = @(Invoke-DeadLoad @parameters -WhatIf:$false) | Select-Object -Last 1
    }

    $result = 'Success'
    $reason = $null
    $analysisId = 'analysis-' + (Get-DLUtcNow).ToString('yyyyMMddTHHmmssZ')
    $created = (Get-DLUtcNow).ToString('o')
    $volume = $null
    if ($summary)
    {
        $analysisId = [string]$summary.RunId
        $created = [string]$summary.EndTime
        if ($summary.Reason) { $reason = [string]$summary.Reason }
        switch ([string]$summary.Result)
        {
            'Disabled' { $result = 'Disabled' }
            'Failed' { $result = 'Failed' }
            'Partial' { $result = 'Partial' }
            default { $result = 'Success' }
        }
        if ($summary.Volume) { $volume = [pscustomobject][ordered]@{ drive = $summary.Volume.Drive; sizeBytes = [int64]$summary.Volume.SizeBytes; freeBytes = [int64]$summary.Volume.FreeBytesBefore } }
    }
    elseif ([int]$config.General.Enabled -ne 1)
    {
        $result = 'Disabled'
        $reason = 'Engine disabled by configuration'
    }

    $plans = @{}
    if ($summary -and $summary.PSObject.Properties['Plan']) { foreach ($category in @($summary.Plan)) { $plans[$category.Id] = $category } }
    foreach ($record in $records)
    {
        if (-not $record.available -or -not $plans.ContainsKey($record.id) -or $result -eq 'Disabled') { continue }
        $category = $plans[$record.id]
        $record.ageDays = $category.AgeDays
        $record.ageBasis = $category.AgeBasis
        $items = New-Object 'System.Collections.Generic.List[object]'
        $guardedCount = 0
        $guardedBytes = [int64]0
        foreach ($item in @($category.Items | Sort-Object -Property Bytes -Descending))
        {
            if ($item.ProtectReason -eq 'Process')
            {
                $guardedCount++
                $guardedBytes += $item.Bytes
                continue
            }
            if (-not $item.Selected) { continue }
            $entry = [ordered]@{
                path         = $item.Path
                kind         = $item.Kind
                bytes        = [int64]$item.Bytes
                lastWriteUtc = $item.ModifiedUtc
                reason       = $item.Rule
                reasonText   = (Get-DLRuleText -Rule $item.Rule -Category $category)
                fingerprint  = $item.Fingerprint
            }
            if ($item.Kind -ne 'File')
            {
                $entry.fileCount = @($item.Files).Count
                $entry.files = @($item.Files | ForEach-Object { [pscustomobject][ordered]@{ path = $_.Path; bytes = [int64]$_.Bytes; fingerprint = $_.Fingerprint } })
            }
            $items.Add([pscustomobject]$entry)
            $record.estimatedBytes += [int64]$item.Bytes
        }
        $record.items = $items.ToArray()
        $record.itemCount = $items.Count
        if ($guardedCount -gt 0)
        {
            $record.guardedSkipped = [pscustomobject][ordered]@{
                reason    = 'Process'
                itemCount = $guardedCount
                bytes     = $guardedBytes
                message   = 'Revit or AutoCAD is running, so these files are kept until it closes.'
            }
        }
    }

    $totals = [pscustomobject][ordered]@{ itemCount = 0; estimatedBytes = [int64]0; selectedItemCount = 0; selectedBytes = [int64]0 }
    foreach ($record in $records)
    {
        if (-not $record.available) { continue }
        $totals.itemCount += $record.itemCount
        $totals.estimatedBytes += $record.estimatedBytes
        if (-not $record.defaultSelected) { continue }
        $totals.selectedItemCount += $record.itemCount
        $totals.selectedBytes += $record.estimatedBytes
    }

    $analysis = [pscustomobject][ordered]@{
        schemaVersion = 1
        product       = 'DeadLoad'
        version       = $script:DLVersion
        analysisId    = $analysisId
        createdUtc    = $created
        result        = $result
        reason        = $reason
        reportOnly    = ([int]$config.General.ReportOnly -eq 1)
        volume        = $volume
        totals        = $totals
        categories    = $records.ToArray()
    }
    Write-DLJsonFile -Path $Path -InputObject $analysis
    $analysis | Add-Member -NotePropertyName Path -NotePropertyValue $Path
    $analysis.PSObject.TypeNames.Insert(0, 'DeadLoad.Analysis')
    return $analysis
}
