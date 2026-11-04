Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

function Get-DLSha256
{
    param ([Parameter(Mandatory)] [System.IO.Stream]$Stream)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { return ([System.BitConverter]::ToString($sha.ComputeHash($Stream)) -replace '-', '') }
    finally { $sha.Dispose() }
}

function Get-DLFileSha256
{
    param ([Parameter(Mandatory)] [string]$Path)

    # Read-share so a file another process holds open can still be hashed (support bundle).
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try { return Get-DLSha256 -Stream $stream }
    finally { $stream.Dispose() }
}

function Expand-DLDestination
{
    <#
        .SYNOPSIS
            Expands a Copy/Move destination: {Computer}, {User} (profile folder name),
            {Category}, {Version}, {Root}; then appends the item's path relative to its group.
    #>
    param ([string]$Template, [pscustomobject]$Item, [string]$RelativePath)

    $user = ''
    if ($Item.Group.ProfilePath) { $user = Split-Path -Path $Item.Group.ProfilePath -Leaf }
    $version = ''
    if ($Item.Group.Version) { $version = [string]$Item.Group.Version }
    $base = $Template.Replace('{Computer}', $env:COMPUTERNAME).Replace('{User}', $user).Replace('{Category}', $Item.Category).Replace('{Version}', $version).Replace('{Root}', $Item.Group.Path)
    if ($base -match '(^|\\)\.\.(\\|$)') { return $null }
    return (Join-Path $base $RelativePath)
}

