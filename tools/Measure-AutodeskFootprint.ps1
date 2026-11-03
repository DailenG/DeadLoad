#Requires -Version 5.1
<#
    .SYNOPSIS
        Read-only inventory of the disk footprint of Autodesk Revit, AutoCAD and shared
        Autodesk components on one workstation.

    .DESCRIPTION
        Produces the measurements DeadLoad's built-in categories are designed against:
        which folders exist per product year, how big they are, how old their contents are,
        which file types they hold, which products are installed, which Autodesk processes
        run under which profile, and the Revit.ini journal and cache settings.

        Strictly read-only. It enumerates folders and reads registry values and Revit.ini
        files; it never writes, deletes, moves, loads a registry hive, or opens a file for
        writing. The only write is the optional -OutFile.

        Safety while enumerating:
        - Reparse points (junctions, symbolic links, cloud placeholders) are counted and
          never traversed, so a planted junction cannot redirect the walk.
        - Desktop Connector workspaces (DC, ACCDocs, BIM 360) and other user data folders
          are reported by existence only and never traversed.
        - Each root has a time budget; a truncated root says so.

        Run elevated or as SYSTEM to see every profile. Run as a normal user to see only
        your own profile; other profiles then show access errors.

        Paths in the output are tokenized ({UserProfile}, {LocalAppData}, {AppData},
        {Temp}, {ProgramData}, {WindowsTemp}, {SystemDrive}) and profiles are reported by
        alias (P1, P2, ...). Raw output still contains the computer name, profile SIDs and
        journal file names; keep it out of source control (measurements/raw/ is ignored).

    .PARAMETER MaxDepth
        How many folder levels below each root get their own row in the tree summaries.
        Deeper content is still counted in its ancestors.

    .PARAMETER RootTimeBudgetSeconds
        Maximum time spent walking any single root before it is marked truncated.

    .PARAMETER OutFile
        Also write the JSON to this path. Without it, JSON goes to the output stream only.

    .EXAMPLE
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Measure-AutodeskFootprint.ps1 -OutFile C:\Windows\Temp\dl-probe.json

        Run from an elevated prompt or an RMM SYSTEM context; collect the JSON afterwards.

    .NOTES
        Part of DeadLoad (docs/MEASUREMENTS.md describes how results are recorded).
        Windows PowerShell 5.1 and PowerShell 7. 7-bit ASCII only.
#>
[CmdletBinding()]
[OutputType([string])]
param
(
    [ValidateRange(1, 6)]
    [int]$MaxDepth = 3,

    [ValidateRange(5, 3600)]
    [int]$RootTimeBudgetSeconds = 120,

    [string]$OutFile
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:ProbeVersion = '1.0.0'
$script:Now = [datetime]::UtcNow

# Process names (without .exe) whose owners matter for the per-profile process guard.
$script:ProcessPatterns = @(
    'Revit*', 'RevitWorker*', 'RevitAccelerator*', 'acad*', 'AcEventSync*', 'AcQMod*',
    'DesktopConnector*', 'Roamer*', 'Navisworks*', 'dwgviewr*', 'AdskAccess*', 'AdskLicensing*',
    'AdSSO*', 'AdODIS*', 'senddmp*', 'AdskIdentityManager*'
)

# File name patterns counted separately in temp folders and Autodesk trees.
$script:TempPatterns = @(
    '*.sv$', '*.ac$', '*.dwl', '*.dwl2', '*.bak', '*.err', '*.dmp', '*.log', '*.tmp',
    '*adsk*', '*autodesk*', '*revit*', '*acad*', '*odis*', '*cer*', '*.rvt', '*.rfa', '*.dwg'
)

#region Helpers

function ConvertTo-ProbeToken
{
    <#
        .SYNOPSIS
            Replaces known path prefixes with tokens so output carries no profile names.
    #>
    param
    (
        [AllowEmptyString()]
        [AllowNull()]
        [string]$Path,

        # Ordered list of @(prefix, token); longest prefixes first.
        [object[]]$Map
    )

    if ([string]::IsNullOrEmpty($Path)) { return $Path }

    foreach ($pair in $Map)
    {
        $prefix = [string]$pair[0]
        if ($prefix -and $Path.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase))
        {
            return ([string]$pair[1]) + $Path.Substring($prefix.Length)
        }
    }

    return $Path
}

