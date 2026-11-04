$script:DLRegistryRoots = @{
    MachinePolicy = 'HKLM:\SOFTWARE\Policies\DeadLoad'
    UserPolicy    = 'HKCU:\SOFTWARE\Policies\DeadLoad'
    Local         = 'HKLM:\SOFTWARE\DeadLoad'
}

function Get-DLRegistryKeyValues
{
    <#
        .SYNOPSIS
            All values of one DeadLoad key as a hashtable (empty when the key is absent).
            SR-8: only HKLM policy, HKCU policy (tray settings) and HKLM local are read.
    #>
    param
    (
        [Parameter(Mandatory)] [ValidateSet('MachinePolicy', 'UserPolicy', 'Local')] [string]$Root,
        [string]$SubKey = ''
    )

    $path = $script:DLRegistryRoots[$Root]
    if ($SubKey) { $path = Join-Path $path $SubKey }
    $values = @{}
    if (-not (Test-Path -LiteralPath $path)) { return $values }
    $key = Get-Item -LiteralPath $path -ErrorAction SilentlyContinue
    if (-not $key) { return $values }
    foreach ($name in $key.GetValueNames())
    {
        if ($name) { $values[$name] = $key.GetValue($name) }
    }
    return $values
}

function Import-DLDataFile
{
    param ([Parameter(Mandatory)] [string]$Name)

    $path = Join-Path (Join-Path $script:DLModuleRoot 'Data') $Name
    # Import-PowerShellDataFile does not exist on Windows PowerShell 5.1 builds older than
    # 5.0 RTM servicing; a restricted-language parse of the file is equivalent.
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw ('{0}: {1}' -f $Name, $errors[0].Message) }
    $data = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.HashtableAst] }, $false)
    return $data.SafeGetValue()
}

