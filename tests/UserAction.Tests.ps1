#Requires -Version 5.1
# Phase 4: Invoke-DeadLoadUserAction.ps1. The real script runs in a child process of the same
# host (as the tray starts it). Nothing inside the script is mocked: -ModulePath points at a stub
# module built in the sandbox that records its parameters, and DEADLOAD_TEST_TRAYPOLICY replaces
# the registry so every test is hermetic and nothing is written to HKLM or HKCU.

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    $script:ScriptPath = Join-Path $script:RepoRoot 'src\engine\Invoke-DeadLoadUserAction.ps1'
    $script:HostPath = (Get-Process -Id $PID).Path
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

    $script:StubSource = @'
# Stub of the DeadLoad module for the user action tests. Behavior comes from environment
# variables set on the child process; every call is appended to calls.jsonl beside the stub.
$script:CallLog = Join-Path $PSScriptRoot 'calls.jsonl'

function Write-StubCall
{
    param ([string]$Command, [hashtable]$Parameters)
    $line = ([pscustomobject]@{ Command = $Command; Parameters = $Parameters }) | ConvertTo-Json -Compress -Depth 4
    Add-Content -LiteralPath $script:CallLog -Value $line -Encoding UTF8
}

function Invoke-DeadLoad
{
    [CmdletBinding(SupportsShouldProcess)]
    param ([string]$Mode, [switch]$NoEventLog)

    Write-StubCall -Command 'Invoke-DeadLoad' -Parameters @{ Mode = $Mode; NoEventLog = [bool]$NoEventLog }
    Write-Verbose 'stub verbose prose'
    Write-Information 'stub information prose'
    if ($env:DEADLOAD_STUB_WARN) { Write-Warning 'stub warning' }
    if ($env:DEADLOAD_STUB_THROW) { throw 'stub engine exploded' }
    $result = 'Success'
    if ($env:DEADLOAD_STUB_RESULT) { $result = $env:DEADLOAD_STUB_RESULT }
    [pscustomobject]@{
        PSTypeName = 'DeadLoad.RunSummary'
        Mode       = $Mode
        Result     = $result
        Reason     = $null
        Totals     = [pscustomobject]@{ FreedBytes = [int64]5242880; DeletedCount = 3 }
    }
}

function Export-DeadLoadSupportBundle
{
    [CmdletBinding(SupportsShouldProcess)]
    param ([int]$Days = 7, [string]$Destination)

    Write-StubCall -Command 'Export-DeadLoadSupportBundle' -Parameters @{ Days = $Days; Destination = $Destination }
    if ($env:DEADLOAD_STUB_WARN) { Write-Warning 'Not included: one.txt (locked)'; Write-Warning 'Not included: two.txt (locked)' }
    if ($env:DEADLOAD_STUB_THROW) { throw ('Destination not found: {0}' -f $Destination) }
    New-Object System.IO.FileInfo (Join-Path $Destination 'DeadLoad-support-TEST-20260101-000000.zip')
}

