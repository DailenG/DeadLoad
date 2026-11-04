#Requires -Version 5.1
# Phase 2 (policy templates): the committed ADMX/ADML match the settings catalog and the
# generator is deterministic.

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:Generator = Join-Path $script:RepoRoot 'build\New-DeadLoadAdmx.ps1'
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

    $script:AdmxText = [System.IO.File]::ReadAllText((Join-Path $script:PolicyDir 'DeadLoad.admx'))
    $script:AdmlText = [System.IO.File]::ReadAllText((Join-Path $script:PolicyDir 'en-US\DeadLoad.adml'))
    [xml]$script:Admx = $script:AdmxText
    [xml]$script:Adml = $script:AdmlText
    $script:Ns = New-Object System.Xml.XmlNamespaceManager $script:Admx.NameTable
    $script:Ns.AddNamespace('p', 'http://schemas.microsoft.com/GroupPolicy/2006/07/PolicyDefinitions')
    $script:Policies = @{}
    foreach ($node in $script:Admx.SelectNodes('//p:policies/p:policy', $script:Ns)) { $script:Policies[$node.GetAttribute('name')] = $node }

    # Expected policies: name, key, value name and catalog entry.
    $sections = @{}
    foreach ($s in $script:Catalog.Sections) { $sections[$s.Name] = $s }
    $script:Expected = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in @($script:Catalog.Settings | Where-Object { $_.Section -ne 'Category' }))
    {
        $key = 'Software\Policies\DeadLoad'
        if ($sections[$entry.Section].SubKey) { $key += '\' + $sections[$entry.Section].SubKey }
        $script:Expected.Add([pscustomobject]@{ Name = ('{0}_{1}' -f $entry.Section, $entry.Name); Key = $key; Entry = $entry })
    }
    foreach ($definition in $script:Defaults.Categories)
    {
        foreach ($entry in @($script:Catalog.Settings | Where-Object { $_.Section -eq 'Category' }))
        {
            if ($entry.ContainsKey('Categories') -and @($entry.Categories) -notcontains $definition.Id) { continue }
            $script:Expected.Add([pscustomobject]@{
                    Name  = ('Category_{0}_{1}' -f ($definition.Id -replace '[^A-Za-z0-9_]', '_'), $entry.Name)
                    Key   = ('Software\Policies\DeadLoad\Categories\{0}' -f $definition.Id)
                    Entry = $entry
                })
        }
    }

    function Get-PolicyValueName
    {
        param ($Policy)
        if ($Policy.HasAttribute('valueName')) { return $Policy.GetAttribute('valueName') }
        $element = $Policy.SelectSingleNode('p:elements/*', $script:Ns)
        return $element.GetAttribute('valueName')
    }
}

