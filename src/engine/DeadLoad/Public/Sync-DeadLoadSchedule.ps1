function Sync-DeadLoadSchedule
{
    <#
        .SYNOPSIS
            Creates, updates or removes the DeadLoad scheduled tasks (\DeadLoad\Maintenance,
            PressureCheck, OnDemand) from the effective schedule settings (D15).

        .DESCRIPTION
            Without a switch it re-applies the Maintenance and PressureCheck triggers when the
            schedule policy changed (a fingerprint in each task's description avoids rewriting
            unchanged tasks). -Register creates or replaces all three tasks (installer).
            -Remove deletes them and the task folder (uninstaller). Requires administrator or
            SYSTEM rights for any change.

        .OUTPUTS
            One row per task: Name, Action (Registered, Updated, Unchanged, Removed, Absent,
            WhatIf).

        .EXAMPLE
            Sync-DeadLoadSchedule -Register -InstallPath 'C:\Program Files\DeadLoad' -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium', DefaultParameterSetName = 'Sync')]
    param
    (
        [Parameter(ParameterSetName = 'Register')] [switch]$Register,
        [Parameter(ParameterSetName = 'Remove')] [switch]$Remove,
        [Parameter(ParameterSetName = 'Register')] [Parameter(ParameterSetName = 'Sync')] [string]$InstallPath
    )

    $names = @('Maintenance', 'PressureCheck', 'OnDemand')

    if ($Remove)
    {
        $service = Get-DLTaskService
        $folder = Get-DLTaskFolder -Service $service
        foreach ($name in $names)
        {
            $action = 'Absent'
            if ($folder)
            {
                $task = $null
                try { $task = $folder.GetTask($name) } catch { $task = $null }
                if ($task)
                {
                    $action = 'WhatIf'
                    if ($PSCmdlet.ShouldProcess(('{0}\{1}' -f $script:DLTaskFolder, $name), 'Delete scheduled task'))
                    {
                        $folder.DeleteTask($name, 0)
                        $action = 'Removed'
                    }
                }
            }
            [pscustomobject]@{ Name = $name; Action = $action }
        }
        if ($folder -and $PSCmdlet.ShouldProcess($script:DLTaskFolder, 'Delete task folder'))
        {
            try { $service.GetFolder('\').DeleteFolder($script:DLTaskFolder.TrimStart('\'), 0) } catch { Write-Verbose ('Task folder kept: {0}' -f $_.Exception.Message) }
        }
        return
    }

    if (-not $InstallPath) { $InstallPath = Get-DLInstallPath }
    $config = Get-DLConfiguration
    $fingerprint = Get-DLScheduleFingerprint -Schedule $config.Schedule -InstallPath $InstallPath
    $targets = @('Maintenance', 'PressureCheck')
    if ($Register) { $targets = $names }

    $service = $null
    $folder = $null
    if (-not $WhatIfPreference)
    {
        $service = Get-DLTaskService
        $folder = Get-DLTaskFolder -Service $service -Create:([bool]$Register)
        if (-not $folder) { throw ('Task folder {0} does not exist; install DeadLoad or run with -Register.' -f $script:DLTaskFolder) }
    }

    foreach ($name in $targets)
    {
        $existing = $null
        if ($folder) { try { $existing = $folder.GetTask($name) } catch { $existing = $null } }
        if (-not $Register -and $existing -and ([string]$existing.Definition.RegistrationInfo.Description).Contains($fingerprint))
        {
            [pscustomobject]@{ Name = $name; Action = 'Unchanged' }
            continue
        }
        if (-not $Register -and -not $existing -and $folder)
        {
            # Sync only maintains tasks the installer created.
            [pscustomobject]@{ Name = $name; Action = 'Absent' }
            continue
        }

        $xml = New-DLTaskXml -Name $name -Schedule $config.Schedule -InstallPath $InstallPath -Fingerprint $fingerprint
        if (-not $PSCmdlet.ShouldProcess(('{0}\{1}' -f $script:DLTaskFolder, $name), 'Register scheduled task'))
        {
            [pscustomobject]@{ Name = $name; Action = 'WhatIf' }
            continue
        }

        $sddl = $null
        if ($name -eq 'OnDemand') { $sddl = $script:DLOnDemandSddl }
        # 6 = TASK_CREATE_OR_UPDATE; 5 = TASK_LOGON_SERVICE_ACCOUNT (SYSTEM).
        [void]$folder.RegisterTask($name, $xml, 6, 'SYSTEM', $null, 5, $sddl)
        $action = 'Registered'
        if ($existing) { $action = 'Updated' }
        [pscustomobject]@{ Name = $name; Action = $action }
    }
}