function Get-ProbeMachineMap
{
    $systemTemp = Join-Path $env:SystemRoot 'Temp'
    return @(
        , @($systemTemp, '{WindowsTemp}')
        , @($env:ProgramData, '{ProgramData}')
        , @(${env:ProgramFiles(x86)}, '{ProgramFilesX86}')
        , @($env:ProgramFiles, '{ProgramFiles}')
        , @($env:SystemRoot, '{SystemRoot}')
        , @($env:SystemDrive, '{SystemDrive}')
    )
}

function Get-ProbeProfileMap
{
    param ([string]$ProfilePath)

    return @(
        , @((Join-Path $ProfilePath 'AppData\Local\Temp'), '{Temp}')
        , @((Join-Path $ProfilePath 'AppData\Local'), '{LocalAppData}')
        , @((Join-Path $ProfilePath 'AppData\Roaming'), '{AppData}')
        , @($ProfilePath, '{UserProfile}')
    ) + (Get-ProbeMachineMap)
}

function Get-ProbeAgeBucket
{
    # Buckets match the retention windows under discussion (1, 7, 30, 90 days).
    param ([datetime]$StampUtc)

    $days = ($script:Now - $StampUtc).TotalDays
    if ($days -lt 1) { return 'Under1d' }
    if ($days -lt 7) { return 'From1to7d' }
    if ($days -lt 30) { return 'From7to30d' }
    if ($days -lt 90) { return 'From30to90d' }
    return 'Over90d'
}

function Format-ProbeTime
{
    # ISO 8601 text: Windows PowerShell 5.1 would otherwise serialize dates as \/Date(ms)\/.
    param ([AllowNull()] [object]$Value)

    if ($null -eq $Value) { return $null }
    return ([datetime]$Value).ToUniversalTime().ToString('o')
}

function New-ProbeStat
{
    return @{
        Files          = [int64]0
        Bytes          = [int64]0
        Directories    = [int64]0
        ReparsePoints  = [int64]0
        Errors         = [int64]0
        Truncated      = $false
        OldestWrite    = $null
        NewestWrite    = $null
        NewestAccess   = $null
        Extensions     = @{}
        AgeBytes       = @{ Under1d = [int64]0; From1to7d = [int64]0; From7to30d = [int64]0; From30to90d = [int64]0; Over90d = [int64]0 }
        PatternCounts  = @{}
    }
}

function Add-ProbeFile
{
    <#
        .SYNOPSIS
            Adds one file to every summary row that contains it (its ancestors down to the
            row depth). Per-file values are computed once.
    #>
    param ([object[]]$Stats, [System.IO.FileInfo]$File, [string[]]$Patterns)

    $length = [int64]$File.Length
    $write = $File.LastWriteTimeUtc
    $create = $File.CreationTimeUtc
    $access = $File.LastAccessTimeUtc

    # Age by the newer of write and create: a copied-in old file is new to this machine.
    $stamp = $write
    if ($create -gt $stamp) { $stamp = $create }
    $bucket = Get-ProbeAgeBucket -StampUtc $stamp

    $extension = $File.Extension.ToLowerInvariant()
    if (-not $extension) { $extension = '(none)' }

    $matchedPatterns = @(foreach ($pattern in $Patterns) { if ($File.Name -like $pattern) { $pattern } })

    foreach ($stat in $Stats)
    {
        $stat.Files++
        $stat.Bytes += $length

        if ($null -eq $stat.OldestWrite -or $write -lt $stat.OldestWrite) { $stat.OldestWrite = $write }
        if ($null -eq $stat.NewestWrite -or $write -gt $stat.NewestWrite) { $stat.NewestWrite = $write }
        if ($null -eq $stat.NewestAccess -or $access -gt $stat.NewestAccess) { $stat.NewestAccess = $access }

        $stat.AgeBytes[$bucket] += $length

        if (-not $stat.Extensions.ContainsKey($extension)) { $stat.Extensions[$extension] = @([int64]0, [int64]0) }
        $stat.Extensions[$extension][0]++
        $stat.Extensions[$extension][1] += $length

        foreach ($pattern in $matchedPatterns)
        {
            if (-not $stat.PatternCounts.ContainsKey($pattern)) { $stat.PatternCounts[$pattern] = @([int64]0, [int64]0) }
            $stat.PatternCounts[$pattern][0]++
            $stat.PatternCounts[$pattern][1] += $length
        }
    }
}

