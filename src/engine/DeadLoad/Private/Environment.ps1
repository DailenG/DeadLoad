# Everything the engine learns about the machine comes through these functions so tests can
# replace them (profiles, processes, free space, last-access tracking, installed Revit years,
# machine paths).

function Get-DLProfile
{
    <#
        .SYNOPSIS
            User profiles from ProfileList (domain/local S-1-5-21 and Entra S-1-12-1 SIDs).
            -Current returns only the profile of the account running the engine.
    #>
    param ([switch]$Current)

    if ($Current)
    {
        $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return [pscustomobject]@{
            Sid    = $identity.User.Value
            Path   = [Environment]::GetFolderPath('UserProfile')
            Loaded = $true
        }
    }

    $list = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    foreach ($key in @(Get-ChildItem -Path $list -ErrorAction SilentlyContinue | Sort-Object -Property PSChildName))
    {
        $sid = $key.PSChildName
        if ($sid -notmatch '^S-1-(5-21|12-1)-') { continue }
        $path = $null
        try { $path = [Environment]::ExpandEnvironmentVariables((Get-ItemProperty -LiteralPath $key.PSPath -Name 'ProfileImagePath' -ErrorAction Stop).ProfileImagePath) } catch { $path = $null }
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Container)) { continue }
        [pscustomobject]@{
            Sid    = $sid
            Path   = $path
            Loaded = (Test-Path -LiteralPath ('Registry::HKEY_USERS\{0}' -f $sid))
        }
    }
}

function Get-DLProcessOwner
{
    <#
        .SYNOPSIS
            Running processes: Name (no extension), Path, and the owner Sid for processes whose
            name matches -OwnerOf (looking up every owner costs a WMI call per process).
    #>
    param ([string[]]$OwnerOf = @('*'))

    $processes = @()
    try { $processes = @(Get-CimInstance -ClassName Win32_Process -ErrorAction Stop -Verbose:$false) } catch { return }
    foreach ($process in $processes)
    {
        $name = [System.IO.Path]::GetFileNameWithoutExtension([string]$process.Name)
        $sid = $null
        $wanted = $false
        foreach ($pattern in $OwnerOf) { if ($name -like $pattern) { $wanted = $true; break } }
        if ($wanted)
        {
            # GetOwnerSid is a read, but Invoke-CimMethod honors -WhatIf: without -WhatIf:$false a
            # what-if run would see no owners and plan as if no guarded process ran.
            try { $sid = (Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop -WhatIf:$false -Confirm:$false -Verbose:$false).Sid } catch { $sid = $null }
        }
        [pscustomobject]@{
            Name = $name
            Sid  = $sid
            Path = [string]$process.ExecutablePath
        }
    }
}

function Get-DLVolume
{
    <#
        .SYNOPSIS
            Size and free bytes of the volume holding a path (default: the system drive).
    #>
    param ([string]$Path = $env:SystemDrive)

    $root = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath(($Path.TrimEnd('\') + '\')))
    $drive = New-Object System.IO.DriveInfo $root
    return [pscustomobject]@{
        Drive     = $root
        SizeBytes = [int64]$drive.TotalSize
        FreeBytes = [int64]$drive.AvailableFreeSpace
    }
}

function Test-DLLastAccessTracking
{
    <#
        .SYNOPSIS
            Whether NTFS records last access (bit 0 of NtfsDisableLastAccessUpdate is 0).
            From Get-FreeSpace 2.0 Test-FSLastAccessTracking (Dailen Gunter, GPL-3.0).
    #>
    [OutputType([bool])]
    param ()

    try
    {
        $raw = [int64](Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem' -Name 'NtfsDisableLastAccessUpdate' -ErrorAction Stop).NtfsDisableLastAccessUpdate
        return (($raw -band 1) -eq 0)
    }
    catch
    {
        # Missing value: Windows defaults to system managed, enabled.
        return $true
    }
}

function Get-DLMachinePath
{
    # Machine-scope tokens. Tests redirect them into a sandbox.
    return @{
        WindowsTemp = (Join-Path $env:SystemRoot 'Temp')
        ProgramData = $env:ProgramData
        SystemDrive = ($env:SystemDrive + '\')
    }
}

function Get-DLInstalledRevitYear
{
    <#
        .SYNOPSIS
            Revit years with a core product entry under Uninstall ("Revit 2026" or
            "Autodesk Revit 2026"); add-ins named "... for Autodesk Revit 2026" do not count.
    #>
    [OutputType([int[]])]
    param ()

    $years = New-Object 'System.Collections.Generic.HashSet[int]'
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall')
    {
        foreach ($key in @(Get-ChildItem -Path $root -ErrorAction SilentlyContinue))
        {
            $name = $null
            try { $name = [string](Get-ItemProperty -LiteralPath $key.PSPath -Name 'DisplayName' -ErrorAction Stop).DisplayName } catch { continue }
            if ($name -match '^\s*(Autodesk\s+)?Revit\s+(\d{4})(\.\d+)?\s*$') { [void]$years.Add([int]$Matches[2]) }
        }
    }
    return , ([int[]]@($years))
}

function Get-DLDesktopConnectorWorkspace
{
    <#
        .SYNOPSIS
            Desktop Connector WorkspaceLocation overrides (machine, and a loaded user hive).
    #>
    param ([string]$Sid)

    $keys = @('HKLM:\SOFTWARE\Autodesk\Desktop Connector Advanced Settings')
    if ($Sid) { $keys += ('Registry::HKEY_USERS\{0}\SOFTWARE\Autodesk\Desktop Connector Advanced Settings' -f $Sid) }
    foreach ($key in $keys)
    {
        try
        {
            $value = [string](Get-ItemProperty -LiteralPath $key -Name 'WorkspaceLocation' -ErrorAction Stop).WorkspaceLocation
            if ($value) { [Environment]::ExpandEnvironmentVariables($value) }
        }
        catch
        {
            Write-Verbose ('No WorkspaceLocation at {0}' -f $key)
        }
    }
}

function Get-DLUtcNow
{
    return [datetime]::UtcNow
}