function ConvertTo-DLSettingValue
{
    <#
        .SYNOPSIS
            Validates one raw value against its catalog entry. Returns @{ Ok; Value; Error }.
    #>
    param ([hashtable]$Entry, [object]$Raw)

    $fail = { param($message) return @{ Ok = $false; Value = $null; Error = $message } }
    switch ($Entry.Type)
    {
        'Bool'
        {
            $number = 0
            if (-not [int]::TryParse([string]$Raw, [ref]$number) -or ($number -ne 0 -and $number -ne 1)) { return (& $fail 'expected 0 or 1') }
            return @{ Ok = $true; Value = $number; Error = $null }
        }
        'Int'
        {
            $number = [int64]0
            if (-not [int64]::TryParse([string]$Raw, [ref]$number)) { return (& $fail 'expected a whole number') }
            if ($Entry.ContainsKey('Min') -and $number -lt $Entry.Min) { return (& $fail ('below minimum {0}' -f $Entry.Min)) }
            if ($Entry.ContainsKey('Max') -and $number -gt $Entry.Max) { return (& $fail ('above maximum {0}' -f $Entry.Max)) }
            return @{ Ok = $true; Value = $number; Error = $null }
        }
        'Enum'
        {
            foreach ($allowed in $Entry.Values)
            {
                if ([string]$Raw -eq $allowed) { return @{ Ok = $true; Value = $allowed; Error = $null } }
            }
            return (& $fail ('expected one of {0}' -f ($Entry.Values -join ', ')))
        }
        'Time'
        {
            if ([string]$Raw -notmatch '^([01]\d|2[0-3]):[0-5]\d$') { return (& $fail 'expected HH:mm') }
            return @{ Ok = $true; Value = [string]$Raw; Error = $null }
        }
        'Days'
        {
            $days = @(([string]$Raw -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
            if ($days.Count -eq 0) { return (& $fail 'expected at least one day') }
            foreach ($day in $days)
            {
                if ([System.Enum]::GetNames([System.DayOfWeek]) -notcontains $day) { return (& $fail ('not a day name: {0}' -f $day)) }
            }
            return @{ Ok = $true; Value = ($days -join ','); Error = $null }
        }
        default
        {
            $text = [string]$Raw
            if ($text.Length -gt 1024) { return (& $fail 'longer than 1024 characters') }
            return @{ Ok = $true; Value = $text; Error = $null }
        }
    }
}

function Resolve-DLSetting
{
    # One setting through its sources in precedence order; invalid values are rejected and
    # the next source wins (3002).
    param
    (
        [hashtable]$Entry,
        [string]$TraceName,
        [object]$Default,
        [object[]]$Source,
        [System.Collections.Generic.List[object]]$Trace,
        [System.Collections.Generic.List[object]]$Rejected
    )

    foreach ($candidate in $Source)
    {
        if (-not $candidate.Values.ContainsKey($Entry.Name)) { continue }
        $converted = ConvertTo-DLSettingValue -Entry $Entry -Raw $candidate.Values[$Entry.Name]
        if ($converted.Ok)
        {
            $Trace.Add([pscustomobject][ordered]@{ Name = $TraceName; Value = $converted.Value; Source = $candidate.Name })
            return $converted.Value
        }
        $Rejected.Add([pscustomobject][ordered]@{ Name = $TraceName; Value = [string]$candidate.Values[$Entry.Name]; Source = $candidate.Name; Reason = $converted.Error })
    }
    $Trace.Add([pscustomobject][ordered]@{ Name = $TraceName; Value = $Default; Source = 'Default' })
    return $Default
}

function ConvertFrom-DLCustomTarget
{
    <#
        .SYNOPSIS
            Parses one policy custom target ("Path=<template>;Include=*.log;Unit=File;
            AgeDays=30;Action=Delete") into a category definition, or returns the reason it
            is rejected (FR-2: allowlisted roots only, no '..').
    #>
    param ([string]$Name, [string]$Data, [string[]]$AllowedRoot)

    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$') { return [pscustomobject]@{ Definition = $null; Reason = 'invalid name' } }
    $fields = @{}
    foreach ($pair in ([string]$Data -split ';'))
    {
        if (-not $pair.Trim()) { continue }
        $index = $pair.IndexOf('=')
        if ($index -lt 1) { return [pscustomobject]@{ Definition = $null; Reason = ('malformed field {0}' -f $pair) } }
        $fields[$pair.Substring(0, $index).Trim()] = $pair.Substring($index + 1).Trim()
    }
    $path = [string]$fields['Path']
    if (-not $path) { return [pscustomobject]@{ Definition = $null; Reason = 'no Path' } }
    if ($path -match '(^|\\|/)\.\.(\\|/|$)') { return [pscustomobject]@{ Definition = $null; Reason = 'path contains ..' } }
    if ($path -match '/') { return [pscustomobject]@{ Definition = $null; Reason = 'use backslashes' } }

    $allowed = $false
    foreach ($root in $AllowedRoot)
    {
        if ($path.Equals($root, [System.StringComparison]::OrdinalIgnoreCase) -or $path.StartsWith($root + '\', [System.StringComparison]::OrdinalIgnoreCase)) { $allowed = $true; break }
    }
    if (-not $allowed) { return [pscustomobject]@{ Definition = $null; Reason = 'path is outside the allowed roots' } }

    $unit = 'File'
    if ($fields.ContainsKey('Unit')) { $unit = $fields['Unit'] }
    if (@('File', 'Folder') -notcontains $unit) { return [pscustomobject]@{ Definition = $null; Reason = 'Unit must be File or Folder' } }
    $action = 'Delete'
    if ($fields.ContainsKey('Action')) { $action = $fields['Action'] }
    if (@('Delete', 'Compress', 'Copy', 'Move', 'None') -notcontains $action) { return [pscustomobject]@{ Definition = $null; Reason = 'invalid Action' } }
    $age = 0
    if ($fields.ContainsKey('AgeDays') -and -not [int]::TryParse($fields['AgeDays'], [ref]$age)) { return [pscustomobject]@{ Definition = $null; Reason = 'invalid AgeDays' } }
    if ($age -lt 1 -and $action -ne 'None') { return [pscustomobject]@{ Definition = $null; Reason = 'AgeDays of at least 1 is required' } }

    $token = ''
    if ($path -match '^\{(\w+)\}') { $token = $Matches[1] }
    $scope = 'Machine'
    if ($script:DLUserTokens -contains $token) { $scope = 'User' }
    $include = @('*')
    if ($fields.ContainsKey('Include')) { $include = @($fields['Include'] -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }

    return [pscustomobject]@{
        Reason     = $null
        Definition = @{
            Id = ('custom.{0}' -f $Name); Scope = $scope; Unit = $unit; Recurse = ($fields['Recurse'] -eq '1'); Guarded = $true
            Roots = @($path); Include = $include; Custom = $true
            Settings = @{ Enabled = 1; AgeDays = $age; AgeBasis = 'Newest'; RoutineAction = $action; MinAgeHours = 24 }
        }
    }
}

function Get-DLConfiguration
{
    <#
        .SYNOPSIS
            Effective configuration: machine policy > local > shipped defaults per setting
            (tray: machine policy > user policy > local > defaults), each with its source.
            -Override (tests) wins over everything; -NoRegistry skips policy and local.

        .OUTPUTS
            Hashtable: General, Pressure, Schedule, Tray, Categories (ordered id -> @{
            Definition; Settings }), ProtectedPatterns, ProtectedPaths, GuardedProcesses,
            Trace (Name, Value, Source), Rejected (Name, Value, Source, Reason).
    #>
    param
    (
        [hashtable]$Override = @{},
        [switch]$NoRegistry
    )

    $defaults = Import-DLDataFile -Name 'Defaults.psd1'
    $catalog = Import-DLDataFile -Name 'Settings.psd1'
    $trace = New-Object 'System.Collections.Generic.List[object]'
    $rejected = New-Object 'System.Collections.Generic.List[object]'

    $readSources = {
        param([string]$SubKey, [string]$Section, [bool]$UserPolicy)
        $list = @()
        if ($Override.ContainsKey($Section) -and $Override[$Section] -is [hashtable])
        {
            $list += [pscustomobject]@{ Name = 'Override'; Values = $Override[$Section] }
        }
        if (-not $NoRegistry)
        {
            $list += [pscustomobject]@{ Name = 'Policy'; Values = (Get-DLRegistryKeyValues -Root MachinePolicy -SubKey $SubKey) }
            if ($UserPolicy) { $list += [pscustomobject]@{ Name = 'UserPolicy'; Values = (Get-DLRegistryKeyValues -Root UserPolicy -SubKey $SubKey) } }
            $list += [pscustomobject]@{ Name = 'Local'; Values = (Get-DLRegistryKeyValues -Root Local -SubKey $SubKey) }
        }
        return , $list
    }

    $result = @{ Trace = $trace; Rejected = $rejected }
    foreach ($section in @($catalog.Sections | Where-Object { $_.Name -ne 'Category' }))
    {
        $sources = & $readSources $section.SubKey $section.Name ($section.Name -eq 'Tray')
        $values = @{}
        foreach ($entry in @($catalog.Settings | Where-Object { $_.Section -eq $section.Name }))
        {
            $traceName = $entry.Name
            if ($section.SubKey) { $traceName = '{0}\{1}' -f $section.SubKey, $entry.Name }
            $values[$entry.Name] = Resolve-DLSetting -Entry $entry -TraceName $traceName -Default $defaults[$section.Name][$entry.Name] -Source $sources -Trace $trace -Rejected $rejected
        }
        $result[$section.Name] = $values
    }

    foreach ($name in 'ProtectedPatterns', 'ProtectedPaths', 'GuardedProcesses', 'CustomTargetRoots')
    {
        $result[$name] = @($defaults[$name])
        if ($Override.ContainsKey($name)) { $result[$name] = @($Override[$name]) }
    }

    # Built-in definitions, then policy custom targets, unless a test replaces them all.
    $definitions = New-Object 'System.Collections.Generic.List[hashtable]'
    if ($Override.ContainsKey('Definitions')) { foreach ($d in $Override['Definitions']) { $definitions.Add($d) } }
    else { foreach ($d in $defaults.Categories) { $definitions.Add($d) } }

    $customSources = @()
    if ($Override.ContainsKey('CustomTargets')) { $customSources += [pscustomobject]@{ Name = 'Override'; Values = $Override['CustomTargets'] } }
    if (-not $NoRegistry)
    {
        $customSources += [pscustomobject]@{ Name = 'Policy'; Values = (Get-DLRegistryKeyValues -Root MachinePolicy -SubKey 'CustomTargets') }
        $customSources += [pscustomobject]@{ Name = 'Local'; Values = (Get-DLRegistryKeyValues -Root Local -SubKey 'CustomTargets') }
    }
    $seen = @{}
    foreach ($source in $customSources)
    {
        foreach ($name in @($source.Values.Keys | Sort-Object))
        {
            if ($seen.ContainsKey($name)) { continue }
            $seen[$name] = $true
            $parsed = ConvertFrom-DLCustomTarget -Name $name -Data ([string]$source.Values[$name]) -AllowedRoot $result.CustomTargetRoots
            if ($parsed.Definition)
            {
                $definitions.Add($parsed.Definition)
                $trace.Add([pscustomobject][ordered]@{ Name = ('CustomTargets\{0}' -f $name); Value = [string]$source.Values[$name]; Source = $source.Name })
            }
            else
            {
                $rejected.Add([pscustomobject][ordered]@{ Name = ('CustomTargets\{0}' -f $name); Value = [string]$source.Values[$name]; Source = $source.Name; Reason = $parsed.Reason })
            }
        }
    }

    $categoryEntries = @($catalog.Settings | Where-Object { $_.Section -eq 'Category' })
    $categories = [ordered]@{}
    $categoryOverride = @{}
    if ($Override.ContainsKey('Categories')) { $categoryOverride = $Override['Categories'] }
    foreach ($definition in $definitions)
    {
        $id = $definition.Id
        $subKey = 'Categories\{0}' -f $id
        $sources = @()
        if ($categoryOverride.ContainsKey($id)) { $sources += [pscustomobject]@{ Name = 'Override'; Values = $categoryOverride[$id] } }
        if (-not $NoRegistry)
        {
            $sources += [pscustomobject]@{ Name = 'Policy'; Values = (Get-DLRegistryKeyValues -Root MachinePolicy -SubKey $subKey) }
            $sources += [pscustomobject]@{ Name = 'Local'; Values = (Get-DLRegistryKeyValues -Root Local -SubKey $subKey) }
        }
        $settings = @{}
        foreach ($entry in $categoryEntries)
        {
            if ($entry.ContainsKey('Categories') -and $entry.Categories -notcontains $id) { continue }
            $default = $defaults.CategorySettingDefaults[$entry.Name]
            if ($definition.Settings -and $definition.Settings.ContainsKey($entry.Name)) { $default = $definition.Settings[$entry.Name] }
            $settings[$entry.Name] = Resolve-DLSetting -Entry $entry -TraceName ('{0}\{1}' -f $subKey, $entry.Name) -Default $default -Source $sources -Trace $trace -Rejected $rejected
        }
        $categories[$id] = @{ Definition = $definition; Settings = $settings }
    }
    $result['Categories'] = $categories
    $result['Trace'] = $trace.ToArray()
    $result['Rejected'] = $rejected.ToArray()
    return $result
}
