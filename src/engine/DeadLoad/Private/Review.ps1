function Test-DLReviewCategory
{
    <#
        .SYNOPSIS
            D22: whether a category may be offered in, and cleaned through, the user's own
            cleanup review (Analyze and Clean). Returns $null when it may, else the reason:
            Restricted (risk tier, or no tier: a definition without one is never offered),
            MachineScope (not the user's own profile) or NotDelete (a setting change or an
            action other than deletion, which the review never performs).
    #>
    [OutputType([string])]
    param ([Parameter(Mandatory)] [hashtable]$Entry)

    $definition = $Entry.Definition
    if ([string]$definition.Risk -ne 'Routine' -and [string]$definition.Risk -ne 'Review') { return 'Restricted' }
    if ($definition.Scope -ne 'User') { return 'MachineScope' }
    if ($definition.Kind) { return 'NotDelete' }
    $action = [string]$Entry.Settings.RoutineAction
    if ($action -ne 'Delete' -and $action -ne 'None') { return 'NotDelete' }
    return $null
}

function Get-DLFingerprint
{
    # What Clean compares with the analysis: an item changed since the user reviewed it is not
    # the item they reviewed.
    [OutputType([string])]
    param ([int64]$Length, [datetime]$LastWriteUtc)

    return ('{0}:{1}' -f $Length, $LastWriteUtc.Ticks)
}

function Limit-DLReviewedSelection
{
    <#
        .SYNOPSIS
            D23: a review cleanup acts only on the intersection of what the user reviewed and
            what the fresh plan selects. Selected items the user never saw are deselected
            (NotReviewed, not reported); reviewed items whose size or write time changed are
            deselected and reported (ChangedSinceAnalysis). A folder item keeps only its
            reviewed, unchanged files, so a file added inside it after the review stays.
    #>
    param
    (
        [Parameter(Mandatory)] [hashtable]$Run,
        [Parameter(Mandatory)] [pscustomobject]$Entry,
        [Parameter(Mandatory)] [hashtable]$ReviewedItem
    )

    foreach ($item in $Entry.Items)
    {
        if (-not $item.Selected) { continue }
        $outcome = $null
        if (-not $ReviewedItem.ContainsKey($item.Path))
        {
            $outcome = 'NotReviewed'
        }
        elseif ($item.Kind -eq 'File')
        {
            if ($ReviewedItem[$item.Path] -ne (Get-DLFingerprint -Length $item.Length -LastWriteUtc $item.ModifiedUtc)) { $outcome = 'ChangedSinceAnalysis' }
        }
        else
        {
            $kept = New-Object 'System.Collections.Generic.List[object]'
            $length = [int64]0
            foreach ($snapshot in $item.Files)
            {
                if (-not $ReviewedItem.ContainsKey($snapshot.Path)) { continue }
                if ($ReviewedItem[$snapshot.Path] -ne (Get-DLFingerprint -Length $snapshot.Length -LastWriteUtc $snapshot.LastWriteTimeUtc))
                {
                    Add-DLSkip -Run $Run -Path $snapshot.Path -Category $item.Category -Reason 'ChangedSinceAnalysis' -Detail 'changed after the review'
                    continue
                }
                $kept.Add($snapshot)
                $length += $snapshot.Length
            }
            if ($kept.Count -eq 0) { $outcome = 'ChangedSinceAnalysis' }
            else
            {
                $Run.Totals.CandidateBytes -= ($item.Length - $length)
                $Run.Categories[$item.Category].CandidateBytes -= ($item.Length - $length)
                $item.Files = $kept.ToArray()
                $item.Length = $length
            }
        }
        if (-not $outcome) { continue }

        $item.Selected = $false
        $Run.Totals.CandidateCount--
        $Run.Totals.CandidateBytes -= $item.Length
        $Run.Categories[$item.Category].CandidateCount--
        $Run.Categories[$item.Category].CandidateBytes -= $item.Length
        if ($outcome -eq 'NotReviewed')
        {
            $item.Outcome = 'NotReviewed'
            Write-DLDecision -Run $Run -Category $item.Category -Decision 'Kept' -Rule 'NotReviewed' -Path $item.Path
        }
        else
        {
            $item.Outcome = 'Skipped'
            $item.OutcomeReason = $outcome
            Add-DLSkip -Run $Run -Path $item.Path -Category $item.Category -Reason $outcome -Detail 'changed after the review'
        }
    }
}

