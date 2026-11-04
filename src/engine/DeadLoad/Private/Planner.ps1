function Set-DLProtection
{
    <#
        .SYNOPSIS
            Phase 1 of evaluation (ARCHITECTURE section 6): marks protected items. Protection
            is never overridden by a routine or pressure rule.

        .DESCRIPTION
            Protection uses the newest of create, write and (when usable) access time,
            whatever the rule's age basis, so a basis such as Created can never expose a file
            that is still being written.
    #>
    param
    (
        [Parameter(Mandatory)] [hashtable]$Run,
        [Parameter(Mandatory)] [hashtable]$Settings,
        [object[]]$Item = @(),
        [string[]]$GuardedSid = @(),
        [bool]$Guarded,
        # Unguarded categories may still protect these names while the owner runs a guarded
        # process (D20: a live Revit session's temp files).
        [string[]]$GuardedPattern = @()
    )

    $now = Get-DLUtcNow
    $useAccess = [bool]$Run.UseAccess
    $minAge = $now.AddHours(-[double]$Settings.MinAgeHours)

    foreach ($groupItems in @($Item | Group-Object -Property { $_.Group.Path }))
    {
        $ordered = @($groupItems.Group | Sort-Object -Property { Get-DLActivity -Item $_ -Basis 'Newest' -UseAccess $useAccess } -Descending)
        for ($i = 0; $i -lt $ordered.Count; $i++)
        {
            $entry = $ordered[$i]
            $newest = Get-DLActivity -Item $entry -Basis 'Newest' -UseAccess $useAccess
            if ($entry.ProtectReason) { continue }
            $ownerGuarded = ($entry.Group.Sid -and ($GuardedSid -contains $entry.Group.Sid))
            if ($Guarded -and $ownerGuarded) { $entry.ProtectReason = 'Process'; continue }
            if ($ownerGuarded -and $GuardedPattern.Count -gt 0 -and (Test-DLProtectedName -Name $entry.Path.Substring($entry.Group.Path.Length) -Pattern $GuardedPattern)) { $entry.ProtectReason = 'Process'; continue }
            if ([double]$Settings.MinAgeHours -gt 0 -and $newest -gt $minAge) { $entry.ProtectReason = 'MinAgeHours'; continue }
            if ([int]$Settings.ProtectNewest -gt 0 -and $i -lt [int]$Settings.ProtectNewest) { $entry.ProtectReason = 'ProtectNewest'; continue }
        }
    }

    foreach ($entry in $Item)
    {
        if ($entry.ProtectReason)
        {
            $Run.Totals.ProtectedCount++
            $Run.Categories[$entry.Category].ProtectedCount++
            Write-DLDecision -Run $Run -Category $entry.Category -Decision 'Protected' -Rule $entry.ProtectReason -Path $entry.Path
        }
    }
}

function Get-DLScopeKey
{
    param ([pscustomobject]$Item, [string]$LimitScope)

    switch ($LimitScope)
    {
        'User' { return ('user:{0}' -f $Item.Group.Sid) }
        'Machine' { return 'machine' }
        default { return ('group:{0}' -f $Item.Group.Path) }
    }
}

function Test-DLActivation
{
    # ActivateBelowGB/Percent: a routine rule runs only while free space is below the value.
    [OutputType([bool])]
    param ([hashtable]$Settings, [pscustomobject]$Volume)

    $gb = [double]$Settings.ActivateBelowGB
    $percent = [double]$Settings.ActivateBelowPercent
    if ($gb -le 0 -and $percent -le 0) { return $true }
    $threshold = [math]::Max($gb * 1GB, $Volume.SizeBytes * $percent / 100)
    return ($Volume.FreeBytes -lt $threshold)
}

