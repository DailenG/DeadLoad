#Requires -Version 5.1
# Phase 3 (Chocolatey package and build): the install helpers run for real against %TEMP%
# sandboxes and an HKCU test key (never HKLM, Program Files, the event log or Task Scheduler),
# the scripts are checked statically, and Build.ps1 stages into a sandbox.

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:Packaging = Join-Path $script:RepoRoot 'packaging\chocolatey'
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force
    Import-Module (Join-Path $script:Packaging 'tools\DeadLoad.Install.psm1') -Force
    $script:InstallModule = Get-Module DeadLoad.Install
    $script:LegacyCode = '{DCD33BCE-C996-4E9B-9044-B77CCCB33EAD}'

    function script:New-DLTestPayload
    {
        # A payload folder shaped like tools\payload: engine, tray, policy.
        param ([Parameter(Mandatory)] [string]$Root, [string]$Marker = 'v1')

        foreach ($relative in 'engine\DeadLoad\DeadLoad.psd1', 'engine\DeadLoad\Private\A.ps1', 'engine\Start-DeadLoad.ps1', 'tray\DeadLoadTray.exe', 'policy\DeadLoad.admx', 'policy\en-US\DeadLoad.adml')
        {
            $path = Join-Path $Root $relative
            [void][System.IO.Directory]::CreateDirectory((Split-Path -Path $path -Parent))
            [System.IO.File]::WriteAllText($path, ('{0} {1}' -f $relative, $Marker))
        }
    }

    function script:Get-DLSiblingNames
    {
        param ([Parameter(Mandatory)] [string]$Path)
        return @((New-Object System.IO.DirectoryInfo $Path).GetDirectories() | ForEach-Object { $_.Name } | Sort-Object)
    }

    function script:Reset-DLTestAcl
    {
        # The protected ACL leaves a non-elevated test account read-only; as the owner it may
        # still rewrite the DACL, so cleanup grants itself full control first.
        param ([Parameter(Mandatory)] [string]$Path)

        $me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = New-Object System.Security.AccessControl.DirectorySecurity
        $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule ($me, 'FullControl', 'ContainerInherit, ObjectInherit', 'None', 'Allow')))
        & $script:InstallModule { param($p, $s) Set-DLDirectorySecurity -Path $p -Security $s } $Path $security
    }
}

Describe 'Chocolatey nuspec' {

    BeforeAll {
        $script:NuspecPath = Join-Path $script:Packaging 'deadload.nuspec'
        [xml]$script:Nuspec = [System.IO.File]::ReadAllText($script:NuspecPath)
        $script:Metadata = $script:Nuspec.package.metadata
    }

    It 'is valid XML against the nuspec namespace with the package identity' {
        $script:Nuspec.DocumentElement.NamespaceURI | Should -Be 'http://schemas.microsoft.com/packaging/2015/06/nuspec.xsd'
        $script:Metadata.id | Should -Be 'deadload'
        $script:Metadata.title | Should -Be 'DeadLoad'
        $script:Metadata.authors | Should -Be 'Dailen Gunter'
        $script:Metadata.licenseUrl | Should -Be 'https://www.gnu.org/licenses/gpl-3.0.html'
        [string]$script:Metadata.description | Should -Not -BeNullOrEmpty
    }

    It 'has the version of the engine module' {
        $module = Get-DLManifestData -Path (Join-Path $script:RepoRoot 'src\engine\DeadLoad\DeadLoad.psd1')
        $script:Metadata.version | Should -Be ([string]$module.ModuleVersion)
    }

    It 'packs the tools folder, payload included' {
        $files = @($script:Nuspec.package.files.file)
        $files.Count | Should -Be 1
        $files[0].src | Should -Be 'tools\**'
        $files[0].target | Should -Be 'tools'
    }

    It 'names every package parameter the scripts accept' {
        foreach ($name in 'NoTray', 'ReportOnly', 'InstallAdmxLocally', 'PurgeData') { [string]$script:Metadata.description | Should -Match ('/' + $name) }
    }
}

