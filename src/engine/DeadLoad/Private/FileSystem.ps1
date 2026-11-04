function Test-DLReparsePoint
{
    <#
        .SYNOPSIS
            True when the entry is a junction, symbolic link, mount point or cloud placeholder.
    #>
    [OutputType([bool])]
    param ([Parameter(Mandatory)] [System.IO.FileSystemInfo]$Item)

    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function ConvertTo-DLFullPath
{
    # Normalized absolute path without a trailing separator, except for a volume root, whose
    # trailing separator is significant ("C:" alone means the current directory on C:).
    param ([Parameter(Mandatory)] [string]$Path)

    $full = [System.IO.Path]::GetFullPath($Path)
    $root = [System.IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\') }
    return $full
}

function Test-DLPathUnder
{
    [OutputType([bool])]
    param ([string]$Path, [string]$Parent)

    $p = ConvertTo-DLFullPath -Path $Path
    $a = ConvertTo-DLFullPath -Path $Parent
    if ($p.Equals($a, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    $prefix = $a
    if (-not $prefix.EndsWith('\')) { $prefix += '\' }
    return $p.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)
}

function Test-DLPathChain
{
    <#
        .SYNOPSIS
            Checks every directory from Anchor down to Path (both inclusive): each must exist
            and none may be a reparse point. Returns $null when the chain is safe, else the
            reason ('OutsideAnchor', 'Missing', 'Reparse') and the offending path.

        .DESCRIPTION
            SR-1: a junction planted anywhere between the profile (or volume root) and a
            target would redirect a SYSTEM deletion; one reparse component disqualifies the
            whole chain.
    #>
    param
    (
        [Parameter(Mandatory)] [string]$Anchor,
        [Parameter(Mandatory)] [string]$Path
    )

    $anchorFull = ConvertTo-DLFullPath -Path $Anchor
    $full = ConvertTo-DLFullPath -Path $Path
    if (-not (Test-DLPathUnder -Path $full -Parent $anchorFull))
    {
        return [pscustomobject]@{ Reason = 'OutsideAnchor'; Path = $full }
    }

    $current = $anchorFull
    $chain = New-Object 'System.Collections.Generic.List[string]'
    $chain.Add($current)
    $rest = $full.Substring($anchorFull.Length).TrimStart('\')
    if ($rest)
    {
        foreach ($segment in $rest.Split('\'))
        {
            $current = [System.IO.Path]::Combine($current, $segment)
            $chain.Add($current)
        }
    }

    foreach ($entry in $chain)
    {
        $directory = New-Object System.IO.DirectoryInfo $entry
        if (-not $directory.Exists) { return [pscustomobject]@{ Reason = 'Missing'; Path = $entry } }
        if (Test-DLReparsePoint -Item $directory) { return [pscustomobject]@{ Reason = 'Reparse'; Path = $entry } }
    }

    return $null
}

function Get-DLChildEntry
{
    # Immediate children of one directory; enumeration errors become a skip, never a throw.
    param
    (
        [Parameter(Mandatory)] [System.IO.DirectoryInfo]$Directory,
        [hashtable]$Run,
        [string]$Category
    )

    try
    {
        return , @($Directory.GetFileSystemInfos())
    }
    catch
    {
        if ($Run) { Add-DLSkip -Run $Run -Path $Directory.FullName -Category $Category -Reason 'AccessDenied' -Detail $_.Exception.Message }
        return , @()
    }
}

function Get-DLTreeFile
{
    <#
        .SYNOPSIS
            Files under a root, found with an explicit stack and no recursion. Reparse points
            are reported and never entered; excluded folder names (relative to the root) and
            protected paths are never entered.

        .OUTPUTS
            One object: Files (FileInfo[]), Directories (DirectoryInfo[] entered, root
            excluded), HasReparse (a reparse point was met below the root).
    #>
    param
    (
        [Parameter(Mandatory)] [System.IO.DirectoryInfo]$Root,
        [bool]$Recurse = $true,
        [string[]]$ExcludeDirectory = @(),
        [string[]]$ProtectedPath = @(),
        [hashtable]$Run,
        [string]$Category
    )

    $files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $directories = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    $hasReparse = $false
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push($Root)
    $rootFull = ConvertTo-DLFullPath -Path $Root.FullName

    while ($stack.Count -gt 0)
    {
        $directory = $stack.Pop()
        foreach ($entry in (Get-DLChildEntry -Directory $directory -Run $Run -Category $Category))
        {
            if (Test-DLReparsePoint -Item $entry)
            {
                $hasReparse = $true
                if ($Run) { Add-DLSkip -Run $Run -Path $entry.FullName -Category $Category -Reason 'Reparse' -Detail 'not followed' }
                continue
            }

            if ($entry -is [System.IO.DirectoryInfo])
            {
                if (-not $Recurse) { continue }
                $relative = $entry.FullName.Substring($rootFull.Length).TrimStart('\')
                $excluded = $false
                foreach ($name in $ExcludeDirectory)
                {
                    if ($relative -like $name) { $excluded = $true; break }
                }
                if ($excluded) { continue }
                if (Test-DLProtectedPath -Path $entry.FullName -ProtectedPath $ProtectedPath)
                {
                    if ($Run) { Add-DLSkip -Run $Run -Path $entry.FullName -Category $Category -Reason 'ProtectedPath' -Detail 'not entered' }
                    continue
                }
                $directories.Add($entry)
                $stack.Push($entry)
            }
            else
            {
                $files.Add([System.IO.FileInfo]$entry)
            }
        }
    }

    return [pscustomobject]@{
        Files       = $files.ToArray()
        Directories = $directories.ToArray()
        HasReparse  = $hasReparse
    }
}

function Test-DLProtectedPath
{
    [OutputType([bool])]
    param ([string]$Path, [string[]]$ProtectedPath)

    foreach ($protected in $ProtectedPath)
    {
        if (-not $protected) { continue }
        if ($protected.IndexOfAny([char[]]'*?') -ge 0)
        {
            # Wildcards (OneDrive*) apply to the last segment of the protected path.
            $parent = Split-Path -Path $protected -Parent
            $leaf = Split-Path -Path $protected -Leaf
            if (Test-DLPathUnder -Path $Path -Parent $parent)
            {
                $relative = (ConvertTo-DLFullPath -Path $Path).Substring((ConvertTo-DLFullPath -Path $parent).Length).TrimStart('\')
                $first = ($relative -split '\\')[0]
                if ($first -and $first -like $leaf) { return $true }
            }
        }
        elseif (Test-DLPathUnder -Path $Path -Parent $protected)
        {
            return $true
        }
    }
    return $false
}

function Test-DLProtectedName
{
    [OutputType([bool])]
    param ([string]$Name, [string[]]$Pattern)

    foreach ($p in $Pattern)
    {
        if ($Name -like $p) { return $true }
    }
    return $false
}

function Get-DLFileSnapshot
{
    # The state an action must find unchanged before it touches the file.
    param ([Parameter(Mandatory)] [System.IO.FileInfo]$File)

    return [pscustomobject]@{
        Path             = $File.FullName
        Length           = [int64]$File.Length
        Attributes       = $File.Attributes
        LastWriteTimeUtc = $File.LastWriteTimeUtc
        CreationTimeUtc  = $File.CreationTimeUtc
    }
}

function Test-DLFileUnchanged
{
    <#
        .SYNOPSIS
            Re-checks a file at action time (SR-3): still present, not a reparse point,
            attributes, size and write/create times as scanned, every ancestor up to the
            group root safe, and an exclusive open succeeds. Returns $null or a skip reason.
    #>
    param
    (
        [Parameter(Mandatory)] [pscustomobject]$Snapshot,
        [Parameter(Mandatory)] [string]$GroupRoot
    )

    $file = New-Object System.IO.FileInfo $Snapshot.Path
    if (-not $file.Exists) { return 'Missing' }
    if (Test-DLReparsePoint -Item $file) { return 'Reparse' }
    if ($file.Attributes -ne $Snapshot.Attributes) { return 'Changed' }
    if ([int64]$file.Length -ne $Snapshot.Length) { return 'Changed' }
    if ($file.LastWriteTimeUtc -ne $Snapshot.LastWriteTimeUtc -or $file.CreationTimeUtc -ne $Snapshot.CreationTimeUtc) { return 'Changed' }

    $chain = Test-DLPathChain -Anchor $GroupRoot -Path $file.DirectoryName
    if ($chain) { return $chain.Reason }

    if (Test-DLFileLocked -Path $file.FullName) { return 'Locked' }
    return $null
}

function Test-DLFileLocked
{
    # Exclusive open: fails while any other handle is open, including Revit's on a live journal.
    [OutputType([bool])]
    param ([Parameter(Mandatory)] [string]$Path)

    $stream = $null
    try
    {
        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::None)
        return $false
    }
    catch
    {
        return $true
    }
    finally
    {
        if ($stream) { $stream.Dispose() }
    }
}

function Remove-DLFile
{
    <#
        .SYNOPSIS
            The deletion primitive (ARCHITECTURE section 8): re-check, then delete one file
            by full path. Never recursive, never a directory, never a reparse point.

        .OUTPUTS
            Status (Deleted, Skipped, Failed, WhatIf), Reason, Bytes (confirmed freed).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param
    (
        [Parameter(Mandatory)] [pscustomobject]$Snapshot,
        [Parameter(Mandatory)] [string]$GroupRoot
    )

    $reason = Test-DLFileUnchanged -Snapshot $Snapshot -GroupRoot $GroupRoot
    if ($reason) { return [pscustomobject]@{ Status = 'Skipped'; Reason = $reason; Bytes = [int64]0 } }

    if (-not $PSCmdlet.ShouldProcess($Snapshot.Path, 'Delete file'))
    {
        return [pscustomobject]@{ Status = 'WhatIf'; Reason = 'WhatIf'; Bytes = [int64]0 }
    }

    try
    {
        $file = New-Object System.IO.FileInfo $Snapshot.Path
        if (($file.Attributes -band [System.IO.FileAttributes]::ReadOnly) -ne 0)
        {
            $file.Attributes = $file.Attributes -band (-bnot [System.IO.FileAttributes]::ReadOnly)
        }
        [System.IO.File]::Delete($Snapshot.Path)
    }
    catch
    {
        return [pscustomobject]@{ Status = 'Failed'; Reason = $_.Exception.Message; Bytes = [int64]0 }
    }

    if ([System.IO.File]::Exists($Snapshot.Path))
    {
        return [pscustomobject]@{ Status = 'Failed'; Reason = 'still present after delete'; Bytes = [int64]0 }
    }
    return [pscustomobject]@{ Status = 'Deleted'; Reason = $null; Bytes = $Snapshot.Length }
}

function Remove-DLEmptyDirectory
{
    <#
        .SYNOPSIS
            Removes directories that are empty, deepest first, one at a time and never
            recursively. Directories outside or equal to the stop root are left alone.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param
    (
        [string[]]$Path,
        [Parameter(Mandatory)] [string]$StopRoot,
        [switch]$IncludeStopRoot
    )

    $removed = 0
    $ordered = @($Path | Where-Object { $_ } | Sort-Object -Unique | Sort-Object -Property { $_.Length } -Descending)
    foreach ($candidate in $ordered)
    {
        $full = ConvertTo-DLFullPath -Path $candidate
        $isRoot = $full.Equals((ConvertTo-DLFullPath -Path $StopRoot), [System.StringComparison]::OrdinalIgnoreCase)
        if ($isRoot -and -not $IncludeStopRoot) { continue }
        if (-not (Test-DLPathUnder -Path $full -Parent $StopRoot)) { continue }

        $directory = New-Object System.IO.DirectoryInfo $full
        if (-not $directory.Exists) { continue }
        if (Test-DLReparsePoint -Item $directory) { continue }
        $entries = @()
        try { $entries = @($directory.GetFileSystemInfos()) } catch { continue }
        if ($entries.Count -gt 0) { continue }

        if ($PSCmdlet.ShouldProcess($full, 'Remove empty directory'))
        {
            try
            {
                [System.IO.Directory]::Delete($full, $false)
                $removed++
            }
            catch
            {
                Write-Verbose ('Directory not removed: {0}' -f $_.Exception.Message)
            }
        }
    }
    return $removed
}
