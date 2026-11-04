#Requires -Version 5.1
# Phase 1 acceptance tests (docs/PLAN.md 1.1 to 1.21). Every test builds its own sandbox under
# %TEMP%; profiles, processes, free space and machine paths are injected through the module's
# private seams.

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src\engine\DeadLoad\DeadLoad.psd1') -Force

    function script:Set-DLTestEnvironment
    {
        param ([pscustomobject]$Sandbox)

        $script:sb = $Sandbox
        $script:processes = @()
        $script:tracking = $true
        $script:volumeSize = 100MB
        $script:volumeFreeBase = 90MB
        $script:volumeTracked = $null
        $script:volumeTrackedInitial = 0

        Mock -ModuleName DeadLoad Get-DLProfile {
            if ($Current) { return [pscustomobject]@{ Sid = $script:sb.AliceSid; Path = $script:sb.Alice; Loaded = $true } }
            [pscustomobject]@{ Sid = $script:sb.AliceSid; Path = $script:sb.Alice; Loaded = $true }
            [pscustomobject]@{ Sid = $script:sb.BobSid; Path = $script:sb.Bob; Loaded = $true }
        }
        Mock -ModuleName DeadLoad Get-DLMachinePath { @{ WindowsTemp = $script:sb.WindowsTemp; ProgramData = $script:sb.ProgramData; SystemDrive = $script:sb.SystemDrive } }
        Mock -ModuleName DeadLoad Get-DLProcessOwner { $script:processes }
        Mock -ModuleName DeadLoad Test-DLLastAccessTracking { $script:tracking }
        Mock -ModuleName DeadLoad Get-DLDesktopConnectorWorkspace { }
        Mock -ModuleName DeadLoad Get-DLInstalledRevitYear { , [int[]]@(2026) }
        # A simulated volume: free space grows by exactly the bytes removed from the tracked tree.
        Mock -ModuleName DeadLoad Get-DLVolume {
            $free = $script:volumeFreeBase
            if ($script:volumeTracked) { $free += $script:volumeTrackedInitial - (Get-DLTestTreeBytes -Path $script:volumeTracked) }
            [pscustomobject]@{ Drive = [System.IO.Path]::GetPathRoot($script:sb.Root); SizeBytes = [int64]$script:volumeSize; FreeBytes = [int64]$free }
        }
    }

    function script:Get-DLTestTreeBytes
    {
        param ([string]$Path)
        $total = [int64]0
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($Path)
        while ($stack.Count -gt 0)
        {
            foreach ($entry in (New-Object System.IO.DirectoryInfo $stack.Pop()).GetFileSystemInfos())
            {
                if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }
                if ($entry -is [System.IO.DirectoryInfo]) { $stack.Push($entry.FullName) } else { $total += $entry.Length }
            }
        }
        return $total
    }

    function script:Invoke-DLTestRun
    {
        param ([hashtable]$Configuration, [string]$Mode = 'Maintenance', [switch]$ReportOnly, [switch]$WhatIf)
        $result = @(Invoke-DeadLoad -Mode $Mode -Configuration $Configuration -DataRoot $script:sb.Data -NoEventLog -ReportOnly:$ReportOnly -WhatIf:$WhatIf)
        return $result
    }

    function script:Get-DLTestLog
    {
        $log = Get-ChildItem -LiteralPath (Join-Path $script:sb.Data 'logs') -Filter '*.log' | Select-Object -First 1
        return (Get-Content -LiteralPath $log.FullName -Raw)
    }

    # A test category on {LocalAppData}\T\<group> folders, every limit off unless given.
    function script:New-DLTestDefinition
    {
        param ([hashtable]$Settings, [string]$Id = 'test.files', [string]$Root = '{LocalAppData}\T\*', [string]$Unit = 'File', [bool]$Recurse = $true)
        $base = @{ Enabled = 1; AgeDays = 0; AgeBasis = 'Modified'; RoutineAction = 'Delete'; MinAgeHours = 0; ProtectNewest = 0; PressureEnabled = 0 }
        foreach ($key in $Settings.Keys) { $base[$key] = $Settings[$key] }
        return @{ Id = $Id; Scope = 'User'; Unit = $Unit; Recurse = $Recurse; Guarded = $true; Roots = @($Root); Settings = $base }
    }
}