Describe 'Get-DLPackageOptions' {

    It 'defaults every switch to false' {
        $options = Get-DLPackageOptions -Parameters @{}
        foreach ($name in 'NoTray', 'ReportOnly', 'InstallAdmxLocally', 'PurgeData') { $options.$name | Should -BeFalse }
    }

    It 'turns on /<Name> alone' -ForEach @(
        @{ Name = 'NoTray' }, @{ Name = 'ReportOnly' }, @{ Name = 'InstallAdmxLocally' }, @{ Name = 'PurgeData' }
    ) {
        # Get-PackageParameters returns a bare switch as the string 'true'.
        $options = Get-DLPackageOptions -Parameters @{ $Name = 'true' }
        foreach ($other in 'NoTray', 'ReportOnly', 'InstallAdmxLocally', 'PurgeData')
        {
            $options.$other | Should -Be ($other -eq $Name)
        }
    }

    It 'reads names case-insensitively and explicit values' {
        $options = Get-DLPackageOptions -Parameters @{ notray = 'true'; REPORTONLY = 'false'; PurgeData = '0'; InstallAdmxLocally = $true }
        $options.NoTray | Should -BeTrue
        $options.ReportOnly | Should -BeFalse
        $options.PurgeData | Should -BeFalse
        $options.InstallAdmxLocally | Should -BeTrue
    }

    It 'warns on an unknown parameter and ignores it' {
        $options = Get-DLPackageOptions -Parameters @{ NoTary = 'true' } -WarningVariable warnings -WarningAction SilentlyContinue
        $options.NoTray | Should -BeFalse
        @($warnings).Count | Should -Be 1
        [string]$warnings[0] | Should -Match 'NoTary'
    }

    It 'refuses a value it cannot read rather than guess' {
        { Get-DLPackageOptions -Parameters @{ ReportOnly = 'maybe' } } | Should -Throw '*unreadable*'
    }
}

Describe 'Set-DLDataAcl' {

    BeforeEach {
        $script:Sandbox = New-DLSandbox
        $script:DataPath = Join-Path $script:Sandbox.ProgramData 'DeadLoad'
        $script:Me = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    }
    AfterEach {
        if ([System.IO.Directory]::Exists($script:DataPath)) { Reset-DLTestAcl -Path $script:DataPath }
        Remove-DLSandbox -Sandbox $script:Sandbox
    }

    It 'creates the folder with inheritance broken and exactly the three grants' {
        Set-DLDataAcl -Path $script:DataPath -OwnerSid $script:Me -Confirm:$false

        $acl = Get-Acl -LiteralPath $script:DataPath
        $acl.AreAccessRulesProtected | Should -BeTrue
        $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value | Should -Be $script:Me
        $rules = @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier]))
        $rules.Count | Should -Be 3
        @($rules | Where-Object { $_.IsInherited }).Count | Should -Be 0
        @($rules | Where-Object { $_.AccessControlType -ne 'Allow' }).Count | Should -Be 0
        foreach ($rule in $rules)
        {
            $rule.InheritanceFlags | Should -Be ([System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit')
            $rule.PropagationFlags | Should -Be ([System.Security.AccessControl.PropagationFlags]::None)
        }
        $bySid = @{}
        foreach ($rule in $rules) { $bySid[$rule.IdentityReference.Value] = $rule.FileSystemRights }
        @($bySid.Keys | Sort-Object) -join ',' | Should -Be 'S-1-5-18,S-1-5-32-544,S-1-5-32-545'
        ($bySid['S-1-5-18'] -band [System.Security.AccessControl.FileSystemRights]::FullControl) | Should -Be ([System.Security.AccessControl.FileSystemRights]::FullControl)
        ($bySid['S-1-5-32-544'] -band [System.Security.AccessControl.FileSystemRights]::FullControl) | Should -Be ([System.Security.AccessControl.FileSystemRights]::FullControl)
        $users = $bySid['S-1-5-32-545']
        ($users -band [System.Security.AccessControl.FileSystemRights]::ReadAndExecute) | Should -Be ([System.Security.AccessControl.FileSystemRights]::ReadAndExecute)
        # SR-8: nothing a standard user can write.
        $writeBits = [System.Security.AccessControl.FileSystemRights]'Write, Delete, DeleteSubdirectoriesAndFiles, ChangePermissions, TakeOwnership'
        ($users -band $writeBits) | Should -Be 0
    }

    It 'replaces a looser ACL on an existing folder and keeps its content' {
        [void][System.IO.Directory]::CreateDirectory($script:DataPath)
        New-DLTestFile -Path (Join-Path $script:DataPath 'last-run.json') -Bytes 10 | Out-Null
        Set-DLDataAcl -Path $script:DataPath -OwnerSid $script:Me -Confirm:$false
        # Re-applied as on an upgrade. The owner is left as it is: a non-elevated test account
        # holds only the owner's implicit rights now, which do not include taking ownership.
        Set-DLDataAcl -Path $script:DataPath -OwnerSid '' -Confirm:$false

        $acl = Get-Acl -LiteralPath $script:DataPath
        @($acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])).Count | Should -Be 3
        Test-Path -LiteralPath (Join-Path $script:DataPath 'last-run.json') | Should -BeTrue
    }

    It 'changes nothing with -WhatIf' {
        Set-DLDataAcl -Path $script:DataPath -OwnerSid $script:Me -WhatIf
        [System.IO.Directory]::Exists($script:DataPath) | Should -BeFalse
    }

    It 'refuses a junction and leaves its target ACL alone' {
        $before = (Get-Acl -LiteralPath $script:Sandbox.Canary).Sddl
        New-DLJunction -Link $script:DataPath -Target $script:Sandbox.Canary
        try
        {
            { Set-DLDataAcl -Path $script:DataPath -OwnerSid $script:Me -Confirm:$false } | Should -Throw '*reparse point*'
            (Get-Acl -LiteralPath $script:Sandbox.Canary).Sddl | Should -Be $before
        }
        finally { [System.IO.Directory]::Delete($script:DataPath, $false) }
    }
}

