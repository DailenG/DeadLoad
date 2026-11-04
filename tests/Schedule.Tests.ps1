#Requires -Version 5.1
# Phase 3 (scheduler): task XML from policy, validated by Task Scheduler itself without
# registering anything (TASK_VALIDATE_ONLY), and -WhatIf changing nothing.

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:RepoRoot 'src\engine\DeadLoad\DeadLoad.psd1') -Force
    $script:schedule = @{ MaintenanceDays = 'Sunday,Wednesday'; MaintenanceTime = '03:00'; PressureCheckTime = '12:30'; RunOnlyIfIdle = 1; AllowOnBattery = 0 }
    $script:module = Get-Module DeadLoad
}

Describe 'Scheduled task definitions' {

    It 'builds <Name> as SYSTEM with the right triggers and limits' -ForEach @(
        @{ Name = 'Maintenance'; Limit = 'PT1H'; Calendar = 1; Event = 0 }
        @{ Name = 'PressureCheck'; Limit = 'PT30M'; Calendar = 1; Event = 1 }
        @{ Name = 'OnDemand'; Limit = 'PT1H'; Calendar = 0; Event = 0 }
    ) {
        $xmlText = & $script:module { param($n, $s) New-DLTaskXml -Name $n -Schedule $s -InstallPath 'C:\Program Files\DeadLoad' -Fingerprint 'schedule abc' } $Name $script:schedule
        [xml]$xml = $xmlText
        $ns = New-Object System.Xml.XmlNamespaceManager $xml.NameTable
        $ns.AddNamespace('t', 'http://schemas.microsoft.com/windows/2004/02/mit/task')
        $xml.SelectSingleNode('//t:Principal/t:UserId', $ns).InnerText | Should -Be 'S-1-5-18'
        $xml.SelectSingleNode('//t:ExecutionTimeLimit', $ns).InnerText | Should -Be $Limit
        @($xml.SelectNodes('//t:CalendarTrigger', $ns)).Count | Should -Be $Calendar
        @($xml.SelectNodes('//t:EventTrigger', $ns)).Count | Should -Be $Event
        $xml.SelectSingleNode('//t:Exec/t:Arguments', $ns).InnerText | Should -Be ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "C:\Program Files\DeadLoad\engine\Start-DeadLoad.ps1" -Mode {0}' -f $Name)
        $xml.SelectSingleNode('//t:DisallowStartIfOnBatteries', $ns).InnerText | Should -Be 'true'
        $xml.SelectSingleNode('//t:Description', $ns).InnerText | Should -Match 'schedule abc'
    }

    It 'puts the policy days and idle condition on Maintenance only' {
        [xml]$maintenance = & $script:module { param($s) New-DLTaskXml -Name 'Maintenance' -Schedule $s -InstallPath 'C:\X' } $script:schedule
        [xml]$pressure = & $script:module { param($s) New-DLTaskXml -Name 'PressureCheck' -Schedule $s -InstallPath 'C:\X' } $script:schedule
        $maintenance.Task.Triggers.CalendarTrigger.ScheduleByWeek.DaysOfWeek.ChildNodes.Name -join ',' | Should -Be 'Sunday,Wednesday'
        $maintenance.Task.Settings.RunOnlyIfIdle | Should -Be 'true'
        $pressure.Task.Settings.RunOnlyIfIdle | Should -Be 'false'
        $pressure.Task.Triggers.EventTrigger.Subscription | Should -Match 'EventID=2013'
    }

    It 'lets tasks start on battery when the policy allows it' {
        $schedule = $script:schedule.Clone()
        $schedule.AllowOnBattery = 1
        [xml]$xml = & $script:module { param($s) New-DLTaskXml -Name 'Maintenance' -Schedule $s -InstallPath 'C:\X' } $schedule
        $xml.Task.Settings.DisallowStartIfOnBatteries | Should -Be 'false'
    }

    It 'changes the fingerprint when any schedule input changes' {
        $a = & $script:module { param($s) Get-DLScheduleFingerprint -Schedule $s -InstallPath 'C:\X' } $script:schedule
        $changed = $script:schedule.Clone()
        $changed.MaintenanceTime = '04:00'
        $b = & $script:module { param($s) Get-DLScheduleFingerprint -Schedule $s -InstallPath 'C:\X' } $changed
        $a | Should -Not -Be $b
    }

    It 'is accepted by Task Scheduler (<Name>, validate only, nothing registered)' -ForEach @(
        @{ Name = 'Maintenance' }
        @{ Name = 'PressureCheck' }
        @{ Name = 'OnDemand' }
    ) {
        $xmlText = & $script:module { param($n, $s) New-DLTaskXml -Name $n -Schedule $s -InstallPath 'C:\Program Files\DeadLoad' } $Name $script:schedule
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $definition = $service.NewTask(0)
        # Parsing into a definition object catches schema errors; TASK_VALIDATE_ONLY (1) asks
        # the service to check the whole registration without storing it.
        { $definition.XmlText = $xmlText } | Should -Not -Throw
        $root = $service.GetFolder('\')
        $validated = $true
        try { [void]$root.RegisterTask(('DeadLoadValidate-{0}' -f $Name), $xmlText, 1, $null, $null, 3, $null) }
        catch
        {
            # Validation of a SYSTEM principal needs elevation; an access error is not a schema error.
            if ($_.Exception.HResult -ne -2147024891) { throw }
            $validated = $false
        }
        if (-not $validated) { Set-ItResult -Inconclusive -Because 'Task Scheduler validation needs elevation; the definition parsed' }
        $task = $null
        try { $task = $root.GetTask(('DeadLoadValidate-{0}' -f $Name)) } catch { $task = $null }
        $task | Should -BeNullOrEmpty
    }

    It 'registers nothing with -WhatIf' {
        Mock -ModuleName DeadLoad Get-DLTaskService { throw 'Task Scheduler must not be contacted under -WhatIf' }
        $rows = @(Sync-DeadLoadSchedule -Register -InstallPath 'C:\Program Files\DeadLoad' -WhatIf)
        $rows.Count | Should -Be 3
        @($rows | Where-Object { $_.Action -ne 'WhatIf' }).Count | Should -Be 0
    }
}
