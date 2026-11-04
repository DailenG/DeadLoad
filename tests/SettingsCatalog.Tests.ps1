#Requires -Version 5.1
# Website settings catalog: site/data/settings.json mirrors the policy templates (same policies,
# keys, value names, classes, ranges and enum items), carries the shipped defaults, and is what
# build/Export-DeadLoadSettingsCatalog.ps1 produces now (no drift, byte for byte).

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:Exporter = Join-Path $script:RepoRoot 'build\Export-DeadLoadSettingsCatalog.ps1'
    $script:CatalogPath = Join-Path $script:RepoRoot 'site\data\settings.json'
    $script:PolicyDir = Join-Path $script:RepoRoot 'policy'

    function Import-TestDataFile
    {
        param ([string]$Path)
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $ast.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $false).SafeGetValue()
    }

    $dataRoot = Join-Path $script:RepoRoot 'src\engine\DeadLoad\Data'
    $script:Catalog = Import-TestDataFile -Path (Join-Path $dataRoot 'Settings.psd1')
    $script:Defaults = Import-TestDataFile -Path (Join-Path $dataRoot 'Defaults.psd1')

    $script:JsonText = [System.IO.File]::ReadAllText($script:CatalogPath)
    $script:Json = $script:JsonText | ConvertFrom-Json
    $script:Rows = @{}
    foreach ($row in $script:Json.settings) { $script:Rows[$row.id] = $row }

    [xml]$script:Admx = [System.IO.File]::ReadAllText((Join-Path $script:PolicyDir 'DeadLoad.admx'))
    $script:Ns = New-Object System.Xml.XmlNamespaceManager $script:Admx.NameTable
    $script:Ns.AddNamespace('p', 'http://schemas.microsoft.com/GroupPolicy/2006/07/PolicyDefinitions')
    $script:Policies = @($script:Admx.SelectNodes('//p:policies/p:policy', $script:Ns) | Where-Object { $_.GetAttribute('name') -ne 'CustomTargets' })
}

