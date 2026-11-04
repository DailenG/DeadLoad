#Requires -Version 5.1
# Phase 2 (configuration): precedence and validation through the engine's real reader, with
# the registry read (Get-DLRegistryKeyValues) mocked by name.

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $script:RepoRoot 'src\engine\DeadLoad\DeadLoad.psd1') -Force
    $script:module = Get-Module DeadLoad
    $script:defaults = & $script:module { Import-DLDataFile -Name 'Defaults.psd1' }

    function Set-TestRegistry
    {
        # Keys: '<Root>|<SubKey>' -> hashtable of values.
        param ([hashtable]$Table)
        $global:DLTestRegistry = $Table
    }

    function Get-TestConfig { & $script:module { Get-DLConfiguration } }

    function Get-TraceRow
    {
        param ($Config, [string]$Name)
        @($Config.Trace | Where-Object { $_.Name -eq $Name })
    }
}

AfterAll {
    Remove-Variable -Name DLTestRegistry -Scope Global -ErrorAction SilentlyContinue
    Remove-Module DeadLoad -Force -ErrorAction SilentlyContinue
}

Describe 'Configuration precedence and validation' {

    BeforeEach {
        Set-TestRegistry -Table @{}
        Mock -ModuleName DeadLoad Get-DLRegistryKeyValues {
            $values = $global:DLTestRegistry[('{0}|{1}' -f $Root, $SubKey)]
            if ($values) { return $values.Clone() }
            return @{}
        }
    }

    It 'uses the default when no source has a value' {
        $config = Get-TestConfig
        $config.General.TimeBudgetMinutes | Should -Be $script:defaults.General.TimeBudgetMinutes
        $row = @(Get-TraceRow -Config $config -Name 'TimeBudgetMinutes')
        $row.Count | Should -Be 1
        $row[0].Source | Should -Be 'Default'
        @($config.Rejected).Count | Should -Be 0
    }

    It 'lets Local beat Default' {
        Set-TestRegistry -Table @{ 'Local|' = @{ TimeBudgetMinutes = 77 } }
        $config = Get-TestConfig
        $config.General.TimeBudgetMinutes | Should -Be 77
        (Get-TraceRow -Config $config -Name 'TimeBudgetMinutes')[0].Source | Should -Be 'Local'
    }

    It 'lets Policy beat Local' {
        Set-TestRegistry -Table @{ 'Local|' = @{ TimeBudgetMinutes = 77 }; 'MachinePolicy|' = @{ TimeBudgetMinutes = 55 } }
        $config = Get-TestConfig
        $config.General.TimeBudgetMinutes | Should -Be 55
        (Get-TraceRow -Config $config -Name 'TimeBudgetMinutes')[0].Source | Should -Be 'Policy'
    }

    It 'for Tray lets UserPolicy beat Local and machine Policy beat UserPolicy' {
        Set-TestRegistry -Table @{ 'Local|Tray' = @{ CollectDays = 10; NotifyBelowGB = 3 }; 'UserPolicy|Tray' = @{ CollectDays = 20; NotifyBelowGB = 4 }; 'MachinePolicy|Tray' = @{ NotifyBelowGB = 5 } }
        $config = Get-TestConfig
        $config.Tray.CollectDays | Should -Be 20
        (Get-TraceRow -Config $config -Name 'Tray\CollectDays')[0].Source | Should -Be 'UserPolicy'
        $config.Tray.NotifyBelowGB | Should -Be 5
        (Get-TraceRow -Config $config -Name 'Tray\NotifyBelowGB')[0].Source | Should -Be 'Policy'
    }

    It 'does not read user policy for machine sections' {
        Set-TestRegistry -Table @{ 'UserPolicy|' = @{ TimeBudgetMinutes = 99 } }
        (Get-TestConfig).General.TimeBudgetMinutes | Should -Be $script:defaults.General.TimeBudgetMinutes
    }

    It 'rejects <Name> = <Bad> from Policy with a reason and lets Local win' -ForEach @(
        @{ SubKey = ''; Name = 'TimeBudgetMinutes'; Trace = 'TimeBudgetMinutes'; Section = 'General'; Bad = 601; Good = 30 }
        @{ SubKey = ''; Name = 'OnDemandMode'; Trace = 'OnDemandMode'; Section = 'General'; Bad = 'Everything'; Good = 'PressureCheck' }
        @{ SubKey = 'Schedule'; Name = 'MaintenanceTime'; Trace = 'Schedule\MaintenanceTime'; Section = 'Schedule'; Bad = '25:00'; Good = '04:15' }
        @{ SubKey = 'Schedule'; Name = 'MaintenanceDays'; Trace = 'Schedule\MaintenanceDays'; Section = 'Schedule'; Bad = 'Sunday,Funday'; Good = 'Monday,Thursday' }
    ) {
        Set-TestRegistry -Table @{ ('MachinePolicy|' + $SubKey) = @{ $Name = $Bad }; ('Local|' + $SubKey) = @{ $Name = $Good } }
        $config = Get-TestConfig
        $config[$Section][$Name] | Should -Be $Good
        (Get-TraceRow -Config $config -Name $Trace)[0].Source | Should -Be 'Local'
        $rejected = @($config.Rejected | Where-Object { $_.Name -eq $Trace })
        $rejected.Count | Should -Be 1
        $rejected[0].Source | Should -Be 'Policy'
        $rejected[0].Value | Should -Be ([string]$Bad)
        $rejected[0].Reason | Should -Not -BeNullOrEmpty
    }

    It 'applies a category setting from Policy' {
        Set-TestRegistry -Table @{ 'MachinePolicy|Categories\user.temp' = @{ AgeDays = 12 } }
        $config = Get-TestConfig
        $config.Categories['user.temp'].Settings.AgeDays | Should -Be 12
        (Get-TraceRow -Config $config -Name 'Categories\user.temp\AgeDays')[0].Source | Should -Be 'Policy'
    }

    It 'accepts a custom target under an allowed root as category custom.<name>' {
        Set-TestRegistry -Table @{ 'MachinePolicy|CustomTargets' = @{ AppLogs = 'Path={LocalAppData}\Example\Logs;Include=*.log;Unit=File;AgeDays=30;Action=Delete' } }
        $config = Get-TestConfig
        $config.Categories.Contains('custom.AppLogs') | Should -BeTrue
        $definition = $config.Categories['custom.AppLogs'].Definition
        $definition.Roots[0] | Should -Be '{LocalAppData}\Example\Logs'
        $definition.Scope | Should -Be 'User'
        $config.Categories['custom.AppLogs'].Settings.AgeDays | Should -Be 30
        (Get-TraceRow -Config $config -Name 'CustomTargets\AppLogs')[0].Source | Should -Be 'Policy'
    }

    It 'rejects a custom target <Case>' -ForEach @(
        @{ Case = 'outside the allowed roots'; Data = 'Path=C:\Windows\System32;AgeDays=30'; Reason = 'outside the allowed roots' }
        @{ Case = 'containing ..'; Data = 'Path={LocalAppData}\..\..\Windows;AgeDays=30'; Reason = '\.\.' }
    ) {
        Set-TestRegistry -Table @{ 'MachinePolicy|CustomTargets' = @{ Bad = $Data } }
        $config = Get-TestConfig
        $config.Categories.Contains('custom.Bad') | Should -BeFalse
        $rejected = @($config.Rejected | Where-Object { $_.Name -eq 'CustomTargets\Bad' })
        $rejected.Count | Should -Be 1
        $rejected[0].Reason | Should -Match $Reason
    }

    It 'Get-DeadLoadConfiguration -Trace returns one row per setting' {
        Set-TestRegistry -Table @{ 'MachinePolicy|' = @{ TimeBudgetMinutes = 0 } }
        $rows = @(Get-DeadLoadConfiguration -Trace)
        $catalog = & $script:module { Import-DLDataFile -Name 'Settings.psd1' }
        $expected = @($catalog.Settings | Where-Object { $_.Section -ne 'Category' }).Count
        $categoryEntries = @($catalog.Settings | Where-Object { $_.Section -eq 'Category' })
        foreach ($definition in $script:defaults.Categories)
        {
            $expected += @($categoryEntries | Where-Object { -not $_.ContainsKey('Categories') -or @($_.Categories) -contains $definition.Id }).Count
        }
        $settingRows = @($rows | Where-Object { $_.Source -notlike 'Rejected:*' })
        $settingRows.Count | Should -Be $expected
        @($settingRows | Group-Object Name | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
        $rejectedRow = @($rows | Where-Object { $_.Source -eq 'Rejected:Policy' })
        $rejectedRow.Count | Should -Be 1
        $rejectedRow[0].Reason | Should -Not -BeNullOrEmpty
    }
}
