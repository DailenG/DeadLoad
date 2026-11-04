#Requires -Version 5.1
# Design slice 3: the user's cleanup review (ARCHITECTURE D22, D23; docs/design/ENGINE-UI-CONTRACT.md).
# Invoke-DeadLoadAnalysis and Invoke-DeadLoadCleanup run in process against a sandbox; profiles,
# processes, free space and machine paths come through the module's private seams, as in the
# phase 1 safety tests. The current profile is alice; bob's profile must never change.

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    Import-Module (Join-Path $script:RepoRoot 'src\engine\DeadLoad\DeadLoad.psd1') -Force

    function script:Set-DLTestEnvironment
    {
        param ([pscustomobject]$Sandbox)

        $script:sb = $Sandbox
        $script:processes = @()
        # Hashing a tree for a before/after comparison reads every file; judge by write time.
        $script:tracking = $false

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
        Mock -ModuleName DeadLoad Get-DLVolume { [pscustomobject]@{ Drive = [System.IO.Path]::GetPathRoot($script:sb.Root); SizeBytes = [int64]100MB; FreeBytes = [int64]90MB } }
    }

    function script:Invoke-DLTestAnalysis
    {
        param ([hashtable]$Configuration = (New-DLTestConfiguration))
        return (Invoke-DeadLoadAnalysis -Configuration $Configuration -DataRoot $script:sb.Data -NoEventLog)
    }

    function script:Invoke-DLTestCleanup
    {
        param ([string[]]$Category, [hashtable]$Configuration = (New-DLTestConfiguration), [string]$AnalysisId)
        $parameters = @{ Category = $Category; Configuration = $Configuration; DataRoot = $script:sb.Data; NoEventLog = $true }
        if ($AnalysisId) { $parameters.AnalysisId = $AnalysisId }
        return (Invoke-DeadLoadCleanup @parameters)
    }

    function script:Get-DLTestCategory
    {
        param ([object]$Analysis, [string]$Id)
        return (@($Analysis.categories | Where-Object { $_.id -eq $Id }) | Select-Object -First 1)
    }

    function script:Read-DLTestJson
    {
        param ([string]$Path)
        return ([System.IO.File]::ReadAllText($Path) | ConvertFrom-Json)
    }

    function script:Get-DLAliceTemp { Join-Path $script:sb.Alice 'AppData\Local\Temp' }
    function script:Get-DLAliceWebCache { Join-Path $script:sb.Alice 'AppData\Local\Autodesk\Revit\Autodesk Revit 2026\WebBrowserControl' }
    function script:Get-DLAliceJournals { Join-Path $script:sb.Alice 'AppData\Local\Autodesk\Revit\Autodesk Revit 2026\Journals' }

    function script:Set-DLTestFolderAge
    {
        param ([string]$Path, [double]$DaysAgo)
        $when = [datetime]::UtcNow.AddDays(-$DaysAgo)
        [System.IO.Directory]::SetCreationTimeUtc($Path, $when)
        [System.IO.Directory]::SetLastWriteTimeUtc($Path, $when)
        [System.IO.Directory]::SetLastAccessTimeUtc($Path, $when)
    }
}