Export-ModuleMember -Function Invoke-DeadLoad, Export-DeadLoadSupportBundle
'@

    function script:New-DLUASandbox
    {
        param ([string]$Policy = '@{}')

        $sandbox = New-DLSandbox
        $stubRoot = Join-Path $sandbox.Root 'StubModule'
        [void][System.IO.Directory]::CreateDirectory($stubRoot)
        $stubPath = Join-Path $stubRoot 'DeadLoadStub.psm1'
        [System.IO.File]::WriteAllText($stubPath, $script:StubSource, (New-Object System.Text.UTF8Encoding $false))
        $policyPath = Join-Path $sandbox.Root 'tray-policy.psd1'
        [System.IO.File]::WriteAllText($policyPath, $Policy, (New-Object System.Text.UTF8Encoding $false))
        $sandbox | Add-Member -NotePropertyName StubPath -NotePropertyValue $stubPath
        $sandbox | Add-Member -NotePropertyName CallLog -NotePropertyValue (Join-Path $stubRoot 'calls.jsonl')
        $sandbox | Add-Member -NotePropertyName PolicyPath -NotePropertyValue $policyPath
        return $sandbox
    }

    function script:Invoke-DLUAScript
    {
        <#
            Starts the script the way the tray does (separate process, -File, stdout and stderr
            redirected) and returns the exit code, the raw stdout lines and the parsed result.
        #>
        param
        (
            [Parameter(Mandatory)] [pscustomobject]$Sandbox,
            [Parameter(Mandatory)] [string]$Action,
            [hashtable]$Environment = @{},
            [string]$ModulePath = $Sandbox.StubPath
        )

        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $script:HostPath
        $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action {1} -ModulePath "{2}" -NoEventLog' -f $script:ScriptPath, $Action, $ModulePath
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.EnvironmentVariables['DEADLOAD_TEST_TRAYPOLICY'] = $Sandbox.PolicyPath
        foreach ($name in 'DEADLOAD_STUB_WARN', 'DEADLOAD_STUB_THROW', 'DEADLOAD_STUB_RESULT') { [void]$info.EnvironmentVariables.Remove($name) }
        foreach ($name in $Environment.Keys) { $info.EnvironmentVariables[$name] = [string]$Environment[$name] }

        $process = [System.Diagnostics.Process]::Start($info)
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(120000)) { $process.Kill(); throw 'The user action script did not finish within 120 seconds.' }
        $process.WaitForExit()
        $stdout = $stdoutTask.Result
        $lines = @($stdout -split "`r?`n" | Where-Object { $_ -ne '' })
        $parsed = $null
        if ($lines.Count -eq 1) { $parsed = $lines[0] | ConvertFrom-Json }
        $calls = @()
        if ([System.IO.File]::Exists($Sandbox.CallLog))
        {
            $calls = @([System.IO.File]::ReadAllLines($Sandbox.CallLog) | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json })
        }
        return [pscustomobject]@{
            ExitCode = $process.ExitCode
            Lines    = $lines
            Stderr   = $stderrTask.Result
            Result   = $parsed
            Calls    = $calls
        }
    }

    function script:Get-DLUAPropertyNames
    {
        param ([object]$Object)
        return @($Object.PSObject.Properties | ForEach-Object { $_.Name } | Sort-Object)
    }
}

Describe 'Invoke-DeadLoadUserAction CleanTemp' {
    BeforeEach { $script:sb = New-DLUASandbox }
    AfterEach { Remove-DLSandbox -Sandbox $script:sb }

    It 'runs the engine in User mode and returns one JSON object with the CleanTemp shape' {
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CleanTemp

        $run.ExitCode | Should -Be 0
        $run.Lines.Count | Should -Be 1
        $run.Lines[0] | Should -Match '^\{.*\}$'
        (Get-DLUAPropertyNames -Object $run.Result) -join ',' | Should -Be 'Action,FreedBytes,Message,Result'
        $run.Result.Action | Should -Be 'CleanTemp'
        $run.Result.Result | Should -Be 'Success'
        $run.Result.FreedBytes | Should -Be 5242880
        $run.Result.Message | Should -Match '5\.0 MB'

        $run.Calls.Count | Should -Be 1
        $run.Calls[0].Command | Should -Be 'Invoke-DeadLoad'
        $run.Calls[0].Parameters.Mode | Should -Be 'User'
        $run.Calls[0].Parameters.NoEventLog | Should -BeTrue
    }

    It 'keeps engine warnings off stdout and reports them in the message' {
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CleanTemp -Environment @{ DEADLOAD_STUB_WARN = '1' }

        $run.ExitCode | Should -Be 0
        $run.Lines.Count | Should -Be 1
        $run.Result.Result | Should -Be 'Success'
        $run.Result.Message | Should -Match '1 warning'
    }

    It 'maps an engine Partial and Failed summary without failing the script' {
        $partial = Invoke-DLUAScript -Sandbox $script:sb -Action CleanTemp -Environment @{ DEADLOAD_STUB_RESULT = 'Partial' }
        $partial.ExitCode | Should -Be 0
        $partial.Result.Result | Should -Be 'Partial'

        $failed = Invoke-DLUAScript -Sandbox $script:sb -Action CleanTemp -Environment @{ DEADLOAD_STUB_RESULT = 'Failed' }
        $failed.ExitCode | Should -Be 0
        $failed.Result.Result | Should -Be 'Failed'
    }

    It 'treats an engine Skipped run (nothing to do) as Success' {
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CleanTemp -Environment @{ DEADLOAD_STUB_RESULT = 'Skipped' }
        $run.Result.Result | Should -Be 'Success'
    }

    It 'exits 1 with one Failed JSON object when the engine throws' {
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CleanTemp -Environment @{ DEADLOAD_STUB_THROW = '1' }

        $run.ExitCode | Should -Be 1
        $run.Lines.Count | Should -Be 1
        $run.Result.Result | Should -Be 'Failed'
        $run.Result.Message | Should -Match 'stub engine exploded'
        $run.Result.FreedBytes | Should -Be 0
    }

    It 'exits 1 with one Failed JSON object when the module cannot be loaded' {
        $missing = Join-Path $script:sb.Root 'NoSuchModule\DeadLoad.psd1'
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CleanTemp -ModulePath $missing

        $run.ExitCode | Should -Be 1
        $run.Lines.Count | Should -Be 1
        $run.Result.Action | Should -Be 'CleanTemp'
        $run.Result.Result | Should -Be 'Failed'
    }
}

