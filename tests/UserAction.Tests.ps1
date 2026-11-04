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

function Invoke-DeadLoadAnalysis
{
    [CmdletBinding()]
    param ([string]$Path, [switch]$NoEventLog)

    Write-StubCall -Command 'Invoke-DeadLoadAnalysis' -Parameters @{ Path = $Path; NoEventLog = [bool]$NoEventLog }
    if ($env:DEADLOAD_STUB_WARN) { Write-Warning 'stub warning' }
    if ($env:DEADLOAD_STUB_THROW) { throw 'stub engine exploded' }
    $result = 'Success'
    if ($env:DEADLOAD_STUB_RESULT) { $result = $env:DEADLOAD_STUB_RESULT }
    $where = $Path
    if (-not $where) { $where = 'C:\stub\analysis.json' }
    [pscustomobject]@{
        analysisId = 'stub-analysis'
        result     = $result
        reason     = $null
        totals     = [pscustomobject]@{ itemCount = 4; estimatedBytes = [int64]3145728 }
        Path       = $where
    }
}

function Invoke-DeadLoadCleanup
{
    [CmdletBinding(SupportsShouldProcess)]
    param ([string[]]$Category, [string]$AnalysisPath, [string]$AnalysisId, [switch]$NoEventLog)

    Write-StubCall -Command 'Invoke-DeadLoadCleanup' -Parameters @{ Category = @($Category); AnalysisPath = $AnalysisPath; AnalysisId = $AnalysisId; NoEventLog = [bool]$NoEventLog }
    if ($env:DEADLOAD_STUB_THROW) { throw 'stub engine exploded' }
    $result = 'Success'
    if ($env:DEADLOAD_STUB_RESULT) { $result = $env:DEADLOAD_STUB_RESULT }
    [pscustomobject]@{
        result       = $result
        reason       = 'Category revit.journals cannot be cleaned here: Restricted.'
        freedBytes   = [int64]2097152
        deletedCount = 2
        skippedCount = 1
        Path         = 'C:\stub\last-cleanup.json'
    }
}

function Get-DeadLoadConfiguration
{
    [CmdletBinding()]
    param ([switch]$Trace)

    Write-StubCall -Command 'Get-DeadLoadConfiguration' -Parameters @{ Trace = [bool]$Trace }
    if ($env:DEADLOAD_STUB_WARN) { Write-Warning 'stub warning' }
    if ($env:DEADLOAD_STUB_THROW) { throw 'stub engine exploded' }
    [pscustomobject][ordered]@{ Name = 'Enabled'; Value = 1; Source = 'Default' }
    [pscustomobject][ordered]@{ Name = 'Pressure\FloorGB'; Value = 30; Source = 'Policy' }
    [pscustomobject][ordered]@{ Name = 'Categories\user.temp\Roots'; Value = @('{LocalAppData}\Temp', '{Temp}'); Source = 'Default' }
    [pscustomobject][ordered]@{ Name = 'Tray\SupportShare'; Value = ('\\server\sh' + [char]0x00E9 + 're'); Source = 'Local' }
    [pscustomobject][ordered]@{ Name = 'Pressure\TargetGB'; Value = '900000'; Source = 'Rejected:Policy'; Reason = 'above the maximum' }
}