Describe 'User cleanup review: Analyze' {
    BeforeEach { Set-DLTestEnvironment -Sandbox (New-DLSandbox) }
    AfterEach { Remove-DLSandbox -Sandbox $script:sb }

    It 'lists Routine selected, Review unselected and Restricted unavailable, and changes nothing' {
        $old = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'old.tmp') -Bytes 3000 -ModifiedDaysAgo 30
        New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'young.tmp') -ModifiedDaysAgo 0.1 | Out-Null
        $cache = New-DLTestFile -Path (Join-Path (Get-DLAliceWebCache) 'cache.bin') -Bytes 2000 -ModifiedDaysAgo 30
        New-DLTestFile -Path (Join-Path (Get-DLAliceJournals) 'journal.0001.txt') -ModifiedDaysAgo 30 | Out-Null
        New-DLTestFile -Path (Join-Path $script:sb.Bob 'AppData\Local\Temp\bob.tmp') -ModifiedDaysAgo 30 | Out-Null
        New-DLTestFile -Path (Join-Path $script:sb.WindowsTemp 'machine.tmp') -ModifiedDaysAgo 30 | Out-Null
        $beforeUsers = Get-DLTreeState -Path (Join-Path $script:sb.Root 'Users')

        $analysis = Invoke-DLTestAnalysis

        $analysis.Path | Should -Be (Join-Path $script:sb.Data 'analysis.json')
        $file = Read-DLTestJson -Path $analysis.Path
        $file.schemaVersion | Should -Be 1
        $file.analysisId | Should -Be $analysis.analysisId
        $file.result | Should -Be 'Success'

        $temp = Get-DLTestCategory -Analysis $file -Id 'user.temp'
        $temp.risk | Should -Be 'Routine'
        $temp.available | Should -BeTrue
        $temp.defaultSelected | Should -BeTrue
        $temp.displayName | Should -Be 'Temporary files'
        $temp.itemCount | Should -Be 1
        $temp.estimatedBytes | Should -Be 3000
        $temp.items[0].path | Should -Be $old.FullName
        $temp.items[0].bytes | Should -Be 3000
        $temp.items[0].reason | Should -Be 'AgeDays'
        $temp.items[0].reasonText | Should -Be 'Not used in the last 7 days.'
        $temp.items[0].fingerprint | Should -Not -BeNullOrEmpty

        $web = Get-DLTestCategory -Analysis $file -Id 'revit.webcache'
        $web.risk | Should -Be 'Review'
        $web.available | Should -BeTrue
        $web.defaultSelected | Should -BeFalse
        $web.itemCount | Should -Be 1
        $web.items[0].path | Should -Be $cache.FullName

        foreach ($id in 'revit.journals', 'revit.journals.archive', 'revit.ini.journalshelf')
        {
            $restricted = Get-DLTestCategory -Analysis $file -Id $id
            $restricted.risk | Should -Be 'Restricted' -Because $id
            $restricted.available | Should -BeFalse -Because $id
            $restricted.unavailableReason | Should -Be 'Restricted' -Because $id
            $restricted.unavailableText | Should -Not -BeNullOrEmpty -Because $id
            $restricted.defaultSelected | Should -BeFalse -Because $id
            @($restricted.items).Count | Should -Be 0 -Because $id
        }
        # Machine-wide and disabled categories are not part of the user's review.
        Get-DLTestCategory -Analysis $file -Id 'windows.temp' | Should -BeNullOrEmpty
        Get-DLTestCategory -Analysis $file -Id 'revit.collabcache' | Should -BeNullOrEmpty

        $file.totals.itemCount | Should -Be 2
        $file.totals.estimatedBytes | Should -Be 5000
        $file.totals.selectedItemCount | Should -Be 1
        $file.totals.selectedBytes | Should -Be 3000
        [System.IO.File]::ReadAllText($analysis.Path) | Should -Not -Match 'bob'

        Get-DLTreeState -Path (Join-Path $script:sb.Root 'Users') | Should -Be $beforeUsers
        Test-Path -LiteralPath (Join-Path $script:sb.WindowsTemp 'machine.tmp') | Should -BeTrue
    }

    It 'reports guarded files as held back while the user runs Revit' {
        New-DLTestFile -Path (Join-Path (Get-DLAliceWebCache) 'cache.bin') -Bytes 2000 -ModifiedDaysAgo 30 | Out-Null
        $script:processes = @([pscustomobject]@{ Name = 'Revit'; Sid = $script:sb.AliceSid; Path = 'C:\Program Files\Autodesk\Revit 2026\Revit.exe' })

        $analysis = Invoke-DLTestAnalysis

        $web = Get-DLTestCategory -Analysis $analysis -Id 'revit.webcache'
        $web.itemCount | Should -Be 0
        $web.guardedSkipped.reason | Should -Be 'Process'
        $web.guardedSkipped.itemCount | Should -Be 1
        $web.guardedSkipped.bytes | Should -Be 2000
        $web.guardedSkipped.message | Should -Match 'Revit or AutoCAD is running'
    }

    It 'offers the pressure-only PacCache at its pressure age' {
        $pac = Join-Path $script:sb.Alice 'AppData\Local\Autodesk\Revit\PacCache'
        $old = New-DLTestFile -Path (Join-Path $pac 'a\old.pac') -ModifiedDaysAgo 10
        New-DLTestFile -Path (Join-Path $pac 'a\recent.pac') -ModifiedDaysAgo 3 | Out-Null
        New-DLTestFile -Path (Join-Path $pac 'index.json') -ModifiedDaysAgo 30 | Out-Null

        $analysis = Invoke-DLTestAnalysis

        $category = Get-DLTestCategory -Analysis $analysis -Id 'revit.paccache'
        $category.risk | Should -Be 'Review'
        $category.available | Should -BeTrue
        $category.ageDays | Should -Be 7
        @($category.items | ForEach-Object { $_.path }) | Should -Be @($old.FullName)
    }

    It 'lists a custom target that does not delete as unavailable' {
        $config = New-DLTestConfiguration
        $config.CustomTargets = @{ Keep = 'Path={LocalAppData}\Example;Action=Copy;AgeDays=5'; Drop = 'Path={LocalAppData}\Other;Action=Delete;AgeDays=5' }
        $analysis = Invoke-DLTestAnalysis -Configuration $config

        $keep = Get-DLTestCategory -Analysis $analysis -Id 'custom.Keep'
        $keep.available | Should -BeFalse
        $keep.unavailableReason | Should -Be 'NotDelete'
        $drop = Get-DLTestCategory -Analysis $analysis -Id 'custom.Drop'
        $drop.risk | Should -Be 'Review'
        $drop.available | Should -BeTrue
        $drop.defaultSelected | Should -BeFalse
    }

    It 'returns Disabled with no items when the engine is disabled' {
        New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'old.tmp') -ModifiedDaysAgo 30 | Out-Null
        $analysis = Invoke-DLTestAnalysis -Configuration (New-DLTestConfiguration -General @{ Enabled = 0 })

        $analysis.result | Should -Be 'Disabled'
        $analysis.totals.itemCount | Should -Be 0
        (Get-DLTestCategory -Analysis $analysis -Id 'user.temp').itemCount | Should -Be 0
    }
}

