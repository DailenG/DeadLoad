<#
    .SYNOPSIS
        Install, upgrade and uninstall helpers for the DeadLoad Chocolatey package.

    .DESCRIPTION
        chocolateyInstall.ps1 and chocolateyUninstall.ps1 stay thin and call these functions,
        so every step can be unit tested against a %TEMP% sandbox or an HKCU test key: each
        function takes the root path it changes as a parameter, and every state change is
        behind SupportsShouldProcess. build/Build.ps1 imports it for Get-DLManifestData,
        Copy-DLTree and Remove-DLProductTree.

        Runs under Windows PowerShell 5.1 (Chocolatey) and PowerShell 7 (build, tests).
#>

Set-StrictMode -Version 2.0

$script:DLLegacyProductCode = '{DCD33BCE-C996-4E9B-9044-B77CCCB33EAD}'
$script:DLDefaultUninstallRoots = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
)
# Well-known SIDs, never account names: names are localized on non-English Windows.
$script:DLSidSystem = 'S-1-5-18'
$script:DLSidAdministrators = 'S-1-5-32-544'
$script:DLSidUsers = 'S-1-5-32-545'
$script:DLPackageSwitches = @('NoTray', 'ReportOnly', 'InstallAdmxLocally', 'PurgeData')

function Test-DLReparsePoint
{
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [System.IO.FileSystemInfo]$Item)
    return (($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-DLManifestData
{
    <#
        .SYNOPSIS
            Reads a .psd1 data file without executing it (Import-PowerShellDataFile does not
            exist on 5.1).
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw ('Cannot parse {0}: {1}' -f $Path, $errors[0].Message) }
    $table = $ast.Find({ $args[0] -is [System.Management.Automation.Language.HashtableAst] }, $false)
    if (-not $table) { throw ('No hashtable in {0}' -f $Path) }
    return $table.SafeGetValue()
}

function Get-DLPackageOptions
{
    <#
        .SYNOPSIS
            Normalizes Chocolatey package parameters (Get-PackageParameters output) into four
            booleans: NoTray, ReportOnly, InstallAdmxLocally, PurgeData.

        .DESCRIPTION
            A bare switch (/NoTray) arrives as the string 'true'. Names are case-insensitive.
            An unknown name is a warning (a typo must not fail a fleet upgrade); an unreadable
            value is an error (a switch must never be guessed).
    #>
    [CmdletBinding()]
    param ([System.Collections.IDictionary]$Parameters = @{})

    $options = [ordered]@{}
    foreach ($name in $script:DLPackageSwitches) { $options[$name] = $false }

    foreach ($key in @($Parameters.Keys))
    {
        $match = $script:DLPackageSwitches | Where-Object { $_ -eq [string]$key } | Select-Object -First 1
        if (-not $match)
        {
            Write-Warning ('Unknown package parameter /{0} ignored. Known: /{1}' -f $key, ($script:DLPackageSwitches -join ', /'))
            continue
        }
        $value = $Parameters[$key]
        if ($value -is [bool]) { $options[$match] = $value; continue }
        $text = ([string]$value).Trim()
        if (@('', 'true', '1', 'yes') -contains $text) { $options[$match] = $true }
        elseif (@('false', '0', 'no') -contains $text) { $options[$match] = $false }
        else { throw ('Package parameter /{0} has an unreadable value: {1}' -f $match, $text) }
    }
    return [pscustomobject]$options
}

function Remove-DLProductTree
{
    <#
        .SYNOPSIS
            Deletes a folder tree DeadLoad (or the legacy product) owns, refusing the whole
            tree when the folder or anything below it is a reparse point.

        .DESCRIPTION
            The engine's rule (never recurse a target, never follow a link) protects user
            data. This is the one place a whole tree is removed, and only for folders the
            product itself created (install folder, its upgrade siblings, legacy install
            folders, build output). Walking first and refusing on any junction or symlink means
            a planted link can never redirect the delete outside the product folder. Files and
            folders are then deleted by full path, deepest first, without following anything.
            Returns $true when removed, $false when absent or WhatIf; throws on a refusal.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param ([Parameter(Mandatory)] [string]$Path)

    if (-not [System.IO.Directory]::Exists($Path)) { return $false }
    $root = New-Object System.IO.DirectoryInfo $Path
    if (Test-DLReparsePoint -Item $root) { throw ('Refused: {0} is a reparse point.' -f $Path) }

    $directories = New-Object 'System.Collections.Generic.List[string]'
    $files = New-Object 'System.Collections.Generic.List[string]'
    $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
    $stack.Push($root)
    while ($stack.Count -gt 0)
    {
        $directory = $stack.Pop()
        $directories.Add($directory.FullName)
        foreach ($entry in $directory.GetFileSystemInfos())
        {
            if (Test-DLReparsePoint -Item $entry) { throw ('Refused: {0} contains the reparse point {1}.' -f $Path, $entry.FullName) }
            if ($entry -is [System.IO.DirectoryInfo]) { $stack.Push($entry) } else { $files.Add($entry.FullName) }
        }
    }

    if (-not $PSCmdlet.ShouldProcess($Path, 'Delete product folder')) { return $false }
    foreach ($file in $files)
    {
        [System.IO.File]::SetAttributes($file, [System.IO.FileAttributes]::Normal)
        [System.IO.File]::Delete($file)
    }
    # A parent is always listed before its children, so the reverse order is deepest first.
    for ($i = $directories.Count - 1; $i -ge 0; $i--) { [System.IO.Directory]::Delete($directories[$i], $false) }
    return $true
}

function Copy-DLTree
{
    # Copies a package folder; links in the source are skipped, never followed.
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$Source, [Parameter(Mandatory)] [string]$Destination)

    $sourceRoot = (New-Object System.IO.DirectoryInfo $Source).FullName.TrimEnd('\')
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($sourceRoot)
    while ($stack.Count -gt 0)
    {
        $directory = $stack.Pop()
        $target = $Destination + $directory.Substring($sourceRoot.Length)
        [void][System.IO.Directory]::CreateDirectory($target)
        foreach ($entry in (New-Object System.IO.DirectoryInfo $directory).GetFileSystemInfos())
        {
            if (Test-DLReparsePoint -Item $entry) { Write-Warning ('Skipped link in payload: {0}' -f $entry.FullName); continue }
            if ($entry -is [System.IO.DirectoryInfo]) { $stack.Push($entry.FullName); continue }
            # *.exe.ignore files only stop Chocolatey from shimming the exe; not product files.
            if ($entry.Name -like '*.exe.ignore') { continue }
            [System.IO.File]::Copy($entry.FullName, (Join-Path $target $entry.Name), $true)
        }
    }
}

function Update-DLTreeInPlace
{
    <#
        Fallback when a folder cannot be swapped because a file in it is in use (a running
        tray holds DeadLoadTray.exe open; closing it would interrupt the user). A file in use
        can still be renamed, so it is moved aside as *.dlold-<id> and the new copy written;
        the leftover goes at the next install or upgrade.
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$Source, [Parameter(Mandatory)] [string]$Destination)

    $sourceRoot = (New-Object System.IO.DirectoryInfo $Source).FullName.TrimEnd('\')
    $destinationRoot = (New-Object System.IO.DirectoryInfo $Destination).FullName.TrimEnd('\')
    $wanted = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    $stack = New-Object 'System.Collections.Generic.Stack[string]'
    $stack.Push($sourceRoot)
    while ($stack.Count -gt 0)
    {
        $directory = $stack.Pop()
        $relativeDirectory = $directory.Substring($sourceRoot.Length)
        [void]$wanted.Add($relativeDirectory)
        [void][System.IO.Directory]::CreateDirectory($destinationRoot + $relativeDirectory)
        foreach ($entry in (New-Object System.IO.DirectoryInfo $directory).GetFileSystemInfos())
        {
            if ($entry -is [System.IO.DirectoryInfo]) { $stack.Push($entry.FullName); continue }
            $relative = $entry.FullName.Substring($sourceRoot.Length)
            [void]$wanted.Add($relative)
            $target = $destinationRoot + $relative
            try { [System.IO.File]::Copy($entry.FullName, $target, $true) }
            catch
            {
                $aside = '{0}.dlold-{1}' -f $target, [guid]::NewGuid().ToString('N')
                [System.IO.File]::Move($target, $aside)
                [System.IO.File]::Copy($entry.FullName, $target, $true)
                Write-Warning ('{0} was in use; the old copy stays as {1} until the next install.' -f $target, $aside)
            }
        }
    }

    # Files the new payload no longer has; links are never entered.
    $stack.Push($destinationRoot)
    while ($stack.Count -gt 0)
    {
        $directory = $stack.Pop()
        foreach ($entry in (New-Object System.IO.DirectoryInfo $directory).GetFileSystemInfos())
        {
            if (Test-DLReparsePoint -Item $entry) { continue }
            $relative = $entry.FullName.Substring($destinationRoot.Length)
            if ($entry -is [System.IO.DirectoryInfo]) { $stack.Push($entry.FullName); continue }
            if ($wanted.Contains($relative) -or $entry.Name -match '\.dlold-[0-9a-f]{32}$') { continue }
            try { [System.IO.File]::Delete($entry.FullName) }
            catch
            {
                [System.IO.File]::Move($entry.FullName, ('{0}.dlold-{1}' -f $entry.FullName, [guid]::NewGuid().ToString('N')))
            }
        }
    }
}

function Remove-DLStaleUpgradeItems
{
    # Leftovers of an interrupted or in-use upgrade: <folder>.new-<id> and <folder>.old-<id>
    # siblings, and *.dlold-<id> files inside the installed folders.
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$Destination, [Parameter(Mandatory)] [string[]]$Folder)

    $pattern = '^({0})\.(new|old)-[0-9a-f]{{32}}$' -f (($Folder | ForEach-Object { [regex]::Escape($_) }) -join '|')
    foreach ($entry in (New-Object System.IO.DirectoryInfo $Destination).GetDirectories())
    {
        if ($entry.Name -notmatch $pattern) { continue }
        try { [void](Remove-DLProductTree -Path $entry.FullName -Confirm:$false) }
        catch { Write-Warning ('Could not remove {0}: {1}' -f $entry.FullName, $_.Exception.Message) }
    }
    foreach ($name in $Folder)
    {
        $root = Join-Path $Destination $name
        if (-not [System.IO.Directory]::Exists($root)) { continue }
        $stack = New-Object 'System.Collections.Generic.Stack[string]'
        $stack.Push($root)
        while ($stack.Count -gt 0)
        {
            foreach ($entry in (New-Object System.IO.DirectoryInfo $stack.Pop()).GetFileSystemInfos())
            {
                if (Test-DLReparsePoint -Item $entry) { continue }
                if ($entry -is [System.IO.DirectoryInfo]) { $stack.Push($entry.FullName); continue }
                if ($entry.Name -notmatch '\.dlold-[0-9a-f]{32}$') { continue }
                try { [System.IO.File]::Delete($entry.FullName) } catch { Write-Verbose ('Still in use: {0}' -f $entry.FullName) }
            }
        }
    }
}

function Install-DLPayload
{
    <#
        .SYNOPSIS
            Installs the package payload folders (engine, tray, policy) into the install folder.

        .DESCRIPTION
            Each folder is copied to a <name>.new-<id> sibling first and then swapped in by
            two renames, so a task starting mid-upgrade sees either the old or the new engine,
            never a half-copied one. Folders missing from the source are left as they are;
            anything else in the destination (and ProgramData, which this never touches) is
            kept. When a folder cannot be renamed because a file in it is in use, it is updated
            file by file instead (Update-DLTreeInPlace). Idempotent.

        .OUTPUTS
            One row per folder: Folder, Path, Mode (Created, Replaced, InPlace, Missing, WhatIf).
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param
    (
        [Parameter(Mandatory)] [string]$Source,
        [Parameter(Mandatory)] [string]$Destination,
        [string[]]$Folder = @('engine', 'tray', 'policy')
    )

    if (-not [System.IO.Directory]::Exists($Source)) { throw ('Payload not found: {0}' -f $Source) }
    if ($PSCmdlet.ShouldProcess($Destination, 'Create install folder'))
    {
        [void][System.IO.Directory]::CreateDirectory($Destination)
        Remove-DLStaleUpgradeItems -Destination $Destination -Folder $Folder
    }

    foreach ($name in $Folder)
    {
        $from = Join-Path $Source $name
        $target = Join-Path $Destination $name
        if (-not [System.IO.Directory]::Exists($from))
        {
            Write-Verbose ('Payload has no {0} folder; {1} left as it is.' -f $name, $target)
            [pscustomobject]@{ Folder = $name; Path = $target; Mode = 'Missing' }
            continue
        }
        if (-not $PSCmdlet.ShouldProcess($target, ('Install {0} from {1}' -f $name, $from)))
        {
            [pscustomobject]@{ Folder = $name; Path = $target; Mode = 'WhatIf' }
            continue
        }

        $id = [guid]::NewGuid().ToString('N')
        $staging = Join-Path $Destination ('{0}.new-{1}' -f $name, $id)
        Copy-DLTree -Source $from -Destination $staging

        $mode = 'Created'
        $old = $null
        if ([System.IO.Directory]::Exists($target))
        {
            if (Test-DLReparsePoint -Item (New-Object System.IO.DirectoryInfo $target)) { throw ('Refused: {0} is a reparse point.' -f $target) }
            $old = Join-Path $Destination ('{0}.old-{1}' -f $name, $id)
            try
            {
                [System.IO.Directory]::Move($target, $old)
                $mode = 'Replaced'
            }
            catch
            {
                Write-Verbose ('{0} could not be swapped ({1}); updating in place.' -f $target, $_.Exception.Message)
                Update-DLTreeInPlace -Source $staging -Destination $target
                [void](Remove-DLProductTree -Path $staging -Confirm:$false)
                [pscustomobject]@{ Folder = $name; Path = $target; Mode = 'InPlace' }
                continue
            }
        }

        try { [System.IO.Directory]::Move($staging, $target) }
        catch
        {
            if ($old) { [System.IO.Directory]::Move($old, $target) }
            throw
        }
        if ($old)
        {
            try { [void](Remove-DLProductTree -Path $old -Confirm:$false) }
            catch { Write-Warning ('Old copy kept at {0}: {1}' -f $old, $_.Exception.Message) }
        }
        [pscustomobject]@{ Folder = $name; Path = $target; Mode = $mode }
    }
}

function Set-DLDirectorySecurity
{
    # DirectoryInfo.SetAccessControl is an instance method on .NET Framework and an extension
    # method (invisible to PowerShell) on .NET Core.
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$Path, [Parameter(Mandatory)] [System.Security.AccessControl.DirectorySecurity]$Security)

    $info = New-Object System.IO.DirectoryInfo $Path
    $extensions = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($extensions) { $extensions::SetAccessControl($info, $Security) } else { $info.SetAccessControl($Security) }
}

