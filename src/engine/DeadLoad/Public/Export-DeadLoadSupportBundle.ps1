function Export-DeadLoadSupportBundle
{
    <#
        .SYNOPSIS
            Zips the current user's recent Revit journals, worker logs, crash dumps, AutoCAD
            error logs and Autodesk crash reports for support. Returns the zip FileInfo.

        .DESCRIPTION
            Reads with sharing, so journals of a running Revit session are included. Reparse
            points are never followed. Only the current profile is read.

        .EXAMPLE
            Export-DeadLoadSupportBundle -Days 3
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Low')]
    [OutputType([System.IO.FileInfo])]
    param
    (
        [ValidateRange(1, 365)]
        [int]$Days = 7,

        [string]$Destination = [Environment]::GetFolderPath('Desktop')
    )

    $userProfile = Get-DLProfile -Current
    $tokens = Get-DLTokenMap -UserProfile $userProfile
    $cutoff = (Get-DLUtcNow).AddDays(-$Days)
    $sources = @(
        @{ Root = '{LocalAppData}\Autodesk\Revit\Autodesk Revit *\Journals'; Include = @('journal*.txt', '*worker*', '*.dmp', 'DUMP*.txt'); Recurse = $false }
        @{ Root = '{LocalAppData}\CrashDumps'; Include = @('acad*.dmp', 'acadstk*.dmp', 'Revit*.dmp'); Recurse = $false }
        @{ Root = '{Temp}'; Include = @('acad*.err', 'acadstk*.dmp'); Recurse = $false }
        @{ Root = '{LocalAppData}\Autodesk\CER'; Include = @('*'); Recurse = $true }
    )

    $files = New-Object 'System.Collections.Generic.List[object]'
    foreach ($source in $sources)
    {
        foreach ($root in @(Resolve-DLRoot -Template $source.Root -Tokens $tokens))
        {
            $tree = Get-DLTreeFile -Root (New-Object System.IO.DirectoryInfo $root.Path) -Recurse $source.Recurse
            foreach ($file in $tree.Files)
            {
                if ($file.LastWriteTimeUtc -lt $cutoff) { continue }
                if (-not (Test-DLProtectedName -Name $file.Name -Pattern $source.Include)) { continue }
                $relative = $file.FullName.Substring((ConvertTo-DLFullPath -Path $userProfile.Path).Length).TrimStart('\')
                $files.Add([pscustomobject]@{ Path = $file.FullName; Entry = $relative })
            }
        }
    }

    if (-not [System.IO.Directory]::Exists($Destination)) { throw ('Destination not found: {0}' -f $Destination) }
    $zipPath = Join-Path $Destination ('DeadLoad-support-{0}-{1}.zip' -f $env:COMPUTERNAME, (Get-Date).ToString('yyyyMMdd-HHmmss'))
    if (-not $PSCmdlet.ShouldProcess($zipPath, ('Create support bundle with {0} file(s)' -f $files.Count))) { return }

    $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
    try
    {
        foreach ($file in $files)
        {
            try
            {
                $entry = $zip.CreateEntry(($file.Entry -replace '\\', '/'), [System.IO.Compression.CompressionLevel]::Optimal)
                $source = [System.IO.File]::Open($file.Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
                try
                {
                    $target = $entry.Open()
                    try { $source.CopyTo($target) } finally { $target.Dispose() }
                }
                finally { $source.Dispose() }
            }
            catch
            {
                Write-Warning ('Not included: {0} ({1})' -f $file.Entry, $_.Exception.Message)
            }
        }
    }
    finally { $zip.Dispose() }

    Write-DLEvent -Id 4002 -Message ('Support bundle created with {0} file(s).' -f $files.Count)
    return (New-Object System.IO.FileInfo $zipPath)
}
