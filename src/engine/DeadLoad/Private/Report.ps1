$script:DLEventSource = 'DeadLoad'

function Write-DLEvent
{
    <#
        .SYNOPSIS
            Writes one Application log event (ARCHITECTURE section 10). Without a registered
            source (the installer registers it) the event goes to the run log only.
    #>
    param
    (
        [hashtable]$Run,
        [Parameter(Mandatory)] [int]$Id,
        [ValidateSet('Information', 'Warning', 'Error')] [string]$Level = 'Information',
        [Parameter(Mandatory)] [string]$Message
    )

    if ($Run)
    {
        $Run.Events.Add([pscustomobject]@{ Id = $Id; Level = $Level; Message = $Message })
        Write-DLLog -Run $Run -Message ('EVENT {0} {1} {2}' -f $Id, $Level, $Message)
        if ($Run.ContainsKey('NoEventLog') -and $Run.NoEventLog) { return }
    }

    if (-not (Test-DLEventSource)) { return }
    try
    {
        $type = [System.Diagnostics.EventLogEntryType]::$Level
        # The event log caps a message at about 31,000 characters.
        if ($Message.Length -gt 30000) { $Message = $Message.Substring(0, 30000) }
        [System.Diagnostics.EventLog]::WriteEntry($script:DLEventSource, $Message, $type, $Id)
    }
    catch
    {
        Write-Verbose ('Event {0} not written: {1}' -f $Id, $_.Exception.Message)
    }
}

function Test-DLEventSource
{
    [OutputType([bool])]
    param ()

    if ($null -ne $script:DLEventSourceExists) { return $script:DLEventSourceExists }
    $exists = $false
    try { $exists = [System.Diagnostics.EventLog]::SourceExists($script:DLEventSource) } catch { $exists = $false }
    $script:DLEventSourceExists = $exists
    return $exists
}

function New-DLCategoryStat
{
    param ([string]$Id, [bool]$Enabled)

    return [ordered]@{
        Id = $Id; Enabled = $Enabled; Groups = 0; ScannedCount = 0; ScannedBytes = [int64]0
        ProtectedCount = 0; CandidateCount = 0; CandidateBytes = [int64]0; ActedCount = 0
        FreedBytes = [int64]0; SkippedCount = 0; FailedCount = 0
    }
}

function New-DLRunSummary
{
    <#
        .SYNOPSIS
            The run summary (NFR-3: the only object on the output stream), shaped as
            last-run.json (ARCHITECTURE section 10).
    #>
    param
    (
        [Parameter(Mandatory)] [hashtable]$Run,
        [string]$Result,
        [string]$Reason,
        [pscustomobject]$Volume
    )

    $end = Get-DLUtcNow
    # Generic lists go through ToArray(): @() over an empty List[object] throws "Argument types
    # do not match" in some PowerShell builds.
    $trace = @()
    if ($Run.ContainsKey('Trace') -and $Run.Trace) { $trace = @($Run.Trace | ForEach-Object { $_ }) }
    $summary = [pscustomobject][ordered]@{
        PSTypeName      = 'DeadLoad.RunSummary'
        SchemaVersion   = 1
        Product         = 'DeadLoad'
        Version         = $script:DLVersion
        RunId           = $Run.RunId
        Computer        = $env:COMPUTERNAME
        Mode            = $Run.Mode
        StartTime       = $Run.StartTime.ToString('o')
        EndTime         = $end.ToString('o')
        DurationSeconds = [math]::Round(($end - $Run.StartTime).TotalSeconds, 1)
        ReportOnly      = [bool]$Run.ReportOnly
        WhatIf          = [bool]$Run.WhatIf
        Result          = $Result
        Reason          = $Reason
        Volume          = $Volume
        Budget          = [pscustomobject]$Run.Budget
        Totals          = [pscustomobject]$Run.Totals
        Categories      = @($Run.Categories.Values | ForEach-Object { [pscustomobject]$_ })
        Skips           = $Run.Skips.ToArray()
        Failures        = $Run.Failures.ToArray()
        Configuration   = $trace
        Profiles        = @($Run.Aliases | ForEach-Object { [pscustomobject]@{ Alias = $_.Alias; Sid = $_.Sid } })
        LogPath         = $Run.LogPath
    }
    return $summary
}