function Set-DLDataAcl
{
    <#
        .SYNOPSIS
            Creates the data folder (%ProgramData%\DeadLoad) with its protected ACL: inheritance
            broken, SYSTEM and Administrators full control, Users read and execute, owner
            Administrators (SR-8: nothing the engine reads is user-writable).

        .PARAMETER OwnerSid
            Owner to set (default Administrators). Empty leaves the owner as it is. Tests pass
            their own SID because a non-elevated token may not assign Administrators.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param
    (
        [Parameter(Mandatory)] [string]$Path,
        [AllowEmptyString()] [string]$OwnerSid = 'S-1-5-32-544'
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Create folder and apply protected ACL')) { return }
    $info = [System.IO.Directory]::CreateDirectory($Path)
    if (Test-DLReparsePoint -Item $info) { throw ('Refused: {0} is a reparse point.' -f $Path) }

    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)
    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $propagation = [System.Security.AccessControl.PropagationFlags]::None
    $allow = [System.Security.AccessControl.AccessControlType]::Allow
    $grants = @(
        @($script:DLSidSystem, [System.Security.AccessControl.FileSystemRights]::FullControl),
        @($script:DLSidAdministrators, [System.Security.AccessControl.FileSystemRights]::FullControl),
        @($script:DLSidUsers, [System.Security.AccessControl.FileSystemRights]::ReadAndExecute)
    )
    foreach ($grant in $grants)
    {
        $sid = New-Object System.Security.Principal.SecurityIdentifier $grant[0]
        $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule ($sid, $grant[1], $inherit, $propagation, $allow)))
    }
    if ($OwnerSid) { $security.SetOwner((New-Object System.Security.Principal.SecurityIdentifier $OwnerSid)) }
    Set-DLDirectorySecurity -Path $info.FullName -Security $security
}

