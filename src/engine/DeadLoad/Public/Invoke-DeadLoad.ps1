function Invoke-DeadLoad
{
    <#
        .SYNOPSIS
            One DeadLoad run: resolve configuration, scan, plan (protect, routine, pressure),
            act, report. Returns exactly one DeadLoad.RunSummary object.

        .DESCRIPTION
            Modes: Maintenance (routine rules, then pressure tiers if below the floor),
            PressureCheck (only below the floor), OnDemand (the policy's OnDemandMode), User
            (current profile only, user-action categories, no pressure).

            User with -Category is the user's cleanup review (D22, D23): the named categories
            instead of the user-action set, each of which must pass Test-DLReviewCategory (a
            Restricted, machine or non-deletion category fails the run); deletion only, a
            pressure-only category at its PressureAgeDays; Tray.CleanTempMinAgeDays protects
            newer items. -ReviewedItem limits acting to the reviewed items (the intersection).

            Report-only (policy or -ReportOnly) and -WhatIf produce the full plan and change
            nothing. Prose goes to the verbose stream and the run log; the output stream
            carries only the summary.

        .PARAMETER Category
            Run only these category ids.

        .PARAMETER IncludePlan
            Adds a Plan property to the returned summary: every scanned item with full path,
            selection, protection and outcome. Never written to the run reports or events.

        .PARAMETER ReviewedItem
            User review only: full path -> fingerprint (Get-DLFingerprint) of every item and
            folder file the user reviewed. Only selected items found here, unchanged, are acted
            on.

        .PARAMETER Configuration
            Test seam: settings that override every source; registry is not read.

        .PARAMETER DataRoot
            Test seam: where last-run.json, runs\ and logs\ are written.

        .EXAMPLE
            Invoke-DeadLoad -Mode Maintenance -ReportOnly -Verbose
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType('DeadLoad.RunSummary')]
    param
    (
        [ValidateSet('Maintenance', 'PressureCheck', 'OnDemand', 'User')]
        [string]$Mode = 'Maintenance',

        [switch]$ReportOnly,

        [string[]]$Category,

        [switch]$IncludePlan,

        [hashtable]$ReviewedItem,

        [hashtable]$Configuration,

        [string]$DataRoot,

        [switch]$NoEventLog
    )

    if (-not $DataRoot)
    {
        if ($Mode -eq 'User') { $DataRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DeadLoad' }
        else { $DataRoot = Join-Path $env:ProgramData 'DeadLoad' }
    }

    $isWhatIf = [bool]$WhatIfPreference
    $config = $null
    $run = $null
    $volume = $null
    $result = 'Success'
    $reason = $null
    $plan = $null
    $review = ($Mode -eq 'User' -and $Category.Count -gt 0)

    try
    {
        if ($Configuration) { $config = Get-DLConfiguration -Override $Configuration -NoRegistry }
        else { $config = Get-DLConfiguration }
        if ($ReviewedItem -and -not $review) { throw 'ReviewedItem applies only to a User run with Category.' }

        $effectiveReportOnly = ([bool]$ReportOnly -or [int]$config.General.ReportOnly -eq 1)
        $run = New-DLRunContext -Configuration $config -Mode $Mode -DataRoot $DataRoot -ReportOnly $effectiveReportOnly -WhatIf $isWhatIf
        # User runs log to the user's own file only: the machine's Application log (and the RMM
        # alerts on it) describes SYSTEM runs; the tray's entry point writes event 4001.
        $run.NoEventLog = ([bool]$NoEventLog -or $Mode -eq 'User')
        $run.Trace = ConvertTo-DLArray -Value $config.Trace

        Write-DLEvent -Run $run -Id 1000 -Message ('DeadLoad {0} run started: mode {1}, report-only {2}, what-if {3}.' -f $script:DLVersion, $Mode, $effectiveReportOnly, $isWhatIf)

        $integrity = Test-DLIntegrity -ModuleRoot $script:DLModuleRoot
        if ($integrity)
        {
            Write-DLEvent -Run $run -Id 3003 -Level Error -Message ('Integrity check failed; run refused: {0}' -f $integrity)
            $result = 'Failed'
            $reason = 'Integrity: ' + $integrity
            return
        }

        $traceText = ($config.Trace | ForEach-Object { '{0}={1} ({2})' -f $_.Name, $_.Value, $_.Source }) -join '; '
        Write-DLEvent -Run $run -Id 1003 -Message ('Effective configuration: ' + $traceText)
        if ($config.Rejected.Count -gt 0)
        {
            $rejectedText = ($config.Rejected | ForEach-Object { '{0}={1} ({2}): {3}' -f $_.Name, $_.Value, $_.Source, $_.Reason }) -join '; '
            Write-DLEvent -Run $run -Id 3002 -Level Warning -Message ('Configuration values rejected: ' + $rejectedText)
        }

        if ([int]$config.General.Enabled -ne 1)
        {
            $result = 'Disabled'
            $reason = 'Engine disabled by configuration'
            return
        }

        $effectiveMode = $Mode
        if ($Mode -eq 'OnDemand')
        {
            Write-DLEvent -Run $run -Id 4000 -Message ('OnDemand run requested; running {0}.' -f $config.General.OnDemandMode)
            $effectiveMode = [string]$config.General.OnDemandMode
        }

        $tracking = Test-DLLastAccessTracking
        $run.UseAccess = ([int]$config.General.UseLastAccess -eq 1 -and $tracking)
        if (-not $run.UseAccess) { Write-DLLog -Run $run -Message ('Last access not used (UseLastAccess {0}, NTFS tracking {1}): Accessed falls back to Modified.' -f $config.General.UseLastAccess, $tracking) }

        $volume = Get-DLVolume
        $threshold = Get-DLPressureThreshold -Pressure $config.Pressure -Volume $volume
        $freeBefore = $volume.FreeBytes
        $belowFloor = ($volume.FreeBytes -lt $threshold.FloorBytes)
        $run.VolumeState = [ordered]@{
            Drive = $volume.Drive; SizeBytes = $volume.SizeBytes; FreeBytesBefore = $freeBefore; FreeBytesAfter = $freeBefore
            FloorBytes = $threshold.FloorBytes; TargetBytes = $threshold.TargetBytes
            PressureBefore = $belowFloor; PressureAfter = $belowFloor; TargetReached = (-not $belowFloor)
        }

        if ($effectiveMode -eq 'PressureCheck' -and -not $belowFloor)
        {
            $result = 'Skipped'
            $reason = 'Free space above the floor'
            return
        }

        $profiles = @()
        if ($Mode -eq 'User') { $profiles = @(Get-DLProfile -Current) }
        else { $profiles = @(Get-DLProfile) }
        foreach ($userProfile in $profiles) { [void](Register-DLProfileAlias -Run $run -UserProfile $userProfile) }

        # Categories of this run.
        $entries = New-Object 'System.Collections.Generic.List[object]'
        foreach ($id in $config.Categories.Keys)
        {
            $entry = $config.Categories[$id]
            $definition = $entry.Definition
            if ($Category -and $Category -notcontains $id) { continue }
            if ($review)
            {
                $refusal = Test-DLReviewCategory -Entry $entry
                if ($refusal) { throw ('Category {0} cannot be cleaned from the user review: {1}.' -f $id, $refusal) }
            }
            elseif ($Mode -eq 'User')
            {
                if (-not $definition.UserAction) { continue }
                # D25: a Restricted category (or one without a tier) never takes part in a
                # user-started cleanup, whatever its UserAction flag says.
                if ([string]$definition.Risk -ne 'Routine' -and [string]$definition.Risk -ne 'Review') { continue }
            }
            $enabled = ([int]$entry.Settings.Enabled -eq 1)
            $run.Categories[$id] = New-DLCategoryStat -Id $id -Enabled $enabled
            if (-not $enabled) { continue }

            $settings = @{}
            foreach ($key in $entry.Settings.Keys) { $settings[$key] = $entry.Settings[$key] }
            if ($review)
            {
                # The user's own request deletes: a pressure-only category (D9) at the age it
                # gives items up under pressure. The tray's age floor protects newer items.
                if ([string]$settings.RoutineAction -eq 'None')
                {
                    $settings.RoutineAction = 'Delete'
                    $settings.AgeDays = $settings.PressureAgeDays
                    $settings.AgeBasis = 'Newest'
                }
                $floorDays = [double]$config.Tray.CleanTempMinAgeDays
                if ([double]$settings.AgeDays -gt 0) { $settings.AgeDays = [math]::Max([double]$settings.AgeDays, $floorDays) }
                $settings.MinAgeHours = [math]::Max([double]$settings.MinAgeHours, $floorDays * 24)
                $settings.PressureEnabled = 0
            }
            elseif ($Mode -eq 'User')
            {
                # The tray's own age floor; users never trigger pressure.
                $settings.AgeDays = [math]::Max([double]$settings.AgeDays, [double]$config.Tray.CleanTempMinAgeDays)
                $settings.PressureEnabled = 0
            }
            $entries.Add([pscustomobject]@{ Id = $id; Definition = $definition; Settings = $settings; Items = @(); Groups = @() })
        }

        $guard = Get-DLGuardState -Run $run -Refresh
        $installedYears = $null

        foreach ($entry in $entries)
        {
            $definition = $entry.Definition
            $stat = $run.Categories[$entry.Id]

            if ($definition.Kind -eq 'RevitIniShelf')
            {
                Invoke-DLRevitIniShelf -Run $run -Entry @{ Definition = $definition; Settings = $entry.Settings } -Profiles $profiles
                continue
            }

            $scopes = @($null)
            if ($definition.Scope -eq 'User') { $scopes = $profiles }
            $items = New-Object 'System.Collections.Generic.List[object]'
            $groups = New-Object 'System.Collections.Generic.List[object]'
            foreach ($userProfile in $scopes)
            {
                $tokens = Get-DLTokenMap -UserProfile $userProfile
                $protectedPaths = @(foreach ($template in $config.ProtectedPaths) { Expand-DLTemplate -Template $template -Tokens $tokens })
                $sid = $null
                if ($userProfile) { $sid = $userProfile.Sid }
                $protectedPaths += @(Get-DLDesktopConnectorWorkspace -Sid $sid)
                $protectedPaths = @($protectedPaths | Where-Object { $_ })

                foreach ($template in $definition.Roots)
                {
                    foreach ($root in @(Resolve-DLRoot -Template $template -Tokens $tokens -Run $run -Category $entry.Id -ProtectedPath $protectedPaths))
                    {
                        if ($definition.RootFilter -eq 'RevitYearNotInstalled')
                        {
                            if ($null -eq $installedYears) { $installedYears = @(Get-DLInstalledRevitYear) }
                            if (-not $root.Version -or $installedYears -contains $root.Version) { continue }
                        }
                        $group = [pscustomobject]@{
                            Path        = $root.Path
                            Anchor      = $root.Anchor
                            Version     = $root.Version
                            Sid         = $sid
                            ProfilePath = $(if ($userProfile) { $userProfile.Path } else { $null })
                            Touched     = (New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase))
                        }
                        $groups.Add($group)
                        $stat.Groups++
                        foreach ($item in @(Get-DLGroupItem -Run $run -Definition $definition -Group $group -ProtectedPattern $config.ProtectedPatterns -ProtectedPath $protectedPaths))
                        {
                            if ($definition.RootFilter -eq 'NotInstallSource' -and (Test-DLInstallSource -Path $item.Path)) { $item.ProtectReason = 'InstallSource' }
                            $items.Add($item)
                        }
                    }
                }
            }
            $entry.Items = $items.ToArray()
            $entry.Groups = $groups.ToArray()
            foreach ($item in $entry.Items)
            {
                $stat.ScannedCount++
                $stat.ScannedBytes += $item.Length
                $run.Totals.ScannedCount++
                $run.Totals.ScannedBytes += $item.Length
            }

            if ($definition.GuardProcessesAnyOwner -and (Test-DLAnyOwnerGuard -Guard $guard -Pattern $definition.GuardProcessesAnyOwner))
            {
                foreach ($item in $entry.Items) { if (-not $item.ProtectReason) { $item.ProtectReason = 'Process' } }
            }
            Set-DLProtection -Run $run -Settings $entry.Settings -Item $entry.Items -GuardedSid $guard.Sids -Guarded ([bool]$definition.Guarded) -GuardedPattern (ConvertTo-DLArray -Value $definition.GuardedPatterns)

            # Routine phase.
            if ($effectiveMode -ne 'PressureCheck' -and $entry.Settings.RoutineAction -ne 'None' -and $entry.Items.Count -gt 0)
            {
                if (Test-DLActivation -Settings $entry.Settings -Volume $volume)
                {
                    Select-DLRoutine -Run $run -Settings $entry.Settings -Item $entry.Items -Volume $volume
                    if ($ReviewedItem) { Limit-DLReviewedSelection -Run $run -Entry $entry -ReviewedItem $ReviewedItem }
                    Invoke-DLSelected -Run $run -Entry $entry -Action ([string]$entry.Settings.RoutineAction) -Phase 'Routine'
                }
                else
                {
                    Write-DLLog -Run $run -Message ('Category {0}: routine inactive above its ActivateBelow threshold.' -f $entry.Id)
                }
            }
            if (Test-DLBudgetExhausted -Run $run) { break }
        }

        # Pressure phase.
        if ($Mode -ne 'User' -and -not (Test-DLBudgetExhausted -Run $run))
        {
            $volume = Get-DLVolume
            if ($volume.FreeBytes -lt $threshold.FloorBytes)
            {
                $run.VolumeState.PressureBefore = $true
                Write-DLEvent -Run $run -Id 2000 -Level Warning -Message ('Disk pressure: {0:N0} bytes free on {1}, floor {2:N0}, target {3:N0}.' -f $volume.FreeBytes, $volume.Drive, $threshold.FloorBytes, $threshold.TargetBytes)
                $reached = Invoke-DLPressure -Run $run -Entry $entries.ToArray() -Threshold $threshold -SystemDrive $volume.Drive
                $run.VolumeState.TargetReached = $reached
                if ($reached) { Write-DLEvent -Run $run -Id 2001 -Message 'Pressure target reached.' }
                elseif ($run.ReportOnly -or $run.WhatIf) { Write-DLLog -Run $run -Message 'Pressure plan only (report-only or what-if); target not evaluated.' }
                elseif (-not (Test-DLBudgetExhausted -Run $run)) { Write-DLEvent -Run $run -Id 2002 -Level Warning -Message 'Pressure target not reachable: eligible items exhausted.' }
            }
        }

        foreach ($entry in $entries)
        {
            foreach ($group in $entry.Groups) { Remove-DLTouchedDirectory -Group $group }
            $stat = $run.Categories[$entry.Id]
            Write-DLEvent -Run $run -Id 1002 -Message ('Category {0}: groups {1}, scanned {2} ({3:N0} bytes), protected {4}, candidates {5}, acted {6}, freed {7:N0} bytes, skipped {8}, failed {9}.' -f $entry.Id, $stat.Groups, $stat.ScannedCount, $stat.ScannedBytes, $stat.ProtectedCount, $stat.CandidateCount, $stat.ActedCount, $stat.FreedBytes, $stat.SkippedCount, $stat.FailedCount)
        }

        if (Test-DLBudgetExhausted -Run $run) { $result = 'Partial'; $reason = 'Budget exhausted' }
        elseif ($run.Totals.FailedCount -gt 0) { $result = 'Partial'; $reason = ('{0} item(s) failed' -f $run.Totals.FailedCount) }
        elseif ($run.VolumeState.PressureBefore -and -not $run.VolumeState.TargetReached -and -not ($run.ReportOnly -or $run.WhatIf)) { $result = 'Partial'; $reason = 'Pressure target not reached' }
        if ($IncludePlan) { $plan = @(ConvertTo-DLPlan -Entry $entries.ToArray()) }
    }
    catch
    {
        $result = 'Failed'
        $reason = $_.Exception.Message
        if (-not $run)
        {
            $fallback = @{ General = @{ TimeBudgetMinutes = 1; LogRetentionDays = 0 }; Trace = @() }
            $run = New-DLRunContext -Configuration $fallback -Mode $Mode -DataRoot $DataRoot -ReportOnly $true -WhatIf $isWhatIf
            $run.NoEventLog = ([bool]$NoEventLog -or $Mode -eq 'User')
            $run.Trace = @()
        }
        Write-DLEvent -Run $run -Id 3000 -Level Error -Message ('Run error: {0} at {1} {2}' -f $_.Exception.Message, $_.InvocationInfo.PositionMessage, $_.ScriptStackTrace)
    }
    finally
    {
        if ($run)
        {
            if ($run.SkipCounts.Count -gt 0)
            {
                $skipText = ($run.SkipCounts.GetEnumerator() | Sort-Object -Property Name | ForEach-Object { '{0} {1}' -f $_.Name, $_.Value }) -join ', '
                Write-DLEvent -Run $run -Id 3001 -Level Warning -Message ('Items skipped: ' + $skipText)
            }
            if ($run.ContainsKey('VolumeState') -and $run.VolumeState)
            {
                try
                {
                    $after = Get-DLVolume
                    $run.VolumeState.FreeBytesAfter = $after.FreeBytes
                    $run.VolumeState.PressureAfter = ($after.FreeBytes -lt $run.VolumeState.FloorBytes)
                }
                catch { Write-Verbose 'Free space after the run not read.' }
            }
            $volumeObject = $null
            if ($run.ContainsKey('VolumeState') -and $run.VolumeState) { $volumeObject = [pscustomobject]$run.VolumeState }
            $summary = New-DLRunSummary -Run $run -Result $result -Reason $reason -Volume $volumeObject
            $level = 'Information'
            if ($result -eq 'Partial') { $level = 'Warning' }
            if ($result -eq 'Failed') { $level = 'Error' }
            $compact = (ConvertTo-DLJson -InputObject ($summary | Select-Object -Property * -ExcludeProperty Skips, Failures, Configuration)) -replace '\s+', ' '
            Write-DLEvent -Run $run -Id 1001 -Level $level -Message ('Run {0}: {1}. {2}' -f $result, $reason, $compact)
            Save-DLRunReport -Run $run -Summary $summary
            # Added after the report and events: the plan carries full paths.
            if ($IncludePlan)
            {
                if ($null -eq $plan) { $plan = @() }
                $summary | Add-Member -NotePropertyName Plan -NotePropertyValue $plan
            }
            $summary
        }
    }
}