function Add-DLArchiveEntry
{
    <#
        .SYNOPSIS
            Appends one file to a zip archive under a unique entry name. Returns the entry
            name and the archive's length growth.
    #>
    param
    (
        [Parameter(Mandatory)] [string]$ArchivePath,
        [Parameter(Mandatory)] [string]$SourcePath,
        [Parameter(Mandatory)] [string]$EntryName
    )

    $before = [int64]0
    if ([System.IO.File]::Exists($ArchivePath)) { $before = (New-Object System.IO.FileInfo $ArchivePath).Length }

    $zip = [System.IO.Compression.ZipFile]::Open($ArchivePath, [System.IO.Compression.ZipArchiveMode]::Update)
    try
    {
        $name = $EntryName
        if ($zip.GetEntry($name))
        {
            $stem = [System.IO.Path]::GetFileNameWithoutExtension($EntryName)
            $extension = [System.IO.Path]::GetExtension($EntryName)
            $name = '{0}.{1}{2}' -f $stem, (Get-DLUtcNow).ToString('yyyyMMddHHmmssfff'), $extension
        }
        $entry = $zip.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
        $entry.LastWriteTime = [System.IO.File]::GetLastWriteTime($SourcePath)
        $source = [System.IO.File]::Open($SourcePath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
        try
        {
            $target = $entry.Open()
            try { $source.CopyTo($target) } finally { $target.Dispose() }
        }
        finally { $source.Dispose() }
    }
    finally { $zip.Dispose() }

    return [pscustomobject]@{
        EntryName   = $name
        GrowthBytes = (New-Object System.IO.FileInfo $ArchivePath).Length - $before
    }
}

function Test-DLArchiveEntry
{
    # Reopens the archive read-only and compares the entry with the source by length and hash.
    [OutputType([bool])]
    param ([string]$ArchivePath, [string]$EntryName, [int64]$Length, [string]$Sha256)

    try
    {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($ArchivePath)
        try
        {
            $entry = $zip.GetEntry($EntryName)
            if (-not $entry) { return $false }
            if ([int64]$entry.Length -ne $Length) { return $false }
            $stream = $entry.Open()
            try { return ((Get-DLSha256 -Stream $stream) -eq $Sha256) }
            finally { $stream.Dispose() }
        }
        finally { $zip.Dispose() }
    }
    catch
    {
        return $false
    }
}

function Remove-DLArchiveEntry
{
    # Drops an entry that failed verification so the archive holds only verified copies.
    param ([string]$ArchivePath, [string]$EntryName)

    try
    {
        $zip = [System.IO.Compression.ZipFile]::Open($ArchivePath, [System.IO.Compression.ZipArchiveMode]::Update)
        try
        {
            $entry = $zip.GetEntry($EntryName)
            if ($entry) { $entry.Delete() }
        }
        finally { $zip.Dispose() }
    }
    catch
    {
        Write-Verbose ('Could not drop entry {0}: {1}' -f $EntryName, $_.Exception.Message)
    }
}

function Copy-DLVerifiedFile
{
    <#
        .SYNOPSIS
            Copies a file and verifies length and SHA-256; an identical destination is a no-op.
            Returns Status (Copied, Identical, Failed) and a message.
    #>
    param ([string]$SourcePath, [string]$DestinationPath, [int64]$Length)

    try
    {
        $sourceHash = Get-DLFileSha256 -Path $SourcePath
        if ([System.IO.File]::Exists($DestinationPath))
        {
            $existing = New-Object System.IO.FileInfo $DestinationPath
            if ($existing.Length -eq $Length -and (Get-DLFileSha256 -Path $DestinationPath) -eq $sourceHash)
            {
                return [pscustomobject]@{ Status = 'Identical'; Message = $null }
            }
            return [pscustomobject]@{ Status = 'Failed'; Message = 'a different file exists at the destination' }
        }
        $directory = Split-Path -Path $DestinationPath -Parent
        if (-not [System.IO.Directory]::Exists($directory)) { [void][System.IO.Directory]::CreateDirectory($directory) }
        [System.IO.File]::Copy($SourcePath, $DestinationPath, $false)
        $copied = New-Object System.IO.FileInfo $DestinationPath
        if ($copied.Length -ne $Length -or (Get-DLFileSha256 -Path $DestinationPath) -ne $sourceHash)
        {
            return [pscustomobject]@{ Status = 'Failed'; Message = 'verification failed after copy' }
        }
        return [pscustomobject]@{ Status = 'Copied'; Message = $null }
    }
    catch
    {
        return [pscustomobject]@{ Status = 'Failed'; Message = $_.Exception.Message }
    }
}

function Invoke-DLItemAction
{
    <#
        .SYNOPSIS
            Applies one action to one planned item and records the outcome. Report-only and
            -WhatIf log what would happen and change nothing.

        .OUTPUTS
            Status (Acted, Partial, Skipped, Failed, WhatIf, Budget) and FreedBytes.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    param
    (
        [Parameter(Mandatory)] [hashtable]$Run,
        [Parameter(Mandatory)] [pscustomobject]$Item,
        [Parameter(Mandatory)] [string]$Action,
        [Parameter(Mandatory)] [hashtable]$Settings,
        [Parameter(Mandatory)] [hashtable]$Definition,
        [string]$Rule
    )

    $category = $Run.Categories[$Item.Category]
    if (-not (Test-DLBudget -Run $Run -NextBytes $Item.Length))
    {
        $Item.Outcome = 'Budget'
        return [pscustomobject]@{ Status = 'Budget'; FreedBytes = [int64]0 }
    }

    if ($Run.ReportOnly -or $Run.WhatIf)
    {
        Write-DLDecision -Run $Run -Category $Item.Category -Decision 'WouldAct' -Rule $Rule -Path $Item.Path -Detail ('action={0} bytes={1}' -f $Action, $Item.Length)
        $Item.Done = $true
        $Item.Outcome = 'WhatIf'
        return [pscustomobject]@{ Status = 'WhatIf'; FreedBytes = [int64]0 }
    }

    $result = $null
    switch ($Action)
    {
        'Delete' { $result = Invoke-DLDeleteItem -Run $Run -Item $Item }
        'Compress' { $result = Invoke-DLCompressItem -Run $Run -Item $Item -Definition $Definition }
        'Copy' { $result = Invoke-DLCopyItem -Run $Run -Item $Item -Settings $Settings -Move $false }
        'Move' { $result = Invoke-DLCopyItem -Run $Run -Item $Item -Settings $Settings -Move $true }
        default { $result = [pscustomobject]@{ Status = 'Skipped'; FreedBytes = [int64]0; Reason = 'NoAction' } }
    }

    $Item.Done = $true
    $Item.Outcome = $result.Status
    $Item.FreedBytes = [int64]$result.FreedBytes
    if ($result.PSObject.Properties['Reason']) { $Item.OutcomeReason = $result.Reason }
    if ($result.Status -in 'Acted', 'Partial')
    {
        $Run.ActedCount++
        $Run.ActedBytes += $result.FreedBytes
        $Run.Totals.FreedBytes += $result.FreedBytes
        $category.ActedCount++
        $category.FreedBytes += $result.FreedBytes
        switch ($Action)
        {
            'Delete' { $Run.Totals.DeletedCount++ }
            'Compress' { $Run.Totals.CompressedCount++ }
            'Copy' { $Run.Totals.CopiedCount++ }
            'Move' { $Run.Totals.MovedCount++ }
        }
        Write-DLDecision -Run $Run -Category $Item.Category -Decision 'Acted' -Rule $Rule -Path $Item.Path -Detail ('action={0} freed={1} status={2}' -f $Action, $result.FreedBytes, $result.Status)
    }
    return $result
}

function Invoke-DLDeleteItem
{
    param ([hashtable]$Run, [pscustomobject]$Item)

    if ($Item.Kind -eq 'File')
    {
        $outcome = Remove-DLFile -Snapshot $Item.Snapshot -GroupRoot $Item.Group.Path -Confirm:$false
        switch ($outcome.Status)
        {
            'Deleted'
            {
                $parent = Split-Path -Path $Item.Path -Parent
                [void]$Item.Group.Touched.Add($parent)
                return [pscustomobject]@{ Status = 'Acted'; FreedBytes = $outcome.Bytes }
            }
            'Skipped'
            {
                Add-DLSkip -Run $Run -Path $Item.Path -Category $Item.Category -Reason $outcome.Reason -Detail 're-check at action time'
                return [pscustomobject]@{ Status = 'Skipped'; FreedBytes = [int64]0; Reason = $outcome.Reason }
            }
            default
            {
                Add-DLFailure -Run $Run -Path $Item.Path -Category $Item.Category -Message $outcome.Reason
                return [pscustomobject]@{ Status = 'Failed'; FreedBytes = [int64]0; Reason = 'Failed' }
            }
        }
    }

    # Folder or root: every measured file, then the directories left empty.
    $freed = [int64]0
    $kept = 0
    $firstReason = $null
    foreach ($snapshot in $Item.Files)
    {
        $outcome = Remove-DLFile -Snapshot $snapshot -GroupRoot $Item.Group.Path -Confirm:$false
        if ($outcome.Status -eq 'Deleted') { $freed += $outcome.Bytes; continue }
        $kept++
        if ($outcome.Status -eq 'Skipped')
        {
            if (-not $firstReason) { $firstReason = $outcome.Reason }
            Add-DLSkip -Run $Run -Path $snapshot.Path -Category $Item.Category -Reason $outcome.Reason -Detail 're-check at action time'
        }
        else
        {
            if (-not $firstReason) { $firstReason = 'Failed' }
            Add-DLFailure -Run $Run -Path $snapshot.Path -Category $Item.Category -Message $outcome.Reason
        }
    }
    $directories = @($Item.Directories) + @($Item.Path)
    $isRoot = ($Item.Path -eq $Item.Group.Path)
    [void](Remove-DLEmptyDirectory -Path $directories -StopRoot $Item.Group.Path -IncludeStopRoot:$isRoot -Confirm:$false)

    if ($kept -eq 0) { return [pscustomobject]@{ Status = 'Acted'; FreedBytes = $freed } }
    if ($freed -gt 0) { return [pscustomobject]@{ Status = 'Partial'; FreedBytes = $freed; Reason = $firstReason } }
    return [pscustomobject]@{ Status = 'Skipped'; FreedBytes = [int64]0; Reason = $firstReason }
}

function Invoke-DLCompressItem
{
    <#
        .SYNOPSIS
            FR-9: appends the file to the group's monthly archive, verifies the entry (length
            and SHA-256) from a fresh read-only open, and only then deletes the original.
            Freed bytes are the source size minus the archive's growth.
    #>
    param ([hashtable]$Run, [pscustomobject]$Item, [hashtable]$Definition)

    if ($Item.Kind -ne 'File')
    {
        Add-DLFailure -Run $Run -Path $Item.Path -Category $Item.Category -Message 'Compress applies to files only'
        return [pscustomobject]@{ Status = 'Failed'; FreedBytes = [int64]0 }
    }

    $reason = Test-DLFileUnchanged -Snapshot $Item.Snapshot -GroupRoot $Item.Group.Path
    if ($reason)
    {
        Add-DLSkip -Run $Run -Path $Item.Path -Category $Item.Category -Reason $reason -Detail 're-check before compress'
        return [pscustomobject]@{ Status = 'Skipped'; FreedBytes = [int64]0 }
    }

    $template = [string]$Definition.ArchivePath
    if (-not $template) { $template = '{Root}\Archive\{Category}-{yyyy}-{MM}.zip' }
    $month = $Item.Snapshot.LastWriteTimeUtc.ToLocalTime()
    $archivePath = $template.Replace('{Root}', $Item.Group.Path).Replace('{Category}', $Item.Category).Replace('{yyyy}', $month.ToString('yyyy')).Replace('{MM}', $month.ToString('MM'))
    $archiveDirectory = Split-Path -Path $archivePath -Parent

    # The archive folder lives inside the group root; it must not be (or become) a link.
    if ([System.IO.Directory]::Exists($archiveDirectory))
    {
        $chain = Test-DLPathChain -Anchor $Item.Group.Path -Path $archiveDirectory
        if ($chain)
        {
            Add-DLSkip -Run $Run -Path $archiveDirectory -Category $Item.Category -Reason $chain.Reason -Detail 'archive folder unsafe'
            return [pscustomobject]@{ Status = 'Skipped'; FreedBytes = [int64]0 }
        }
    }
    else
    {
        [void][System.IO.Directory]::CreateDirectory($archiveDirectory)
    }
    if ([System.IO.File]::Exists($archivePath) -and (Test-DLReparsePoint -Item (New-Object System.IO.FileInfo $archivePath)))
    {
        Add-DLSkip -Run $Run -Path $archivePath -Category $Item.Category -Reason 'Reparse' -Detail 'archive is a link'
        return [pscustomobject]@{ Status = 'Skipped'; FreedBytes = [int64]0 }
    }

    try
    {
        $sourceHash = Get-DLFileSha256 -Path $Item.Path
        $added = Add-DLArchiveEntry -ArchivePath $archivePath -SourcePath $Item.Path -EntryName $Item.Name
    }
    catch
    {
        Add-DLFailure -Run $Run -Path $Item.Path -Category $Item.Category -Message ('compress failed: {0}' -f $_.Exception.Message)
        return [pscustomobject]@{ Status = 'Failed'; FreedBytes = [int64]0 }
    }

    if (-not (Test-DLArchiveEntry -ArchivePath $archivePath -EntryName $added.EntryName -Length $Item.Snapshot.Length -Sha256 $sourceHash))
    {
        Remove-DLArchiveEntry -ArchivePath $archivePath -EntryName $added.EntryName
        Add-DLFailure -Run $Run -Path $Item.Path -Category $Item.Category -Message 'archive entry failed verification; original kept'
        return [pscustomobject]@{ Status = 'Failed'; FreedBytes = [int64]0 }
    }

    $outcome = Remove-DLFile -Snapshot $Item.Snapshot -GroupRoot $Item.Group.Path -Confirm:$false
    if ($outcome.Status -ne 'Deleted')
    {
        # Verified copy in the archive, original still present: report, never retry blindly.
        Add-DLSkip -Run $Run -Path $Item.Path -Category $Item.Category -Reason $outcome.Reason -Detail 'archived, original kept'
        return [pscustomobject]@{ Status = 'Skipped'; FreedBytes = [int64]0 }
    }
    $freed = [math]::Max([int64]0, $outcome.Bytes - $added.GrowthBytes)
    return [pscustomobject]@{ Status = 'Acted'; FreedBytes = [int64]$freed }
}

