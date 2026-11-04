<#
    .SYNOPSIS
        Tray entry point: runs one user action in the signed-in user's own context and writes
        exactly one compact JSON result object to stdout.

    .DESCRIPTION
        Started by DeadLoadTray.exe without elevation. The tray decides what to show, but this
        script re-reads the tray policy itself (machine policy > user policy > local > defaults)
        so a stale menu, or a user starting the script by hand, cannot run an action that policy
        has turned off.

        Actions:
          CleanTemp    Invoke-DeadLoad -Mode User (current profile, user-action categories, the
                       Tray.CleanTempMinAgeDays age floor). Writes Application event 4001.
          CollectLogs  Export-DeadLoadSupportBundle to SupportShare when it is set and reachable,
                       else to the user's Desktop. The cmdlet writes event 4002.
          Analyze      Invoke-DeadLoadAnalysis: the cleanup review's report-only scan of the
                       current profile; writes analysis.json (D22).
          Clean        Invoke-DeadLoadCleanup -Category: deletes the reviewed items of those
                       categories that a fresh plan still selects (D23). Writes event 4003.
          Configuration
                       Get-DeadLoadConfiguration -Trace: the effective configuration with the
                       source of every value, written to a JSON file (too large for one stdout
                       line) for the window's read-only Settings page. Not gated by policy: it
                       only reads what policy says.
        Tray.AllowCleanTemp gates CleanTemp, Analyze and Clean: every way a user cleans their
        own files.

        stdout carries only the result (docs/design/ENGINE-UI-CONTRACT.md): { Action, Result,
        Message } and per action Path (CollectLogs, Analyze, Clean, Configuration), FreedBytes
        (CleanTemp, Clean), AnalysisId, EstimatedBytes, ItemCount (Analyze), DeletedCount,
        SkippedCount (Clean), EngineVersion, SettingCount, RejectedCount (Configuration). Prose
        goes to the verbose stream. Exit code 0 when the action was handled (whatever its
        Result), 2 when Clean was refused (Result Refused), 1 when the script itself failed
        (Result Failed).

    .PARAMETER Action
        CleanTemp, CollectLogs, Analyze, Clean or Configuration.

    .PARAMETER Categories
        Clean: the category ids the user selected, comma-separated (one argument under -File).

    .PARAMETER AnalysisPath
        Analyze: where to write the analysis; Clean: the analysis to clean from. Default
        %LOCALAPPDATA%\DeadLoad\analysis.json.

    .PARAMETER AnalysisId
        Clean: the id of the analysis the user reviewed; a different file is refused.

    .PARAMETER OutputPath
        Configuration: the file to write. Default %LOCALAPPDATA%\DeadLoad\configuration.json.

    .PARAMETER ModulePath
        The DeadLoad module manifest. Default: DeadLoad\DeadLoad.psd1 beside this script.

    .PARAMETER NoEventLog
        Do not write events 4001 or 4003 and ask the engine not to write events (tests).

    .EXAMPLE
        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File Invoke-DeadLoadUserAction.ps1 -Action CleanTemp

    .EXAMPLE
        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File Invoke-DeadLoadUserAction.ps1 -Action Clean -Categories user.temp,autodesk.cer -AnalysisId 20261104T150000Z-1a2b3c4d
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory)]
    [ValidateSet('CleanTemp', 'CollectLogs', 'Analyze', 'Clean', 'Configuration')]
    [string]$Action,

    [string[]]$Categories,

    [string]$AnalysisPath,

    [string]$AnalysisId,

    [string]$OutputPath,

    # Resolved in the body: Windows PowerShell 5.1 leaves $PSScriptRoot empty in param()
    # defaults of a script started with -File, so a default here fails to bind before any
    # code runs and the tray gets exit 1 with no result.
    [string]$ModulePath,

    [switch]$NoEventLog
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Mirrors the Tray section of Data\Defaults.psd1 and the ranges of Data\Settings.psd1 for the
# values this script needs. Kept here because the script must answer even when the module
# cannot be loaded (a Disabled action never imports it).
$script:TrayDefaults = [ordered]@{
    AllowCleanTemp   = 1
    AllowCollectLogs = 1
    CollectDays      = 7
    SupportShare     = ''
}
$script:TraySchema = @{
    AllowCleanTemp   = @{ Type = 'Bool' }
    AllowCollectLogs = @{ Type = 'Bool' }
    CollectDays      = @{ Type = 'Int'; Min = 1; Max = 365 }
    SupportShare     = @{ Type = 'String' }
}