Describe 'Install-DLPayload' {

    BeforeEach {
        $script:Sandbox = New-DLSandbox
        $script:Source = Join-Path $script:Sandbox.Root 'payload'
        $script:Destination = Join-Path $script:Sandbox.Root 'Program Files\DeadLoad'
        New-DLTestPayload -Root $script:Source
    }
    AfterEach { Remove-DLSandbox -Sandbox $script:Sandbox }

    It 'creates every folder on a first install' {
        $rows = @(Install-DLPayload -Source $script:Source -Destination $script:Destination -Confirm:$false)
        ($rows | ForEach-Object { '{0}={1}' -f $_.Folder, $_.Mode }) -join ',' | Should -Be 'engine=Created,tray=Created,policy=Created'
        foreach ($name in 'engine', 'tray', 'policy') { Get-DLTreeState -Path (Join-Path $script:Destination $name) | Should -Be (Get-DLTreeState -Path (Join-Path $script:Source $name)) }
    }

    It 'replaces cleanly on upgrade: new content, dropped files gone, no staging leftovers, other folders kept' {
        Install-DLPayload -Source $script:Source -Destination $script:Destination -Confirm:$false | Out-Null
        New-DLTestFile -Path (Join-Path $script:Destination 'keep\note.txt') -Bytes 5 | Out-Null
        $keep = Get-DLTreeState -Path (Join-Path $script:Destination 'keep')

        $next = Join-Path $script:Sandbox.Root 'payload2'
        New-DLTestPayload -Root $next -Marker 'v2'
        [System.IO.File]::Delete((Join-Path $next 'engine\DeadLoad\Private\A.ps1'))
        [System.IO.File]::WriteAllText((Join-Path $next 'engine\DeadLoad\Private\B.ps1'), 'B v2')

        $rows = @(Install-DLPayload -Source $next -Destination $script:Destination -Confirm:$false)
        @($rows | ForEach-Object { $_.Mode } | Select-Object -Unique) -join ',' | Should -Be 'Replaced'
        foreach ($name in 'engine', 'tray', 'policy') { Get-DLTreeState -Path (Join-Path $script:Destination $name) | Should -Be (Get-DLTreeState -Path (Join-Path $next $name)) }
        Test-Path -LiteralPath (Join-Path $script:Destination 'engine\DeadLoad\Private\A.ps1') | Should -BeFalse
        (Get-DLSiblingNames -Path $script:Destination) -join ',' | Should -Be 'engine,keep,policy,tray'
        Get-DLTreeState -Path (Join-Path $script:Destination 'keep') | Should -Be $keep
    }

    It 'is idempotent: a second identical install leaves the same tree' {
        Install-DLPayload -Source $script:Source -Destination $script:Destination -Confirm:$false | Out-Null
        $first = Get-DLTreeState -Path $script:Destination
        Install-DLPayload -Source $script:Source -Destination $script:Destination -Confirm:$false | Out-Null
        Get-DLTreeState -Path $script:Destination | Should -Be $first
    }

    It 'leaves an installed folder alone when the payload does not carry it' {
        Install-DLPayload -Source $script:Source -Destination $script:Destination -Confirm:$false | Out-Null
        $tray = Get-DLTreeState -Path (Join-Path $script:Destination 'tray')
        $noTray = Join-Path $script:Sandbox.Root 'payload-notray'
        New-DLTestPayload -Root $noTray -Marker 'v2'
        [void](Remove-DLProductTree -Path (Join-Path $noTray 'tray') -Confirm:$false)

        $rows = @(Install-DLPayload -Source $noTray -Destination $script:Destination -Confirm:$false)
        ($rows | Where-Object { $_.Folder -eq 'tray' }).Mode | Should -Be 'Missing'
        Get-DLTreeState -Path (Join-Path $script:Destination 'tray') | Should -Be $tray
    }

    It 'updates in place when a running tray holds its folder, then clears the leftover next time' {
        Install-DLPayload -Source $script:Source -Destination $script:Destination -Confirm:$false | Out-Null
        $next = Join-Path $script:Sandbox.Root 'payload2'
        New-DLTestPayload -Root $next -Marker 'v2'
        $exe = Join-Path $script:Destination 'tray\DeadLoadTray.exe'
        # A running image is open with read and delete sharing: the folder cannot be renamed,
        # the file can.
        $stream = New-Object System.IO.FileStream ($exe, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]'Read, Delete'))
        try
        {
            $rows = @(Install-DLPayload -Source $next -Destination $script:Destination -Confirm:$false -WarningAction SilentlyContinue)
            ($rows | Where-Object { $_.Folder -eq 'tray' }).Mode | Should -Be 'InPlace'
            [System.IO.File]::ReadAllText($exe) | Should -Be 'tray\DeadLoadTray.exe v2'
        }
        finally { $stream.Dispose() }
        @((New-Object System.IO.DirectoryInfo (Join-Path $script:Destination 'tray')).GetFiles('*.dlold-*')).Count | Should -Be 1
        (Get-DLSiblingNames -Path $script:Destination) -join ',' | Should -Be 'engine,policy,tray'

        Install-DLPayload -Source $next -Destination $script:Destination -Confirm:$false | Out-Null
        @((New-Object System.IO.DirectoryInfo (Join-Path $script:Destination 'tray')).GetFiles('*.dlold-*')).Count | Should -Be 0
        Get-DLTreeState -Path (Join-Path $script:Destination 'tray') | Should -Be (Get-DLTreeState -Path (Join-Path $next 'tray'))
    }

    It 'clears staging siblings an interrupted upgrade left' {
        Install-DLPayload -Source $script:Source -Destination $script:Destination -Confirm:$false | Out-Null
        $stale = Join-Path $script:Destination ('engine.new-{0}' -f [guid]::NewGuid().ToString('N'))
        New-DLTestFile -Path (Join-Path $stale 'x.ps1') -Bytes 3 | Out-Null
        Install-DLPayload -Source $script:Source -Destination $script:Destination -Confirm:$false | Out-Null
        [System.IO.Directory]::Exists($stale) | Should -BeFalse
    }

    It 'skips a link in the payload instead of following it' {
        New-DLTestFile -Path (Join-Path $script:Sandbox.Canary 'secret.txt') -Bytes 4 | Out-Null
        New-DLJunction -Link (Join-Path $script:Source 'engine\linked') -Target $script:Sandbox.Canary
        Install-DLPayload -Source $script:Source -Destination $script:Destination -Confirm:$false -WarningAction SilentlyContinue | Out-Null
        Test-Path -LiteralPath (Join-Path $script:Destination 'engine\linked') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $script:Destination 'engine\DeadLoad\DeadLoad.psd1') | Should -BeTrue
    }

    It 'changes nothing with -WhatIf' {
        $rows = @(Install-DLPayload -Source $script:Source -Destination $script:Destination -WhatIf)
        @($rows | ForEach-Object { $_.Mode } | Select-Object -Unique) -join ',' | Should -Be 'WhatIf'
        [System.IO.Directory]::Exists($script:Destination) | Should -BeFalse
    }
}

