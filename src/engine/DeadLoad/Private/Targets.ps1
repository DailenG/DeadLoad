function ConvertTo-DLArray
{
    # A missing definition field is an empty list, never a list holding one $null.
    param ([object]$Value)

    if ($null -eq $Value) { return , @() }
    $list = New-Object 'System.Collections.Generic.List[object]'
    foreach ($entry in $Value) { if ($null -ne $entry) { $list.Add($entry) } }
    return , $list.ToArray()
}

$script:DLUserTokens = @('UserProfile', 'LocalAppData', 'AppData', 'Temp')
$script:DLMachineTokens = @('WindowsTemp', 'ProgramData', 'SystemDrive')

function Get-DLTokenMap
{
    # Token values for one profile (or none: machine scope only).
    param ([pscustomobject]$UserProfile)

    $map = @{}
    $machine = Get-DLMachinePath
    foreach ($key in $machine.Keys) { $map[$key] = $machine[$key] }
    if ($UserProfile)
    {
        $path = ConvertTo-DLFullPath -Path $UserProfile.Path
        $map['UserProfile'] = $path
        $map['LocalAppData'] = Join-Path $path 'AppData\Local'
        $map['AppData'] = Join-Path $path 'AppData\Roaming'
        $map['Temp'] = Join-Path $path 'AppData\Local\Temp'
    }
    return $map
}