function ConvertTo-ProbeRecord
{
    param ([hashtable]$Stat, [string]$Path, [int]$Depth)

    $top = @(
        $Stat.Extensions.GetEnumerator() |
            Sort-Object -Property { $_.Value[1] } -Descending |
            Select-Object -First 6 |
            ForEach-Object { '{0}:{1}:{2}' -f $_.Key, $_.Value[0], $_.Value[1] }
    )

    $patterns = [ordered]@{}
    foreach ($key in @($Stat.PatternCounts.Keys | Sort-Object))
    {
        $patterns[$key] = '{0}:{1}' -f $Stat.PatternCounts[$key][0], $Stat.PatternCounts[$key][1]
    }

    return [pscustomobject][ordered]@{
        Path           = $Path
        Depth          = $Depth
        Files          = $Stat.Files
        Bytes          = $Stat.Bytes
        MB             = [math]::Round($Stat.Bytes / 1MB, 1)
        Directories    = $Stat.Directories
        ReparsePoints  = $Stat.ReparsePoints
        Errors         = $Stat.Errors
        Truncated      = $Stat.Truncated
        OldestWriteUtc = Format-ProbeTime $Stat.OldestWrite
        NewestWriteUtc = Format-ProbeTime $Stat.NewestWrite
        NewestAccessUtc = Format-ProbeTime $Stat.NewestAccess
        AgeBytes       = [pscustomobject]$Stat.AgeBytes
        TopExtensions  = $top
        Patterns       = [pscustomobject]$patterns
    }
}