Describe 'Remove-DLProductTree' {

    BeforeEach { $script:Sandbox = New-DLSandbox }
    AfterEach { Remove-DLSandbox -Sandbox $script:Sandbox }

    It 'removes a product folder tree' {
        $tree = Join-Path $script:Sandbox.Root 'Get-FreeSpace'
        New-DLTestFile -Path (Join-Path $tree 'a\b\c.txt') -Bytes 3 | Out-Null
        [System.IO.File]::SetAttributes((Join-Path $tree 'a\b\c.txt'), [System.IO.FileAttributes]::ReadOnly)
        Remove-DLProductTree -Path $tree -Confirm:$false | Should -BeTrue
        [System.IO.Directory]::Exists($tree) | Should -BeFalse
    }

    It 'refuses the whole tree when a subfolder is a junction, deleting nothing' {
        $tree = Join-Path $script:Sandbox.Root 'Get-FreeSpace'
        New-DLTestFile -Path (Join-Path $tree 'own.txt') -Bytes 3 | Out-Null
        New-DLTestFile -Path (Join-Path $script:Sandbox.Canary 'keep.txt') -Bytes 3 | Out-Null
        New-DLJunction -Link (Join-Path $tree 'sub\link') -Target $script:Sandbox.Canary
        $canary = Get-DLTreeState -Path $script:Sandbox.Canary

        { Remove-DLProductTree -Path $tree -Confirm:$false } | Should -Throw '*reparse point*'
        Test-Path -LiteralPath (Join-Path $tree 'own.txt') | Should -BeTrue
        Get-DLTreeState -Path $script:Sandbox.Canary | Should -Be $canary
    }

    It 'reports a legacy folder it refuses as Refused, not an error' {
        $tree = Join-Path $script:Sandbox.Root 'Get-FreeSpace'
        New-DLJunction -Link (Join-Path $tree 'link') -Target $script:Sandbox.Canary
        Remove-DLLegacyFolder -Path $tree -Confirm:$false -WarningAction SilentlyContinue | Should -Be 'Refused'
        Remove-DLLegacyFolder -Path (Join-Path $script:Sandbox.Root 'absent') -Confirm:$false | Should -Be 'Absent'
    }
}