function ConvertTo-DLUASetting
{
    <#
        .SYNOPSIS
            Validates one raw value against the tray schema. Returns @{ Valid; Value } so an
            invalid value lets the next source win, as the engine's reader does.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)] [string]$Name,
        [AllowNull()] [object]$Value
    )

    $invalid = @{ Valid = $false; Value = $null }
    if ($null -eq $Value) { return $invalid }
    $schema = $script:TraySchema[$Name]
    switch ($schema.Type)
    {
        'String'
        {
            return @{ Valid = $true; Value = ([string]$Value).Trim() }
        }
        default
        {
            $number = 0
            if (-not [int]::TryParse([string]$Value, [ref]$number)) { return $invalid }
            if ($schema.Type -eq 'Bool')
            {
                if ($number -ne 0 -and $number -ne 1) { return $invalid }
            }
            elseif ($number -lt $schema.Min -or $number -gt $schema.Max) { return $invalid }
            return @{ Valid = $true; Value = $number }
        }
    }
}

function Read-DLUARegistryLayer
{
    <#
        .SYNOPSIS
            Raw values of one registry key as a hashtable (empty when the key is absent). The
            64-bit view is used so HKLM\SOFTWARE\DeadLoad is the key the installer wrote even if
            a 32-bit host runs this script.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)] [Microsoft.Win32.RegistryHive]$Hive,
        [Parameter(Mandatory)] [string]$SubKey
    )

    $values = @{}
    $view = [Microsoft.Win32.RegistryView]::Default
    if ([Environment]::Is64BitOperatingSystem) { $view = [Microsoft.Win32.RegistryView]::Registry64 }
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($Hive, $view)
    try
    {
        $key = $base.OpenSubKey($SubKey, $false)
        if ($null -eq $key) { return $values }
        try
        {
            foreach ($name in $key.GetValueNames()) { $values[$name] = $key.GetValue($name) }
        }
        finally { $key.Dispose() }
    }
    finally { $base.Dispose() }
    return $values
}

function Read-DLUAPolicyFile
{
    # Parsed, never dot-sourced or executed: SafeGetValue accepts only literal data.
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [string]$Path)

    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw ('Test tray policy file does not parse: {0}' -f $Path) }
    $table = $ast.Find({ $args[0] -is [System.Management.Automation.Language.HashtableAst] }, $false)
    if ($null -eq $table) { return @{} }
    return $table.SafeGetValue()
}

function Get-DLUATrayPolicy
{
    <#
        .SYNOPSIS
            Effective tray values this script needs, each with its source.

        .DESCRIPTION
            DEADLOAD_TEST_TRAYPOLICY (path to a .psd1) replaces every registry layer when it is
            set, so tests can prove the Disabled path without writing HKLM. It is a test seam
            only: a value that is not a readable .psd1 fails the action instead of silently
            falling back to the registry.
    #>
    [CmdletBinding()]
    param ()

    $layers = New-Object 'System.Collections.Generic.List[object]'
    $testPolicy = $env:DEADLOAD_TEST_TRAYPOLICY
    if ($testPolicy)
    {
        Write-Verbose ('Tray policy from the test override {0}; registry not read.' -f $testPolicy)
        $layers.Add(@{ Source = 'TestOverride'; Values = (Read-DLUAPolicyFile -Path $testPolicy) })
    }
    else
    {
        $layers.Add(@{ Source = 'Policy'; Values = (Read-DLUARegistryLayer -Hive LocalMachine -SubKey 'SOFTWARE\Policies\DeadLoad\Tray') })
        $layers.Add(@{ Source = 'UserPolicy'; Values = (Read-DLUARegistryLayer -Hive CurrentUser -SubKey 'SOFTWARE\Policies\DeadLoad\Tray') })
        $layers.Add(@{ Source = 'Local'; Values = (Read-DLUARegistryLayer -Hive LocalMachine -SubKey 'SOFTWARE\DeadLoad\Tray') })
    }

    $effective = [ordered]@{}
    $sources = [ordered]@{}
    foreach ($name in $script:TrayDefaults.Keys)
    {
        $effective[$name] = $script:TrayDefaults[$name]
        $sources[$name] = 'Default'
        foreach ($layer in $layers)
        {
            if (-not $layer.Values.ContainsKey($name)) { continue }
            $converted = ConvertTo-DLUASetting -Name $name -Value $layer.Values[$name]
            if (-not $converted.Valid)
            {
                Write-Verbose ('Tray setting {0} from {1} ignored: invalid value.' -f $name, $layer.Source)
                continue
            }
            $effective[$name] = $converted.Value
            $sources[$name] = $layer.Source
            break
        }
        Write-Verbose ('Tray setting {0} = {1} ({2})' -f $name, $effective[$name], $sources[$name])
    }
    $effective['Sources'] = $sources
    return [pscustomobject]$effective
}

