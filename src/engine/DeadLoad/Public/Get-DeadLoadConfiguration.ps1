function Get-DeadLoadConfiguration
{
    <#
        .SYNOPSIS
            The effective DeadLoad configuration (machine policy > local > shipped defaults).

        .DESCRIPTION
            Without -Trace: a hashtable of sections (General, Pressure, Schedule, Tray) and
            Categories (id -> Settings). With -Trace: one row per setting with Name, Value and
            Source (Policy, UserPolicy, Local, Default), plus rejected values with a reason.

        .EXAMPLE
            Get-DeadLoadConfiguration -Trace | Where-Object Source -ne 'Default'
    #>
    [CmdletBinding()]
    param
    (
        [switch]$Trace
    )

    $config = Get-DLConfiguration
    if ($Trace)
    {
        foreach ($row in $config.Trace) { $row }
        foreach ($row in $config.Rejected)
        {
            [pscustomobject][ordered]@{ Name = $row.Name; Value = $row.Value; Source = ('Rejected:{0}' -f $row.Source); Reason = $row.Reason }
        }
        return
    }

    $categories = [ordered]@{}
    foreach ($id in $config.Categories.Keys) { $categories[$id] = $config.Categories[$id].Settings }
    return [pscustomobject][ordered]@{
        General    = $config.General
        Pressure   = $config.Pressure
        Schedule   = $config.Schedule
        Tray       = $config.Tray
        Categories = $categories
    }
}

function Get-DeadLoadStatus
{
    <#
        .SYNOPSIS
            Free space, pressure state and the last run summary. Reads last-run.json; does
            not scan.
    #>
    [CmdletBinding()]
    param
    (
        [string]$DataRoot = (Join-Path $env:ProgramData 'DeadLoad')
    )

    $config = Get-DLConfiguration
    $volume = Get-DLVolume
    $threshold = Get-DLPressureThreshold -Pressure $config.Pressure -Volume $volume
    $last = $null
    $path = Join-Path $DataRoot 'last-run.json'
    if (Test-Path -LiteralPath $path)
    {
        try { $last = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { $last = $null }
    }
    return [pscustomobject][ordered]@{
        Drive       = $volume.Drive
        SizeBytes   = $volume.SizeBytes
        FreeBytes   = $volume.FreeBytes
        FloorBytes  = $threshold.FloorBytes
        TargetBytes = $threshold.TargetBytes
        Pressure    = ($volume.FreeBytes -lt $threshold.FloorBytes)
        LastRun     = $last
    }
}