Describe 'Legacy Get-FreeSpace retirement' {

    BeforeAll {
        $script:TestKey = 'HKCU:\Software\DeadLoadTest-{0}' -f [guid]::NewGuid().ToString('N')
        $script:Uninstall = Join-Path $script:TestKey 'Uninstall'
        $entry = Join-Path $script:Uninstall $script:LegacyCode
        $null = New-Item -Path $entry -Force
        $null = New-ItemProperty -LiteralPath $entry -Name DisplayName -Value 'Get-FreeSpace' -PropertyType String
        $null = New-ItemProperty -LiteralPath $entry -Name DisplayVersion -Value '1.3.5.0' -PropertyType String
    }
    AfterAll { Remove-Item -LiteralPath $script:TestKey -Recurse -Force }

    It 'finds the MSI uninstall entry in the roots it is given' {
        $found = @(Find-DLLegacyInstall -UninstallRoots @((Join-Path $script:TestKey 'Missing'), $script:Uninstall))
        $found.Count | Should -Be 1
        $found[0].ProductCode | Should -Be $script:LegacyCode
        $found[0].DisplayName | Should -Be 'Get-FreeSpace'
        $found[0].DisplayVersion | Should -Be '1.3.5.0'
    }

    It 'finds nothing for another product code' {
        @(Find-DLLegacyInstall -UninstallRoots $script:Uninstall -ProductCode '{00000000-0000-0000-0000-000000000000}').Count | Should -Be 0
    }

    It 'maps msiexec exit code <Code> to <Expected>' -ForEach @(
        @{ Code = 0; Expected = 'Removed' }
        @{ Code = 1605; Expected = 'NotInstalled' }
        @{ Code = 3010; Expected = 'RemovedRestartRequired' }
    ) {
        # The mock body runs in the module's scope, so the exit code is baked into it.
        Mock -ModuleName DeadLoad.Install Invoke-DLMsiExec ([scriptblock]::Create('return {0}' -f $Code))
        Uninstall-DLLegacyMsi -Confirm:$false -WarningAction SilentlyContinue | Should -Be $Expected
        Should -Invoke -ModuleName DeadLoad.Install Invoke-DLMsiExec -Times 1 -Exactly -ParameterFilter { ($Arguments -join ' ') -eq '/x {DCD33BCE-C996-4E9B-9044-B77CCCB33EAD} /qn /norestart' }
    }

    It 'fails the install on any other msiexec exit code' {
        Mock -ModuleName DeadLoad.Install Invoke-DLMsiExec { return 1603 }
        { Uninstall-DLLegacyMsi -Confirm:$false } | Should -Throw '*1603*'
    }

    It 'never starts msiexec with -WhatIf' {
        Mock -ModuleName DeadLoad.Install Invoke-DLMsiExec { return 0 }
        Uninstall-DLLegacyMsi -WhatIf | Should -Be 'WhatIf'
        Should -Invoke -ModuleName DeadLoad.Install Invoke-DLMsiExec -Times 0 -Exactly
    }

    It 'selects only root-folder FreeSpace tasks whose action runs Get-FreeSpace' {
        $tasks = @(
            [pscustomobject]@{ Name = 'Get-FreeSpace Weekly'; Path = '\Get-FreeSpace Weekly'; Actions = @([pscustomobject]@{ Path = 'powershell.exe'; Arguments = '-File "C:\Program Files\Get-FreeSpace\Get-FreeSpace.ps1"' }) }
            [pscustomobject]@{ Name = 'FreeSpaceReport'; Path = '\FreeSpaceReport'; Actions = @([pscustomobject]@{ Path = 'report.exe'; Arguments = '' }) }
            [pscustomobject]@{ Name = 'FreeSpace'; Path = '\Vendor\FreeSpace'; Actions = @([pscustomobject]@{ Path = 'powershell.exe'; Arguments = '-File Get-FreeSpace.ps1' }) }
            [pscustomobject]@{ Name = 'Backup'; Path = '\Backup'; Actions = @([pscustomobject]@{ Path = 'powershell.exe'; Arguments = '-File Get-FreeSpace.ps1' }) }
        )
        @(Get-DLLegacyTask -Task $tasks | ForEach-Object { $_.Path }) -join ',' | Should -Be '\Get-FreeSpace Weekly'
    }
}