Describe 'Phase 1 safety and retention' {

    BeforeEach {
        Set-DLTestEnvironment -Sandbox (New-DLSandbox)
    }

    AfterEach {
        Remove-DLSandbox -Sandbox $script:sb
    }

    It '1.1 never follows a junction planted inside a target; the canary survives' {
        $temp = Join-Path $script:sb.Alice 'AppData\Local\Temp'
        New-DLTestFile -Path (Join-Path $script:sb.Canary 'precious.txt') -ModifiedDaysAgo 400 | Out-Null
        New-DLTestFile -Path (Join-Path $script:sb.Canary 'sub\deep.txt') -ModifiedDaysAgo 400 | Out-Null
        New-DLJunction -Link (Join-Path $temp 'evil') -Target $script:sb.Canary
        New-DLTestFile -Path (Join-Path $temp 'old.tmp') -ModifiedDaysAgo 30 | Out-Null

        $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Categories @{ 'windows.temp' = @{ Enabled = 0 } })

        Test-Path -LiteralPath (Join-Path $script:sb.Canary 'precious.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:sb.Canary 'sub\deep.txt') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $temp 'evil') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $temp 'old.tmp') | Should -BeFalse
        @($summary[0].Skips | Where-Object { $_.Reason -eq 'Reparse' }).Count | Should -BeGreaterThan 0
    }

    It '1.2 disqualifies a root whose ancestor is a junction; nothing under the link target is touched' {
        $fake = Join-Path $script:sb.Canary 'Autodesk Revit 2026\Journals'
        for ($i = 1; $i -le 5; $i++) { New-DLTestFile -Path (Join-Path $fake ('journal.{0:D4}.txt' -f $i)) -ModifiedDaysAgo (40 + $i) | Out-Null }
        $before = Get-DLTreeState -Path $script:sb.Canary
        New-DLJunction -Link (Join-Path $script:sb.Alice 'AppData\Local\Autodesk\Revit') -Target $script:sb.Canary

        $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Categories @{ 'revit.journals' = @{ ProtectNewest = 0; MinAgeHours = 0 } })

        Get-DLTreeState -Path $script:sb.Canary | Should -Be $before
        @($summary[0].Skips | Where-Object { $_.Reason -eq 'Reparse' -and $_.Detail -eq 'root disqualified' }).Count | Should -BeGreaterThan 0
    }

    It '1.3 skips a locked file and reports Locked, never Failed' {
        $temp = Join-Path $script:sb.Alice 'AppData\Local\Temp'
        $locked = New-DLTestFile -Path (Join-Path $temp 'held.tmp') -ModifiedDaysAgo 30
        New-DLTestFile -Path (Join-Path $temp 'free.tmp') -ModifiedDaysAgo 30 | Out-Null
        $handle = [System.IO.File]::Open($locked.FullName, 'Open', 'ReadWrite', 'None')
        try
        {
            $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration)
        }
        finally { $handle.Dispose() }

        Test-Path -LiteralPath $locked.FullName | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $temp 'free.tmp') | Should -BeFalse
        @($summary[0].Skips | Where-Object { $_.Reason -eq 'Locked' }).Count | Should -Be 1
        $summary[0].Result | Should -BeIn @('Success', 'Partial')
    }

    It '1.4 skips guarded categories of a profile whose user runs Revit; other profiles and user.temp are cleaned' {
        foreach ($user in $script:sb.Alice, $script:sb.Bob)
        {
            New-DLTestFile -Path (Join-Path $user 'AppData\Local\Autodesk\Revit\Autodesk Revit 2026\WebBrowserControl\cache.bin') -ModifiedDaysAgo 30 | Out-Null
            New-DLTestFile -Path (Join-Path $user 'AppData\Local\Temp\old.tmp') -ModifiedDaysAgo 30 | Out-Null
            New-DLTestFile -Path (Join-Path $user 'AppData\Local\Temp\{guid}\RevitSessionTemp') -ModifiedDaysAgo 30 | Out-Null
        }
        $script:processes = @([pscustomobject]@{ Name = 'Revit'; Sid = $script:sb.AliceSid; Path = 'C:\Program Files\Autodesk\Revit 2026\Revit.exe' })

        $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration)

        Test-Path -LiteralPath (Join-Path $script:sb.Alice 'AppData\Local\Autodesk\Revit\Autodesk Revit 2026\WebBrowserControl\cache.bin') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:sb.Bob 'AppData\Local\Autodesk\Revit\Autodesk Revit 2026\WebBrowserControl\cache.bin') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:sb.Alice 'AppData\Local\Temp\old.tmp') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:sb.Bob 'AppData\Local\Temp\old.tmp') | Should -BeFalse
        # D20: the running session's own temp files stay; the idle profile's go.
        Test-Path -LiteralPath (Join-Path $script:sb.Alice 'AppData\Local\Temp\{guid}\RevitSessionTemp') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:sb.Bob 'AppData\Local\Temp\{guid}\RevitSessionTemp') | Should -BeFalse
        Get-DLTestLog | Should -Match 'Protected rule=Process'
    }

    It 'FR-10 raises the Revit.ini journal shelf life, keeps higher values and the encoding, and waits for Revit to close' {
        $iniAlice = Join-Path $script:sb.Alice 'AppData\Roaming\Autodesk\Revit\Autodesk Revit 2026\Revit.ini'
        $iniBob = Join-Path $script:sb.Bob 'AppData\Roaming\Autodesk\Revit\Autodesk Revit 2026\Revit.ini'
        foreach ($ini in $iniAlice, $iniBob)
        {
            [void][System.IO.Directory]::CreateDirectory((Split-Path $ini -Parent))
            [System.IO.File]::WriteAllText($ini, "[Backups]`r`nJournalShelfCapacity=50`r`nSaveReminderMinutes=30`r`n[Other]`r`nKey=1`r`n", (New-Object System.Text.UnicodeEncoding($false, $true)))
        }
        $script:processes = @([pscustomobject]@{ Name = 'Revit'; Sid = $script:sb.AliceSid; Path = 'Revit.exe' })

        Invoke-DLTestRun -Configuration (New-DLTestConfiguration) | Out-Null

        $bytes = [System.IO.File]::ReadAllBytes($iniBob)
        ($bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) | Should -BeTrue
        $text = [System.IO.File]::ReadAllText($iniBob)
        $text | Should -Match 'JournalShelfCapacity=50'
        $text | Should -Match '\[Backups\][^\[]*JournalShelfLife=14'
        $text | Should -Match 'SaveReminderMinutes=30'
        $text | Should -Match '\[Other\]\s+Key=1'
        [System.IO.File]::ReadAllText($iniAlice) | Should -Not -Match 'JournalShelfLife'
    }

    It '1.5 applies the age basis <Basis>' -ForEach @(
        @{ Basis = 'Created'; Tracking = $true; Expect = @('c') }
        @{ Basis = 'Modified'; Tracking = $true; Expect = @('m') }
        @{ Basis = 'Accessed'; Tracking = $true; Expect = @('a') }
        @{ Basis = 'Newest'; Tracking = $true; Expect = @('all') }
        @{ Basis = 'Accessed'; Tracking = $false; Expect = @('m') }
    ) {
        $script:tracking = $Tracking
        $root = Join-Path $script:sb.Alice 'AppData\Local\T\g'
        # Each file is old by exactly one time stamp; 'all' is old by all three.
        New-DLTestFile -Path (Join-Path $root 'c') -CreatedDaysAgo 30 -ModifiedDaysAgo 1 -AccessedDaysAgo 1 | Out-Null
        New-DLTestFile -Path (Join-Path $root 'm') -CreatedDaysAgo 1 -ModifiedDaysAgo 30 -AccessedDaysAgo 1 | Out-Null
        New-DLTestFile -Path (Join-Path $root 'a') -CreatedDaysAgo 1 -ModifiedDaysAgo 1 -AccessedDaysAgo 30 | Out-Null
        New-DLTestFile -Path (Join-Path $root 'all') -CreatedDaysAgo 30 -ModifiedDaysAgo 30 -AccessedDaysAgo 30 | Out-Null
        $definition = New-DLTestDefinition -Settings @{ AgeDays = 10; AgeBasis = $Basis }

        Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Definitions @($definition)) | Out-Null

        $gone = @('c', 'm', 'a', 'all' | Where-Object { -not (Test-Path -LiteralPath (Join-Path $root $_)) })
        $expected = @($Expect)
        if ($Basis -ne 'Newest') { $expected += 'all' }
        ($gone | Sort-Object) -join ',' | Should -Be (($expected | Sort-Object -Unique) -join ',')
        if (-not $Tracking) { Get-DLTestLog | Should -Match 'falls back to Modified' }
    }

    It '1.6 keeps the newest N per <Scope>' -ForEach @(
        @{ Scope = 'Group'; Deleted = 8 }
        @{ Scope = 'User'; Deleted = 14 }
        @{ Scope = 'Machine'; Deleted = 17 }
    ) {
        foreach ($user in $script:sb.Alice, $script:sb.Bob)
        {
            foreach ($group in 'g1', 'g2')
            {
                for ($i = 1; $i -le 5; $i++) { New-DLTestFile -Path (Join-Path $user ('AppData\Local\T\{0}\f{1}' -f $group, $i)) -ModifiedDaysAgo ($i + [array]::IndexOf(@('g1', 'g2'), $group) * 0.1) | Out-Null }
            }
        }
        $definition = New-DLTestDefinition -Settings @{ KeepNewest = 3; LimitScope = $Scope }

        $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Definitions @($definition))

        $summary[0].Totals.DeletedCount | Should -Be $Deleted
    }

    It '1.7 removes the oldest first until the total is under MaxTotalMB' {
        $root = Join-Path $script:sb.Alice 'AppData\Local\T\g'
        for ($i = 1; $i -le 10; $i++) { New-DLTestFile -Path (Join-Path $root ('f{0:D2}' -f $i)) -Bytes 1MB -ModifiedDaysAgo $i | Out-Null }
        $definition = New-DLTestDefinition -Settings @{ MaxTotalMB = 4 }

        Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Definitions @($definition)) | Out-Null

        $left = @(Get-ChildItem -LiteralPath $root | ForEach-Object Name | Sort-Object)
        $left -join ',' | Should -Be 'f01,f02,f03,f04'
    }

    It '1.8 caps a category at MaxSharePercent of <Base>' -ForEach @(
        @{ Base = 'Free'; Percent = 5; Kept = 5 }
        @{ Base = 'Disk'; Percent = 3; Kept = 3 }
    ) {
        $script:volumeSize = 100MB
        $script:volumeFreeBase = 100MB
        $root = Join-Path $script:sb.Alice 'AppData\Local\T\g'
        for ($i = 1; $i -le 10; $i++) { New-DLTestFile -Path (Join-Path $root ('f{0:D2}' -f $i)) -Bytes 1MB -ModifiedDaysAgo $i | Out-Null }
        $definition = New-DLTestDefinition -Settings @{ MaxSharePercent = $Percent; ShareBase = $Base }

        Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Definitions @($definition)) | Out-Null

        @(Get-ChildItem -LiteralPath $root).Count | Should -Be $Kept
        Test-Path -LiteralPath (Join-Path $root 'f01') | Should -BeTrue
    }

    It '1.9 MinAgeHours and ProtectNewest override routine and pressure rules' {
        $root = Join-Path $script:sb.Alice 'AppData\Local\T\g'
        $ages = @(0.5, 1, 3, 4, 5, 6, 7, 8)
        foreach ($age in $ages) { New-DLTestFile -Path (Join-Path $root ('f{0}' -f $age)) -Bytes 1MB -ModifiedDaysAgo $age | Out-Null }
        $definition = New-DLTestDefinition -Settings @{ KeepNewest = 1; MinAgeHours = 48; ProtectNewest = 4; PressureEnabled = 1; PressureTier = 1; PressureAgeDays = 0 }
        $script:volumeFreeBase = 1MB
        $script:volumeTracked = $script:sb.Root
        $script:volumeTrackedInitial = Get-DLTestTreeBytes -Path $script:sb.Root

        $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Definitions @($definition) -Pressure @{ FloorPercent = 50; TargetPercent = 90 })

        $left = @(Get-ChildItem -LiteralPath $root | ForEach-Object Name | Sort-Object)
        $left -join ',' | Should -Be 'f0.5,f1,f3,f4'
        $summary[0].Volume.TargetReached | Should -BeFalse
    }

    It '1.10 combines age, count and size with OR semantics' {
        $root = Join-Path $script:sb.Alice 'AppData\Local\T\g'
        # Sizes make each limit select a different set: age > 8.5 d -> f09,f10; rank >= 6 ->
        # f07..f10; cumulative > 5 MB -> f05..f10 (f05 is the first to cross).
        $sizes = @(1, 1, 1, 1, 2, 1, 1, 1, 1, 1)
        for ($i = 1; $i -le 10; $i++) { New-DLTestFile -Path (Join-Path $root ('f{0:D2}' -f $i)) -Bytes ($sizes[$i - 1] * 1MB) -ModifiedDaysAgo $i | Out-Null }
        $definition = New-DLTestDefinition -Settings @{ AgeDays = 8; KeepNewest = 6; MaxTotalMB = 5 }

        Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Definitions @($definition)) | Out-Null

        $left = @(Get-ChildItem -LiteralPath $root | ForEach-Object Name | Sort-Object)
        $left -join ',' | Should -Be 'f01,f02,f03,f04'
        Get-DLTestLog | Should -Match 'Selected rule=MaxTotalMB path=.*f05'
        Get-DLTestLog | Should -Match 'Selected rule=AgeDays\+KeepNewest\+MaxTotalMB path=.*f09'
    }

    It '1.11 processes pressure tiers in order, oldest first, and stops at the target' {
        $tier1 = Join-Path $script:sb.Alice 'AppData\Local\P1\g'
        $tier2 = Join-Path $script:sb.Alice 'AppData\Local\P2\g'
        foreach ($age in 10, 20, 30) { New-DLTestFile -Path (Join-Path $tier1 ('a{0}' -f $age)) -Bytes 1MB -ModifiedDaysAgo $age | Out-Null }
        foreach ($age in 10, 20, 30) { New-DLTestFile -Path (Join-Path $tier2 ('b{0}' -f $age)) -Bytes 1MB -ModifiedDaysAgo $age | Out-Null }
        $definitions = @(
            (New-DLTestDefinition -Id 'test.tier2' -Root '{LocalAppData}\P2\*' -Settings @{ RoutineAction = 'None'; PressureEnabled = 1; PressureTier = 2; PressureAgeDays = 1 })
            (New-DLTestDefinition -Id 'test.tier1' -Root '{LocalAppData}\P1\*' -Settings @{ RoutineAction = 'None'; PressureEnabled = 1; PressureTier = 1; PressureAgeDays = 1 })
        )
        $script:volumeFreeBase = 10MB
        $script:volumeTracked = $script:sb.Root
        $script:volumeTrackedInitial = Get-DLTestTreeBytes -Path $script:sb.Root

        $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Definitions $definitions -Pressure @{ FloorPercent = 12; TargetPercent = 14 })

        @(Get-ChildItem -LiteralPath $tier1).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath $tier2 | ForEach-Object Name | Sort-Object) -join ',' | Should -Be 'b10,b20'
        $summary[0].Volume.TargetReached | Should -BeTrue
        Get-DLTestLog | Should -Match 'EVENT 2001'
    }

    It '1.11 reports 2002 when eligible items run out before the target' {
        $tier1 = Join-Path $script:sb.Alice 'AppData\Local\P1\g'
        foreach ($age in 10, 20) { New-DLTestFile -Path (Join-Path $tier1 ('a{0}' -f $age)) -Bytes 1MB -ModifiedDaysAgo $age | Out-Null }
        $definitions = @((New-DLTestDefinition -Id 'test.tier1' -Root '{LocalAppData}\P1\*' -Settings @{ RoutineAction = 'None'; PressureEnabled = 1; PressureTier = 1; PressureAgeDays = 1 }))
        $script:volumeFreeBase = 10MB
        $script:volumeTracked = $script:sb.Root
        $script:volumeTrackedInitial = Get-DLTestTreeBytes -Path $script:sb.Root

        $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Definitions $definitions -Pressure @{ FloorPercent = 12; TargetPercent = 50 })

        @(Get-ChildItem -LiteralPath $tier1).Count | Should -Be 0
        $summary[0].Volume.TargetReached | Should -BeFalse
        $summary[0].Result | Should -Be 'Partial'
        Get-DLTestLog | Should -Match 'EVENT 2002'
    }

    It '1.12 runs an ActivateBelow rule only below its threshold (free <Free> MB)' -ForEach @(
        @{ Free = 60MB; Deleted = $false }
        @{ Free = 40MB; Deleted = $true }
    ) {
        $script:volumeSize = 100MB
        $script:volumeFreeBase = $Free
        $file = New-DLTestFile -Path (Join-Path $script:sb.Alice 'AppData\Local\T\g\old') -ModifiedDaysAgo 30
        $definition = New-DLTestDefinition -Settings @{ AgeDays = 7; ActivateBelowPercent = 50 }

        Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Definitions @($definition)) | Out-Null

        (Test-Path -LiteralPath $file.FullName) | Should -Be (-not $Deleted)
    }

    It '1.13 compresses journals into verified monthly archives and expires old archives' {
        $journals = Join-Path $script:sb.Alice 'AppData\Local\Autodesk\Revit\Autodesk Revit 2026\Journals'
        $expected = @{}
        for ($i = 0; $i -lt 60; $i++)
        {
            $name = 'journal.{0:D4}.txt' -f (60 - $i)
            $file = New-DLTestFile -Path (Join-Path $journals $name) -Bytes 4096 -ModifiedDaysAgo ($i + 0.5)
            if ($i -ge 5)
            {
                $month = $file.LastWriteTimeUtc.ToLocalTime().ToString('yyyy-MM')
                if (-not $expected.ContainsKey($month)) { $expected[$month] = New-Object 'System.Collections.Generic.List[string]' }
                $expected[$month].Add($name)
            }
        }
        $oldArchive = Join-Path $journals 'Archive\journals-2020-01.zip'
        [void][System.IO.Directory]::CreateDirectory((Split-Path $oldArchive -Parent))
        $zip = [System.IO.Compression.ZipFile]::Open($oldArchive, 'Create'); $zip.Dispose()
        [System.IO.File]::SetLastWriteTimeUtc($oldArchive, [datetime]::UtcNow.AddDays(-200))
        $settings = @{ AgeDays = 3; MinAgeHours = 48; ProtectNewest = 5 }

        $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Categories @{ 'revit.journals' = $settings; 'revit.journals.archive' = @{ ProtectNewest = 0 } })

        @(Get-ChildItem -LiteralPath $journals -Filter 'journal.*.txt' | ForEach-Object Name | Sort-Object) -join ',' | Should -Be 'journal.0056.txt,journal.0057.txt,journal.0058.txt,journal.0059.txt,journal.0060.txt'
        foreach ($month in $expected.Keys)
        {
            $archive = [System.IO.Compression.ZipFile]::OpenRead((Join-Path $journals ('Archive\journals-{0}.zip' -f $month)))
            try { @($archive.Entries | ForEach-Object FullName | Sort-Object) -join ',' | Should -Be (@($expected[$month] | Sort-Object) -join ',') }
            finally { $archive.Dispose() }
        }
        Test-Path -LiteralPath $oldArchive | Should -BeFalse
        $summary[0].Totals.CompressedCount | Should -Be 55
        $summary[0].Totals.FailedCount | Should -Be 0
    }

    It '1.14 keeps the original when the archive entry fails verification' {
        $journals = Join-Path $script:sb.Alice 'AppData\Local\Autodesk\Revit\Autodesk Revit 2026\Journals'
        $file = New-DLTestFile -Path (Join-Path $journals 'journal.0001.txt') -Bytes 4096 -ModifiedDaysAgo 10
        Mock -ModuleName DeadLoad Add-DLArchiveEntry {
            [void][System.IO.Directory]::CreateDirectory((Split-Path $ArchivePath -Parent))
            $zip = [System.IO.Compression.ZipFile]::Open($ArchivePath, 'Update')
            try
            {
                $stream = $zip.CreateEntry($EntryName).Open()
                $stream.Write([byte[]](1, 2, 3), 0, 3)
                $stream.Dispose()
            }
            finally { $zip.Dispose() }
            [pscustomobject]@{ EntryName = $EntryName; GrowthBytes = 3 }
        }

        $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Categories @{ 'revit.journals' = @{ ProtectNewest = 0; MinAgeHours = 0 } })

        Test-Path -LiteralPath $file.FullName | Should -BeTrue
        @($summary[0].Failures | Where-Object { $_.Message -match 'verification' }).Count | Should -Be 1
        $summary[0].Totals.CompressedCount | Should -Be 0
    }

    It '1.15 copies and moves to a local destination, verified and idempotent (<Action>)' -ForEach @(
        @{ Action = 'Copy' }
        @{ Action = 'Move' }
    ) {
        $root = Join-Path $script:sb.Alice 'AppData\Local\T\g'
        New-DLTestFile -Path (Join-Path $root 'sub\f1') -Bytes 2048 -ModifiedDaysAgo 30 | Out-Null
        $destination = Join-Path $script:sb.Root 'Dest\{User}\{Category}'
        $definition = New-DLTestDefinition -Settings @{ AgeDays = 7; RoutineAction = $Action; Destination = $destination }
        $config = New-DLTestConfiguration -Definitions @($definition)

        $first = Invoke-DLTestRun -Configuration $config
        $copied = Join-Path $script:sb.Root 'Dest\alice\test.files\sub\f1'
        Test-Path -LiteralPath $copied | Should -BeTrue
        (Get-FileHash -LiteralPath $copied).Hash.Length | Should -Be 64
        $first[0].Totals.FailedCount | Should -Be 0
        if ($Action -eq 'Copy')
        {
            Test-Path -LiteralPath (Join-Path $root 'sub\f1') | Should -BeTrue
            $second = Invoke-DLTestRun -Configuration $config
            $second[0].Totals.FailedCount | Should -Be 0
            $second[0].Totals.CopiedCount | Should -Be 1
        }
        else
        {
            Test-Path -LiteralPath (Join-Path $root 'sub\f1') | Should -BeFalse
            $first[0].Totals.MovedCount | Should -Be 1
        }
    }

    It '1.16 never touches protected patterns in Journals or Temp' {
        $journals = Join-Path $script:sb.Alice 'AppData\Local\Autodesk\Revit\Autodesk Revit 2026\Journals'
        $temp = Join-Path $script:sb.Alice 'AppData\Local\Temp'
        $kept = @(
            (New-DLTestFile -Path (Join-Path $journals 'Model_backup.rvt') -ModifiedDaysAgo 90)
            (New-DLTestFile -Path (Join-Path $journals 'Family.rfa') -ModifiedDaysAgo 90)
            (New-DLTestFile -Path (Join-Path $temp 'Drawing1.dwg') -ModifiedDaysAgo 90)
            (New-DLTestFile -Path (Join-Path $temp 'Drawing1.bak') -ModifiedDaysAgo 90)
        )
        New-DLTestFile -Path (Join-Path $temp 'junk.tmp') -ModifiedDaysAgo 90 | Out-Null
        $script:volumeFreeBase = 1MB
        $config = New-DLTestConfiguration -Categories @{ 'revit.journals' = @{ ProtectNewest = 0; MinAgeHours = 0; RoutineAction = 'Delete' } } -Pressure @{ FloorPercent = 50; TargetPercent = 90 }

        Invoke-DLTestRun -Configuration $config | Out-Null

        foreach ($file in $kept) { Test-Path -LiteralPath $file.FullName | Should -BeTrue }
        Test-Path -LiteralPath (Join-Path $temp 'junk.tmp') | Should -BeFalse
    }

    It '1.17 stops cleanly at the <Budget> budget with partial totals' -ForEach @(
        @{ Budget = 'item'; General = @{ MaxItemsPerRun = 3 }; Deleted = 3; Flag = 'ItemsExhausted' }
        @{ Budget = 'byte'; General = @{ MaxDeleteMBPerRun = 2 }; Deleted = 2; Flag = 'BytesExhausted' }
    ) {
        $temp = Join-Path $script:sb.Alice 'AppData\Local\Temp'
        for ($i = 1; $i -le 10; $i++) { New-DLTestFile -Path (Join-Path $temp ('f{0:D2}.tmp' -f $i)) -Bytes 1MB -ModifiedDaysAgo (10 + $i) | Out-Null }

        $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration -General $General)

        $summary[0].Totals.DeletedCount | Should -Be $Deleted
        $summary[0].Budget.$Flag | Should -BeTrue
        $summary[0].Result | Should -Be 'Partial'
        @(Get-ChildItem -LiteralPath $temp).Count | Should -Be (10 - $Deleted)
    }

    It '1.18 plans fully and changes nothing in <Mode>' -ForEach @(
        @{ Mode = 'report-only' }
        @{ Mode = 'what-if' }
    ) {
        $temp = Join-Path $script:sb.Alice 'AppData\Local\Temp'
        for ($i = 1; $i -le 5; $i++) { New-DLTestFile -Path (Join-Path $temp ('f{0}.tmp' -f $i)) -ModifiedDaysAgo 30 | Out-Null }
        New-DLTestFile -Path (Join-Path $script:sb.Alice 'AppData\Local\Autodesk\Revit\Autodesk Revit 2026\Journals\journal.0001.txt') -ModifiedDaysAgo 30 | Out-Null
        # Hashing the tree reads every file, which refreshes last access; judge by write time.
        $script:tracking = $false
        $before = Get-DLTreeState -Path (Join-Path $script:sb.Root 'Users')

        if ($Mode -eq 'report-only') { $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Categories @{ 'revit.journals' = @{ ProtectNewest = 0 } }) -ReportOnly }
        else { $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Categories @{ 'revit.journals' = @{ ProtectNewest = 0 } }) -WhatIf }

        Get-DLTreeState -Path (Join-Path $script:sb.Root 'Users') | Should -Be $before
        $summary[0].Totals.CandidateCount | Should -BeGreaterOrEqual 6
        $summary[0].Totals.DeletedCount | Should -Be 0
        Get-DLTestLog | Should -Match 'WouldAct'
    }

    It '1.19 emits exactly one DeadLoad.RunSummary on the output stream' {
        New-DLTestFile -Path (Join-Path $script:sb.Alice 'AppData\Local\Temp\f.tmp') -ModifiedDaysAgo 30 | Out-Null
        $output = @(Invoke-DeadLoad -Configuration (New-DLTestConfiguration) -DataRoot $script:sb.Data -NoEventLog -Verbose 4>$null)
        $output.Count | Should -Be 1
        $output[0].PSObject.TypeNames | Should -Contain 'DeadLoad.RunSummary'
    }

    It '1.21 reports freed bytes equal to confirmed deletions, the locked file excluded' {
        $temp = Join-Path $script:sb.Alice 'AppData\Local\Temp'
        $sizes = @(1000, 2000, 3000, 4000)
        for ($i = 0; $i -lt 4; $i++) { New-DLTestFile -Path (Join-Path $temp ('f{0}.tmp' -f $i)) -Bytes $sizes[$i] -ModifiedDaysAgo 30 | Out-Null }
        $handle = [System.IO.File]::Open((Join-Path $temp 'f3.tmp'), 'Open', 'ReadWrite', 'None')
        try { $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration) }
        finally { $handle.Dispose() }

        $summary[0].Totals.FreedBytes | Should -Be 6000
        $summary[0].Totals.DeletedCount | Should -Be 3
    }
}