function Write-DLUAEvent
{
    <#
        .SYNOPSIS
            Writes one Application event under the DeadLoad source, only when the installer
            registered it: WriteEntry on a missing source would try to create it, which a
            standard user cannot do and an admin must not do from here.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)] [int]$Id,
        [Parameter(Mandatory)] [string]$Message
    )

    try
    {
        if (-not [System.Diagnostics.EventLog]::SourceExists('DeadLoad'))
        {
            Write-Verbose 'Event source DeadLoad not registered; event not written.'
            return
        }
        [System.Diagnostics.EventLog]::WriteEntry('DeadLoad', $Message, [System.Diagnostics.EventLogEntryType]::Information, $Id)
    }
    catch
    {
        # A standard user may be unable to search every log; the action result still stands.
        Write-Verbose ('Event {0} not written: {1}' -f $Id, $_.Exception.Message)
    }
}

function ConvertTo-DLUAJson
{
    <#
        .SYNOPSIS
            One compact JSON line, non-ASCII escaped as \uXXXX so the result survives whatever
            code page the redirected stdout uses (a user name with accents in a path).
    #>
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [System.Collections.IDictionary]$Result)

    $json = ([pscustomobject]$Result) | ConvertTo-Json -Compress -Depth 3
    return [regex]::Replace($json, '[^\x00-\x7F]', { param($match) '\u{0:x4}' -f [int][char]$match.Value })
}

function Invoke-DLUACleanTemp
{
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [System.Collections.IDictionary]$Result)

    $parameters = @{ Mode = 'User' }
    if ($NoEventLog) { $parameters['NoEventLog'] = $true }
    $engineWarnings = $null
    # Warnings would reach stdout under -File; they are counted into the message instead.
    $summary = @(Invoke-DeadLoad @parameters -WarningAction SilentlyContinue -WarningVariable engineWarnings) | Select-Object -Last 1
    if ($null -eq $summary) { throw 'The engine returned no run summary.' }

    $freed = [int64]0
    if ($summary.PSObject.Properties['Totals'] -and $null -ne $summary.Totals -and $summary.Totals.PSObject.Properties['FreedBytes'])
    {
        $freed = [int64]$summary.Totals.FreedBytes
    }
    $reason = $null
    if ($summary.PSObject.Properties['Reason']) { $reason = [string]$summary.Reason }

    # Skipped (nothing to do) is a success from the user's point of view.
    switch ([string]$summary.Result)
    {
        'Partial' { $Result.Result = 'Partial' }
        'Failed' { $Result.Result = 'Failed' }
        'Disabled' { $Result.Result = 'Disabled' }
        default { $Result.Result = 'Success' }
    }
    $Result.FreedBytes = $freed

    $message = 'Freed {0} from your temp files.' -f (Format-DLUABytes -Bytes $freed)
    if ($Result.Result -eq 'Disabled') { $message = 'Cleanup is turned off on this computer.' }
    elseif ($Result.Result -eq 'Failed') { $message = 'Temp cleanup failed.' }
    if ($reason) { $message = '{0} ({1})' -f $message, $reason }
    if (@($engineWarnings).Count -gt 0) { $message = '{0} {1} warning(s).' -f $message, @($engineWarnings).Count }
    $Result.Message = $message
    Write-Verbose $message

    if (-not $NoEventLog)
    {
        Write-DLUAEvent -Id 4001 -Message ('User temp cleanup (tray): result {0}, freed {1} bytes. {2}' -f $Result.Result, $freed, $message)
    }
}