function Register-DLEventSource
{
    # Needs administrator rights: SourceExists scans every log, including Security.
    [CmdletBinding(SupportsShouldProcess)]
    param ([string]$Source = 'DeadLoad', [string]$LogName = 'Application')

    if ([System.Diagnostics.EventLog]::SourceExists($Source))
    {
        $current = [System.Diagnostics.EventLog]::LogNameFromSourceName($Source, '.')
        if ($current -ne $LogName) { Write-Warning ('Event source {0} is registered to {1}, not {2}.' -f $Source, $current, $LogName) }
        return 'Present'
    }
    if (-not $PSCmdlet.ShouldProcess($Source, ('Register event source in {0}' -f $LogName))) { return 'WhatIf' }
    [System.Diagnostics.EventLog]::CreateEventSource($Source, $LogName)
    return 'Registered'
}

function Unregister-DLEventSource
{
    [CmdletBinding(SupportsShouldProcess)]
    param ([string]$Source = 'DeadLoad')

    if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) { return 'Absent' }
    if (-not $PSCmdlet.ShouldProcess($Source, 'Remove event source')) { return 'WhatIf' }
    [System.Diagnostics.EventLog]::DeleteEventSource($Source)
    return 'Removed'
}

function Set-DLLocalRegistry
{
    <#
        .SYNOPSIS
            Writes the package's local values under HKLM\SOFTWARE\DeadLoad: Version and
            InstallPath (REG_SZ), and ReportOnly = 1 (REG_DWORD) when asked. Without
            -ReportOnly an existing ReportOnly value is left alone: an administrator may have
            set it outside the package.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param
    (
        [string]$Path = 'HKLM:\SOFTWARE\DeadLoad',
        [Parameter(Mandatory)] [string]$Version,
        [Parameter(Mandatory)] [string]$InstallPath,
        [switch]$ReportOnly
    )

    if (-not $PSCmdlet.ShouldProcess($Path, 'Write Version, InstallPath and package options')) { return }
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -Path $Path -Force }
    $null = New-ItemProperty -LiteralPath $Path -Name 'Version' -Value $Version -PropertyType String -Force
    $null = New-ItemProperty -LiteralPath $Path -Name 'InstallPath' -Value $InstallPath -PropertyType String -Force
    if ($ReportOnly) { $null = New-ItemProperty -LiteralPath $Path -Name 'ReportOnly' -Value 1 -PropertyType DWord -Force }
}