function Expand-DLTemplate
{
    <#
        .SYNOPSIS
            Expands {Token} placeholders. Wildcards are left for Resolve-DLRoot. Returns $null
            for an unknown token or a missing value.
    #>
    param ([string]$Template, [hashtable]$Tokens)

    $result = $Template
    foreach ($match in @([regex]::Matches($Template, '\{(\w+)\}')))
    {
        $name = $match.Groups[1].Value
        if (-not $Tokens.ContainsKey($name) -or -not $Tokens[$name]) { return $null }
        $result = $result.Replace($match.Value, ([string]$Tokens[$name]).TrimEnd('\'))
    }
    return $result
}

function Resolve-DLRoot
{
    <#
        .SYNOPSIS
            Resolves one root template to existing directories. The leading token fixes the
            anchor (the profile folder for user tokens, the volume root for machine tokens);
            every component from the anchor down is checked for reparse points (SR-1), and
            wildcard segments are matched against real child directories, never followed
            through a link.

        .OUTPUTS
            Path, Anchor, Version (4-digit year found in the path, or $null).
    #>
    param
    (
        [Parameter(Mandatory)] [string]$Template,
        [Parameter(Mandatory)] [hashtable]$Tokens,
        [hashtable]$Run,
        [string]$Category,
        [string[]]$ProtectedPath = @()
    )

    if ($Template -notmatch '^\{(\w+)\}(.*)$') { return }
    $token = $Matches[1]
    $rest = $Matches[2].Trim('\')
    if ($rest -match '(^|\\)\.\.(\\|$)') { return }
    if (-not $Tokens.ContainsKey($token) -or -not $Tokens[$token]) { return }

    $base = ConvertTo-DLFullPath -Path ([string]$Tokens[$token])
    if ($script:DLUserTokens -contains $token) { $anchor = ConvertTo-DLFullPath -Path $Tokens['UserProfile'] }
    else { $anchor = [System.IO.Path]::GetPathRoot($base) }

    $chain = Test-DLPathChain -Anchor $anchor -Path $base
    if ($chain)
    {
        if ($chain.Reason -eq 'Reparse' -and $Run) { Add-DLSkip -Run $Run -Path $chain.Path -Category $Category -Reason 'Reparse' -Detail 'root disqualified' }
        return
    }

    $current = @($base)
    if ($rest)
    {
        foreach ($segment in $rest.Split('\'))
        {
            $next = New-Object 'System.Collections.Generic.List[string]'
            foreach ($directory in $current)
            {
                if ($segment.IndexOfAny([char[]]'*?') -ge 0)
                {
                    foreach ($entry in (Get-DLChildEntry -Directory (New-Object System.IO.DirectoryInfo $directory) -Run $Run -Category $Category))
                    {
                        if ($entry -isnot [System.IO.DirectoryInfo]) { continue }
                        if ($entry.Name -notlike $segment) { continue }
                        if (Test-DLReparsePoint -Item $entry)
                        {
                            if ($Run) { Add-DLSkip -Run $Run -Path $entry.FullName -Category $Category -Reason 'Reparse' -Detail 'root disqualified' }
                            continue
                        }
                        $next.Add($entry.FullName)
                    }
                }
                else
                {
                    $child = New-Object System.IO.DirectoryInfo (Join-Path $directory $segment)
                    if (-not $child.Exists) { continue }
                    if (Test-DLReparsePoint -Item $child)
                    {
                        if ($Run) { Add-DLSkip -Run $Run -Path $child.FullName -Category $Category -Reason 'Reparse' -Detail 'root disqualified' }
                        continue
                    }
                    $next.Add($child.FullName)
                }
            }
            $current = $next.ToArray()
            if ($current.Count -eq 0) { return }
        }
    }

    foreach ($path in $current)
    {
        if (Test-DLProtectedPath -Path $path -ProtectedPath $ProtectedPath)
        {
            if ($Run) { Add-DLSkip -Run $Run -Path $path -Category $Category -Reason 'ProtectedPath' -Detail 'root under a protected path' }
            continue
        }
        $version = $null
        $years = [regex]::Matches($path.Substring($base.Length), '(?<!\d)(\d{4})(?!\d)')
        if ($years.Count -gt 0) { $version = [int]$years[$years.Count - 1].Groups[1].Value }
        [pscustomobject]@{ Path = $path; Anchor = $anchor; Version = $version }
    }
}

function Get-DLActivity
{
    <#
        .SYNOPSIS
            Activity time (UTC) of an item under an age basis. Accessed counts only when
            last access is usable; otherwise it falls back to Modified. Newest is the max of
            the three (Get-FreeSpace 2.0 Get-FSActivityTime, Dailen Gunter, GPL-3.0).
    #>
    param
    (
        [Parameter(Mandatory)] [pscustomobject]$Item,
        [string]$Basis = 'Newest',
        [bool]$UseAccess = $true
    )

    switch ($Basis)
    {
        'Created' { return $Item.CreatedUtc }
        'Modified' { return $Item.ModifiedUtc }
        'Accessed'
        {
            if ($UseAccess) { return $Item.AccessedUtc }
            return $Item.ModifiedUtc
        }
        default
        {
            $value = $Item.ModifiedUtc
            if ($Item.CreatedUtc -gt $value) { $value = $Item.CreatedUtc }
            if ($UseAccess -and $Item.AccessedUtc -gt $value) { $value = $Item.AccessedUtc }
            return $value
        }
    }
}

function New-DLItem
{
    param
    (
        [string]$Category,
        [pscustomobject]$Group,
        [string]$Kind,
        [string]$Path,
        [int64]$Length,
        [datetime]$CreatedUtc,
        [datetime]$ModifiedUtc,
        [datetime]$AccessedUtc
    )

    return [pscustomobject]@{
        Category      = $Category
        Group         = $Group
        Kind          = $Kind
        Path          = $Path
        Name          = [System.IO.Path]::GetFileName($Path)
        Length        = $Length
        CreatedUtc    = $CreatedUtc
        ModifiedUtc   = $ModifiedUtc
        AccessedUtc   = $AccessedUtc
        Snapshot      = $null
        Files         = @()
        Directories   = @()
        ProtectReason = $null
        Activity      = $null
        Rank          = 0
        Selected      = $false
        SelectRule    = $null
        Done          = $false
    }
}

function Get-DLGroupItem
{
    <#
        .SYNOPSIS
            The items of one group (one resolved root): files, immediate child folders, or
            the root itself, per the category's unit. Folder and root items carry the exact
            files measured so actions touch nothing else.
    #>
    param
    (
        [Parameter(Mandatory)] [hashtable]$Run,
        [Parameter(Mandatory)] [hashtable]$Definition,
        [Parameter(Mandatory)] [pscustomobject]$Group,
        [string[]]$ProtectedPattern = @(),
        [string[]]$ProtectedPath = @()
    )

    $id = $Definition.Id
    $root = New-Object System.IO.DirectoryInfo $Group.Path
    $include = ConvertTo-DLArray -Value $Definition.Include
    if ($include.Count -eq 0) { $include = @('*') }
    $exclude = ConvertTo-DLArray -Value $Definition.Exclude
    $excludeDirectory = ConvertTo-DLArray -Value $Definition.ExcludeDirectory
    $patternsApply = ($Definition.ProtectedPatternsApply -ne $false)

    switch ($Definition.Unit)
    {
        'File'
        {
            $tree = Get-DLTreeFile -Root $root -Recurse ([bool]$Definition.Recurse) -ExcludeDirectory $excludeDirectory -ProtectedPath $ProtectedPath -Run $Run -Category $id
            foreach ($file in $tree.Files)
            {
                if (-not (Test-DLProtectedName -Name $file.Name -Pattern $include)) { continue }
                if (Test-DLProtectedName -Name $file.Name -Pattern $exclude) { continue }
                $item = New-DLItem -Category $id -Group $Group -Kind 'File' -Path $file.FullName -Length $file.Length -CreatedUtc $file.CreationTimeUtc -ModifiedUtc $file.LastWriteTimeUtc -AccessedUtc $file.LastAccessTimeUtc
                $item.Snapshot = Get-DLFileSnapshot -File $file
                if ($patternsApply -and (Test-DLProtectedName -Name $file.Name -Pattern $ProtectedPattern)) { $item.ProtectReason = 'ProtectedPattern' }
                $item
            }
        }
        'Folder'
        {
            foreach ($entry in (Get-DLChildEntry -Directory $root -Run $Run -Category $id))
            {
                if ($entry -isnot [System.IO.DirectoryInfo]) { continue }
                if (Test-DLReparsePoint -Item $entry)
                {
                    Add-DLSkip -Run $Run -Path $entry.FullName -Category $id -Reason 'Reparse' -Detail 'not followed'
                    continue
                }
                if (Test-DLProtectedName -Name $entry.Name -Pattern $exclude) { continue }
                Get-DLAggregateItem -Run $Run -Definition $Definition -Group $Group -Directory $entry -ExcludeDirectory @() -ProtectedPattern $ProtectedPattern -ProtectedPath $ProtectedPath
            }
        }
        'Root'
        {
            Get-DLAggregateItem -Run $Run -Definition $Definition -Group $Group -Directory $root -ExcludeDirectory $excludeDirectory -ProtectedPattern $ProtectedPattern -ProtectedPath $ProtectedPath
        }
    }
}

function Get-DLAggregateItem
{
    # A folder judged as one unit: activity is the newest anywhere inside, size the total.
    param
    (
        [hashtable]$Run,
        [hashtable]$Definition,
        [pscustomobject]$Group,
        [System.IO.DirectoryInfo]$Directory,
        [string[]]$ExcludeDirectory,
        [string[]]$ProtectedPattern,
        [string[]]$ProtectedPath
    )

    $tree = Get-DLTreeFile -Root $Directory -Recurse $true -ExcludeDirectory $ExcludeDirectory -ProtectedPath $ProtectedPath -Run $Run -Category $Definition.Id
    $item = New-DLItem -Category $Definition.Id -Group $Group -Kind 'Folder' -Path $Directory.FullName -Length 0 -CreatedUtc $Directory.CreationTimeUtc -ModifiedUtc $Directory.LastWriteTimeUtc -AccessedUtc $Directory.LastAccessTimeUtc
    $length = [int64]0
    $snapshots = New-Object 'System.Collections.Generic.List[object]'
    $patternsApply = ($Definition.ProtectedPatternsApply -ne $false)
    foreach ($file in $tree.Files)
    {
        $length += $file.Length
        $snapshots.Add((Get-DLFileSnapshot -File $file))
        if ($file.CreationTimeUtc -gt $item.CreatedUtc) { $item.CreatedUtc = $file.CreationTimeUtc }
        if ($file.LastWriteTimeUtc -gt $item.ModifiedUtc) { $item.ModifiedUtc = $file.LastWriteTimeUtc }
        if ($file.LastAccessTimeUtc -gt $item.AccessedUtc) { $item.AccessedUtc = $file.LastAccessTimeUtc }
        if ($patternsApply -and -not $item.ProtectReason -and (Test-DLProtectedName -Name $file.Name -Pattern $ProtectedPattern)) { $item.ProtectReason = 'ProtectedPattern' }
    }
    foreach ($sub in $tree.Directories)
    {
        if ($sub.CreationTimeUtc -gt $item.CreatedUtc) { $item.CreatedUtc = $sub.CreationTimeUtc }
        if ($sub.LastWriteTimeUtc -gt $item.ModifiedUtc) { $item.ModifiedUtc = $sub.LastWriteTimeUtc }
    }
    # A reparse point inside cannot be removed, and the folder could not be emptied.
    if ($tree.HasReparse) { $item.ProtectReason = 'Reparse' }
    $item.Length = $length
    $item.Files = $snapshots.ToArray()
    $item.Directories = @($tree.Directories | ForEach-Object { $_.FullName })
    return $item
}