Describe 'Local registry and tray Run value' {

    BeforeEach {
        $script:TestKey = 'HKCU:\Software\DeadLoadTest-{0}' -f [guid]::NewGuid().ToString('N')
        $script:Local = Join-Path $script:TestKey 'DeadLoad'
        $script:Run = Join-Path $script:TestKey 'Run'
    }
    AfterEach { if (Test-Path -LiteralPath $script:TestKey) { Remove-Item -LiteralPath $script:TestKey -Recurse -Force } }

    It 'writes Version and InstallPath as strings and ReportOnly as a DWORD' {
        Set-DLLocalRegistry -Path $script:Local -Version '0.1.0' -InstallPath 'C:\Program Files\DeadLoad' -ReportOnly -Confirm:$false
        $key = Get-Item -LiteralPath $script:Local
        $key.GetValue('Version') | Should -Be '0.1.0'
        $key.GetValueKind('Version') | Should -Be 'String'
        $key.GetValue('InstallPath') | Should -Be 'C:\Program Files\DeadLoad'
        $key.GetValue('ReportOnly') | Should -Be 1
        $key.GetValueKind('ReportOnly') | Should -Be 'DWord'
    }

    It 'keeps a ReportOnly value an administrator set when /ReportOnly is not given' {
        Set-DLLocalRegistry -Path $script:Local -Version '0.1.0' -InstallPath 'C:\X' -ReportOnly -Confirm:$false
        Set-DLLocalRegistry -Path $script:Local -Version '0.2.0' -InstallPath 'C:\X' -Confirm:$false
        (Get-Item -LiteralPath $script:Local).GetValue('ReportOnly') | Should -Be 1
        (Get-Item -LiteralPath $script:Local).GetValue('Version') | Should -Be '0.2.0'
    }

    It 'uninstall removes the package values, keeps other local settings, and purges on request' {
        Set-DLLocalRegistry -Path $script:Local -Version '0.1.0' -InstallPath 'C:\X' -ReportOnly -Confirm:$false
        Remove-DLLocalRegistry -Path $script:Local -Confirm:$false | Should -Be 'Kept'
        $names = @((Get-Item -LiteralPath $script:Local).GetValueNames())
        $names -join ',' | Should -Be 'ReportOnly'
        Remove-DLLocalRegistry -Path $script:Local -Purge -Confirm:$false | Should -Be 'Purged'
        Test-Path -LiteralPath $script:Local | Should -BeFalse
        Remove-DLLocalRegistry -Path $script:Local -Confirm:$false | Should -Be 'Absent'
    }

    It 'uninstall removes the key when only package values were in it' {
        Set-DLLocalRegistry -Path $script:Local -Version '0.1.0' -InstallPath 'C:\X' -Confirm:$false
        Remove-DLLocalRegistry -Path $script:Local -Confirm:$false | Should -Be 'Removed'
        Test-Path -LiteralPath $script:Local | Should -BeFalse
    }

    It 'never touches a policy key' {
        { Remove-DLLocalRegistry -Path 'HKCU:\Software\Policies\DeadLoad' -Purge -Confirm:$false } | Should -Throw '*policy key*'
    }

    It 'writes the tray Run value quoted and removes it' {
        Set-DLTrayRunKey -Path $script:Run -ExePath 'C:\Program Files\DeadLoad\tray\DeadLoadTray.exe' -Confirm:$false
        (Get-Item -LiteralPath $script:Run).GetValue('DeadLoadTray') | Should -Be '"C:\Program Files\DeadLoad\tray\DeadLoadTray.exe"'
        Remove-DLTrayRunKey -Path $script:Run -Confirm:$false | Should -Be 'Removed'
        Remove-DLTrayRunKey -Path $script:Run -Confirm:$false | Should -Be 'Absent'
    }
}

