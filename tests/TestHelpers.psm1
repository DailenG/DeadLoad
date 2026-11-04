Set-StrictMode -Version 2.0

function New-DLSandbox
{
    <#
        .SYNOPSIS
            A throwaway tree under %TEMP%: two profiles, a machine area (Windows\Temp,
            ProgramData, a system drive root), a canary folder outside every target, and a
            data root for reports. Every test builds its own.
    #>
    $root = Join-Path ([System.IO.Path]::GetTempPath()) ('DeadLoadTest-' + [guid]::NewGuid().ToString('N').Substring(0, 12))
    $paths = [ordered]@{
        Root        = $root
        Alice       = Join-Path $root 'Users\alice'
        Bob         = Join-Path $root 'Users\bob'
        WindowsTemp = Join-Path $root 'Windows\Temp'
        ProgramData = Join-Path $root 'ProgramData'
        SystemDrive = Join-Path $root 'C'
        Canary      = Join-Path $root 'Canary'
        Data        = Join-Path $root 'Data'
    }
    foreach ($key in @($paths.Keys)) { [void][System.IO.Directory]::CreateDirectory($paths[$key]) }
    foreach ($user in 'Alice', 'Bob')
    {
        foreach ($sub in 'AppData\Local\Temp', 'AppData\Roaming', 'Documents')
        {
            [void][System.IO.Directory]::CreateDirectory((Join-Path $paths[$user] $sub))
        }
    }
    $paths.AliceSid = 'S-1-5-21-1000-1000-1000-1001'
    $paths.BobSid = 'S-1-5-21-1000-1000-1000-1002'
    return [pscustomobject]$paths
}

function Remove-DLSandbox
{
    # Junctions are removed first and without recursion, so cleanup never reaches a target.
    param ([Parameter(Mandatory)] [pscustomobject]$Sandbox)

    if (-not [System.IO.Directory]::Exists($Sandbox.Root)) { return }
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Sandbox.Root)
    $links = New-Object 'System.Collections.Generic.List[string]'
    while ($stack.Count -gt 0)
    {
        $directory = $stack.Pop()
        foreach ($entry in (New-Object System.IO.DirectoryInfo $directory).GetFileSystemInfos())
        {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $links.Add($entry.FullName); continue }
            if ($entry -is [System.IO.DirectoryInfo]) { $stack.Push($entry.FullName) }
            else { $entry.Attributes = 'Normal' }
        }
    }
    foreach ($link in $links)
    {
        if ([System.IO.Directory]::Exists($link)) { [System.IO.Directory]::Delete($link, $false) } else { [System.IO.File]::Delete($link) }
    }
    [System.IO.Directory]::Delete($Sandbox.Root, $true)
}

function New-DLTestFile
{
    <#
        .SYNOPSIS
            Creates a file of a given size with controlled timestamps (days ago, UTC).
    #>
    param
    (
        [Parameter(Mandatory)] [string]$Path,
        [int64]$Bytes = 1024,
        [double]$ModifiedDaysAgo = 0,
        [double]$CreatedDaysAgo = -1,
        [double]$AccessedDaysAgo = -1
    )

    $directory = Split-Path -Path $Path -Parent
    [void][System.IO.Directory]::CreateDirectory($directory)
    $stream = [System.IO.File]::Create($Path)
    try
    {
        if ($Bytes -gt 0)
        {
            $buffer = New-Object byte[] ([int][math]::Min($Bytes, 65536))
            (New-Object System.Random 7).NextBytes($buffer)
            $left = $Bytes
            while ($left -gt 0)
            {
                $chunk = [int][math]::Min($left, $buffer.Length)
                $stream.Write($buffer, 0, $chunk)
                $left -= $chunk
            }
        }
    }
    finally { $stream.Dispose() }

    $now = [datetime]::UtcNow
    if ($CreatedDaysAgo -lt 0) { $CreatedDaysAgo = $ModifiedDaysAgo }
    if ($AccessedDaysAgo -lt 0) { $AccessedDaysAgo = $ModifiedDaysAgo }
    [System.IO.File]::SetCreationTimeUtc($Path, $now.AddDays(-$CreatedDaysAgo))
    [System.IO.File]::SetLastWriteTimeUtc($Path, $now.AddDays(-$ModifiedDaysAgo))
    [System.IO.File]::SetLastAccessTimeUtc($Path, $now.AddDays(-$AccessedDaysAgo))
    return (New-Object System.IO.FileInfo $Path)
}

function New-DLJunction
{
    param ([Parameter(Mandatory)] [string]$Link, [Parameter(Mandatory)] [string]$Target)

    [void][System.IO.Directory]::CreateDirectory((Split-Path -Path $Link -Parent))
    $null = New-Item -ItemType Junction -Path $Link -Value $Target
}

function Get-DLTreeState
{
    <#
        .SYNOPSIS
            Every file under a folder (no link followed) with length, write time and SHA-256,
            and every directory: two equal states mean nothing changed on disk.
    #>
    param ([Parameter(Mandatory)] [string]$Path)

    $lines = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($Path)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    while ($stack.Count -gt 0)
    {
        $directory = $stack.Pop()
        $lines.Add('D ' + $directory.Substring($Path.Length))
        foreach ($entry in @((New-Object System.IO.DirectoryInfo $directory).GetFileSystemInfos() | Sort-Object -Property Name))
        {
            if (($entry.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) { $lines.Add('L ' + $entry.FullName.Substring($Path.Length)); continue }
            if ($entry -is [System.IO.DirectoryInfo]) { $stack.Push($entry.FullName); continue }
            $bytes = [System.IO.File]::ReadAllBytes($entry.FullName)
            $lines.Add(('F {0} {1} {2} {3}' -f $entry.FullName.Substring($Path.Length), $entry.Length, $entry.LastWriteTimeUtc.Ticks, ([System.BitConverter]::ToString($sha.ComputeHash($bytes)))))
        }
    }
    $sha.Dispose()
    return (($lines | Sort-Object) -join "`n")
}

function New-DLTestConfiguration
{
    <#
        .SYNOPSIS
            Test configuration: no pressure (floor 0), generous budgets, optional replacement
            category definitions and per-category overrides.
    #>
    param
    (
        [object[]]$Definitions,
        [hashtable]$Categories = @{},
        [hashtable]$General = @{},
        [hashtable]$Pressure = @{}
    )

    $config = @{
        General    = @{ Enabled = 1; ReportOnly = 0; TimeBudgetMinutes = 30; MaxDeleteMBPerRun = 0; MaxItemsPerRun = 0; UseLastAccess = 1; LogRetentionDays = 30 }
        Pressure   = @{ FloorPercent = 0; FloorGB = 0; TargetPercent = 0; TargetGB = 0 }
        Categories = $Categories
    }
    foreach ($key in $General.Keys) { $config.General[$key] = $General[$key] }
    foreach ($key in $Pressure.Keys) { $config.Pressure[$key] = $Pressure[$key] }
    if ($PSBoundParameters.ContainsKey('Definitions')) { $config.Definitions = $Definitions }
    return $config
}

Export-ModuleMember -Function New-DLSandbox, Remove-DLSandbox, New-DLTestFile, New-DLJunction, Get-DLTreeState, New-DLTestConfiguration