Describe 'Website settings catalog' {

    It 'is 7-bit ASCII, UTF-8 without BOM, LF only' {
        $bytes = [System.IO.File]::ReadAllBytes($script:CatalogPath)
        ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
        @($bytes | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0
        $script:JsonText.Contains("`r") | Should -BeFalse
    }

    It 'is exactly what the exporter writes now' {
        $temp = Join-Path ([System.IO.Path]::GetTempPath()) ('deadload-catalog-test-' + [guid]::NewGuid().ToString('N') + '.json')
        try
        {
            $null = & $script:Exporter -OutputPath $temp
            [System.IO.File]::ReadAllText($temp) | Should -BeExactly $script:JsonText -Because 'run build\Export-DeadLoadSettingsCatalog.ps1 after changing Settings.psd1, Defaults.psd1 or the ADMX generator'
        }
        finally
        {
            if ([System.IO.File]::Exists($temp)) { [System.IO.File]::Delete($temp) }
        }
    }

    It 'has one row per committed ADMX policy with the same key, value name and class' {
        $script:Policies.Count | Should -BeGreaterThan 0
        @($script:Json.settings).Count | Should -Be $script:Policies.Count
        foreach ($policy in $script:Policies)
        {
            $name = $policy.GetAttribute('name')
            $row = $script:Rows[$name]
            $row | Should -Not -BeNullOrEmpty -Because $name
            $row.key | Should -BeExactly $policy.GetAttribute('key') -Because $name
            $valueName = $policy.GetAttribute('valueName')
            if (-not $valueName) { $valueName = $policy.SelectSingleNode('p:elements/*', $script:Ns).GetAttribute('valueName') }
            $row.valueName | Should -BeExactly $valueName -Because $name
            $row.class | Should -BeExactly $policy.GetAttribute('class') -Because $name
            $row.key.StartsWith('Software\Policies\DeadLoad') | Should -BeTrue
        }
    }

    It 'carries the ADMX ranges, enum items and registry types' {
        foreach ($policy in $script:Policies)
        {
            $name = $policy.GetAttribute('name')
            $row = $script:Rows[$name]
            switch ($row.type)
            {
                'Bool'
                {
                    $row.registryType | Should -Be 'REG_DWORD'
                    $policy.SelectSingleNode('p:enabledValue/p:decimal', $script:Ns).GetAttribute('value') | Should -Be '1'
                }
                'Int'
                {
                    $row.registryType | Should -Be 'REG_DWORD'
                    $decimal = $policy.SelectSingleNode('p:elements/p:decimal', $script:Ns)
                    [string]$row.min | Should -Be $decimal.GetAttribute('minValue') -Because $name
                    [string]$row.max | Should -Be $decimal.GetAttribute('maxValue') -Because $name
                }
                'Enum'
                {
                    $row.registryType | Should -Be 'REG_SZ'
                    $items = @($policy.SelectNodes('p:elements/p:enum/p:item/p:value/p:string', $script:Ns) | ForEach-Object { $_.InnerText })
                    (@($row.values) -join ',') | Should -BeExactly ($items -join ',') -Because $name
                }
                default
                {
                    $row.registryType | Should -Be 'REG_SZ'
                    [string]$row.maxLength | Should -Be $policy.SelectSingleNode('p:elements/p:text', $script:Ns).GetAttribute('maxLength') -Because $name
                }
            }
        }
    }

    It 'gives every setting the shipped default the engine uses' {
        $sections = @{}
        foreach ($s in $script:Catalog.Sections) { $sections[$s.Name] = $s }
        foreach ($entry in @($script:Catalog.Settings | Where-Object { $_.Section -ne 'Category' }))
        {
            $row = $script:Rows[('{0}_{1}' -f $entry.Section, $entry.Name)]
            $row.type | Should -BeExactly $entry.Type
            [string]$row.default | Should -BeExactly ([string]$script:Defaults[$entry.Section][$entry.Name]) -Because $row.id
        }
        foreach ($definition in $script:Defaults.Categories)
        {
            foreach ($entry in @($script:Catalog.Settings | Where-Object { $_.Section -eq 'Category' }))
            {
                if ($entry.ContainsKey('Categories') -and @($entry.Categories) -notcontains $definition.Id) { continue }
                $expected = $script:Defaults.CategorySettingDefaults[$entry.Name]
                if ($definition.ContainsKey('Settings') -and $definition.Settings.ContainsKey($entry.Name)) { $expected = $definition.Settings[$entry.Name] }
                $row = $script:Rows[('Category_{0}_{1}' -f ($definition.Id -replace '[^A-Za-z0-9_]', '_'), $entry.Name)]
                $row | Should -Not -BeNullOrEmpty
                $row.categoryId | Should -BeExactly $definition.Id
                [string]$row.default | Should -BeExactly ([string]$expected) -Because $row.id
            }
        }
    }

    It 'states the same default as the policy explain text' {
        foreach ($row in $script:Json.settings)
        {
            $shown = [string]$row.default
            if ($row.type -eq 'Bool') { if ($row.default -eq 1) { $shown = 'Enabled (1)' } else { $shown = 'Disabled (0)' } }
            elseif ($shown -eq '') { $shown = '(empty)' }
            $row.explain.Contains('Shipped default: ' + $shown + '.') | Should -BeTrue -Because $row.id
        }
    }

    It 'lists every built-in category with its risk tier when the defaults define one' {
        @($script:Json.categories).Count | Should -Be @($script:Defaults.Categories).Count
        foreach ($definition in $script:Defaults.Categories)
        {
            $category = @($script:Json.categories | Where-Object { $_.id -eq $definition.Id })
            $category.Count | Should -Be 1
            if ($definition.ContainsKey('Risk'))
            {
                $category[0].risk | Should -BeExactly $definition.Risk
                @('Routine', 'Review', 'Restricted') | Should -Contain $category[0].risk
                foreach ($row in @($script:Json.settings | Where-Object { $_.categoryId -eq $definition.Id })) { $row.risk | Should -BeExactly $definition.Risk }
            }
            else
            {
                $category[0].PSObject.Properties.Name | Should -Not -Contain 'risk'
            }
        }
    }
}