function Invoke-DLSelected
{
    # Acts on the routine selection of one category, oldest first, refreshing the process
    # guard before each group.
    param ([hashtable]$Run, [pscustomobject]$Entry, [string]$Action, [string]$Phase)

    $selected = @($Entry.Items | Where-Object { $_.Selected -and -not $_.Done })
    foreach ($groupItems in @($selected | Group-Object -Property { $_.Group.Path }))
    {
        if ($Entry.Definition.Guarded -and $groupItems.Group[0].Group.Sid)
        {
            $guard = Get-DLGuardState -Run $Run -Refresh
            if ($guard.Sids -contains $groupItems.Group[0].Group.Sid)
            {
                foreach ($item in $groupItems.Group)
                {
                    $item.Outcome = 'Skipped'
                    $item.OutcomeReason = 'Process'
                    Add-DLSkip -Run $Run -Path $item.Path -Category $Entry.Id -Reason 'Process' -Detail 'guarded process started before action'
                }
                continue
            }
        }
        foreach ($item in @($groupItems.Group | Sort-Object -Property Activity))
        {
            $outcome = Invoke-DLItemAction -Run $Run -Item $item -Action $Action -Settings $Entry.Settings -Definition $Entry.Definition -Rule ('{0}:{1}' -f $Phase, $item.SelectRule) -Confirm:$false -WhatIf:$false
            if ($outcome.Status -eq 'Budget') { return }
        }
    }
}