function Remove-DLLocalRegistry
{
    <#
        .SYNOPSIS
            Removes the package's Version and InstallPath values; the key itself only when it is
            then empty, or with -Purge (local settings an administrator wrote survive an
            uninstall unless /PurgeData). Never touches SOFTWARE\Policies (GPO owns it).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param ([string]$Path = 'HKLM:\SOFTWARE\DeadLoad', [switch]$Purge)

    if ($Path -match '\\Policies(\\|$)') { throw ('Refused: {0} is a policy key.' -f $Path) }
    if (-not (Test-Path -LiteralPath $Path)) { return 'Absent' }
    if ($Purge)
    {
        if (-not $PSCmdlet.ShouldProcess($Path, 'Remove key and every local setting')) { return 'WhatIf' }
        Remove-Item -LiteralPath $Path -Recurse -Force
        return 'Purged'
    }
    if (-not $PSCmdlet.ShouldProcess($Path, 'Remove Version and InstallPath')) { return 'WhatIf' }
    foreach ($name in 'Version', 'InstallPath') { Remove-ItemProperty -LiteralPath $Path -Name $name -ErrorAction SilentlyContinue }
    $key = Get-Item -LiteralPath $Path
    if ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0)
    {
        Remove-Item -LiteralPath $Path -Force
        return 'Removed'
    }
    return 'Kept'
}