function Invoke-ProbeWalk
{
    <#
        .SYNOPSIS
            Walks a tree with an explicit stack (no recursion, so deep temp trees cannot
            hit the PowerShell call depth limit) and fills one stat per folder at or above
            RowDepth. Each folder carries the list of stats it contributes to.
    #>
    param
    (
        [System.IO.DirectoryInfo]$Root,
        [int]$RowDepth,
        [datetime]$DeadlineUtc,
        [string[]]$Patterns
    )

    $rows = New-Object 'System.Collections.Generic.List[object]'
    $stack = New-Object 'System.Collections.Generic.Stack[object]'
    $stack.Push(@($Root, 0, @()))
    $truncated = $false

    while ($stack.Count -gt 0)
    {
        $frame = $stack.Pop()
        $directory = [System.IO.DirectoryInfo]$frame[0]
        $depth = [int]$frame[1]
        $stats = [object[]]$frame[2]

        if ($depth -le $RowDepth)
        {
            $own = New-ProbeStat
            $rows.Add(@($directory.FullName, $depth, $own))
            $stats = $stats + @(, $own)
        }

        foreach ($stat in $stats) { $stat.Directories++ }

        if ([datetime]::UtcNow -gt $DeadlineUtc)
        {
            $truncated = $true
            break
        }

        $children = $null
        try
        {
            $children = $directory.GetFileSystemInfos()
        }
        catch
        {
            foreach ($stat in $stats) { $stat.Errors++ }
            continue
        }

        foreach ($child in $children)
        {
            # Never follow a junction, symlink or cloud placeholder: count it and move on.
            if (($child.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
            {
                foreach ($stat in $stats) { $stat.ReparsePoints++ }
                continue
            }

            if ($child -is [System.IO.DirectoryInfo])
            {
                $stack.Push(@($child, ($depth + 1), $stats))
            }
            else
            {
                Add-ProbeFile -Stats $stats -File $child -Patterns $Patterns
            }
        }
    }

    # A deadline leaves part of the tree uncounted; every row may be short, so flag all.
    if ($truncated -or $stack.Count -gt 0)
    {
        foreach ($row in $rows) { $row[2].Truncated = $true }
    }

    # Comma keeps the list whole; a single row would otherwise unroll into its fields.
    return , $rows
}

function Measure-ProbeTree
{
    <#
        .SYNOPSIS
            Summarizes a folder tree: one row per folder down to RowDepth, totals in the
            first row (depth 0). Returns $null when the root is absent.
    #>
    param
    (
        [string]$Path,
        [int]$RowDepth,
        [object[]]$Map,
        [string[]]$Patterns = @()
    )

    if (-not $Path) { return $null }

    $root = New-Object System.IO.DirectoryInfo $Path
    if (-not $root.Exists) { return $null }

    $token = ConvertTo-ProbeToken -Path $root.FullName -Map $Map
    if (($root.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
    {
        return [pscustomobject]@{ Root = $token; IsReparsePoint = $true; Rows = @() }
    }

    $deadline = [datetime]::UtcNow.AddSeconds($RootTimeBudgetSeconds)
    $walked = Invoke-ProbeWalk -Root $root -RowDepth $RowDepth -DeadlineUtc $deadline -Patterns $Patterns
    $rows = @(
        foreach ($row in $walked)
        {
            ConvertTo-ProbeRecord -Stat $row[2] -Path (ConvertTo-ProbeToken -Path $row[0] -Map $Map) -Depth $row[1]
        }
    )

    return [pscustomobject]@{
        Root           = $token
        IsReparsePoint = $false
        Rows           = @($rows | Sort-Object -Property Path)
    }
}

function Get-ProbeDirectoryState
{
    # Existence and reparse state only; used for folders that must never be traversed.
    param ([string]$Path, [object[]]$Map)

    $item = New-Object System.IO.DirectoryInfo $Path
    return [pscustomobject]@{
        Path           = ConvertTo-ProbeToken -Path $Path -Map $Map
        Exists         = $item.Exists
        IsReparsePoint = ($item.Exists -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0))
    }
}

#endregion

#region Collectors

function Get-ProbeMachine
{
    $lastAccessRaw = $null
    try
    {
        $lastAccessRaw = [int64](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'NtfsDisableLastAccessUpdate').NtfsDisableLastAccessUpdate
    }
    catch
    {
        $lastAccessRaw = $null
    }

    $os = $null
    try { $os = Get-CimInstance -ClassName Win32_OperatingSystem } catch { $os = $null }

    $drive = New-Object System.IO.DriveInfo ($env:SystemDrive)
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal $identity

    $osCaption = $null
    $osBuild = $null
    if ($os)
    {
        $osCaption = $os.Caption
        $osBuild = $os.BuildNumber
    }

    return [pscustomobject][ordered]@{
        Computer                    = $env:COMPUTERNAME
        OS                          = $osCaption
        OSBuild                     = $osBuild
        PowerShell                  = $PSVersionTable.PSVersion.ToString()
        RunAsSystem                 = $identity.IsSystem
        Elevated                    = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
        NtfsDisableLastAccessUpdate = $lastAccessRaw
        LastAccessTracking          = ($null -eq $lastAccessRaw -or (($lastAccessRaw -band 1) -eq 0))
        SystemDrive                 = $env:SystemDrive
        SystemDriveSizeBytes        = $drive.TotalSize
        SystemDriveFreeBytes        = $drive.AvailableFreeSpace
    }
}

function Get-ProbeProfile
{
    # ProfileList rather than C:\Users\*: catches profiles stored elsewhere and skips the
    # service accounts that have no Autodesk data.
    $list = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    $index = 0
    foreach ($key in @(Get-ChildItem -Path $list | Sort-Object -Property PSChildName))
    {
        $sid = $key.PSChildName
        if ($sid -notmatch '^S-1-(5-21|12-1)-') { continue }

        $path = $null
        try { $path = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -Path $key.PSPath -Name 'ProfileImagePath').ProfileImagePath) } catch { $path = $null }
        if (-not $path) { continue }

        $index++
        [pscustomobject]@{
            Alias  = 'P{0}' -f $index
            Sid    = $sid
            Path   = $path
            Exists = (Test-Path -LiteralPath $path -PathType Container)
            Loaded = (Test-Path -LiteralPath ('Registry::HKEY_USERS\{0}' -f $sid))
        }
    }
}

function Get-ProbeInstalledProduct
{
    $roots = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $map = Get-ProbeMachineMap

    foreach ($root in $roots)
    {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in @(Get-ChildItem -Path $root))
        {
            $values = $null
            try { $values = Get-ItemProperty -Path $key.PSPath } catch { continue }
            # A key with no values yields nothing at all, not an empty object.
            if ($null -eq $values) { continue }

            $names = @($values.PSObject.Properties | ForEach-Object { $_.Name })
            $publisher = if ($names -contains 'Publisher') { [string]$values.Publisher } else { '' }
            $displayName = if ($names -contains 'DisplayName') { [string]$values.DisplayName } else { '' }
            if ($publisher -notlike 'Autodesk*' -and $displayName -notlike '*Autodesk*') { continue }

            [pscustomobject][ordered]@{
                DisplayName     = $displayName
                DisplayVersion  = if ($names -contains 'DisplayVersion') { [string]$values.DisplayVersion } else { $null }
                InstallDate     = if ($names -contains 'InstallDate') { [string]$values.InstallDate } else { $null }
                InstallLocation = if ($names -contains 'InstallLocation') { ConvertTo-ProbeToken -Path ([string]$values.InstallLocation) -Map $map } else { $null }
                InstallSource   = if ($names -contains 'InstallSource') { ConvertTo-ProbeToken -Path ([string]$values.InstallSource) -Map $map } else { $null }
                KeyName         = $key.PSChildName
                View            = if ($root -like '*WOW6432Node*') { 'x86' } else { 'x64' }
            }
        }
    }
}