function Invoke-DLPressure
{
    <#
        .SYNOPSIS
            FR-6: tiers in order, oldest first, one item at a time, re-reading free space
            after each, until the target is reached. Returns whether it was reached.
    #>
    param ([hashtable]$Run, [object[]]$Entry, [pscustomobject]$Threshold, [string]$SystemDrive)

    $candidates = Get-DLPressureCandidate -Run $Run -Entry $Entry -SystemDrive $SystemDrive
    $byId = @{}
    foreach ($e in $Entry) { $byId[$e.Id] = $e }
    $refreshedGroups = @{}
    foreach ($candidate in $candidates)
    {
        $item = $candidate.Item
        $definition = $byId[$item.Category].Definition
        if ($definition.Guarded -and $item.Group.Sid -and -not $refreshedGroups.ContainsKey($item.Group.Path))
        {
            $refreshedGroups[$item.Group.Path] = 'clear'
            $guard = Get-DLGuardState -Run $Run -Refresh
            if ($guard.Sids -contains $item.Group.Sid) { $refreshedGroups[$item.Group.Path] = 'guarded' }
        }
        if ($refreshedGroups[$item.Group.Path] -eq 'guarded')
        {
            Add-DLSkip -Run $Run -Path $item.Path -Category $item.Category -Reason 'Process' -Detail 'guarded process started before action'
            continue
        }

        $Run.Totals.CandidateCount++
        $Run.Totals.CandidateBytes += $item.Length
        $Run.Categories[$item.Category].CandidateCount++
        $Run.Categories[$item.Category].CandidateBytes += $item.Length
        $outcome = Invoke-DLItemAction -Run $Run -Item $item -Action ([string]$candidate.Settings.PressureAction) -Settings $candidate.Settings -Definition $definition -Rule ('Pressure:tier{0}' -f $candidate.Tier) -Confirm:$false -WhatIf:$false
        if ($outcome.Status -eq 'Budget') { return $false }
        if ($Run.ReportOnly -or $Run.WhatIf) { continue }
        if ((Get-DLVolume).FreeBytes -ge $Threshold.TargetBytes) { return $true }
    }
    if ($Run.ReportOnly -or $Run.WhatIf) { return $false }
    return ((Get-DLVolume).FreeBytes -ge $Threshold.TargetBytes)
}