Export-ModuleMember -Function Invoke-DeadLoad, Export-DeadLoadSupportBundle, Invoke-DeadLoadAnalysis, Invoke-DeadLoadCleanup, Get-DeadLoadConfiguration
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
            [string]$ModulePath = $Sandbox.StubPath,
            [string]$ScriptPath = $script:ScriptPath,
            [string]$Arguments = '',
            [switch]$NoModulePath
        )

        $moduleArgument = ' -ModulePath "{0}"' -f $ModulePath
        if ($NoModulePath) { $moduleArgument = '' }
        $info = New-Object System.Diagnostics.ProcessStartInfo
        $info.FileName = $script:HostPath
        $info.Arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Action {1}{2} -NoEventLog {3}' -f $ScriptPath, $Action, $moduleArgument, $Arguments
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

    It 'loads the module beside it when started without -ModulePath, as the tray starts it' {
        # The installed layout: engine\Invoke-DeadLoadUserAction.ps1 and engine\DeadLoad\DeadLoad.psd1.
        $engine = Join-Path $script:sb.Root 'engine'
        $moduleFolder = Join-Path $engine 'DeadLoad'
        [void][System.IO.Directory]::CreateDirectory($moduleFolder)
        Copy-Item -LiteralPath $script:ScriptPath -Destination $engine
        Copy-Item -LiteralPath $script:sb.StubPath -Destination $moduleFolder
        $manifest = "@{ RootModule = 'DeadLoadStub.psm1'; ModuleVersion = '0.0.1'; GUID = '0f6d1c52-2a43-4d1e-9a51-3c2b7e9d4a10'; FunctionsToExport = @('Invoke-DeadLoad', 'Export-DeadLoadSupportBundle') }"
        [System.IO.File]::WriteAllText((Join-Path $moduleFolder 'DeadLoad.psd1'), $manifest, (New-Object System.Text.UTF8Encoding $false))

        $run = Invoke-DLUAScript -Sandbox $script:sb -Action CleanTemp -ScriptPath (Join-Path $engine 'Invoke-DeadLoadUserAction.ps1') -NoModulePath

        $run.Stderr | Should -BeNullOrEmpty
        $run.ExitCode | Should -Be 0
        $run.Lines.Count | Should -Be 1
        $run.Result.Result | Should -Be 'Success'
        Test-Path -LiteralPath (Join-Path $moduleFolder 'calls.jsonl') | Should -BeTrue
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

Describe 'Invoke-DeadLoadUserAction Analyze and Clean' {
    BeforeEach { $script:sb = New-DLUASandbox }
    AfterEach { Remove-DLSandbox -Sandbox $script:sb }

    It 'Analyze returns one JSON object with the Analyze shape' {
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action Analyze

        $run.ExitCode | Should -Be 0
        $run.Lines.Count | Should -Be 1
        (Get-DLUAPropertyNames -Object $run.Result) -join ',' | Should -Be 'Action,AnalysisId,EstimatedBytes,ItemCount,Message,Path,Result'
        $run.Result.Action | Should -Be 'Analyze'
        $run.Result.Result | Should -Be 'Success'
        $run.Result.AnalysisId | Should -Be 'stub-analysis'
        $run.Result.EstimatedBytes | Should -Be 3145728
        $run.Result.ItemCount | Should -Be 4
        $run.Result.Path | Should -Be 'C:\stub\analysis.json'
        $run.Result.Message | Should -Match 'estimated 3\.0 MB in 4 item'
        $run.Calls.Count | Should -Be 1
        $run.Calls[0].Command | Should -Be 'Invoke-DeadLoadAnalysis'
        $run.Calls[0].Parameters.NoEventLog | Should -BeTrue
    }

    It 'Analyze passes -AnalysisPath through' {
        $target = Join-Path $script:sb.Root 'mine.json'
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action Analyze -Arguments ('-AnalysisPath "{0}"' -f $target)

        $run.Calls[0].Parameters.Path | Should -Be $target
        $run.Result.Path | Should -Be $target
    }

    It 'Clean splits the comma-separated categories and returns the Clean shape' {
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action Clean -Arguments '-Categories user.temp,autodesk.cer -AnalysisId stub-analysis'

        $run.ExitCode | Should -Be 0
        $run.Lines.Count | Should -Be 1
        (Get-DLUAPropertyNames -Object $run.Result) -join ',' | Should -Be 'Action,DeletedCount,FreedBytes,Message,Path,Result,SkippedCount'
        $run.Result.Result | Should -Be 'Success'
        $run.Result.FreedBytes | Should -Be 2097152
        $run.Result.DeletedCount | Should -Be 2
        $run.Result.SkippedCount | Should -Be 1
        $run.Result.Path | Should -Be 'C:\stub\last-cleanup.json'
        $run.Result.Message | Should -Match 'Recovered 2\.0 MB'
        $run.Calls[0].Command | Should -Be 'Invoke-DeadLoadCleanup'
        @($run.Calls[0].Parameters.Category) -join '|' | Should -Be 'user.temp|autodesk.cer'
        $run.Calls[0].Parameters.AnalysisId | Should -Be 'stub-analysis'
    }

    It 'Clean exits 2 with Result Refused when the engine refuses the request' {
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action Clean -Arguments '-Categories revit.journals' -Environment @{ DEADLOAD_STUB_RESULT = 'Refused' }

        $run.ExitCode | Should -Be 2
        $run.Lines.Count | Should -Be 1
        $run.Result.Result | Should -Be 'Refused'
        $run.Result.Message | Should -Match 'Nothing was deleted'
        $run.Result.Message | Should -Match 'revit\.journals'
    }

    It 'Clean maps Partial and ReportOnly' -ForEach @(
        @{ Engine = 'Partial'; Message = 'skipped' }
        @{ Engine = 'ReportOnly'; Message = 'Report-only' }
    ) {
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action Clean -Arguments '-Categories user.temp' -Environment @{ DEADLOAD_STUB_RESULT = $Engine }

        $run.ExitCode | Should -Be 0
        $run.Result.Result | Should -Be $Engine
        $run.Result.Message | Should -Match $Message
    }

    It 'exits 1 with one Failed JSON object of the right shape when the engine throws' {
        $analyze = Invoke-DLUAScript -Sandbox $script:sb -Action Analyze -Environment @{ DEADLOAD_STUB_THROW = '1' }
        $analyze.ExitCode | Should -Be 1
        $analyze.Result.Result | Should -Be 'Failed'
        (Get-DLUAPropertyNames -Object $analyze.Result) -join ',' | Should -Be 'Action,AnalysisId,EstimatedBytes,ItemCount,Message,Path,Result'

        $clean = Invoke-DLUAScript -Sandbox $script:sb -Action Clean -Arguments '-Categories user.temp' -Environment @{ DEADLOAD_STUB_THROW = '1' }
        $clean.ExitCode | Should -Be 1
        $clean.Result.Result | Should -Be 'Failed'
        $clean.Result.FreedBytes | Should -Be 0
    }

    It 'returns Disabled for Analyze and Clean, without loading the module, when AllowCleanTemp is 0' {
        [System.IO.File]::WriteAllText($script:sb.PolicyPath, '@{ AllowCleanTemp = 0 }', (New-Object System.Text.UTF8Encoding $false))

        foreach ($action in 'Analyze', 'Clean')
        {
            $run = Invoke-DLUAScript -Sandbox $script:sb -Action $action -Arguments '-Categories user.temp'
            $run.ExitCode | Should -Be 0 -Because $action
            $run.Result.Result | Should -Be 'Disabled' -Because $action
        }
        $run.Calls.Count | Should -Be 0
    }
}

Describe 'Invoke-DeadLoadUserAction Configuration' {
    BeforeEach { $script:sb = New-DLUASandbox }
    AfterEach { Remove-DLSandbox -Sandbox $script:sb }

    It 'writes the traced configuration to a file and returns the Configuration shape' {
        $target = Join-Path $script:sb.Root 'out\configuration.json'
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action Configuration -Arguments ('-OutputPath "{0}"' -f $target)

        $run.ExitCode | Should -Be 0
        $run.Lines.Count | Should -Be 1
        $run.Lines[0] | Should -Not -Match '[^\x00-\x7F]'
        (Get-DLUAPropertyNames -Object $run.Result) -join ',' | Should -Be 'Action,EngineVersion,Message,Path,RejectedCount,Result,SettingCount'
        $run.Result.Action | Should -Be 'Configuration'
        $run.Result.Result | Should -Be 'Success'
        $run.Result.Path | Should -Be $target
        $run.Result.SettingCount | Should -Be 4
        $run.Result.RejectedCount | Should -Be 1
        $run.Result.EngineVersion | Should -Match '^\d+\.\d+'
        $run.Result.Message | Should -Match '4 setting\(s\) read; 1 value\(s\) ignored'
        $run.Calls.Count | Should -Be 1
        $run.Calls[0].Command | Should -Be 'Get-DeadLoadConfiguration'
        $run.Calls[0].Parameters.Trace | Should -BeTrue

        [System.IO.File]::Exists($target) | Should -BeTrue
        [System.IO.File]::Exists($target + '.tmp') | Should -BeFalse
        $document = [System.IO.File]::ReadAllText($target) | ConvertFrom-Json
        $document.schemaVersion | Should -Be 1
        $document.engineVersion | Should -Be $run.Result.EngineVersion
        @($document.settings).Count | Should -Be 5
        $roots = @($document.settings | Where-Object { $_.name -eq 'Categories\user.temp\Roots' })[0]
        $roots.value | Should -Be '{LocalAppData}\Temp; {Temp}'
        $roots.source | Should -Be 'Default'
        $share = @($document.settings | Where-Object { $_.name -eq 'Tray\SupportShare' })[0]
        $share.value | Should -Be ('\\server\sh' + [char]0x00E9 + 're')
        $share.source | Should -Be 'Local'
        $ignored = @($document.settings | Where-Object { $_.source -eq 'Rejected:Policy' })[0]
        $ignored.name | Should -Be 'Pressure\TargetGB'
        $ignored.reason | Should -Be 'above the maximum'
        @($document.settings | Where-Object { $_.name -eq 'Enabled' })[0].value | Should -Be '1'
    }

    It 'replaces an existing file and reads policy even when every tray action is turned off' {
        [System.IO.File]::WriteAllText($script:sb.PolicyPath, '@{ AllowCleanTemp = 0; AllowCollectLogs = 0 }', (New-Object System.Text.UTF8Encoding $false))
        $target = Join-Path $script:sb.Root 'configuration.json'
        [System.IO.File]::WriteAllText($target, 'old', (New-Object System.Text.UTF8Encoding $false))

        $run = Invoke-DLUAScript -Sandbox $script:sb -Action Configuration -Arguments ('-OutputPath "{0}"' -f $target)

        $run.ExitCode | Should -Be 0
        $run.Result.Result | Should -Be 'Success'
        ([System.IO.File]::ReadAllText($target) | ConvertFrom-Json).schemaVersion | Should -Be 1
    }

    It 'keeps engine warnings off stdout and counts them in the message' {
        $target = Join-Path $script:sb.Root 'configuration.json'
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action Configuration -Arguments ('-OutputPath "{0}"' -f $target) -Environment @{ DEADLOAD_STUB_WARN = '1' }

        $run.ExitCode | Should -Be 0
        $run.Lines.Count | Should -Be 1
        $run.Result.Message | Should -Match '1 warning'
    }

    It 'exits 1 with one Failed JSON object of the same shape and writes no file when the engine throws' {
        $target = Join-Path $script:sb.Root 'configuration.json'
        $run = Invoke-DLUAScript -Sandbox $script:sb -Action Configuration -Arguments ('-OutputPath "{0}"' -f $target) -Environment @{ DEADLOAD_STUB_THROW = '1' }

        $run.ExitCode | Should -Be 1
        $run.Lines.Count | Should -Be 1
        (Get-DLUAPropertyNames -Object $run.Result) -join ',' | Should -Be 'Action,EngineVersion,Message,Path,RejectedCount,Result,SettingCount'
        $run.Result.Result | Should -Be 'Failed'
        $run.Result.Message | Should -Match 'stub engine exploded'
        $run.Result.Path | Should -BeNullOrEmpty
        $run.Result.SettingCount | Should -Be 0
        [System.IO.File]::Exists($target) | Should -BeFalse
    }
}