function Get-ProbeAutoCadRelease
{
    # HKLM:\SOFTWARE\Autodesk\AutoCAD\R<n>\ACAD-<id>:<lcid> maps the R-number in user
    # folder names to a product and year without guessing.
    $root = 'HKLM:\SOFTWARE\Autodesk\AutoCAD'
    if (-not (Test-Path -LiteralPath $root)) { return }

    $map = Get-ProbeMachineMap
    foreach ($release in @(Get-ChildItem -Path $root))
    {
        foreach ($product in @(Get-ChildItem -Path $release.PSPath -ErrorAction SilentlyContinue))
        {
            $values = $null
            try { $values = Get-ItemProperty -Path $product.PSPath } catch { continue }
            if ($null -eq $values) { $names = @() }
            else { $names = @($values.PSObject.Properties | ForEach-Object { $_.Name }) }

            [pscustomobject][ordered]@{
                Release     = $release.PSChildName
                ProductKey  = $product.PSChildName
                ProductName = if ($names -contains 'ProductName') { [string]$values.ProductName } else { $null }
                Language    = if ($names -contains 'Language') { [string]$values.Language } else { $null }
                AcadLocation = if ($names -contains 'AcadLocation') { ConvertTo-ProbeToken -Path ([string]$values.AcadLocation) -Map $map } else { $null }
            }
        }
    }
}