function Set-DLTrayRunKey
{
    [CmdletBinding(SupportsShouldProcess)]
    param
    (
        [string]$Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        [string]$Name = 'DeadLoadTray',
        [Parameter(Mandatory)] [string]$ExePath
    )

    if (-not $PSCmdlet.ShouldProcess(('{0}\{1}' -f $Path, $Name), 'Start the tray at sign-in')) { return }
    if (-not (Test-Path -LiteralPath $Path)) { $null = New-Item -Path $Path -Force }
    # Quoted: the path has a space (Program Files) and an unquoted Run value is a hijack risk.
    $null = New-ItemProperty -LiteralPath $Path -Name $Name -Value ('"{0}"' -f $ExePath) -PropertyType String -Force
}

function Remove-DLTrayRunKey
{
    [CmdletBinding(SupportsShouldProcess)]
    param
    (
        [string]$Path = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run',
        [string]$Name = 'DeadLoadTray'
    )

    if (-not (Test-Path -LiteralPath $Path)) { return 'Absent' }
    $value = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if (-not $value) { return 'Absent' }
    if (-not $PSCmdlet.ShouldProcess(('{0}\{1}' -f $Path, $Name), 'Remove tray start at sign-in')) { return 'WhatIf' }
    Remove-ItemProperty -LiteralPath $Path -Name $Name
    return 'Removed'
}