Describe 'Install-DLAdmx' {

    BeforeEach { $script:Sandbox = New-DLSandbox }
    AfterEach { Remove-DLSandbox -Sandbox $script:Sandbox }

    It 'copies the ADMX and each language ADML into a PolicyDefinitions folder' {
        $source = Join-Path $script:Sandbox.Root 'policy'
        New-DLTestFile -Path (Join-Path $source 'DeadLoad.admx') -Bytes 10 | Out-Null
        New-DLTestFile -Path (Join-Path $source 'en-US\DeadLoad.adml') -Bytes 10 | Out-Null
        $destination = Join-Path $script:Sandbox.Root 'PolicyDefinitions'
        $written = @(Install-DLAdmx -Source $source -Destination $destination -Confirm:$false)
        $written.Count | Should -Be 2
        Test-Path -LiteralPath (Join-Path $destination 'DeadLoad.admx') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $destination 'en-US\DeadLoad.adml') | Should -BeTrue
    }
}

Describe 'Package and build scripts, static checks' {

    BeforeDiscovery {
        $repo = Split-Path -Path $PSScriptRoot -Parent
        $script:ScriptCases = @(
            # By extension: -Include beside -LiteralPath filters nothing on Windows PowerShell 5.1.
            Get-ChildItem -LiteralPath (Join-Path $repo 'packaging') -Recurse -File | Where-Object { @('.ps1', '.psm1', '.psd1') -contains $_.Extension } | ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } }
            @{ Path = (Join-Path $repo 'build\Build.ps1'); Name = 'Build.ps1' }
        )
        $script:TextCases = @(
            Get-ChildItem -LiteralPath (Join-Path $repo 'packaging') -Recurse -File | ForEach-Object { @{ Path = $_.FullName; Name = $_.Name } }
            @{ Path = (Join-Path $repo 'build\Build.ps1'); Name = 'Build.ps1' }
            @{ Path = (Join-Path $repo 'docs\OPERATIONS.md'); Name = 'OPERATIONS.md' }
        )
    }

    It '<Name> parses without errors' -ForEach $script:ScriptCases {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        @($errors).Count | Should -Be 0
    }

    It '<Name> has no pipeline chain operators' -ForEach $script:ScriptCases {
        # Windows PowerShell 5.1 cannot parse them; scan the text so 7 cannot hide one.
        [System.IO.File]::ReadAllText($Path) | Should -Not -Match '&{2}|\|{2}'
    }

    It '<Name> is 7-bit ASCII' -ForEach $script:TextCases {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }
}