function Select-DLRoutine
{
    <#
        .SYNOPSIS
            Phase 2 (routine): an unprotected item is selected when ANY configured limit
            selects it (D13, logrotate semantics). Count, size and share are evaluated per
            LimitScope over every item, protected ones included, newest first.
    #>
    param
    (
        [Parameter(Mandatory)] [hashtable]$Run,
        [Parameter(Mandatory)] [hashtable]$Settings,
        [object[]]$Item = @(),
        [Parameter(Mandatory)] [pscustomobject]$Volume
    )

    if ([string]$Settings.RoutineAction -eq 'None') { return }
    $now = Get-DLUtcNow
    $useAccess = [bool]$Run.UseAccess
    $basis = [string]$Settings.AgeBasis
    $ageDays = [double]$Settings.AgeDays
    $keep = [int]$Settings.KeepNewest
    $maxBytes = [double]$Settings.MaxTotalMB * 1MB
    $shareBase = $Volume.FreeBytes
    if ($Settings.ShareBase -eq 'Disk') { $shareBase = $Volume.SizeBytes }
    $maxShare = [double]$shareBase * [double]$Settings.MaxSharePercent / 100

    foreach ($scope in @($Item | Group-Object -Property { Get-DLScopeKey -Item $_ -LimitScope $Settings.LimitScope }))
    {
        $ordered = @($scope.Group | Sort-Object -Property { Get-DLActivity -Item $_ -Basis $basis -UseAccess $useAccess } -Descending)
        $cumulative = [int64]0
        for ($i = 0; $i -lt $ordered.Count; $i++)
        {
            $entry = $ordered[$i]
            $cumulative += $entry.Length
            $activity = Get-DLActivity -Item $entry -Basis $basis -UseAccess $useAccess
            $entry.Activity = $activity
            $entry.Rank = $i

            $rules = New-Object 'System.Collections.Generic.List[string]'
            if ($ageDays -gt 0 -and $activity -lt $now.AddDays(-$ageDays)) { $rules.Add('AgeDays') }
            if ($keep -gt 0 -and $i -ge $keep) { $rules.Add('KeepNewest') }
            if ($maxBytes -gt 0 -and $cumulative -gt $maxBytes) { $rules.Add('MaxTotalMB') }
            if ($maxShare -gt 0 -and $cumulative -gt $maxShare) { $rules.Add('MaxSharePercent') }

            if ($entry.ProtectReason) { continue }
            if ($rules.Count -gt 0)
            {
                $entry.Selected = $true
                $entry.SelectRule = ($rules -join '+')
                $Run.Totals.CandidateCount++
                $Run.Totals.CandidateBytes += $entry.Length
                $Run.Categories[$entry.Category].CandidateCount++
                $Run.Categories[$entry.Category].CandidateBytes += $entry.Length
                Write-DLDecision -Run $Run -Category $entry.Category -Decision 'Selected' -Rule $entry.SelectRule -Path $entry.Path -Detail ('action={0}' -f $Settings.RoutineAction)
            }
            else
            {
                $detail = $null
                if ($ageDays -gt 0 -and $useAccess -and ($basis -eq 'Accessed' -or $basis -eq 'Newest'))
                {
                    $withoutAccess = Get-DLActivity -Item $entry -Basis $basis -UseAccess $false
                    if ($withoutAccess -lt $now.AddDays(-$ageDays)) { $detail = 'kept only because of last access time' }
                }
                Write-DLDecision -Run $Run -Category $entry.Category -Decision 'Kept' -Rule 'WithinLimits' -Path $entry.Path -Detail $detail
            }
        }
    }
}

function Get-DLPressureCandidate
{
    <#
        .SYNOPSIS
            Phase 3 candidates: unprotected, not yet acted on, older than PressureAgeDays and
            beyond PressureKeepNewest in their group, on the system volume; ordered by tier,
            then oldest first.
    #>
    param
    (
        [Parameter(Mandatory)] [hashtable]$Run,
        [Parameter(Mandatory)] [object[]]$Entry,
        [Parameter(Mandatory)] [string]$SystemDrive
    )

    $now = Get-DLUtcNow
    $useAccess = [bool]$Run.UseAccess
    $candidates = New-Object 'System.Collections.Generic.List[object]'
    foreach ($category in $Entry)
    {
        $settings = $category.Settings
        if (-not [bool]$settings.PressureEnabled) { continue }
        foreach ($groupItems in @($category.Items | Group-Object -Property { $_.Group.Path }))
        {
            $ordered = @($groupItems.Group | Sort-Object -Property { Get-DLActivity -Item $_ -Basis 'Newest' -UseAccess $useAccess } -Descending)
            for ($i = 0; $i -lt $ordered.Count; $i++)
            {
                # Not $entry: PowerShell names are case-insensitive and $Entry is a typed
                # [object[]] parameter, which would wrap every assigned item in an array.
                $candidate = $ordered[$i]
                if ($candidate.ProtectReason -or $candidate.Done) { continue }
                if ($i -lt [int]$settings.PressureKeepNewest) { continue }
                $newest = Get-DLActivity -Item $candidate -Basis 'Newest' -UseAccess $useAccess
                if ($newest -gt $now.AddDays(-[double]$settings.PressureAgeDays)) { continue }
                if (-not ([System.IO.Path]::GetPathRoot($candidate.Path)).Equals($SystemDrive, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
                $candidates.Add([pscustomobject]@{ Item = $candidate; Tier = [int]$settings.PressureTier; Activity = $newest; Settings = $settings })
            }
        }
    }
    return , @($candidates | Sort-Object -Property Tier, Activity)
}

function Get-DLPressureThreshold
{
    # Floor and target in bytes: the larger of the GB and percent values (ARCHITECTURE 6).
    param ([hashtable]$Pressure, [pscustomobject]$Volume)

    return [pscustomobject]@{
        FloorBytes  = [int64][math]::Max([double]$Pressure.FloorGB * 1GB, [double]$Volume.SizeBytes * [double]$Pressure.FloorPercent / 100)
        TargetBytes = [int64][math]::Max([double]$Pressure.TargetGB * 1GB, [double]$Volume.SizeBytes * [double]$Pressure.TargetPercent / 100)
    }
}
