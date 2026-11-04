function Get-DLGuardState
{
    <#
        .SYNOPSIS
            SR-2: owner SIDs of running guarded processes, plus the names of every running
            process (for machine categories guarded by any owner). Cached for 30 seconds;
            -Refresh forces a new read before a group is acted on.
    #>
    param
    (
        [Parameter(Mandatory)] [hashtable]$Run,
        [switch]$Refresh
    )

    $now = Get-DLUtcNow
    if (-not $Refresh -and $Run.ContainsKey('Guard') -and $Run.Guard -and ($now - $Run.Guard.ReadAt).TotalSeconds -lt 30) { return $Run.Guard }

    $guarded = ConvertTo-DLArray -Value $Run.Config.GuardedProcesses
    $sids = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $names = New-Object 'System.Collections.Generic.List[string]'
    foreach ($process in @(Get-DLProcessOwner))
    {
        $names.Add([string]$process.Name)
        foreach ($pattern in $guarded)
        {
            if ([string]$process.Name -like $pattern)
            {
                if ($process.Sid) { [void]$sids.Add([string]$process.Sid) }
                break
            }
        }
    }
    $Run.Guard = [pscustomobject]@{ ReadAt = $now; Sids = (ConvertTo-DLArray -Value $sids); Names = $names.ToArray() }
    return $Run.Guard
}

function Test-DLAnyOwnerGuard
{
    # Machine categories (installer extracts) wait while any installer-type process runs.
    [OutputType([bool])]
    param ([pscustomobject]$Guard, [string[]]$Pattern)

    foreach ($name in $Guard.Names)
    {
        foreach ($p in $Pattern)
        {
            if ($name -like $p) { return $true }
        }
    }
    return $false
}

function Read-DLTextFile
{
    # Text and its encoding, so a rewrite keeps Revit.ini in the encoding Revit wrote.
    param ([string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    $offset = 0
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { $encoding = New-Object System.Text.UnicodeEncoding($false, $true); $offset = 2 }
    elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $encoding = New-Object System.Text.UTF8Encoding($true); $offset = 3 }
    return [pscustomobject]@{ Text = $encoding.GetString($bytes, $offset, $bytes.Length - $offset); Encoding = $encoding }
}

function Set-DLIniMinimum
{
    <#
        .SYNOPSIS
            Returns the ini text with each named key of a section raised to at least its
            minimum (added when missing; never lowered). Changed is false when nothing moved.
    #>
    param ([string]$Text, [string]$Section, [hashtable]$Minimum)

    $newline = "`r`n"
    $lines = New-Object 'System.Collections.Generic.List[string]'
    foreach ($line in ($Text -split "`r?`n")) { $lines.Add($line) }
    if ($lines.Count -gt 0 -and $lines[$lines.Count - 1] -eq '') { $lines.RemoveAt($lines.Count - 1) }

    $start = -1
    $end = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++)
    {
        if ($lines[$i] -match '^\s*\[(.+)\]\s*$')
        {
            if ($start -ge 0) { $end = $i; break }
            if ($Matches[1] -eq $Section) { $start = $i }
        }
    }
    if ($start -lt 0)
    {
        $lines.Add(('[{0}]' -f $Section))
        $start = $lines.Count - 1
        $end = $lines.Count
    }

    $changed = $false
    foreach ($key in @($Minimum.Keys | Sort-Object))
    {
        $found = $false
        for ($i = $start + 1; $i -lt $end; $i++)
        {
            if ($lines[$i] -match ('^\s*{0}\s*=\s*(.*)$' -f [regex]::Escape($key)))
            {
                $found = $true
                $current = 0
                if (-not [int]::TryParse($Matches[1].Trim(), [ref]$current) -or $current -lt [int]$Minimum[$key])
                {
                    $lines[$i] = '{0}={1}' -f $key, $Minimum[$key]
                    $changed = $true
                }
                break
            }
        }
        if (-not $found)
        {
            $lines.Insert($end, ('{0}={1}' -f $key, $Minimum[$key]))
            $end++
            $changed = $true
        }
    }
    return [pscustomobject]@{ Text = (($lines -join $newline) + $newline); Changed = $changed }
}

function Invoke-DLRevitIniShelf
{
    <#
        .SYNOPSIS
            FR-10 (category revit.ini.journalshelf): raises [Backups] JournalShelfCapacity and
            JournalShelfLife in each profile's Revit.ini so Revit does not prune journals
            DeadLoad is told to keep. Skipped while the profile's owner runs a guarded
            process (Revit rewrites the file on exit).
    #>
    param
    (
        [hashtable]$Run,
        [hashtable]$Entry,
        [object[]]$Profiles
    )

    $definition = $Entry.Definition
    $settings = $Entry.Settings
    $id = $definition.Id
    $stat = $Run.Categories[$id]
    $minimum = @{ JournalShelfCapacity = [int]$settings.ShelfCapacity; JournalShelfLife = [int]$settings.ShelfLifeDays }

    foreach ($userProfile in $Profiles)
    {
        $tokens = Get-DLTokenMap -UserProfile $userProfile
        $guard = Get-DLGuardState -Run $Run -Refresh
        foreach ($template in $definition.Roots)
        {
            foreach ($group in @(Resolve-DLRoot -Template $template -Tokens $tokens -Run $Run -Category $id))
            {
                $stat.Groups++
                $ini = New-Object System.IO.FileInfo (Join-Path $group.Path 'Revit.ini')
                if (-not $ini.Exists) { continue }
                $stat.ScannedCount++
                if (Test-DLReparsePoint -Item $ini) { Add-DLSkip -Run $Run -Path $ini.FullName -Category $id -Reason 'Reparse'; continue }
                if ($guard.Sids -contains $userProfile.Sid) { Add-DLSkip -Run $Run -Path $ini.FullName -Category $id -Reason 'Process'; continue }

                $content = Read-DLTextFile -Path $ini.FullName
                $updated = Set-DLIniMinimum -Text $content.Text -Section 'Backups' -Minimum $minimum
                if (-not $updated.Changed) { continue }
                $stat.CandidateCount++
                if ($Run.ReportOnly -or $Run.WhatIf)
                {
                    Write-DLDecision -Run $Run -Category $id -Decision 'WouldAct' -Rule 'ShelfMinimum' -Path $ini.FullName -Detail ('capacity>={0} life>={1}' -f $minimum.JournalShelfCapacity, $minimum.JournalShelfLife)
                    continue
                }
                if (Test-DLFileLocked -Path $ini.FullName) { Add-DLSkip -Run $Run -Path $ini.FullName -Category $id -Reason 'Locked'; continue }
                try
                {
                    $temporary = $ini.FullName + '.deadload.tmp'
                    [System.IO.File]::WriteAllText($temporary, $updated.Text, $content.Encoding)
                    [System.IO.File]::Replace($temporary, $ini.FullName, [NullString]::Value)
                    $stat.ActedCount++
                    Write-DLDecision -Run $Run -Category $id -Decision 'Acted' -Rule 'ShelfMinimum' -Path $ini.FullName -Detail ('capacity>={0} life>={1}' -f $minimum.JournalShelfCapacity, $minimum.JournalShelfLife)
                }
                catch
                {
                    Add-DLFailure -Run $Run -Path $ini.FullName -Category $id -Message $_.Exception.Message
                }
            }
        }
    }
}