function ConvertTo-DLPlan
{
    <#
        .SYNOPSIS
            The per-item plan of a run (Invoke-DeadLoad -IncludePlan): every scanned item with
            its selection, protection and outcome, in full paths. Only the user review asks for
            it; it is never written to the run reports.
    #>
    param ([object[]]$Entry = @())

    foreach ($category in $Entry)
    {
        $settings = $category.Settings
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $category.Items)
        {
            $files = @()
            if ($item.Kind -ne 'File')
            {
                $files = @(foreach ($snapshot in $item.Files)
                    {
                        [pscustomobject][ordered]@{
                            Path        = $snapshot.Path
                            Bytes       = [int64]$snapshot.Length
                            Fingerprint = (Get-DLFingerprint -Length $snapshot.Length -LastWriteUtc $snapshot.LastWriteTimeUtc)
                        }
                    })
            }
            $items.Add([pscustomobject][ordered]@{
                    Kind          = $item.Kind
                    Path          = $item.Path
                    Bytes         = [int64]$item.Length
                    ModifiedUtc   = $item.ModifiedUtc.ToString('o')
                    Fingerprint   = (Get-DLFingerprint -Length $item.Length -LastWriteUtc $item.ModifiedUtc)
                    Selected      = [bool]$item.Selected
                    Rule          = $item.SelectRule
                    ProtectReason = $item.ProtectReason
                    Outcome       = $item.Outcome
                    OutcomeReason = $item.OutcomeReason
                    FreedBytes    = [int64]$item.FreedBytes
                    Files         = $files
                })
        }
        [pscustomobject][ordered]@{
            Id              = $category.Id
            RoutineAction   = [string]$settings.RoutineAction
            AgeDays         = [double]$settings.AgeDays
            AgeBasis        = [string]$settings.AgeBasis
            KeepNewest      = [int]$settings.KeepNewest
            MaxTotalMB      = [double]$settings.MaxTotalMB
            MaxSharePercent = [double]$settings.MaxSharePercent
            MinAgeHours     = [double]$settings.MinAgeHours
            Items           = $items.ToArray()
        }
    }
}

function Get-DLReasonText
{
    # Plain-language text for a skip, protection or selection reason id (ENGINE-UI-CONTRACT).
    [OutputType([string])]
    param ([string]$Reason)

    switch ($Reason)
    {
        'Missing' { return 'No longer found.' }
        'Changed' { return 'Changed while the cleanup ran.' }
        'ChangedSinceAnalysis' { return 'Changed after it was reviewed.' }
        'Locked' { return 'In use by a program.' }
        'Process' { return 'Revit or AutoCAD is running.' }
        'MinAgeHours' { return 'Used too recently.' }
        'ProtectNewest' { return 'One of the newest, which are kept.' }
        'ProtectedPattern' { return 'A design or project file type, which is never removed.' }
        'Reparse' { return 'A link to another location, which is never followed.' }
        'OutsideAnchor' { return 'Its folder moved or changed.' }
        'InstallSource' { return 'An installed product still refers to it.' }
        'NotSelected' { return 'No longer matches the cleanup rule.' }
        'ReportOnly' { return 'Report-only mode is on, so nothing was deleted.' }
        'Budget' { return 'The cleanup reached its time or size limit.' }
        'Failed' { return 'Could not be deleted.' }
        'Restricted' { return 'Only the scheduled maintenance can clean this category.' }
        'MachineScope' { return 'This category is shared by everyone on this computer; only the scheduled maintenance cleans it.' }
        'NotDelete' { return 'This category is not cleaned by deleting files.' }
        default { return $Reason }
    }
}

function Get-DLRuleText
{
    # Why an item was selected, from the routine rule ids of Select-DLRoutine.
    [OutputType([string])]
    param ([string]$Rule, [pscustomobject]$Category)

    $parts = New-Object 'System.Collections.Generic.List[string]'
    foreach ($id in ([string]$Rule -split '\+'))
    {
        switch ($id)
        {
            'AgeDays'
            {
                $days = $Category.AgeDays
                switch ($Category.AgeBasis)
                {
                    'Created' { $parts.Add(('Created more than {0} days ago' -f $days)) }
                    'Modified' { $parts.Add(('Not changed in the last {0} days' -f $days)) }
                    'Accessed' { $parts.Add(('Not opened in the last {0} days' -f $days)) }
                    default { $parts.Add(('Not used in the last {0} days' -f $days)) }
                }
            }
            'KeepNewest' { $parts.Add(('Beyond the newest {0} kept' -f $Category.KeepNewest)) }
            'MaxTotalMB' { $parts.Add(('Beyond the {0} MB size limit' -f $Category.MaxTotalMB)) }
            'MaxSharePercent' { $parts.Add(('Beyond the {0} percent space limit' -f $Category.MaxSharePercent)) }
            default { if ($id) { $parts.Add($id) } }
        }
    }
    return (($parts -join '; ') + '.')
}

function Write-DLJsonFile
{
    # Write-then-rename so the tray never reads half a file. UTF-8 without a byte order mark.
    param ([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [object]$InputObject)

    $directory = Split-Path -Path $Path -Parent
    if (-not [System.IO.Directory]::Exists($directory)) { [void][System.IO.Directory]::CreateDirectory($directory) }
    $json = $InputObject | ConvertTo-Json -Depth 10
    $temporary = $Path + '.tmp'
    [System.IO.File]::WriteAllText($temporary, $json, (New-Object System.Text.UTF8Encoding($false)))
    # [NullString]: PowerShell turns $null into '' for a string argument, which Replace rejects.
    if ([System.IO.File]::Exists($Path)) { [System.IO.File]::Replace($temporary, $Path, [NullString]::Value) }
    else { [System.IO.File]::Move($temporary, $Path) }
}