function Invoke-DLCopyItem
{
    param ([hashtable]$Run, [pscustomobject]$Item, [hashtable]$Settings, [bool]$Move)

    $template = [string]$Settings.Destination
    if (-not $template)
    {
        Add-DLFailure -Run $Run -Path $Item.Path -Category $Item.Category -Message 'no Destination configured'
        return [pscustomobject]@{ Status = 'Failed'; FreedBytes = [int64]0 }
    }

    $snapshots = @($Item.Snapshot)
    if ($Item.Kind -ne 'File') { $snapshots = @($Item.Files) }
    $freed = [int64]0
    $problems = 0
    foreach ($snapshot in $snapshots)
    {
        $reason = Test-DLFileUnchanged -Snapshot $snapshot -GroupRoot $Item.Group.Path
        if ($reason)
        {
            Add-DLSkip -Run $Run -Path $snapshot.Path -Category $Item.Category -Reason $reason -Detail 're-check before copy'
            $problems++
            continue
        }
        $relative = $snapshot.Path.Substring((ConvertTo-DLFullPath -Path $Item.Group.Path).Length).TrimStart('\')
        $destination = Expand-DLDestination -Template $template -Item $Item -RelativePath $relative
        if (-not $destination)
        {
            Add-DLFailure -Run $Run -Path $snapshot.Path -Category $Item.Category -Message 'destination rejected'
            $problems++
            continue
        }
        $copy = Copy-DLVerifiedFile -SourcePath $snapshot.Path -DestinationPath $destination -Length $snapshot.Length
        if ($copy.Status -eq 'Failed')
        {
            Add-DLFailure -Run $Run -Path $snapshot.Path -Category $Item.Category -Message $copy.Message
            $problems++
            continue
        }
        if ($Move)
        {
            $outcome = Remove-DLFile -Snapshot $snapshot -GroupRoot $Item.Group.Path -Confirm:$false
            if ($outcome.Status -eq 'Deleted')
            {
                $freed += $outcome.Bytes
                [void]$Item.Group.Touched.Add((Split-Path -Path $snapshot.Path -Parent))
            }
            else
            {
                Add-DLSkip -Run $Run -Path $snapshot.Path -Category $Item.Category -Reason $outcome.Reason -Detail 'copied, original kept'
                $problems++
            }
        }
    }

    if ($Move -and $Item.Kind -ne 'File')
    {
        $isRoot = ($Item.Path -eq $Item.Group.Path)
        [void](Remove-DLEmptyDirectory -Path (@($Item.Directories) + @($Item.Path)) -StopRoot $Item.Group.Path -IncludeStopRoot:$isRoot -Confirm:$false)
    }

    if ($problems -eq 0) { return [pscustomobject]@{ Status = 'Acted'; FreedBytes = $freed } }
    if ($problems -lt $snapshots.Count) { return [pscustomobject]@{ Status = 'Partial'; FreedBytes = $freed } }
    return [pscustomobject]@{ Status = 'Failed'; FreedBytes = [int64]0 }
}