function Get-ProbeProcess
{
    param ([object[]]$Profiles)

    $aliasBySid = @{}
    foreach ($userProfile in $Profiles) { $aliasBySid[$userProfile.Sid] = $userProfile.Alias }

    $processes = @()
    try { $processes = @(Get-CimInstance -ClassName Win32_Process) } catch { return }

    foreach ($process in $processes)
    {
        $name = [System.IO.Path]::GetFileNameWithoutExtension([string]$process.Name)
        $matched = $false
        foreach ($pattern in $script:ProcessPatterns)
        {
            if ($name -like $pattern) { $matched = $true; break }
        }
        if (-not $matched -and [string]$process.ExecutablePath -notlike '*\Autodesk*') { continue }

        $ownerSid = $null
        try
        {
            $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid
            $ownerSid = $owner.Sid
        }
        catch
        {
            $ownerSid = $null
        }

        $owner = 'unknown'
        if ($ownerSid -and $aliasBySid.ContainsKey($ownerSid)) { $owner = $aliasBySid[$ownerSid] }
        elseif ($ownerSid) { $owner = $ownerSid }

        [pscustomobject][ordered]@{
            Name           = [string]$process.Name
            ExecutablePath = ConvertTo-ProbeToken -Path ([string]$process.ExecutablePath) -Map (Get-ProbeMachineMap)
            Owner          = $owner
        }
    }
}