Describe 'Policy templates' {

    It 'parse as XML, are 7-bit ASCII, CRLF and UTF-8 without BOM' {
        foreach ($file in (Join-Path $script:PolicyDir 'DeadLoad.admx'), (Join-Path $script:PolicyDir 'en-US\DeadLoad.adml'))
        {
            $bytes = [System.IO.File]::ReadAllBytes($file)
            ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB) | Should -BeFalse
            @($bytes | Where-Object { $_ -gt 0x7F }).Count | Should -Be 0
            $text = [System.IO.File]::ReadAllText($file)
            ($text -replace "`r`n", '') -match "`n" | Should -BeFalse
            { [xml]$text } | Should -Not -Throw
        }
        $script:Admx.policyDefinitions.policyNamespaces.target.namespace | Should -Be 'DeadLoad.Policies'
        $script:Admx.policyDefinitions.policyNamespaces.target.prefix | Should -Be 'deadload'
    }

    It 'has every catalog setting as a policy with the right key and value name' {
        $script:Expected.Count | Should -BeGreaterThan 0
        foreach ($expected in $script:Expected)
        {
            $policy = $script:Policies[$expected.Name]
            $policy | Should -Not -BeNullOrEmpty -Because $expected.Name
            $policy.GetAttribute('key') | Should -Be $expected.Key -Because $expected.Name
            Get-PolicyValueName -Policy $policy | Should -Be $expected.Entry.Name -Because $expected.Name
            $class = 'Machine'
            if ($expected.Entry.ContainsKey('Scope') -and $expected.Entry.Scope -eq 'Both') { $class = 'Both' }
            $policy.GetAttribute('class') | Should -Be $class -Because $expected.Name
        }
        # Every setting policy plus CustomTargets, nothing else.
        $script:Policies.Count | Should -Be ($script:Expected.Count + 1)
    }

    It 'uses the element type of each catalog type and matches decimal ranges' {
        foreach ($expected in $script:Expected)
        {
            $policy = $script:Policies[$expected.Name]
            $entry = $expected.Entry
            switch ($entry.Type)
            {
                'Bool'
                {
                    $policy.SelectSingleNode('p:enabledValue/p:decimal', $script:Ns).GetAttribute('value') | Should -Be '1'
                    $policy.SelectSingleNode('p:disabledValue/p:decimal', $script:Ns).GetAttribute('value') | Should -Be '0'
                }
                'Int'
                {
                    $decimal = $policy.SelectSingleNode('p:elements/p:decimal', $script:Ns)
                    $decimal.GetAttribute('minValue') | Should -Be ([string]$entry.Min) -Because $expected.Name
                    $decimal.GetAttribute('maxValue') | Should -Be ([string]$entry.Max) -Because $expected.Name
                    $decimal.GetAttribute('storeAsText') | Should -Be 'false'
                }
                'Enum'
                {
                    $values = @($policy.SelectNodes('p:elements/p:enum/p:item/p:value/p:string', $script:Ns) | ForEach-Object { $_.InnerText })
                    ($values -join ',') | Should -Be (@($entry.Values) -join ',') -Because $expected.Name
                }
                default
                {
                    $policy.SelectSingleNode('p:elements/p:text', $script:Ns) | Should -Not -BeNullOrEmpty -Because $expected.Name
                }
            }
        }
    }

    It 'has a CustomTargets list policy documenting the format and allowed roots' {
        $policy = $script:Policies['CustomTargets']
        $list = $policy.SelectSingleNode('p:elements/p:list', $script:Ns)
        $list.GetAttribute('key') | Should -Be 'Software\Policies\DeadLoad\CustomTargets'
        $list.GetAttribute('explicitValue') | Should -Be 'true'
        $help = ($script:Adml.policyDefinitionResources.resources.stringTable.string | Where-Object { $_.id -eq 'CustomTargets_Help' }).InnerText
        $help | Should -Match ([regex]::Escape('Include=*.log;Unit=File;AgeDays=30;Action=Delete'))
        foreach ($root in $script:Defaults.CustomTargetRoots) { $help | Should -Match ([regex]::Escape($root)) }
    }

    It 'has no duplicate policy, category, string or presentation ids' {
        $names = @($script:Admx.SelectNodes('//p:policies/p:policy', $script:Ns) | ForEach-Object { $_.GetAttribute('name') })
        @($names | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
        $categories = @($script:Admx.SelectNodes('//p:categories/p:category', $script:Ns) | ForEach-Object { $_.GetAttribute('name') })
        @($categories | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
        $strings = @($script:Adml.policyDefinitionResources.resources.stringTable.string | ForEach-Object { $_.id })
        @($strings | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
        $presentations = @($script:Adml.policyDefinitionResources.resources.presentationTable.presentation | ForEach-Object { $_.id })
        @($presentations | Group-Object | Where-Object { $_.Count -gt 1 }).Count | Should -Be 0
    }

    It 'resolves every string and presentation reference in the ADML' {
        $strings = @{}
        foreach ($s in $script:Adml.policyDefinitionResources.resources.stringTable.string) { $strings[$s.id] = $true }
        $presentations = @{}
        foreach ($p in $script:Adml.policyDefinitionResources.resources.presentationTable.presentation) { $presentations[$p.id] = $true }
        $refs = [regex]::Matches($script:AdmxText, '\$\((string|presentation)\.([^)]+)\)')
        $refs.Count | Should -BeGreaterThan 0
        foreach ($ref in $refs)
        {
            $table = $strings
            if ($ref.Groups[1].Value -eq 'presentation') { $table = $presentations }
            $table.ContainsKey($ref.Groups[2].Value) | Should -BeTrue -Because $ref.Value
        }
        # Every category id from the defaults has its own subcategory.
        foreach ($definition in $script:Defaults.Categories)
        {
            $name = 'Cat_Category_' + ($definition.Id -replace '[^A-Za-z0-9_]', '_')
            $script:Admx.SelectSingleNode(('//p:category[@name="{0}"]' -f $name), $script:Ns) | Should -Not -BeNullOrEmpty
        }
    }

    It 'states each category''s risk tier, display name and description in its explain text (D22)' {
        $strings = @{}
        foreach ($s in $script:Adml.policyDefinitionResources.resources.stringTable.string) { $strings[$s.id] = $s.InnerText }
        foreach ($definition in $script:Defaults.Categories)
        {
            @('Routine', 'Review', 'Restricted') | Should -Contain $definition.Risk -Because $definition.Id
            $definition.DisplayName | Should -Not -BeNullOrEmpty -Because $definition.Id
            $definition.Description | Should -Not -BeNullOrEmpty -Because $definition.Id
            $token = $definition.Id -replace '[^A-Za-z0-9_]', '_'
            $help = $strings[('Category_{0}_Enabled_Help' -f $token)]
            $help | Should -Match ([regex]::Escape(('Risk tier {0}' -f $script:Defaults.RiskTiers[$definition.Risk]))) -Because $definition.Id
            $help | Should -Match ([regex]::Escape($definition.Description)) -Because $definition.Id
            $strings[('Cat_Category_' + $token)] | Should -Be ('{0} ({1})' -f $definition.DisplayName, $definition.Id)
        }
    }

    It 'is deterministic and matches the committed files' {
        $base = Join-Path ([System.IO.Path]::GetTempPath()) ('dladmx-' + [guid]::NewGuid().ToString('N'))
        try
        {
            $outputs = @((Join-Path $base 'a'), (Join-Path $base 'b'))
            foreach ($out in $outputs) { $null = & $script:Generator -OutputPath $out }
            foreach ($relative in 'DeadLoad.admx', 'en-US\DeadLoad.adml')
            {
                $a = [System.IO.File]::ReadAllBytes((Join-Path $outputs[0] $relative))
                $b = [System.IO.File]::ReadAllBytes((Join-Path $outputs[1] $relative))
                $committed = [System.IO.File]::ReadAllBytes((Join-Path $script:PolicyDir $relative))
                [Convert]::ToBase64String($a) | Should -Be ([Convert]::ToBase64String($b)) -Because $relative
                [Convert]::ToBase64String($a) | Should -Be ([Convert]::ToBase64String($committed)) -Because ('{0} must be regenerated and committed' -f $relative)
            }
        }
        finally
        {
            if (Test-Path -LiteralPath $base) { Remove-Item -LiteralPath $base -Recurse -Force }
        }
    }
}
