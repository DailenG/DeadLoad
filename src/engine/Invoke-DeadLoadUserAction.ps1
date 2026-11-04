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

        stdout carries only the result: { Action, Result (Success|Partial|Failed|Disabled),
        Message, Path (CollectLogs), FreedBytes (CleanTemp) }. Prose goes to the verbose stream.
        Exit code 0 unless the script itself failed (1, with Result Failed).

    .PARAMETER Action
        CleanTemp or CollectLogs.

    .PARAMETER ModulePath
        The DeadLoad module manifest. Default: DeadLoad\DeadLoad.psd1 beside this script.

    .PARAMETER NoEventLog
        Do not write event 4001 and ask the engine not to write events (tests).

    .EXAMPLE
        powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File Invoke-DeadLoadUserAction.ps1 -Action CleanTemp
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory)]
    [ValidateSet('CleanTemp', 'CollectLogs')]
    [string]$Action,

    [string]$ModulePath = (Join-Path $PSScriptRoot 'DeadLoad\DeadLoad.psd1'),

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
if ($Action -eq 'CollectLogs') { $result.Path = $null }
else { $result.FreedBytes = [int64]0 }
$exitCode = 0

try
{
    $policy = Get-DLUATrayPolicy
    $allowName = 'Allow' + $Action
    if ([int]$policy.$allowName -ne 1)
    {
        $result.Result = 'Disabled'
        $result.Message = 'This action is turned off by your administrator.'
        Write-Verbose ('{0} disabled by {1}.' -f $Action, $policy.Sources[$allowName])
    }
    else
    {
        Import-Module -Name $ModulePath -ErrorAction Stop -Verbose:$false
        if ($Action -eq 'CleanTemp') { Invoke-DLUACleanTemp -Result $result }
        else { Invoke-DLUACollectLogs -Result $result -Policy $policy }
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
