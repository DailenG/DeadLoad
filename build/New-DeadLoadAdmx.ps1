<#
    .SYNOPSIS
        Generates the DeadLoad Group Policy templates (DeadLoad.admx and en-US\DeadLoad.adml)
        from the engine's settings catalog.

    .DESCRIPTION
        The engine's config reader and these templates both come from
        src\engine\DeadLoad\Data\Settings.psd1 (and the category ids in Defaults.psd1), so a
        policy can never name a value the engine does not read (ARCHITECTURE section 5).

        One policy per setting: machine policies under Software\Policies\DeadLoad[\subkey];
        tray settings are class Both (machine and user policy). Category settings repeat under
        one subcategory per built-in category id. A CustomTargets list policy writes
        Software\Policies\DeadLoad\CustomTargets.

        Output is UTF-8 without a byte order mark, CRLF, 7-bit ASCII and in catalog order, so
        re-running the script produces byte-identical files.

    .PARAMETER OutputPath
        Folder that receives DeadLoad.admx and en-US\DeadLoad.adml (default: <repo>\policy).

    .OUTPUTS
        System.IO.FileInfo for each file written.

    .EXAMPLE
        pwsh -NoProfile -File build\New-DeadLoadAdmx.ps1
#>
[CmdletBinding(SupportsShouldProcess)]
param
(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$repoRoot = Split-Path -Path $PSScriptRoot -Parent
if (-not $OutputPath) { $OutputPath = Join-Path $repoRoot 'policy' }
$dataRoot = Join-Path $repoRoot 'src\engine\DeadLoad\Data'

$policyRoot = 'Software\Policies\DeadLoad'
$localRoot = 'HKLM\Software\DeadLoad'
$supportedOn = 'deadload:SUPPORTED_WIN10'
$newLine = "`r`n"

function Import-DLAdmxDataFile
{
    # A restricted-language parse of the .psd1 behaves the same on 5.1 and 7 and never runs code.
    param ([Parameter(Mandatory)] [string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw ('{0}: {1}' -f $Path, $errors[0].Message) }
    $data = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $false)
    return $data.SafeGetValue()
}

function ConvertTo-DLXmlText
{
    param ([AllowEmptyString()] [string]$Text)

    return $Text.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;').Replace('"', '&quot;')
}

function ConvertTo-DLAdmxToken
{
    # Category ids carry dots; policy, string and presentation ids are kept to [A-Za-z0-9_].
    param ([string]$Text)

    return ($Text -replace '[^A-Za-z0-9_]', '_')
}

$catalog = Import-DLAdmxDataFile -Path (Join-Path $dataRoot 'Settings.psd1')
$defaults = Import-DLAdmxDataFile -Path (Join-Path $dataRoot 'Defaults.psd1')

# Ordered so the files come out in catalog order on every run and host.
$strings = New-Object 'System.Collections.Specialized.OrderedDictionary'
$presentations = New-Object 'System.Collections.Specialized.OrderedDictionary'
$categoryLines = New-Object 'System.Collections.Generic.List[string]'
$policyLines = New-Object 'System.Collections.Generic.List[string]'
$policyNames = @{}

function Add-DLString
{
    # Shared strings (enum item names) may be added again only with the same text.
    param ([string]$Id, [AllowEmptyString()] [string]$Text)

    if ($strings.Contains($Id))
    {
        if ($strings[$Id] -cne $Text) { throw ('String id {0} is defined twice with different text.' -f $Id) }
        return
    }
    $strings.Add($Id, $Text)
}

function Add-DLPresentation
{
    param ([string]$Id, [string[]]$Control)

    if ($presentations.Contains($Id)) { throw ('Presentation id {0} is defined twice.' -f $Id) }
    $presentations.Add($Id, $Control)
}

function Add-DLCategory
{
    param ([string]$Name, [string]$Display, [string]$Parent)

    Add-DLString -Id $Name -Text $Display
    if ($Parent)
    {
        $categoryLines.Add(('    <category name="{0}" displayName="$(string.{0})">' -f $Name))
        $categoryLines.Add(('      <parentCategory ref="{0}" />' -f $Parent))
        $categoryLines.Add('    </category>')
    }
    else
    {
        $categoryLines.Add(('    <category name="{0}" displayName="$(string.{0})" />' -f $Name))
    }
}

function Format-DLDefault
{
    param ([hashtable]$Entry, [object]$Value)

    if ($Entry.Type -eq 'Bool')
    {
        if ([int]$Value -eq 1) { return 'Enabled (1)' }
        return 'Disabled (0)'
    }
    if ([string]$Value -eq '') { return '(empty)' }
    return [string]$Value
}

function Add-DLSettingPolicy
{
    <#
        One catalog setting as one policy: the policy, its display and explain strings and,
        for every type but Bool, its presentation.
    #>
    param
    (
        [hashtable]$Entry,
        [string]$PolicyName,
        [string]$Display,
        [string]$SubKey,
        [string]$Parent,
        [object]$Default,
        [string]$Context
    )

    if ($policyNames.ContainsKey($PolicyName)) { throw ('Policy name {0} is generated twice.' -f $PolicyName) }
    $policyNames[$PolicyName] = $true

    $key = $policyRoot
    $localKey = $localRoot
    if ($SubKey)
    {
        $key = $policyRoot + '\' + $SubKey
        $localKey = $localRoot + '\' + $SubKey
    }
    $class = 'Machine'
    $hive = 'HKLM'
    if ($Entry.ContainsKey('Scope') -and $Entry.Scope -eq 'Both')
    {
        $class = 'Both'
        $hive = 'HKLM or HKCU'
    }
    $name = $Entry.Name
    $registryType = 'REG_SZ'
    if ($Entry.Type -eq 'Bool' -or $Entry.Type -eq 'Int') { $registryType = 'REG_DWORD' }

    switch ($Entry.Type)
    {
        'Bool' { $allowed = 'Enabled sets 1, Disabled sets 0.' }
        'Int' { $allowed = 'Allowed values: {0} to {1}.' -f $Entry.Min, $Entry.Max }
        'Enum' { $allowed = 'Allowed values: {0}.' -f (@($Entry['Values']) -join ', ') }
        'Time' { $allowed = 'Format: HH:mm, 24-hour local time.' }
        'Days' { $allowed = 'Format: comma-separated English day names (Sunday to Saturday).' }
        default { $allowed = 'Up to 1024 characters.' }
    }
    $paragraphs = New-Object 'System.Collections.Generic.List[string]'
    if ($Context) { $paragraphs.Add($Context) }
    $paragraphs.Add($Entry.Explain)
    $paragraphs.Add($allowed + ' Shipped default: ' + (Format-DLDefault -Entry $Entry -Value $Default) + '.')
    if ($class -eq 'Both')
    {
        $paragraphs.Add('Not configured: the user policy applies, else the local setting (' + $localKey + '), else the shipped default. Machine policy takes precedence over user policy.')
    }
    else
    {
        $paragraphs.Add('Not configured: the local setting (' + $localKey + ') applies, else the shipped default.')
    }
    $paragraphs.Add('Registry: ' + $hive + '\' + $key + ', value ' + $name + ' (' + $registryType + '). A value the engine cannot use is ignored (event 3002) and the next source applies.')

    Add-DLString -Id $PolicyName -Text $Display
    Add-DLString -Id ($PolicyName + '_Help') -Text ($paragraphs -join ($newLine + $newLine))

    $attributes = 'name="{0}" class="{1}" displayName="$(string.{0})" explainText="$(string.{0}_Help)"' -f $PolicyName, $class
    if ($Entry.Type -ne 'Bool') { $attributes += ' presentation="$(presentation.{0})"' -f $PolicyName }
    $attributes += ' key="{0}"' -f (ConvertTo-DLXmlText -Text $key)
    if ($Entry.Type -eq 'Bool') { $attributes += ' valueName="{0}"' -f $name }

    $policyLines.Add(('    <policy {0}>' -f $attributes))
    $policyLines.Add(('      <parentCategory ref="{0}" />' -f $Parent))
    $policyLines.Add(('      <supportedOn ref="{0}" />' -f $supportedOn))

    $label = ConvertTo-DLXmlText -Text $Entry.Display
    switch ($Entry.Type)
    {
        'Bool'
        {
            $policyLines.Add('      <enabledValue>')
            $policyLines.Add('        <decimal value="1" />')
            $policyLines.Add('      </enabledValue>')
            $policyLines.Add('      <disabledValue>')
            $policyLines.Add('        <decimal value="0" />')
            $policyLines.Add('      </disabledValue>')
        }
        'Int'
        {
            $policyLines.Add('      <elements>')
            $policyLines.Add(('        <decimal id="{0}" valueName="{0}" required="true" minValue="{1}" maxValue="{2}" storeAsText="false" />' -f $name, $Entry.Min, $Entry.Max))
            $policyLines.Add('      </elements>')
            Add-DLPresentation -Id $PolicyName -Control @(('<decimalTextBox refId="{0}" defaultValue="{1}">{2}</decimalTextBox>' -f $name, $Default, $label))
        }
        'Enum'
        {
            $values = @($Entry['Values'])
            $policyLines.Add('      <elements>')
            $policyLines.Add(('        <enum id="{0}" valueName="{0}" required="true">' -f $name))
            foreach ($value in $values)
            {
                $valueId = 'Value_' + (ConvertTo-DLAdmxToken -Text $value)
                Add-DLString -Id $valueId -Text $value
                $policyLines.Add(('          <item displayName="$(string.{0})">' -f $valueId))
                $policyLines.Add(('            <value><string>{0}</string></value>' -f (ConvertTo-DLXmlText -Text $value)))
                $policyLines.Add('          </item>')
            }
            $policyLines.Add('        </enum>')
            $policyLines.Add('      </elements>')
            $defaultItem = [array]::IndexOf([string[]]$values, [string]$Default)
            if ($defaultItem -lt 0) { throw ('Default {0} of {1} is not one of its values.' -f $Default, $PolicyName) }
            Add-DLPresentation -Id $PolicyName -Control @(('<dropdownList refId="{0}" noSort="true" defaultItem="{1}">{2}</dropdownList>' -f $name, $defaultItem, $label))
        }
        default
        {
            # Time and Days say their format in the label: the text box is all an admin sees.
            $maxLength = 1024
            $required = 'false'
            if ($Entry.Type -eq 'Time')
            {
                $label = ConvertTo-DLXmlText -Text ($Entry.Display + ', 24-hour local time, for example 03:00')
                $maxLength = 5
                $required = 'true'
            }
            elseif ($Entry.Type -eq 'Days')
            {
                $label = ConvertTo-DLXmlText -Text ($Entry.Display + ', comma-separated day names (Sunday to Saturday), for example Monday,Thursday')
                $maxLength = 255
                $required = 'true'
            }
            $policyLines.Add('      <elements>')
            $policyLines.Add(('        <text id="{0}" valueName="{0}" required="{1}" maxLength="{2}" />' -f $name, $required, $maxLength))
            $policyLines.Add('      </elements>')
            $control = @(('<textBox refId="{0}">' -f $name), ('  <label>{0}</label>' -f $label))
            if ([string]$Default -ne '') { $control += ('  <defaultValue>{0}</defaultValue>' -f (ConvertTo-DLXmlText -Text ([string]$Default))) }
            $control += '</textBox>'
            Add-DLPresentation -Id $PolicyName -Control $control
        }
    }
    $policyLines.Add('    </policy>')
}

# Categories: DeadLoad > one per catalog section > (Categories) one per built-in category id.
Add-DLString -Id 'SUPPORTED_WIN10' -Text 'At least Windows 10'
Add-DLCategory -Name 'DeadLoad' -Display 'DeadLoad'
$sectionCategory = @{}
foreach ($section in $catalog.Sections)
{
    $categoryName = 'Cat_' + (ConvertTo-DLAdmxToken -Text $section.Name)
    if ($section.Name -eq 'Category') { $categoryName = 'Cat_Categories' }
    $sectionCategory[$section.Name] = $categoryName
    Add-DLCategory -Name $categoryName -Display $section.Display -Parent 'DeadLoad'
}
foreach ($definition in $defaults.Categories)
{
    $display = $definition.Id
    if ($definition.ContainsKey('DisplayName')) { $display = '{0} ({1})' -f $definition.DisplayName, $definition.Id }
    Add-DLCategory -Name ('Cat_Category_' + (ConvertTo-DLAdmxToken -Text $definition.Id)) -Display $display -Parent $sectionCategory['Category']
}

$sections = @{}
foreach ($section in $catalog.Sections) { $sections[$section.Name] = $section }

foreach ($entry in @($catalog.Settings | Where-Object { $_.Section -ne 'Category' }))
{
    $section = $sections[$entry.Section]
    Add-DLSettingPolicy -Entry $entry -PolicyName ('{0}_{1}' -f $entry.Section, $entry.Name) -Display $entry.Display -SubKey $section.SubKey -Parent $sectionCategory[$entry.Section] -Default $defaults[$entry.Section][$entry.Name]
}

$categoryEntries = @($catalog.Settings | Where-Object { $_.Section -eq 'Category' })
foreach ($definition in $defaults.Categories)
{
    $id = $definition.Id
    $token = ConvertTo-DLAdmxToken -Text $id
    $subKey = $sections['Category'].SubKey.Replace('{Id}', $id)
    # D22: the category's own text and its risk tier, from Defaults.psd1 (one source with the
    # user's cleanup review).
    if (-not $definition.ContainsKey('Risk') -or -not $defaults.RiskTiers.ContainsKey($definition.Risk)) { throw ('Category {0} has no known Risk tier.' -f $id) }
    $context = 'Category {0} ({1}). {2} Risk tier {3}' -f $id, $definition.DisplayName, $definition.Description, $defaults.RiskTiers[$definition.Risk]
    foreach ($entry in $categoryEntries)
    {
        # Same applicability rule as the engine: an entry with a Categories list is only for those ids.
        if ($entry.ContainsKey('Categories') -and @($entry.Categories) -notcontains $id) { continue }
        $default = $defaults.CategorySettingDefaults[$entry.Name]
        if ($definition.ContainsKey('Settings') -and $definition.Settings.ContainsKey($entry.Name)) { $default = $definition.Settings[$entry.Name] }
        Add-DLSettingPolicy -Entry $entry -PolicyName ('Category_{0}_{1}' -f $token, $entry.Name) -Display ('{0}: {1}' -f $id, $entry.Display) -SubKey $subKey -Parent ('Cat_Category_' + $token) -Default $default -Context $context
    }
}

# Custom targets: one registry value per target; the engine parses and validates each.
$customKey = $policyRoot + '\CustomTargets'
$roots = @($defaults.CustomTargetRoots)
$customHelp = @(
    'Adds cleanup targets beyond the built-in categories. Each entry is one registry value under ' + $customKey + ': the value name is the target name and the value data is its definition. Policy entries take precedence over local entries (' + $localRoot + '\CustomTargets) of the same name.'
    'Value name: 1 to 64 characters (letters, digits, period, underscore, hyphen), starting with a letter or digit. The target becomes category custom.<name>; its settings can be tuned under ' + $policyRoot + '\Categories\custom.<name> like a built-in category.'
    ('Value data: semicolon-separated fields, for example:' + $newLine + 'Path={LocalAppData}\Example\Logs;Include=*.log;Unit=File;AgeDays=30;Action=Delete')
    (@(
            'Path (required): a folder template that starts with an allowed root. Backslashes only; .. is not allowed.'
            'Include: comma-separated file name patterns (default *).'
            'Unit: File or Folder (default File).'
            'AgeDays: items whose activity is older than this many days are selected; at least 1 unless Action is None.'
            'Action: Delete, Compress, Copy, Move or None (default Delete).'
            'Recurse: 1 to include subfolders (default 0).'
        ) -join $newLine)
    ('Allowed roots:' + $newLine + ($roots -join $newLine))
    'Protected paths and protected file types still apply. A target that breaks these rules is ignored (event 3002) and the others still run.'
)
Add-DLString -Id 'CustomTargets' -Text 'Custom targets'
Add-DLString -Id 'CustomTargets_Help' -Text ($customHelp -join ($newLine + $newLine))
Add-DLPresentation -Id 'CustomTargets' -Control @('<listBox refId="CustomTargetsList">Targets (value name = target name, value = definition)</listBox>')
$policyLines.Add(('    <policy name="CustomTargets" class="Machine" displayName="$(string.CustomTargets)" explainText="$(string.CustomTargets_Help)" presentation="$(presentation.CustomTargets)" key="{0}">' -f (ConvertTo-DLXmlText -Text $customKey)))
$policyLines.Add(('      <parentCategory ref="{0}" />' -f $sectionCategory['Category']))
$policyLines.Add(('      <supportedOn ref="{0}" />' -f $supportedOn))
$policyLines.Add('      <elements>')
$policyLines.Add(('        <list id="CustomTargetsList" key="{0}" explicitValue="true" />' -f (ConvertTo-DLXmlText -Text $customKey)))
$policyLines.Add('      </elements>')
$policyLines.Add('    </policy>')

$schema = 'xmlns:xsd="http://www.w3.org/2001/XMLSchema" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" revision="1.0" schemaVersion="1.0" xmlns="http://schemas.microsoft.com/GroupPolicy/2006/07/PolicyDefinitions"'

$admx = New-Object 'System.Collections.Generic.List[string]'
$admx.Add('<?xml version="1.0" encoding="utf-8"?>')
$admx.Add('<!-- Generated by build/New-DeadLoadAdmx.ps1 from src/engine/DeadLoad/Data/Settings.psd1. Do not edit. -->')
$admx.Add(('<policyDefinitions {0}>' -f $schema))
$admx.Add('  <policyNamespaces>')
$admx.Add('    <target prefix="deadload" namespace="DeadLoad.Policies" />')
$admx.Add('  </policyNamespaces>')
$admx.Add('  <resources minRequiredRevision="1.0" />')
$admx.Add('  <supportedOn>')
$admx.Add('    <definitions>')
$admx.Add('      <definition name="SUPPORTED_WIN10" displayName="$(string.SUPPORTED_WIN10)" />')
$admx.Add('    </definitions>')
$admx.Add('  </supportedOn>')
$admx.Add('  <categories>')
$admx.AddRange($categoryLines)
$admx.Add('  </categories>')
$admx.Add('  <policies>')
$admx.AddRange($policyLines)
$admx.Add('  </policies>')
$admx.Add('</policyDefinitions>')

$adml = New-Object 'System.Collections.Generic.List[string]'
$adml.Add('<?xml version="1.0" encoding="utf-8"?>')
$adml.Add('<!-- Generated by build/New-DeadLoadAdmx.ps1 from src/engine/DeadLoad/Data/Settings.psd1. Do not edit. -->')
$adml.Add(('<policyDefinitionResources {0}>' -f $schema))
$adml.Add('  <displayName>DeadLoad</displayName>')
$adml.Add('  <description>Policy settings for DeadLoad, the disk space manager for Autodesk Revit and AutoCAD workstations.</description>')
$adml.Add('  <resources>')
$adml.Add('    <stringTable>')
foreach ($id in $strings.Keys)
{
    # Explain paragraphs keep their CRLF line breaks; Group Policy editors show them as written.
    $adml.Add(('      <string id="{0}">{1}</string>' -f $id, (ConvertTo-DLXmlText -Text $strings[$id])))
}
$adml.Add('    </stringTable>')
$adml.Add('    <presentationTable>')
foreach ($id in $presentations.Keys)
{
    $adml.Add(('      <presentation id="{0}">' -f $id))
    foreach ($line in $presentations[$id]) { $adml.Add('        ' + $line) }
    $adml.Add('      </presentation>')
}
$adml.Add('    </presentationTable>')
$adml.Add('  </resources>')
$adml.Add('</policyDefinitionResources>')

$files = [ordered]@{
    (Join-Path $OutputPath 'DeadLoad.admx')         = (($admx -join $newLine) + $newLine)
    (Join-Path $OutputPath 'en-US\DeadLoad.adml')   = (($adml -join $newLine) + $newLine)
}

$encoding = New-Object System.Text.UTF8Encoding($false)
foreach ($path in @($files.Keys))
{
    $text = $files[$path]
    # Fail before writing anything a Group Policy editor or the repository rules would refuse.
    if ($text -match '[^\x00-\x7F]') { throw ('{0} would contain a non-ASCII character.' -f $path) }
    $null = [xml]$text
    if ($PSCmdlet.ShouldProcess($path, 'Write policy template'))
    {
        [void][System.IO.Directory]::CreateDirectory((Split-Path -Path $path -Parent))
        [System.IO.File]::WriteAllText($path, $text, $encoding)
        Get-Item -LiteralPath $path
    }
}
