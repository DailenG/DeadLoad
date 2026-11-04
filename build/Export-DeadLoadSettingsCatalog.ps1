<#
    .SYNOPSIS
        Exports every DeadLoad Group Policy setting as site/data/settings.json for the website's
        policy generator.

    .DESCRIPTION
        The website must never offer a value the ADMX does not define. So this script does not
        re-derive the policy layout on its own: it runs build/New-DeadLoadAdmx.ps1 into a
        temporary folder and reads each policy's name, class, registry key, value name, range,
        enum items, display name and explain text from the generated DeadLoad.admx and
        en-US\DeadLoad.adml. The engine data files add what the templates do not carry in a
        typed form: the catalog type (Bool, Int, Enum, String, Time, Days), the shipped default
        (Data/Defaults.psd1, resolved the way the engine and the ADMX generator resolve it) and,
        when a category definition has one, its Risk tier (Routine, Review, Restricted).

        Each catalog setting is matched to its policy by the generator's naming rule and the
        registry key and value name are compared; any mismatch stops the export, so a change to
        the generator that this script does not understand fails loudly instead of drifting.

        The CustomTargets list policy is not exported (it is a list of free-form definitions,
        not a value the generator can validate); the JSON says so.

        Output is 7-bit ASCII, UTF-8 without a byte order mark, LF line endings, in ADMX order,
        with no time stamp, so re-running the script produces a byte-identical file.

    .PARAMETER OutputPath
        The JSON file to write (default: <repo>\site\data\settings.json).

    .OUTPUTS
        System.IO.FileInfo for the file written.

    .EXAMPLE
        pwsh -NoProfile -File build\Export-DeadLoadSettingsCatalog.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param