Describe 'Build.ps1 -StageOnly' {

    BeforeAll {
        $script:Sandbox = New-DLSandbox
        $script:Out = Join-Path $script:Sandbox.Root 'out'
        $hostExe = (Get-Process -Id $PID).Path
        $build = Join-Path $script:RepoRoot 'build\Build.ps1'
        $script:BuildOutput = & $hostExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $build -NoSign -SkipTray -StageOnly -OutputPath $script:Out 2>&1
        $script:BuildExit = $LASTEXITCODE
        $script:Stage = Join-Path $script:Out 'stage'
    }
    AfterAll { Remove-DLSandbox -Sandbox $script:Sandbox }

    It 'succeeds' {
        $script:BuildExit | Should -Be 0 -Because (($script:BuildOutput | Out-String))
    }

    It 'stages the engine module exactly as the source has it' {
        Get-DLTreeState -Path (Join-Path $script:Stage 'engine\DeadLoad') | Should -Be (Get-DLTreeState -Path (Join-Path $script:RepoRoot 'src\engine\DeadLoad'))
    }

    It 'stages <Relative> when the source has it' -ForEach @(
        @{ Relative = 'engine\Start-DeadLoad.ps1' }
        @{ Relative = 'engine\Invoke-DeadLoadUserAction.ps1' }
    ) {
        $source = Join-Path $script:RepoRoot ('src\' + $Relative)
        Test-Path -LiteralPath (Join-Path $script:Stage $Relative) | Should -Be (Test-Path -LiteralPath $source)
    }

    It 'stages the policy templates' {
        Test-Path -LiteralPath (Join-Path $script:Stage 'policy\DeadLoad.admx') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $script:Stage 'policy\en-US\DeadLoad.adml') | Should -BeTrue
    }

    It 'leaves the tray out with -SkipTray and makes no package' {
        [System.IO.Directory]::Exists((Join-Path $script:Stage 'tray')) | Should -BeFalse
        [System.IO.Directory]::Exists((Join-Path $script:Out 'pack')) | Should -BeFalse
        @([System.IO.Directory]::GetFiles($script:Out, '*.nupkg')).Count | Should -Be 0
    }

    It 'lists the staged files' {
        ($script:BuildOutput | Out-String) | Should -Match ([regex]::Escape('engine\DeadLoad\DeadLoad.psd1'))
    }
}