Describe 'Invoke-DeadLoadUserAction CollectLogs' {
    AfterEach { Remove-DLSandbox -Sandbox $script:sb }

    It 'writes to the Desktop by default with the default CollectDays' {
        $script:sb = New-DLUASandbox
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CollectLogs
        $desktop = [Environment]::GetFolderPath('Desktop')
        $tokens = $null
        $errors = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:RepoRoot 'src\engine\DeadLoad\Data\Defaults.psd1'), [ref]$tokens, [ref]$errors)
        $defaults = $ast.Find({ $args[0] -is [System.Management.Automation.Language.HashtableAst] }, $false).SafeGetValue()

        $run.ExitCode | Should -Be 0
        $run.Lines.Count | Should -Be 1
        (Get-DLUAPropertyNames -Object $run.Result) -join ',' | Should -Be 'Action,Message,Path,Result'
        $run.Result.Action | Should -Be 'CollectLogs'
        $run.Result.Result | Should -Be 'Success'
        $run.Calls.Count | Should -Be 1
        $run.Calls[0].Command | Should -Be 'Export-DeadLoadSupportBundle'
        $run.Calls[0].Parameters.Destination | Should -Be $desktop
        $run.Calls[0].Parameters.Days | Should -Be $defaults.Tray.CollectDays
        $run.Result.Path | Should -Be (Join-Path $desktop 'DeadLoad-support-TEST-20260101-000000.zip')
    }

    It 'writes to SupportShare when the folder exists and honors CollectDays' {
        $script:sb = New-DLUASandbox
        $share = Join-Path $script:sb.Root 'Share'
        [void][System.IO.Directory]::CreateDirectory($share)
        [System.IO.File]::WriteAllText($script:sb.PolicyPath, ("@{{ SupportShare = '{0}'; CollectDays = 3 }}" -f $share))

        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CollectLogs

        $run.ExitCode | Should -Be 0
        $run.Result.Result | Should -Be 'Success'
        $run.Calls[0].Parameters.Destination | Should -Be $share
        $run.Calls[0].Parameters.Days | Should -Be 3
        $run.Result.Path | Should -Be (Join-Path $share 'DeadLoad-support-TEST-20260101-000000.zip')
        $run.Result.Message | Should -Not -Match 'not reachable'
    }

    It 'falls back to the Desktop when SupportShare does not exist and says so' {
        $script:sb = New-DLUASandbox
        $share = Join-Path $script:sb.Root 'NoSuchShare'
        [System.IO.File]::WriteAllText($script:sb.PolicyPath, ("@{{ SupportShare = '{0}' }}" -f $share))

        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CollectLogs

        $run.ExitCode | Should -Be 0
        $run.Result.Result | Should -Be 'Success'
        $run.Calls[0].Parameters.Destination | Should -Be ([Environment]::GetFolderPath('Desktop'))
        $run.Result.Message | Should -Match 'not reachable'
        [System.IO.Directory]::Exists($share) | Should -BeFalse
    }

    It 'reports Partial when files could not be included, with stdout still one object' {
        $script:sb = New-DLUASandbox
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CollectLogs -Environment @{ DEADLOAD_STUB_WARN = '1' }

        $run.ExitCode | Should -Be 0
        $run.Lines.Count | Should -Be 1
        $run.Result.Result | Should -Be 'Partial'
        $run.Result.Message | Should -Match '2 file\(s\) could not be included'
    }

    It 'exits 1 with one Failed JSON object when the bundle cmdlet throws' {
        $script:sb = New-DLUASandbox
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CollectLogs -Environment @{ DEADLOAD_STUB_THROW = '1' }

        $run.ExitCode | Should -Be 1
        $run.Lines.Count | Should -Be 1
        $run.Result.Result | Should -Be 'Failed'
        $run.Result.PSObject.Properties['Path'] | Should -Not -BeNullOrEmpty
        $run.Result.Path | Should -BeNullOrEmpty
    }
}