function Get-ProbeRevitJournal
{
    <#
        .SYNOPSIS
            Classifies the top-level files of each Revit Journals folder so the journal
            category's include patterns are based on observed names, not assumptions.
    #>
    param ([string]$LocalAppData, [object[]]$Map)

    $revitRoot = Join-Path $LocalAppData 'Autodesk\Revit'
    if (-not (Test-Path -LiteralPath $revitRoot)) { return }

    foreach ($versionDir in @(Get-ChildItem -LiteralPath $revitRoot -Directory -Force -ErrorAction SilentlyContinue))
    {
        if (($versionDir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { continue }

        $journals = Join-Path $versionDir.FullName 'Journals'
        $dir = New-Object System.IO.DirectoryInfo $journals
        if (-not $dir.Exists) { continue }
        if (($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
        {
            [pscustomobject]@{ Path = ConvertTo-ProbeToken -Path $journals -Map $Map; IsReparsePoint = $true }
            continue
        }

        $classes = [ordered]@{}
        $shapes = @{}
        $sizes = New-Object 'System.Collections.Generic.List[int64]'
        $files = @()
        try { $files = @($dir.GetFiles()) } catch { $files = @() }

        foreach ($file in $files)
        {
            $class = 'Other'
            if ($file.Name -match '^journal\.\d+\.txt$') { $class = 'Journal'; $sizes.Add([int64]$file.Length) }
            elseif ($file.Name -match '\.dmp$') { $class = 'Dump' }
            elseif ($file.Name -match 'worker') { $class = 'WorkerLog' }

            if (-not $classes.Contains($class))
            {
                # Key is Files, not Count: on a dictionary .Count is the key count.
                $classes[$class] = [ordered]@{ Files = 0; Bytes = [int64]0; OldestWriteUtc = $null; NewestWriteUtc = $null }
            }
            $entry = $classes[$class]
            $entry['Files']++
            $entry['Bytes'] += [int64]$file.Length
            if ($null -eq $entry['OldestWriteUtc'] -or $file.LastWriteTimeUtc -lt $entry['OldestWriteUtc']) { $entry['OldestWriteUtc'] = $file.LastWriteTimeUtc }
            if ($null -eq $entry['NewestWriteUtc'] -or $file.LastWriteTimeUtc -gt $entry['NewestWriteUtc']) { $entry['NewestWriteUtc'] = $file.LastWriteTimeUtc }

            # Name shape with digit runs collapsed, e.g. journal.N.N.dmp, so naming
            # conventions are visible without listing every file.
            $shape = [regex]::Replace($file.Name, '\d+', 'N')
            if (-not $shapes.ContainsKey($shape)) { $shapes[$shape] = 0 }
            $shapes[$shape]++
        }

        $subdirs = @()
        try { $subdirs = @($dir.GetDirectories() | ForEach-Object { $_.Name }) } catch { $subdirs = @() }

        $sorted = @($sizes | Sort-Object)
        $median = $null
        if ($sorted.Count -gt 0) { $median = $sorted[[int][math]::Floor($sorted.Count / 2)] }

        foreach ($entry in @($classes.Values))
        {
            $entry['OldestWriteUtc'] = Format-ProbeTime $entry['OldestWriteUtc']
            $entry['NewestWriteUtc'] = Format-ProbeTime $entry['NewestWriteUtc']
        }

        [pscustomobject][ordered]@{
            Path            = ConvertTo-ProbeToken -Path $journals -Map $Map
            IsReparsePoint  = $false
            Classes         = [pscustomobject]$classes
            NameShapes      = [pscustomobject]$shapes
            JournalBytesMin = if ($sorted.Count -gt 0) { $sorted[0] } else { $null }
            JournalBytesMedian = $median
            JournalBytesMax = if ($sorted.Count -gt 0) { $sorted[-1] } else { $null }
            Subdirectories  = $subdirs
        }
    }
}

function Get-ProbeRevitIni
{
    <#
        .SYNOPSIS
            Reads journal and cache related keys from each Revit.ini without changing it.
    #>
    param ([string[]]$Paths, [object[]]$Map)

    foreach ($path in $Paths)
    {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }

        $lines = @()
        try { $lines = @(Get-Content -LiteralPath $path) } catch { continue }

        $section = ''
        $keys = New-Object 'System.Collections.Generic.List[string]'
        foreach ($line in $lines)
        {
            if ($line -match '^\s*\[(.+)\]\s*$') { $section = $Matches[1]; continue }
            if ($line -match '^\s*([^=;]*(Journal|Cache|Shelf)[^=]*)=(.*)$')
            {
                $keys.Add(('[{0}] {1}={2}' -f $section, $Matches[1].Trim(), (ConvertTo-ProbeToken -Path $Matches[3].Trim() -Map $Map)))
            }
        }

        [pscustomobject]@{
            Path = ConvertTo-ProbeToken -Path $path -Map $Map
            Keys = $keys.ToArray()
        }
    }
}

function Get-ProbeProfileFootprint
{
    param ([pscustomobject]$UserProfile)

    $map = Get-ProbeProfileMap -ProfilePath $UserProfile.Path
    $local = Join-Path $UserProfile.Path 'AppData\Local'
    $roaming = Join-Path $UserProfile.Path 'AppData\Roaming'
    $temp = Join-Path $local 'Temp'

    $revitIni = @()
    $revitRoaming = Join-Path $roaming 'Autodesk\Revit'
    if (Test-Path -LiteralPath $revitRoaming)
    {
        $revitIni = @(Get-ChildItem -LiteralPath $revitRoaming -Directory -Force -ErrorAction SilentlyContinue |
                ForEach-Object { Join-Path $_.FullName 'Revit.ini' })
    }

    # User data and sync workspaces: existence only, never traversed.
    $userData = @(
        foreach ($name in 'DC', 'ACCDocs', 'BIM 360', 'Documents', 'Desktop', 'OneDrive')
        {
            Get-ProbeDirectoryState -Path (Join-Path $UserProfile.Path $name) -Map $map
        }
    )

    return [pscustomobject][ordered]@{
        Alias           = $UserProfile.Alias
        Exists          = $UserProfile.Exists
        Loaded          = $UserProfile.Loaded
        LocalAutodesk   = Measure-ProbeTree -Path (Join-Path $local 'Autodesk') -RowDepth $MaxDepth -Map $map -Patterns $script:TempPatterns
        RoamingAutodesk = Measure-ProbeTree -Path (Join-Path $roaming 'Autodesk') -RowDepth $MaxDepth -Map $map -Patterns $script:TempPatterns
        Temp            = Measure-ProbeTree -Path $temp -RowDepth 1 -Map $map -Patterns $script:TempPatterns
        RevitJournals   = @(Get-ProbeRevitJournal -LocalAppData $local -Map $map)
        RevitIni        = @(Get-ProbeRevitIni -Paths $revitIni -Map $map)
        UserDataFolders = $userData
    }
}

function Get-ProbeLegacy
{
    # Remnants of the tool DeadLoad replaces; the package retires them.
    $msiKeys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\{DCD33BCE-C996-4E9B-9044-B77CCCB33EAD}',
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\{DCD33BCE-C996-4E9B-9044-B77CCCB33EAD}'
    )

    $tasks = @()
    try
    {
        $tasks = @(Get-ScheduledTask -ErrorAction Stop |
                Where-Object { $_.TaskName -like '*FreeSpace*' -or $_.TaskPath -like '*FreeSpace*' } |
                ForEach-Object { '{0}{1}' -f $_.TaskPath, $_.TaskName })
    }
    catch
    {
        $tasks = @()
    }

    return [pscustomobject][ordered]@{
        Msi135Installed      = [bool](@($msiKeys | Where-Object { Test-Path -LiteralPath $_ }).Count)
        ProgramFilesFolder   = Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Get-FreeSpace')
        ProgramFilesX86Folder = [bool](${env:ProgramFiles(x86)} -and (Test-Path -LiteralPath (Join-Path ${env:ProgramFiles(x86)} 'Get-FreeSpace')))
        ScheduledTasks       = $tasks
    }
}

#endregion

$machineMap = Get-ProbeMachineMap
$profiles = @(Get-ProbeProfile)

Write-Verbose ('Measuring {0} profile(s).' -f $profiles.Count)
$profileResults = @(
    foreach ($userProfile in $profiles)
    {
        if (-not $userProfile.Exists) { continue }
        Write-Verbose ('Profile {0}' -f $userProfile.Alias)
        Get-ProbeProfileFootprint -UserProfile $userProfile
    }
)

Write-Verbose 'Measuring machine-wide roots.'
$autodeskRoot = Join-Path $env:SystemDrive 'Autodesk'

$result = [pscustomobject][ordered]@{
    SchemaVersion     = 1
    ProbeVersion      = $script:ProbeVersion
    CollectedAtUtc    = Format-ProbeTime $script:Now
    Machine           = Get-ProbeMachine
    Profiles          = @($profiles | ForEach-Object { [pscustomobject]@{ Alias = $_.Alias; Sid = $_.Sid; Exists = $_.Exists; Loaded = $_.Loaded } })
    InstalledProducts = @(Get-ProbeInstalledProduct | Sort-Object -Property DisplayName)
    AutoCadReleases   = @(Get-ProbeAutoCadRelease)
    Processes         = @(Get-ProbeProcess -Profiles $profiles)
    ProgramDataAutodesk = Measure-ProbeTree -Path (Join-Path $env:ProgramData 'Autodesk') -RowDepth $MaxDepth -Map $machineMap -Patterns $script:TempPatterns
    SystemDriveAutodesk = Measure-ProbeTree -Path $autodeskRoot -RowDepth 2 -Map $machineMap -Patterns $script:TempPatterns
    WindowsTemp       = Measure-ProbeTree -Path (Join-Path $env:SystemRoot 'Temp') -RowDepth 1 -Map $machineMap -Patterns $script:TempPatterns
    ProfileFootprints = $profileResults
    Legacy            = Get-ProbeLegacy
}

$json = $result | ConvertTo-Json -Depth 12

if ($OutFile)
{
    $directory = Split-Path -Path $OutFile -Parent
    if ($directory -and -not (Test-Path -LiteralPath $directory))
    {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
    # ASCII keeps the file readable by any tool; tokenized paths and names are ASCII in
    # practice, and anything else is escaped by ConvertTo-Json.
    Set-Content -LiteralPath $OutFile -Value $json -Encoding ASCII
    Write-Verbose ('Wrote {0}' -f $OutFile)
}

$json