function Remove-DLTouchedDirectory
{
    # Folders emptied by this run's file deletions, and their emptied ancestors, up to (not
    # including) the group root.
    param ([pscustomobject]$Group)

    if ($Group.Touched.Count -eq 0) { return }
    $all = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $rootFull = ConvertTo-DLFullPath -Path $Group.Path
    foreach ($path in $Group.Touched)
    {
        $current = ConvertTo-DLFullPath -Path $path
        while ($current.Length -gt $rootFull.Length -and (Test-DLPathUnder -Path $current -Parent $rootFull))
        {
            [void]$all.Add($current)
            $current = Split-Path -Path $current -Parent
        }
    }
    [void](Remove-DLEmptyDirectory -Path (ConvertTo-DLArray -Value $all) -StopRoot $Group.Path -Confirm:$false -WhatIf:$false)
}

function Test-DLInstallSource
{
    # D8: a C:\Autodesk folder an installed product names as its InstallSource is kept.
    [OutputType([bool])]
    param ([string]$Path)

    if ($null -eq $script:DLInstallSources)
    {
        $sources = New-Object 'System.Collections.Generic.List[string]'
        foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
        {
            foreach ($key in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue))
            {
                try
                {
                    $value = [string](Get-ItemProperty -LiteralPath $key.PSPath -Name 'InstallSource' -ErrorAction Stop).InstallSource
                    if ($value) { $sources.Add($value) }
                }
                catch { continue }
            }
        }
        $script:DLInstallSources = $sources.ToArray()
    }
    foreach ($source in $script:DLInstallSources)
    {
        if ((Test-DLPathUnder -Path $source -Parent $Path) -or (Test-DLPathUnder -Path $Path -Parent $source)) { return $true }
    }
    return $false
}