function Invoke-DLUACollectLogs
{
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Result,
        [Parameter(Mandatory)] [pscustomobject]$Policy
    )

    $desktop = [Environment]::GetFolderPath('Desktop')
    $destination = $desktop
    $note = $null
    if ($Policy.SupportShare)
    {
        # An unreachable share is not an error: the user still gets a bundle on the Desktop.
        if ([System.IO.Directory]::Exists($Policy.SupportShare)) { $destination = $Policy.SupportShare }
        else { $note = 'The support share is not reachable, so the file was saved to your Desktop.' }
    }
    Write-Verbose ('Support bundle destination: {0}' -f $destination)

    $bundleWarnings = $null
    $zip = @(Export-DeadLoadSupportBundle -Days $Policy.CollectDays -Destination $destination -WarningAction SilentlyContinue -WarningVariable bundleWarnings) | Select-Object -Last 1
    if ($null -eq $zip) { throw 'No support bundle was created.' }

    $Result.Path = [string]$zip.FullName
    $skipped = @($bundleWarnings).Count
    if ($skipped -gt 0)
    {
        $Result.Result = 'Partial'
        $message = 'Logs collected; {0} file(s) could not be included.' -f $skipped
    }
    else
    {
        $Result.Result = 'Success'
        $message = 'Logs collected.'
    }
    if ($note) { $message = '{0} {1}' -f $message, $note }
    $Result.Message = $message
    Write-Verbose $message
}

function Invoke-DLUAAnalyze
{
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [System.Collections.IDictionary]$Result)

    $parameters = @{}
    if ($AnalysisPath) { $parameters['Path'] = $AnalysisPath }
    if ($NoEventLog) { $parameters['NoEventLog'] = $true }
    $engineWarnings = $null
    $analysis = @(Invoke-DeadLoadAnalysis @parameters -WarningAction SilentlyContinue -WarningVariable engineWarnings) | Select-Object -Last 1
    if ($null -eq $analysis) { throw 'The engine returned no analysis.' }

    $Result.Path = [string]$analysis.Path
    $Result.AnalysisId = [string]$analysis.analysisId
    $Result.EstimatedBytes = [int64]$analysis.totals.estimatedBytes
    $Result.ItemCount = [int]$analysis.totals.itemCount
    switch ([string]$analysis.result)
    {
        'Disabled' { $Result.Result = 'Disabled'; $message = 'Cleanup is turned off on this computer.' }
        'Failed' { $Result.Result = 'Failed'; $message = 'The analysis failed.' }
        'Partial' { $Result.Result = 'Partial'; $message = 'The analysis stopped early: an estimated {0} in {1} item(s) found so far.' -f (Format-DLUABytes -Bytes $Result.EstimatedBytes), $Result.ItemCount }
        default { $Result.Result = 'Success'; $message = 'An estimated {0} in {1} item(s) can be cleaned.' -f (Format-DLUABytes -Bytes $Result.EstimatedBytes), $Result.ItemCount }
    }
    if ($analysis.reason -and $Result.Result -ne 'Success') { $message = '{0} ({1})' -f $message, $analysis.reason }
    if (@($engineWarnings).Count -gt 0) { $message = '{0} {1} warning(s).' -f $message, @($engineWarnings).Count }
    $Result.Message = $message
    Write-Verbose $message
}