function Install-DLAdmx
{
    <#
        .SYNOPSIS
            Copies DeadLoad.admx and every language's DeadLoad.adml into a PolicyDefinitions
            folder (local store; a domain uses the central store, see docs/OPERATIONS.md).
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param
    (
        [Parameter(Mandatory)] [string]$Source,
        [string]$Destination = (Join-Path $env:SystemRoot 'PolicyDefinitions')
    )

    if (-not [System.IO.Directory]::Exists($Source)) { throw ('Policy templates not found: {0}' -f $Source) }
    foreach ($admx in (New-Object System.IO.DirectoryInfo $Source).GetFiles('*.admx'))
    {
        $target = Join-Path $Destination $admx.Name
        if ($PSCmdlet.ShouldProcess($target, 'Copy ADMX'))
        {
            [void][System.IO.Directory]::CreateDirectory($Destination)
            [System.IO.File]::Copy($admx.FullName, $target, $true)
            $target
        }
    }
    foreach ($language in (New-Object System.IO.DirectoryInfo $Source).GetDirectories())
    {
        if (Test-DLReparsePoint -Item $language) { continue }
        foreach ($adml in $language.GetFiles('*.adml'))
        {
            $target = Join-Path (Join-Path $Destination $language.Name) $adml.Name
            if ($PSCmdlet.ShouldProcess($target, 'Copy ADML'))
            {
                [void][System.IO.Directory]::CreateDirectory((Join-Path $Destination $language.Name))
                [System.IO.File]::Copy($adml.FullName, $target, $true)
                $target
            }
        }
    }
}

function Find-DLLegacyInstall
{
    <#
        .SYNOPSIS
            The legacy Get-FreeSpace MSI's uninstall entries (FR-23), in both registry views.
    #>
    [CmdletBinding()]
    param
    (
        [string]$ProductCode = $script:DLLegacyProductCode,
        [string[]]$UninstallRoots = $script:DLDefaultUninstallRoots
    )

    foreach ($root in $UninstallRoots)
    {
        $key = Join-Path $root $ProductCode
        if (-not (Test-Path -LiteralPath $key)) { continue }
        $item = Get-ItemProperty -LiteralPath $key
        $names = @($item.PSObject.Properties | ForEach-Object { $_.Name })
        $displayName = $null
        $displayVersion = $null
        if ($names -contains 'DisplayName') { $displayName = $item.DisplayName }
        if ($names -contains 'DisplayVersion') { $displayVersion = $item.DisplayVersion }
        [pscustomobject]@{ ProductCode = $ProductCode; Key = $key; DisplayName = $displayName; DisplayVersion = $displayVersion }
    }
}

function Invoke-DLMsiExec
{
    # The one place msiexec runs, so tests can replace it.
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string[]]$Arguments)

    $msiexec = Join-Path $env:SystemRoot 'System32\msiexec.exe'
    $process = Start-Process -FilePath $msiexec -ArgumentList $Arguments -Wait -PassThru -WindowStyle Hidden
    return $process.ExitCode
}

function Uninstall-DLLegacyMsi
{
    <#
        .SYNOPSIS
            Silently uninstalls the legacy MSI. 0 and 1605 (not installed) are success; 3010
            (restart required) is success with a warning and no restart (a restart is a
            separate, user-impacting decision); anything else fails the install.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param
    (
        [string]$ProductCode = $script:DLLegacyProductCode,
        [string]$LogPath
    )

    $arguments = @('/x', $ProductCode, '/qn', '/norestart')
    if ($LogPath) { $arguments += @('/l*v', ('"{0}"' -f $LogPath)) }
    if (-not $PSCmdlet.ShouldProcess($ProductCode, ('msiexec.exe {0}' -f ($arguments -join ' ')))) { return 'WhatIf' }
    $code = Invoke-DLMsiExec -Arguments $arguments
    switch ($code)
    {
        0 { return 'Removed' }
        1605 { return 'NotInstalled' }
        3010
        {
            Write-Warning ('Legacy MSI {0} removed; Windows reports a restart is required (3010). No restart was started.' -f $ProductCode)
            return 'RemovedRestartRequired'
        }
        default { throw ('msiexec /x {0} failed with exit code {1}.' -f $ProductCode, $code) }
    }
}