(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
if (-not $OutputPath) { $OutputPath = Join-Path $repoRoot 'site\data\settings.json' }
$dataRoot = Join-Path $repoRoot 'src\engine\DeadLoad\Data'
$generator = Join-Path $PSScriptRoot 'New-DeadLoadAdmx.ps1'
$policyRoot = 'Software\Policies\DeadLoad'
$riskTiers = @('Routine', 'Review', 'Restricted')

function Import-DLCatalogDataFile
{
    # Same restricted-language parse as New-DeadLoadAdmx.ps1 and the engine: never runs code.
    param ([Parameter(Mandatory)] [string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw ('{0}: {1}' -f $Path, $errors[0].Message) }
    $data = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $false)
    return $data.SafeGetValue()
}

function ConvertTo-DLJsonString
{
    # Escapes everything outside printable ASCII so the file stays 7-bit on every host.
    param ([AllowEmptyString()] [string]$Text)

    $builder = New-Object System.Text.StringBuilder
    [void]$builder.Append('"')
    foreach ($char in $Text.ToCharArray())
    {
        $code = [int]$char
        switch ($code)
        {
            34 { [void]$builder.Append('\"'); continue }
            92 { [void]$builder.Append('\\'); continue }
            10 { [void]$builder.Append('\n'); continue }
            13 { [void]$builder.Append('\r'); continue }
            9 { [void]$builder.Append('\t'); continue }
            default
            {
                if ($code -lt 32 -or $code -gt 126) { [void]$builder.Append(('\u{0:x4}' -f $code)) }
                else { [void]$builder.Append($char) }
            }
        }
    }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function ConvertTo-DLJson
{
    <#
        A small deterministic JSON writer: ConvertTo-Json formats and escapes differently on 5.1
        and 7, which would make the committed file depend on the host that built it.
        Ordered dictionaries keep their key order; arrays of scalars stay on one line.
    #>
    param ([AllowNull()] [object]$Value, [int]$Indent = 0)

    $pad = ' ' * ($Indent + 2)
    $closePad = ' ' * $Indent
    if ($null -eq $Value) { return 'null' }
    if ($Value -is [bool]) { if ($Value) { return 'true' } return 'false' }
    if ($Value -is [string]) { return (ConvertTo-DLJsonString -Text $Value) }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [int16] -or $Value -is [byte])
    {
        return ([long]$Value).ToString([System.Globalization.CultureInfo]::InvariantCulture)
    }
    if ($Value -is [System.Collections.IDictionary])
    {
        if ($Value.Count -eq 0) { return '{}' }
        $parts = foreach ($key in @($Value.Keys))
        {
            $pad + (ConvertTo-DLJsonString -Text ([string]$key)) + ': ' + (ConvertTo-DLJson -Value $Value[$key] -Indent ($Indent + 2))
        }
        return ("{`n" + ($parts -join ",`n") + "`n" + $closePad + '}')
    }
    if ($Value -is [System.Collections.IEnumerable])
    {
        $items = @($Value)
        if ($items.Count -eq 0) { return '[]' }
        $scalar = $true
        foreach ($item in $items) { if ($item -is [System.Collections.IDictionary]) { $scalar = $false } }
        if ($scalar)
        {
            $inline = foreach ($item in $items) { ConvertTo-DLJson -Value $item -Indent ($Indent + 2) }
            return ('[' + ($inline -join ', ') + ']')
        }
        $parts = foreach ($item in $items) { $pad + (ConvertTo-DLJson -Value $item -Indent ($Indent + 2)) }
        return ("[`n" + ($parts -join ",`n") + "`n" + $closePad + ']')
    }
    throw ('Cannot write a value of type {0} as JSON.' -f $Value.GetType().FullName)
}

$catalog = Import-DLCatalogDataFile -Path (Join-Path $dataRoot 'Settings.psd1')
$defaults = Import-DLCatalogDataFile -Path (Join-Path $dataRoot 'Defaults.psd1')

# ---------------------------------------------------------------- run the ADMX generator
$work = Join-Path ([System.IO.Path]::GetTempPath()) ('deadload-catalog-' + [guid]::NewGuid().ToString('N'))
try
{
    $null = & $generator -OutputPath $work -WhatIf:$false -Confirm:$false
    [xml]$admx = [System.IO.File]::ReadAllText((Join-Path $work 'DeadLoad.admx'))
    [xml]$adml = [System.IO.File]::ReadAllText((Join-Path $work 'en-US\DeadLoad.adml'))
}
finally
{
    if ([System.IO.Directory]::Exists($work)) { [System.IO.Directory]::Delete($work, $true) }
}

$ns = New-Object System.Xml.XmlNamespaceManager $admx.NameTable
$ns.AddNamespace('p', 'http://schemas.microsoft.com/GroupPolicy/2006/07/PolicyDefinitions')
$strings = @{}
foreach ($node in $adml.SelectNodes('//p:stringTable/p:string', $ns)) { $strings[$node.GetAttribute('id')] = $node.InnerText }
function Get-DLString
{
    param ([string]$Reference)

    if ($Reference -notmatch '^\$\(string\.(.+)\)$') { throw ('Not a string reference: {0}' -f $Reference) }
    $id = $Matches[1]
    if (-not $strings.ContainsKey($id)) { throw ('ADML has no string {0}.' -f $id) }
    # ADML keeps CRLF between explain paragraphs; the web uses LF.
    return ($strings[$id] -replace "`r`n", "`n")
}

$categoryParents = @{}
foreach ($node in $admx.SelectNodes('//p:categories/p:category', $ns))
{
    $parent = $node.SelectSingleNode('p:parentCategory', $ns)
    $parentName = $null
    if ($parent) { $parentName = $parent.GetAttribute('ref') }
    $categoryParents[$node.GetAttribute('name')] = @{ Display = (Get-DLString -Reference $node.GetAttribute('displayName')); Parent = $parentName }
}

# ---------------------------------------------------------------- expected settings from the data files
# Policy naming rule of New-DeadLoadAdmx.ps1: <Section>_<Name>, Category_<id token>_<Name>.
$sections = @{}
foreach ($section in $catalog.Sections) { $sections[$section.Name] = $section }
$expected = @{}
foreach ($entry in @($catalog.Settings | Where-Object { $_.Section -ne 'Category' }))
{
    $key = $policyRoot
    if ($sections[$entry.Section].SubKey) { $key += '\' + $sections[$entry.Section].SubKey }
    $expected[('{0}_{1}' -f $entry.Section, $entry.Name)] = @{
        Entry      = $entry
        Key        = $key
        Default    = $defaults[$entry.Section][$entry.Name]
        CategoryId = $null
        Risk       = $null
        TraceName  = $(if ($sections[$entry.Section].SubKey) { '{0}\{1}' -f $sections[$entry.Section].SubKey, $entry.Name } else { $entry.Name })
    }
}
$categories = New-Object 'System.Collections.Generic.List[object]'
foreach ($definition in $defaults.Categories)
{
    $id = $definition.Id
    $risk = $null
    if ($definition.ContainsKey('Risk'))
    {
        $risk = [string]$definition.Risk
        if ($riskTiers -notcontains $risk) { throw ('Category {0} has an unknown Risk tier: {1}' -f $id, $risk) }
    }
    $enabled = $defaults.CategorySettingDefaults['Enabled']
    if ($definition.ContainsKey('Settings') -and $definition.Settings.ContainsKey('Enabled')) { $enabled = $definition.Settings['Enabled'] }
    $scope = 'User'
    if ($definition.ContainsKey('Scope')) { $scope = [string]$definition.Scope }
    $info = [ordered]@{ id = $id; scope = $scope; enabledByDefault = ([int]$enabled -eq 1) }
    if ($null -ne $risk) { $info['risk'] = $risk }
    foreach ($field in @('DisplayName', 'Description'))
    {
        if ($definition.ContainsKey($field)) { $info[$field.Substring(0, 1).ToLowerInvariant() + $field.Substring(1)] = [string]$definition[$field] }
    }
    $categories.Add($info)

    $subKey = $sections['Category'].SubKey.Replace('{Id}', $id)
    foreach ($entry in @($catalog.Settings | Where-Object { $_.Section -eq 'Category' }))
    {
        if ($entry.ContainsKey('Categories') -and @($entry.Categories) -notcontains $id) { continue }
        $default = $defaults.CategorySettingDefaults[$entry.Name]
        if ($definition.ContainsKey('Settings') -and $definition.Settings.ContainsKey($entry.Name)) { $default = $definition.Settings[$entry.Name] }
        $expected[('Category_{0}_{1}' -f ($id -replace '[^A-Za-z0-9_]', '_'), $entry.Name)] = @{
            Entry      = $entry
            Key        = ($policyRoot + '\' + $subKey)
            Default    = $default
            CategoryId = $id
            Risk       = $risk
            TraceName  = ('{0}\{1}' -f $subKey, $entry.Name)
        }
    }
}

# ---------------------------------------------------------------- join, in ADMX order
$settings = New-Object 'System.Collections.Generic.List[object]'
$seen = @{}
foreach ($policy in $admx.SelectNodes('//p:policies/p:policy', $ns))
{
    $name = $policy.GetAttribute('name')
    if ($name -eq 'CustomTargets') { continue }
    if (-not $expected.ContainsKey($name)) { throw ('ADMX policy {0} is not a catalog setting this script knows.' -f $name) }
    $x = $expected[$name]
    $entry = $x.Entry
    $seen[$name] = $true

    $key = $policy.GetAttribute('key')
    if ($key -cne $x.Key) { throw ('Policy {0}: ADMX key {1}, catalog key {2}.' -f $name, $key, $x.Key) }
    $valueName = $policy.GetAttribute('valueName')
    if (-not $valueName)
    {
        $element = $policy.SelectSingleNode('p:elements/*', $ns)
        $valueName = $element.GetAttribute('valueName')
    }
    if ($valueName -cne $entry.Name) { throw ('Policy {0}: ADMX value {1}, catalog value {2}.' -f $name, $valueName, $entry.Name) }

    $parentRef = $policy.SelectSingleNode('p:parentCategory', $ns).GetAttribute('ref')
    $sectionDisplay = $categoryParents[$parentRef].Display
    $categoryFolder = $null
    if ($x.CategoryId)
    {
        # The category's own folder in the editor; its parent is the Categories section.
        $categoryFolder = $categoryParents[$parentRef].Display
        $sectionDisplay = $categoryParents[$categoryParents[$parentRef].Parent].Display
    }

    $registryType = 'REG_SZ'
    if ($entry.Type -eq 'Bool' -or $entry.Type -eq 'Int') { $registryType = 'REG_DWORD' }

    $row = [ordered]@{
        id           = $name
        class        = $policy.GetAttribute('class')
        section      = [string]$entry.Section
        sectionName  = $sectionDisplay
        categoryId   = $x.CategoryId
        categoryFolder = $categoryFolder
        key          = $key
        valueName    = $valueName
        traceName    = $x.TraceName
        type         = [string]$entry.Type
        registryType = $registryType
    }
    switch ($entry.Type)
    {
        'Int'
        {
            $decimal = $policy.SelectSingleNode('p:elements/p:decimal', $ns)
            $row['min'] = [long]$decimal.GetAttribute('minValue')
            $row['max'] = [long]$decimal.GetAttribute('maxValue')
        }
        'Enum'
        {
            $row['values'] = @($policy.SelectNodes('p:elements/p:enum/p:item/p:value/p:string', $ns) | ForEach-Object { $_.InnerText })
        }
        'Bool' { }
        default
        {
            $row['maxLength'] = [long]$policy.SelectSingleNode('p:elements/p:text', $ns).GetAttribute('maxLength')
        }
    }
    $default = $x.Default
    if ($entry.Type -eq 'Bool' -or $entry.Type -eq 'Int') { $default = [long]$default } else { $default = [string]$default }
    $row['default'] = $default
    $row['display'] = Get-DLString -Reference $policy.GetAttribute('displayName')
    $row['explain'] = Get-DLString -Reference $policy.GetAttribute('explainText')
    if ($null -ne $x.Risk) { $row['risk'] = $x.Risk }
    $settings.Add($row)
}
foreach ($name in @($expected.Keys)) { if (-not $seen.ContainsKey($name)) { throw ('Catalog setting {0} has no ADMX policy.' -f $name) } }

$sectionList = foreach ($section in $catalog.Sections)
{
    [ordered]@{ name = [string]$section.Name; display = [string]$section.Display }
}

$tierList = New-Object 'System.Collections.Generic.List[object]'
if ($defaults.ContainsKey('RiskTiers'))
{
    foreach ($tier in $riskTiers)
    {
        if ($defaults.RiskTiers.ContainsKey($tier)) { $tierList.Add([ordered]@{ tier = $tier; meaning = [string]$defaults.RiskTiers[$tier] }) }
    }
}

$document = [ordered]@{
    schemaVersion     = 1
    comment           = 'Generated by build/Export-DeadLoadSettingsCatalog.ps1 from build/New-DeadLoadAdmx.ps1 output and src/engine/DeadLoad/Data. Do not edit.'
    policyRoot        = $policyRoot
    machineHive       = 'HKLM'
    userHive          = 'HKCU'
    notExported       = @('CustomTargets (list policy: one value per custom target; set it in the Group Policy editor)')
    riskTiers         = $tierList.ToArray()
    sections          = @($sectionList)
    categories        = $categories.ToArray()
    settings          = $settings.ToArray()
}

$text = (ConvertTo-DLJson -Value $document) + "`n"
if ($text -match '[^\x00-\x7F]') { throw ('{0} would contain a non-ASCII character.' -f $OutputPath) }
if ($PSCmdlet.ShouldProcess($OutputPath, 'Write settings catalog'))
{
    [void][System.IO.Directory]::CreateDirectory((Split-Path -Path $OutputPath -Parent))
    [System.IO.File]::WriteAllText($OutputPath, $text, (New-Object System.Text.UTF8Encoding($false)))
    Get-Item -LiteralPath $OutputPath
}