Describe '1.20 No network during a run' {

    BeforeAll {
        if (-not ('DeadLoadTests.SentinelProxy' -as [type]))
        {
            Add-Type -TypeDefinition @'
namespace DeadLoadTests
{
    public class SentinelProxy : System.Net.IWebProxy
    {
        public static int Calls;
        public System.Net.ICredentials Credentials { get; set; }
        public System.Uri GetProxy(System.Uri destination) { Calls++; return destination; }
        public bool IsBypassed(System.Uri host) { Calls++; return false; }
    }
}
'@
        }
    }

    BeforeEach {
        Set-DLTestEnvironment -Sandbox (New-DLSandbox)
        $script:savedProxy = [System.Net.WebRequest]::DefaultWebProxy
        [System.Net.WebRequest]::DefaultWebProxy = New-Object DeadLoadTests.SentinelProxy
        $script:httpProxyType = 'System.Net.Http.HttpClient' -as [type]
        if ($script:httpProxyType -and $script:httpProxyType.GetProperty('DefaultProxy'))
        {
            $script:savedHttpProxy = [System.Net.Http.HttpClient]::DefaultProxy
            [System.Net.Http.HttpClient]::DefaultProxy = New-Object DeadLoadTests.SentinelProxy
        }
        [DeadLoadTests.SentinelProxy]::Calls = 0
        foreach ($command in 'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer', 'Test-NetConnection', 'Resolve-DnsName')
        {
            Mock -ModuleName DeadLoad $command { throw ('network command called: {0}' -f $MyInvocation.MyCommand.Name) }
        }
    }

    AfterEach {
        [System.Net.WebRequest]::DefaultWebProxy = $script:savedProxy
        if ($script:httpProxyType -and $script:httpProxyType.GetProperty('DefaultProxy')) { [System.Net.Http.HttpClient]::DefaultProxy = $script:savedHttpProxy }
        Remove-DLSandbox -Sandbox $script:sb
    }

    It 'makes no web call and uses no proxy during a full run' {
        New-DLTestFile -Path (Join-Path $script:sb.Alice 'AppData\Local\Temp\f.tmp') -ModifiedDaysAgo 30 | Out-Null
        New-DLTestFile -Path (Join-Path $script:sb.Alice 'AppData\Local\Autodesk\Revit\Autodesk Revit 2026\Journals\journal.0001.txt') -ModifiedDaysAgo 30 | Out-Null

        $summary = Invoke-DLTestRun -Configuration (New-DLTestConfiguration -Categories @{ 'revit.journals' = @{ ProtectNewest = 0; MinAgeHours = 0 } })

        $summary[0].Result | Should -Be 'Success'
        [DeadLoadTests.SentinelProxy]::Calls | Should -Be 0
        foreach ($command in 'Invoke-WebRequest', 'Invoke-RestMethod', 'Start-BitsTransfer') { Should -Invoke -ModuleName DeadLoad $command -Times 0 -Exactly }
    }

    It 'contains no web client in the engine source' {
        $source = Get-ChildItem -Path (Join-Path $script:RepoRoot 'src\engine') -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' } | ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }
        ($source -join "`n") | Should -Not -Match '(?i)Invoke-WebRequest|Invoke-RestMethod|Net\.WebClient|HttpClient|WebRequest\]|Start-BitsTransfer|Net\.Sockets'
    }
}