function Remove-DLLegacyFolder
{
    <#
        .SYNOPSIS
            Removes a legacy Get-FreeSpace install folder left behind by the MSI.

        .DESCRIPTION
            A whole-tree removal is acceptable here only because the folder is the legacy
            product's own install folder, not a cleanup target; Remove-DLProductTree first
            checks the folder and every subfolder and refuses everything when any of them is a
            reparse point, so a link can never carry the delete elsewhere. A refusal is a
            warning: the remnant is harmless, the new install must not fail on it.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param ([Parameter(Mandatory)] [string]$Path)

    if (-not [System.IO.Directory]::Exists($Path)) { return 'Absent' }
    try
    {
        if (Remove-DLProductTree -Path $Path) { return 'Removed' }
        return 'WhatIf'
    }
    catch
    {
        Write-Warning ('Legacy folder kept: {0}' -f $_.Exception.Message)
        return 'Refused'
    }
}

function Get-DLLegacyTask
{
    <#
        .SYNOPSIS
            Legacy scheduled tasks to remove: in the root folder only, name containing
            FreeSpace, AND an exec action that runs a Get-FreeSpace script. A name match alone
            is never enough.

        .PARAMETER Task
            Task rows (Name, Path, Actions with Path and Arguments) to judge; default reads the
            root task folder through the Task Scheduler COM API (read-only).
    #>
    [CmdletBinding()]
    param ([object[]]$Task)

    if (-not $PSBoundParameters.ContainsKey('Task'))
    {
        $service = New-Object -ComObject 'Schedule.Service'
        $service.Connect()
        $Task = foreach ($registered in @($service.GetFolder('\').GetTasks(1)))
        {
            $actions = foreach ($action in @($registered.Definition.Actions))
            {
                # Type 0 is an exec action; the others (mail, message, COM handler) run no script.
                if ($action.Type -eq 0) { [pscustomobject]@{ Path = [string]$action.Path; Arguments = [string]$action.Arguments } }
            }
            [pscustomobject]@{ Name = [string]$registered.Name; Path = [string]$registered.Path; Actions = @($actions) }
        }
    }

    foreach ($candidate in @($Task))
    {
        if ($null -eq $candidate) { continue }
        if ($candidate.Path -ne ('\' + $candidate.Name)) { continue }
        if ($candidate.Name -notlike '*FreeSpace*') { continue }
        $runsLegacy = $false
        foreach ($action in @($candidate.Actions))
        {
            if ($null -eq $action) { continue }
            if (('{0} {1}' -f $action.Path, $action.Arguments) -match 'Get-FreeSpace') { $runsLegacy = $true }
        }
        if ($runsLegacy) { $candidate }
    }
}

function Remove-DLLegacyTask
{
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param ([Parameter(Mandatory)] [object[]]$Task)

    $root = $null
    foreach ($candidate in $Task)
    {
        if (-not $PSCmdlet.ShouldProcess($candidate.Path, 'Delete legacy scheduled task')) { continue }
        if (-not $root)
        {
            $service = New-Object -ComObject 'Schedule.Service'
            $service.Connect()
            $root = $service.GetFolder('\')
        }
        $root.DeleteTask($candidate.Name, 0)
        $candidate.Path
    }
}

function Find-DLLegacyChocolateyPackage
{
    <#
        .SYNOPSIS
            Chocolatey packages that installed the legacy Get-FreeSpace (FR-23), by what they
            are rather than a fixed id: deployments used their own feeds and ids.

        .DESCRIPTION
            A package folder under <ChocolateyInstall>\lib qualifies when its id is
            get-freespace (or getfreespace, get_freespace, get.freespace), its nuspec title is
            Get-FreeSpace, or a script in it names the legacy ProductCode or get-freespace.msi.
            DeadLoad's own package never qualifies; a folder that is a reparse point is skipped.
            Read-only.
    #>
    [CmdletBinding()]
    param
    (
        [string]$LibPath,
        [string]$ProductCode = $script:DLLegacyProductCode
    )

    if (-not $LibPath)
    {
        if (-not $env:ChocolateyInstall) { return }
        $LibPath = Join-Path $env:ChocolateyInstall 'lib'
    }
    if (-not [System.IO.Directory]::Exists($LibPath)) { return }
    $code = $ProductCode.Trim('{', '}')

    foreach ($folder in @([System.IO.DirectoryInfo]::new($LibPath).GetDirectories()))
    {
        if (Test-DLReparsePoint -Item $folder) { continue }
        $nuspecs = @($folder.GetFiles('*.nuspec'))
        if ($nuspecs.Count -eq 0) { continue }
        $id = $folder.Name
        $title = $null
        $version = $null
        try
        {
            [xml]$document = [System.IO.File]::ReadAllText($nuspecs[0].FullName)
            $metadata = $document.package.metadata
            if ($metadata.id) { $id = [string]$metadata.id }
            if ($metadata.title) { $title = [string]$metadata.title }
            if ($metadata.version) { $version = [string]$metadata.version }
        }
        catch { Write-Verbose ('Unreadable nuspec {0}: {1}' -f $nuspecs[0].FullName, $_.Exception.Message) }
        if ($id -eq 'deadload') { continue }

        $reason = $null
        if ($id -match '^get[-_.]?freespace$') { $reason = 'id' }
        elseif ($title -eq 'Get-FreeSpace') { $reason = 'title' }
        else
        {
            foreach ($script in @($folder.GetFiles('*.ps1', [System.IO.SearchOption]::AllDirectories)))
            {
                $text = [System.IO.File]::ReadAllText($script.FullName)
                if ($text.IndexOf($code, [System.StringComparison]::OrdinalIgnoreCase) -ge 0 -or
                    $text.IndexOf('get-freespace.msi', [System.StringComparison]::OrdinalIgnoreCase) -ge 0)
                {
                    $reason = 'script'
                    break
                }
            }
        }
        if ($reason) { [pscustomobject]@{ Id = $id; Version = $version; Title = $title; Path = $folder.FullName; MatchedBy = $reason } }
    }
}

function Remove-DLLegacyChocolateyPackage
{
    <#
        .SYNOPSIS
            Drops Chocolatey's record of a legacy Get-FreeSpace package once the product itself
            is gone, so choco upgrade all cannot reinstall it beside DeadLoad.

        .DESCRIPTION
            choco uninstall <id> -n --skip-autouninstaller -y: -n skips the package's own
            uninstall script and the auto-uninstaller is skipped too, because the MSI was
            already removed by Uninstall-DLLegacyMsi; only the record goes. A failure is a
            warning: the stale record must not fail the DeadLoad install.
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param
    (
        [Parameter(Mandatory)] [string]$Id,
        [string]$ChocoPath
    )

    if (-not $ChocoPath)
    {
        if (-not $env:ChocolateyInstall) { Write-Warning ('Chocolatey not found; record {0} kept.' -f $Id); return 'Kept' }
        $ChocoPath = Join-Path $env:ChocolateyInstall 'bin\choco.exe'
    }
    $arguments = @('uninstall', $Id, '-n', '--skip-autouninstaller', '-y', '--limit-output')
    if (-not $PSCmdlet.ShouldProcess($Id, ('choco {0}' -f ($arguments -join ' ')))) { return 'WhatIf' }
    $output = & $ChocoPath @arguments 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0)
    {
        Write-Warning ('choco uninstall {0} -n exited {1}; the Chocolatey record is kept: {2}' -f $Id, $LASTEXITCODE, $output.Trim())
        return 'Kept'
    }
    return 'Removed'
}

Export-ModuleMember -Function Get-DLManifestData, Get-DLPackageOptions, Remove-DLProductTree, Copy-DLTree, Install-DLPayload,
    Set-DLDataAcl, Register-DLEventSource, Unregister-DLEventSource, Set-DLLocalRegistry, Remove-DLLocalRegistry,
    Set-DLTrayRunKey, Remove-DLTrayRunKey, Install-DLAdmx, Find-DLLegacyInstall, Uninstall-DLLegacyMsi,
    Remove-DLLegacyFolder, Get-DLLegacyTask, Remove-DLLegacyTask, Find-DLLegacyChocolateyPackage,
    Remove-DLLegacyChocolateyPackage