function Invoke-DLUAClean
{
    [CmdletBinding()]
    param ([Parameter(Mandatory)] [System.Collections.IDictionary]$Result)

    # powershell.exe -File passes "a,b" as one string; the engine splits it again.
    $ids = @($Categories | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $parameters = @{ Category = $ids }
    if ($AnalysisPath) { $parameters['AnalysisPath'] = $AnalysisPath }
    if ($AnalysisId) { $parameters['AnalysisId'] = $AnalysisId }
    if ($NoEventLog) { $parameters['NoEventLog'] = $true }
    $engineWarnings = $null
    $cleanup = @(Invoke-DeadLoadCleanup @parameters -WarningAction SilentlyContinue -WarningVariable engineWarnings) | Select-Object -Last 1
    if ($null -eq $cleanup) { throw 'The engine returned no cleanup report.' }

    # No report is written for a refusal: Path stays null.
    if ($cleanup.Path) { $Result.Path = [string]$cleanup.Path }
    $Result.FreedBytes = [int64]$cleanup.freedBytes
    $Result.DeletedCount = [int]$cleanup.deletedCount
    $Result.SkippedCount = [int]$cleanup.skippedCount
    $freed = Format-DLUABytes -Bytes $Result.FreedBytes
    switch ([string]$cleanup.result)
    {
        'Refused' { $Result.Result = 'Refused'; $message = 'Nothing was deleted: {0}' -f $cleanup.reason }
        'Disabled' { $Result.Result = 'Disabled'; $message = 'Cleanup is turned off on this computer.' }
        'ReportOnly' { $Result.Result = 'ReportOnly'; $message = 'Report-only mode is on, so nothing was deleted.' }
        'Failed' { $Result.Result = 'Failed'; $message = 'The cleanup failed after recovering {0}. ({1})' -f $freed, $cleanup.reason }
        'Partial' { $Result.Result = 'Partial'; $message = 'Recovered {0}; {1} item(s) were skipped.' -f $freed, $Result.SkippedCount }
        default { $Result.Result = 'Success'; $message = 'Recovered {0}.' -f $freed }
    }
    if (@($engineWarnings).Count -gt 0) { $message = '{0} {1} warning(s).' -f $message, @($engineWarnings).Count }
    $Result.Message = $message
    Write-Verbose $message

    if (-not $NoEventLog -and $Result.Result -ne 'Refused')
    {
        Write-DLUAEvent -Id 4003 -Message ('User cleanup review (tray): result {0}, categories {1}, deleted {2}, skipped {3}, freed {4} bytes.' -f $Result.Result, ($ids -join ','), $Result.DeletedCount, $Result.SkippedCount, $Result.FreedBytes)
    }
}

function ConvertTo-DLUAText
{
    # One display string per value: lists joined with "; ", switches as 1 or 0.
    param ([AllowNull()] [object]$Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [string]) { return $Value }
    if ($Value -is [bool]) { if ($Value) { return '1' } return '0' }
    if ($Value -is [System.Collections.IEnumerable]) { return (@($Value | ForEach-Object { [string]$_ }) -join '; ') }
    return [string]$Value
}

function Invoke-DLUAConfiguration
{
    <#
        .SYNOPSIS
            Writes the effective configuration (Get-DeadLoadConfiguration -Trace) to a JSON file
            and reports its path: 300 and more rows do not belong on one stdout line.
    #>
    [CmdletBinding()]
    param
    (
        [Parameter(Mandatory)] [System.Collections.IDictionary]$Result,
        [AllowNull()] [object]$Module
    )

    $engineWarnings = $null
    $rows = @(Get-DeadLoadConfiguration -Trace -WarningAction SilentlyContinue -WarningVariable engineWarnings)
    $settings = New-Object 'System.Collections.Generic.List[object]'
    $rejected = 0
    foreach ($row in $rows)
    {
        $reason = $null
        if ($row.PSObject.Properties['Reason']) { $reason = [string]$row.Reason }
        $source = [string]$row.Source
        if ($source -like 'Rejected:*') { $rejected++ }
        $settings.Add([pscustomobject][ordered]@{ name = [string]$row.Name; value = (ConvertTo-DLUAText -Value $row.Value); source = $source; reason = $reason })
    }

    $engineVersion = $null
    if ($null -ne $Module) { $engineVersion = [string]$Module.Version }
    $document = [pscustomobject][ordered]@{
        schemaVersion = 1
        product       = 'DeadLoad'
        engineVersion = $engineVersion
        createdUtc    = [DateTime]::UtcNow.ToString('o')
        settings      = $settings.ToArray()
    }

    $target = $OutputPath
    if (-not $target) { $target = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'DeadLoad\configuration.json' }
    $folder = Split-Path -Path $target -Parent
    if (-not [System.IO.Directory]::Exists($folder)) { [void][System.IO.Directory]::CreateDirectory($folder) }
    # Write then rename, so the window never reads half a file.
    $temporary = $target + '.tmp'
    [System.IO.File]::WriteAllText($temporary, ($document | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding $false))
    if ([System.IO.File]::Exists($target)) { [System.IO.File]::Replace($temporary, $target, [NullString]::Value) }
    else { [System.IO.File]::Move($temporary, $target) }

    $Result.Path = $target
    $Result.EngineVersion = $engineVersion
    $Result.SettingCount = $settings.Count - $rejected
    $Result.RejectedCount = $rejected
    $Result.Result = 'Success'
    $message = '{0} setting(s) read; {1} value(s) ignored.' -f $Result.SettingCount, $rejected
    if (@($engineWarnings).Count -gt 0) { $message = '{0} {1} warning(s).' -f $message, @($engineWarnings).Count }
    $Result.Message = $message
    Write-Verbose $message
}

function Format-DLUABytes
{
    param ([int64]$Bytes)

    if ($Bytes -ge 1GB) { return ('{0:N1} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} bytes' -f $Bytes)
}

# The shape is fixed per action so the tray can rely on it.
$result = [ordered]@{ Action = $Action; Result = 'Failed'; Message = '' }
switch ($Action)
{
    'CollectLogs' { $result.Path = $null }
    'Analyze' { $result.Path = $null; $result.AnalysisId = $null; $result.EstimatedBytes = [int64]0; $result.ItemCount = 0 }
    'Clean' { $result.Path = $null; $result.FreedBytes = [int64]0; $result.DeletedCount = 0; $result.SkippedCount = 0 }
    'Configuration' { $result.Path = $null; $result.EngineVersion = $null; $result.SettingCount = 0; $result.RejectedCount = 0 }
    default { $result.FreedBytes = [int64]0 }
}
$exitCode = 0

try
{
    $policy = $null
    $disabled = $false
    # Configuration only reads the effective configuration, policy included: no switch gates it.
    if ($Action -ne 'Configuration')
    {
        $policy = Get-DLUATrayPolicy
        # The review flow cleans the user's own files, as CleanTemp does: one policy gates both.
        $allowName = 'Allow' + $Action
        if ($Action -eq 'Analyze' -or $Action -eq 'Clean') { $allowName = 'AllowCleanTemp' }
        if ([int]$policy.$allowName -ne 1)
        {
            $disabled = $true
            $result.Result = 'Disabled'
            $result.Message = 'This action is turned off by your administrator.'
            Write-Verbose ('{0} disabled by {1}.' -f $Action, $policy.Sources[$allowName])
        }
    }
    if (-not $disabled)
    {
        if (-not $ModulePath) { $ModulePath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'DeadLoad\DeadLoad.psd1' }
        $module = @(Import-Module -Name $ModulePath -ErrorAction Stop -Verbose:$false -PassThru) | Select-Object -First 1
        switch ($Action)
        {
            'CleanTemp' { Invoke-DLUACleanTemp -Result $result }
            'Analyze' { Invoke-DLUAAnalyze -Result $result }
            'Clean' { Invoke-DLUAClean -Result $result }
            'Configuration' { Invoke-DLUAConfiguration -Result $result -Module $module }
            default { Invoke-DLUACollectLogs -Result $result -Policy $policy }
        }
        if ($result.Result -eq 'Refused') { $exitCode = 2 }
    }
}
catch
{
    $result.Result = 'Failed'
    $result.Message = $_.Exception.Message
    Write-Verbose ('{0} failed: {1}' -f $Action, $_.Exception.Message)
    $exitCode = 1
}

Write-Output (ConvertTo-DLUAJson -Result $result)
exit $exitCode