Describe 'User cleanup review: Clean' {
    BeforeEach { Set-DLTestEnvironment -Sandbox (New-DLSandbox) }
    AfterEach { Remove-DLSandbox -Sandbox $script:sb }

    It 'deletes only the reviewed items: one added after Analyze stays, other profiles are untouched' {
        $a = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'a.tmp') -Bytes 1000 -ModifiedDaysAgo 30
        $b = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'sub\b.tmp') -Bytes 2000 -ModifiedDaysAgo 30
        $cache = New-DLTestFile -Path (Join-Path (Get-DLAliceWebCache) 'cache.bin') -ModifiedDaysAgo 30
        New-DLTestFile -Path (Join-Path $script:sb.Bob 'AppData\Local\Temp\bob.tmp') -ModifiedDaysAgo 30 | Out-Null
        $bobBefore = Get-DLTreeState -Path $script:sb.Bob
        $analysis = Invoke-DLTestAnalysis
        $late = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'late.tmp') -ModifiedDaysAgo 30

        $cleanup = Invoke-DLTestCleanup -Category 'user.temp' -AnalysisId $analysis.analysisId

        $cleanup.result | Should -Be 'Success'
        Test-Path -LiteralPath $a.FullName | Should -BeFalse
        Test-Path -LiteralPath $b.FullName | Should -BeFalse
        Test-Path -LiteralPath $late.FullName | Should -BeTrue
        Test-Path -LiteralPath $cache.FullName | Should -BeTrue
        Get-DLTreeState -Path $script:sb.Bob | Should -Be $bobBefore

        $cleanup.deletedCount | Should -Be 2
        $cleanup.skippedCount | Should -Be 0
        $cleanup.freedBytes | Should -Be 3000
        $cleanup.estimatedBytes | Should -Be 3000
        $cleanup.analysisId | Should -Be $analysis.analysisId
        $cleanup.Path | Should -Be (Join-Path $script:sb.Data 'last-cleanup.json')
        $file = Read-DLTestJson -Path $cleanup.Path
        @($file.deleted | ForEach-Object { $_.path } | Sort-Object) | Should -Be @(@($a.FullName, $b.FullName) | Sort-Object)
    }

    It 'skips and reports an item made recent, changed or locked after Analyze' {
        $a = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'a.tmp') -Bytes 1000 -ModifiedDaysAgo 30
        $b = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'b.tmp') -Bytes 2000 -ModifiedDaysAgo 30
        $c = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'c.tmp') -Bytes 4000 -ModifiedDaysAgo 30
        $d = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'd.tmp') -Bytes 8000 -ModifiedDaysAgo 30
        $analysis = Invoke-DLTestAnalysis
        (Get-DLTestCategory -Analysis $analysis -Id 'user.temp').itemCount | Should -Be 4
        # b is used again; d is rewritten but keeps an old write time, so only the review notices.
        [System.IO.File]::SetLastWriteTimeUtc($b.FullName, [datetime]::UtcNow)
        $written = [System.IO.File]::GetLastWriteTimeUtc($d.FullName)
        [System.IO.File]::AppendAllText($d.FullName, 'more')
        [System.IO.File]::SetLastWriteTimeUtc($d.FullName, $written)

        $handle = [System.IO.File]::Open($c.FullName, 'Open', 'ReadWrite', 'None')
        try { $cleanup = Invoke-DLTestCleanup -Category 'user.temp' }
        finally { $handle.Dispose() }

        $cleanup.result | Should -Be 'Partial'
        Test-Path -LiteralPath $a.FullName | Should -BeFalse
        foreach ($kept in $b, $c, $d) { Test-Path -LiteralPath $kept.FullName | Should -BeTrue -Because $kept.Name }
        $cleanup.deletedCount | Should -Be 1
        $cleanup.freedBytes | Should -Be 1000
        $cleanup.skippedCount | Should -Be 3
        $reasons = @{}
        foreach ($skip in $cleanup.skipped) { $reasons[$skip.path] = $skip.reason }
        $reasons[$b.FullName] | Should -Be 'MinAgeHours'
        $reasons[$c.FullName] | Should -Be 'Locked'
        $reasons[$d.FullName] | Should -Be 'ChangedSinceAnalysis'
        @($cleanup.skipped | Where-Object { -not $_.reasonText }).Count | Should -Be 0
    }

    It 'refuses a request naming a <Kind> category and deletes nothing' -ForEach @(
        @{ Kind = 'Restricted'; Id = 'revit.journals'; Reason = 'Restricted' }
        @{ Kind = 'machine-wide'; Id = 'windows.temp'; Reason = 'MachineScope' }
        @{ Kind = 'unknown'; Id = 'no.such.category'; Reason = 'not a category' }
    ) {
        $temp = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'old.tmp') -ModifiedDaysAgo 30
        $journal = New-DLTestFile -Path (Join-Path (Get-DLAliceJournals) 'journal.0001.txt') -ModifiedDaysAgo 30
        $machine = New-DLTestFile -Path (Join-Path $script:sb.WindowsTemp 'machine.tmp') -ModifiedDaysAgo 30
        Invoke-DLTestAnalysis | Out-Null

        $cleanup = Invoke-DLTestCleanup -Category 'user.temp', $Id

        $cleanup.result | Should -Be 'Refused'
        $cleanup.Path | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path $script:sb.Data 'last-cleanup.json') | Should -BeFalse
        $cleanup.reason | Should -Match ([regex]::Escape($Id))
        $cleanup.reason | Should -Match $Reason
        $cleanup.deletedCount | Should -Be 0
        Test-Path -LiteralPath $temp.FullName | Should -BeTrue
        Test-Path -LiteralPath $journal.FullName | Should -BeTrue
        Test-Path -LiteralPath $machine.FullName | Should -BeTrue
    }

    It 'refuses when the analysis is missing or is not the one reviewed' {
        $temp = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'old.tmp') -ModifiedDaysAgo 30

        $missing = Invoke-DLTestCleanup -Category 'user.temp'
        $missing.result | Should -Be 'Refused'
        $missing.reason | Should -Match 'Analyze'

        Invoke-DLTestAnalysis | Out-Null
        $stale = Invoke-DLTestCleanup -Category 'user.temp' -AnalysisId 'some-other-analysis'
        $stale.result | Should -Be 'Refused'
        $stale.reason | Should -Match 'changed since'
        Test-Path -LiteralPath $temp.FullName | Should -BeTrue
    }

    It 'never lets an edited analysis widen the cleanup beyond the fresh plan' {
        $temp = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'old.tmp') -ModifiedDaysAgo 30
        $young = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'young.tmp') -ModifiedDaysAgo 0.1
        $bob = New-DLTestFile -Path (Join-Path $script:sb.Bob 'AppData\Local\Temp\bob.tmp') -ModifiedDaysAgo 30
        $canary = New-DLTestFile -Path (Join-Path $script:sb.Canary 'precious.txt') -ModifiedDaysAgo 400
        $analysis = Invoke-DLTestAnalysis
        $file = Read-DLTestJson -Path $analysis.Path
        $category = Get-DLTestCategory -Analysis $file -Id 'user.temp'
        $extra = @(foreach ($target in $young, $bob, $canary)
            {
                [pscustomobject]@{ path = $target.FullName; kind = 'File'; bytes = $target.Length; lastWriteUtc = $target.LastWriteTimeUtc.ToString('o'); reason = 'AgeDays'; reasonText = 'x'; fingerprint = ('{0}:{1}' -f $target.Length, $target.LastWriteTimeUtc.Ticks) }
            })
        $category.items = @($category.items) + $extra
        [System.IO.File]::WriteAllText($analysis.Path, ($file | ConvertTo-Json -Depth 10))

        $cleanup = Invoke-DLTestCleanup -Category 'user.temp'

        Test-Path -LiteralPath $temp.FullName | Should -BeFalse
        Test-Path -LiteralPath $young.FullName | Should -BeTrue
        Test-Path -LiteralPath $bob.FullName | Should -BeTrue
        Test-Path -LiteralPath $canary.FullName | Should -BeTrue
        $cleanup.deletedCount | Should -Be 1
        $reasons = @{}
        foreach ($skip in $cleanup.skipped) { $reasons[$skip.path] = $skip.reason }
        $reasons[$young.FullName] | Should -Be 'MinAgeHours'
        $reasons[$bob.FullName] | Should -Be 'Missing'
        $reasons[$canary.FullName] | Should -Be 'Missing'
    }

    It 'cleans a Review category only when it is named' {
        $temp = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'old.tmp') -ModifiedDaysAgo 30
        $cache = New-DLTestFile -Path (Join-Path (Get-DLAliceWebCache) 'cache.bin') -ModifiedDaysAgo 30
        $analysis = Invoke-DLTestAnalysis

        Invoke-DLTestCleanup -Category 'user.temp' | Out-Null
        Test-Path -LiteralPath $temp.FullName | Should -BeFalse
        Test-Path -LiteralPath $cache.FullName | Should -BeTrue

        $cleanup = Invoke-DLTestCleanup -Category 'revit.webcache' -AnalysisId $analysis.analysisId
        $cleanup.result | Should -Be 'Success'
        Test-Path -LiteralPath $cache.FullName | Should -BeFalse
    }

    It 'accepts the categories as one comma-separated string, as powershell.exe -File passes them' {
        $temp = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'old.tmp') -ModifiedDaysAgo 30
        $cache = New-DLTestFile -Path (Join-Path (Get-DLAliceWebCache) 'cache.bin') -ModifiedDaysAgo 30
        Invoke-DLTestAnalysis | Out-Null

        $cleanup = Invoke-DLTestCleanup -Category 'user.temp,revit.webcache'

        $cleanup.deletedCount | Should -Be 2
        Test-Path -LiteralPath $temp.FullName | Should -BeFalse
        Test-Path -LiteralPath $cache.FullName | Should -BeFalse
    }

    It 'leaves a file added inside a reviewed folder item' {
        $cer = Join-Path $script:sb.Alice 'AppData\Local\Autodesk\CER'
        $report = New-DLTestFile -Path (Join-Path $cer 'hash1\report.log') -Bytes 1500 -ModifiedDaysAgo 40
        Set-DLTestFolderAge -Path (Join-Path $cer 'hash1') -DaysAgo 40
        $config = New-DLTestConfiguration -Categories @{ 'autodesk.cer' = @{ ProtectNewest = 0 } }
        $analysis = Invoke-DLTestAnalysis -Configuration $config
        $category = Get-DLTestCategory -Analysis $analysis -Id 'autodesk.cer'
        $category.itemCount | Should -Be 1
        $category.items[0].kind | Should -Be 'Folder'
        $category.items[0].fileCount | Should -Be 1
        $late = New-DLTestFile -Path (Join-Path $cer 'hash1\late.log') -ModifiedDaysAgo 40
        # Adding a file touches the folder; set it back so only the file filter can keep late.log.
        Set-DLTestFolderAge -Path (Join-Path $cer 'hash1') -DaysAgo 40

        $cleanup = Invoke-DLTestCleanup -Category 'autodesk.cer' -Configuration $config

        Test-Path -LiteralPath $report.FullName | Should -BeFalse
        Test-Path -LiteralPath $late.FullName | Should -BeTrue
        $cleanup.freedBytes | Should -Be 1500
    }

    It 'deletes nothing in report-only mode and says so' {
        $temp = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'old.tmp') -ModifiedDaysAgo 30
        $config = New-DLTestConfiguration -General @{ ReportOnly = 1 }
        $analysis = Invoke-DLTestAnalysis -Configuration $config
        $analysis.reportOnly | Should -BeTrue

        $cleanup = Invoke-DLTestCleanup -Category 'user.temp' -Configuration $config

        $cleanup.result | Should -Be 'ReportOnly'
        $cleanup.freedBytes | Should -Be 0
        $cleanup.skipped[0].reason | Should -Be 'ReportOnly'
        Test-Path -LiteralPath $temp.FullName | Should -BeTrue
    }

    It 'returns Disabled and deletes nothing when the engine is disabled after Analyze' {
        $temp = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'old.tmp') -ModifiedDaysAgo 30
        Invoke-DLTestAnalysis | Out-Null

        $cleanup = Invoke-DLTestCleanup -Category 'user.temp' -Configuration (New-DLTestConfiguration -General @{ Enabled = 0 })

        $cleanup.result | Should -Be 'Disabled'
        $cleanup.deletedCount | Should -Be 0
        Test-Path -LiteralPath $temp.FullName | Should -BeTrue
    }
}