function ConvertTo-DLJson
{
    # Windows PowerShell 5.1 serializes dates as \/Date()\/; summaries hold ISO strings only.
    param ([Parameter(Mandatory)] [object]$InputObject)

    $copy = $InputObject | Select-Object -Property * -ExcludeProperty PSTypeName
    return ($copy | ConvertTo-Json -Depth 8)
}

function Save-DLRunReport
{
    <#
        .SYNOPSIS
            Writes last-run.json, runs\<runId>.json and the run log under the data root, then
            prunes this product's own logs and run files older than LogRetentionDays.
    #>
    param ([hashtable]$Run, [pscustomobject]$Summary)

    try
    {
        $runs = Join-Path $Run.DataRoot 'runs'
        $logs = Split-Path -Path $Run.LogPath -Parent
        foreach ($directory in $Run.DataRoot, $runs, $logs)
        {
            if (-not [System.IO.Directory]::Exists($directory)) { [void][System.IO.Directory]::CreateDirectory($directory) }
        }
        $json = ConvertTo-DLJson -InputObject $Summary
        $encoding = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText((Join-Path $runs ('{0}.json' -f $Run.RunId)), $json, $encoding)
        # Write-then-rename so a reader never sees half a file.
        $last = Join-Path $Run.DataRoot 'last-run.json'
        $temporary = $last + '.tmp'
        [System.IO.File]::WriteAllText($temporary, $json, $encoding)
        # [NullString]: PowerShell turns $null into '' for a string argument, which Replace rejects.
        if ([System.IO.File]::Exists($last)) { [System.IO.File]::Replace($temporary, $last, [NullString]::Value) }
        else { [System.IO.File]::Move($temporary, $last) }
        [System.IO.File]::AppendAllLines($Run.LogPath, [string[]]$Run.LogLines, $encoding)

        $days = [int]$Run.Config.General.LogRetentionDays
        if ($days -gt 0)
        {
            $cutoff = (Get-DLUtcNow).AddDays(-$days)
            foreach ($pair in @(@($runs, '*.json'), @($logs, 'deadload-*.log')))
            {
                foreach ($old in @((New-Object System.IO.DirectoryInfo $pair[0]).GetFiles($pair[1])))
                {
                    if ($old.LastWriteTimeUtc -lt $cutoff -and -not (Test-DLReparsePoint -Item $old)) { $old.Delete() }
                }
            }
        }
    }
    catch
    {
        Write-Warning ('DeadLoad report not saved: {0}' -f $_.Exception.Message)
    }
}

function Test-DLIntegrity
{
    <#
        .SYNOPSIS
            SR-7 / D14: when the module manifest is signed, every data file must carry a
            signature from the same certificate and an intact hash. Returns $null when the
            check passes (or the build is unsigned), else the reason.
    #>
    param
    (
        [Parameter(Mandatory)] [string]$ModuleRoot
    )

    $manifest = Get-AuthenticodeSignature -FilePath (Join-Path $ModuleRoot 'DeadLoad.psd1')
    if ($manifest.Status -eq 'NotSigned' -or -not $manifest.SignerCertificate) { return $null }
    if ($manifest.Status -eq 'HashMismatch') { return 'module manifest hash mismatch' }

    foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $ModuleRoot 'Data') -Filter '*.psd1'))
    {
        $signature = Get-AuthenticodeSignature -FilePath $file.FullName
        if (-not $signature.SignerCertificate) { return ('{0} is not signed' -f $file.Name) }
        if ($signature.Status -eq 'HashMismatch') { return ('{0} was modified after signing' -f $file.Name) }
        if ($signature.SignerCertificate.Thumbprint -ne $manifest.SignerCertificate.Thumbprint) { return ('{0} has a different signer' -f $file.Name) }
        # Same signer, intact hash: accept the same trust status as the manifest itself.
        if ($signature.Status -ne 'Valid' -and $signature.Status -ne $manifest.Status) { return ('{0} signature status {1}' -f $file.Name, $signature.Status) }
    }
    return $null
}