Describe 'Invoke-DeadLoadUserAction policy' {
    AfterEach { Remove-DLSandbox -Sandbox $script:sb }

    It 'returns Disabled and never loads the module when AllowCleanTemp is 0' {
        $script:sb = New-DLUASandbox -Policy '@{ AllowCleanTemp = 0 }'
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CleanTemp

        $run.ExitCode | Should -Be 0
        $run.Lines.Count | Should -Be 1
        $run.Result.Result | Should -Be 'Disabled'
        $run.Result.FreedBytes | Should -Be 0
        $run.Calls.Count | Should -Be 0
    }

    It 'returns Disabled when AllowCollectLogs is 0 and leaves CleanTemp allowed' {
        $script:sb = New-DLUASandbox -Policy '@{ AllowCollectLogs = 0 }'

        $collect = Invoke-DLUAScript -Sandbox $script:sb -Action CollectLogs
        $collect.ExitCode | Should -Be 0
        $collect.Result.Result | Should -Be 'Disabled'
        $collect.Result.Path | Should -BeNullOrEmpty
        $collect.Calls.Count | Should -Be 0

        $clean = Invoke-DLUAScript -Sandbox $script:sb -Action CleanTemp
        $clean.Result.Result | Should -Be 'Success'
    }

    It 'ignores invalid values so the default applies' {
        $script:sb = New-DLUASandbox -Policy "@{ AllowCleanTemp = 7; CollectDays = 0 }"

        $clean = Invoke-DLUAScript -Sandbox $script:sb -Action CleanTemp
        $clean.Result.Result | Should -Be 'Success'

        # Both runs share the sandbox call log, so pick the bundle call rather than the first.
        $collect = Invoke-DLUAScript -Sandbox $script:sb -Action CollectLogs
        $bundleCalls = @($collect.Calls | Where-Object { $_.Command -eq 'Export-DeadLoadSupportBundle' })
        $bundleCalls.Count | Should -Be 1
        $bundleCalls[0].Parameters.Days | Should -Be 7
    }

    It 'fails closed when the test policy file does not parse' {
        $script:sb = New-DLUASandbox -Policy '@{ AllowCleanTemp = '
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CleanTemp

        $run.ExitCode | Should -Be 1
        $run.Result.Result | Should -Be 'Failed'
        $run.Calls.Count | Should -Be 0
    }
}

Describe 'Invoke-DeadLoadUserAction output encoding' {
    AfterEach { Remove-DLSandbox -Sandbox $script:sb }

    It 'escapes non-ASCII characters in the JSON so stdout stays 7-bit' {
        $script:sb = New-DLUASandbox
        $share = Join-Path $script:sb.Root ('Sh' + [char]0x00E9 + 'are')
        [void][System.IO.Directory]::CreateDirectory($share)
        [System.IO.File]::WriteAllText($script:sb.PolicyPath, ("@{{ SupportShare = '{0}' }}" -f $share), (New-Object System.Text.UTF8Encoding $true))

        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CollectLogs

        $run.Lines[0] | Should -Not -Match '[^\x00-\x7F]'
        $run.Lines[0] | Should -Match '\\u00e9'
        $run.Result.Path | Should -Be (Join-Path $share 'DeadLoad-support-TEST-20260101-000000.zip')
    }
}