Describe 'User cleanup review: engine boundary' {
    BeforeEach { Set-DLTestEnvironment -Sandbox (New-DLSandbox) }
    AfterEach { Remove-DLSandbox -Sandbox $script:sb }

    It 'keeps Restricted categories out of CleanTemp even when an administrator enables them (D25)' {
        $temp = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'old.tmp') -ModifiedDaysAgo 30
        $save = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'drawing_1_1_1234.sv$') -ModifiedDaysAgo 60
        $config = New-DLTestConfiguration -Categories @{ 'autocad.recovery' = @{ Enabled = 1 } }

        $summary = @(Invoke-DeadLoad -Mode User -Configuration $config -DataRoot $script:sb.Data -NoEventLog)

        $summary[0].Result | Should -Be 'Success'
        Test-Path -LiteralPath $temp.FullName | Should -BeFalse
        Test-Path -LiteralPath $save.FullName | Should -BeTrue
        @($summary[0].Categories | ForEach-Object { $_.Id }) | Should -Be @('user.temp')
    }

    It 'skips a Restricted or untiered category in CleanTemp whatever its UserAction flag' {
        $base = @{ Scope = 'User'; Unit = 'File'; Recurse = $false; Guarded = $false; UserAction = $true; Settings = @{ Enabled = 1; AgeDays = 7; AgeBasis = 'Modified'; RoutineAction = 'Delete'; MinAgeHours = 0 } }
        $definitions = @(
            ($base.Clone() + @{ Id = 'test.routine'; Risk = 'Routine'; Roots = @('{LocalAppData}\R') })
            ($base.Clone() + @{ Id = 'test.restricted'; Risk = 'Restricted'; Roots = @('{LocalAppData}\X') })
            ($base.Clone() + @{ Id = 'test.untiered'; Roots = @('{LocalAppData}\U') })
        )
        $local = Join-Path $script:sb.Alice 'AppData\Local'
        $routine = New-DLTestFile -Path (Join-Path $local 'R\old.log') -ModifiedDaysAgo 30
        $restricted = New-DLTestFile -Path (Join-Path $local 'X\old.log') -ModifiedDaysAgo 30
        $untiered = New-DLTestFile -Path (Join-Path $local 'U\old.log') -ModifiedDaysAgo 30

        $summary = @(Invoke-DeadLoad -Mode User -Configuration (New-DLTestConfiguration -Definitions $definitions) -DataRoot $script:sb.Data -NoEventLog)

        $summary[0].Result | Should -Be 'Success'
        Test-Path -LiteralPath $routine.FullName | Should -BeFalse
        Test-Path -LiteralPath $restricted.FullName | Should -BeTrue
        Test-Path -LiteralPath $untiered.FullName | Should -BeTrue
    }

    It 'fails a User run that names a Restricted category and touches nothing' {
        $journal = New-DLTestFile -Path (Join-Path (Get-DLAliceJournals) 'journal.0001.txt') -ModifiedDaysAgo 30
        $summary = @(Invoke-DeadLoad -Mode User -Category 'revit.journals' -Configuration (New-DLTestConfiguration) -DataRoot $script:sb.Data -NoEventLog)

        $summary[0].Result | Should -Be 'Failed'
        $summary[0].Reason | Should -Match 'Restricted'
        Test-Path -LiteralPath $journal.FullName | Should -BeTrue
    }

    It 'refuses reviewed items outside a User review run' {
        $temp = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'old.tmp') -ModifiedDaysAgo 30
        $summary = @(Invoke-DeadLoad -Mode Maintenance -ReviewedItem @{ $temp.FullName = 'x' } -Configuration (New-DLTestConfiguration) -DataRoot $script:sb.Data -NoEventLog)

        $summary[0].Result | Should -Be 'Failed'
        Test-Path -LiteralPath $temp.FullName | Should -BeTrue
    }

    It 'leaves SYSTEM runs unchanged: no plan in the summary or the run report' {
        $temp = New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'old.tmp') -ModifiedDaysAgo 30
        $bob = New-DLTestFile -Path (Join-Path $script:sb.Bob 'AppData\Local\Temp\old.tmp') -ModifiedDaysAgo 30
        $summary = @(Invoke-DeadLoad -Mode Maintenance -Configuration (New-DLTestConfiguration) -DataRoot $script:sb.Data -NoEventLog)

        $summary.Count | Should -Be 1
        $names = @($summary[0].PSObject.Properties | ForEach-Object { $_.Name })
        ($names -join ',') | Should -Be 'SchemaVersion,Product,Version,RunId,Computer,Mode,StartTime,EndTime,DurationSeconds,ReportOnly,WhatIf,Result,Reason,Volume,Budget,Totals,Categories,Skips,Failures,Configuration,Profiles,LogPath'
        Test-Path -LiteralPath $temp.FullName | Should -BeFalse
        Test-Path -LiteralPath $bob.FullName | Should -BeFalse
        [System.IO.File]::ReadAllText((Join-Path $script:sb.Data 'last-run.json')) | Should -Not -Match '"Plan"'
    }

    It 'keeps the plan out of the user run report' {
        New-DLTestFile -Path (Join-Path (Get-DLAliceTemp) 'old.tmp') -ModifiedDaysAgo 30 | Out-Null
        Invoke-DLTestAnalysis | Out-Null

        $report = [System.IO.File]::ReadAllText((Join-Path $script:sb.Data 'last-user-action.json'))
        $report | Should -Not -Match '"Plan"'
        $report | Should -Not -Match ([regex]::Escape(($script:sb.Alice -replace '\\', '\\')))
    }
}
