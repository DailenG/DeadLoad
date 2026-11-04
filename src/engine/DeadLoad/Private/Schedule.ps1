$script:DLTaskFolder = '\DeadLoad'
# Authenticated Users may read and run OnDemand; only SYSTEM and Administrators may change it.
$script:DLOnDemandSddl = 'D:(A;;FA;;;SY)(A;;FA;;;BA)(A;;GRGX;;;AU)'

function ConvertTo-DLXmlText
{
    param ([string]$Text)
    return [System.Security.SecurityElement]::Escape($Text)
}

function New-DLTaskXml
{
    <#
        .SYNOPSIS
            Task Scheduler XML for one DeadLoad task, built from the effective schedule
            settings (ARCHITECTURE section 11). Pure: no system call, so it is unit-tested.
    #>
    [OutputType([string])]
    param
    (
        [Parameter(Mandatory)] [ValidateSet('Maintenance', 'PressureCheck', 'OnDemand')] [string]$Name,
        [Parameter(Mandatory)] [hashtable]$Schedule,
        [Parameter(Mandatory)] [string]$InstallPath,
        [string]$Fingerprint = ''
    )

    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $entry = Join-Path $InstallPath 'engine\Start-DeadLoad.ps1'
    $arguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Mode {1}' -f $entry, $Name
    $today = (Get-Date).Date.ToString('yyyy-MM-dd')

    $triggers = ''
    $limit = 'PT1H'
    switch ($Name)
    {
        'Maintenance'
        {
            $days = (([string]$Schedule.MaintenanceDays) -split ',' | ForEach-Object { '<{0} />' -f $_.Trim() }) -join ''
            $triggers = '<CalendarTrigger><StartBoundary>{0}T{1}:00</StartBoundary><Enabled>true</Enabled><ScheduleByWeek><DaysOfWeek>{2}</DaysOfWeek><WeeksInterval>1</WeeksInterval></ScheduleByWeek></CalendarTrigger>' -f $today, $Schedule.MaintenanceTime, $days
        }
        'PressureCheck'
        {
            $limit = 'PT30M'
            # System event 2013 is the low-disk warning; the daily trigger covers missed events.
            $query = '&lt;QueryList&gt;&lt;Query Id="0" Path="System"&gt;&lt;Select Path="System"&gt;*[System[(EventID=2013)]]&lt;/Select&gt;&lt;/Query&gt;&lt;/QueryList&gt;'
            $triggers = ('<CalendarTrigger><StartBoundary>{0}T{1}:00</StartBoundary><Enabled>true</Enabled><ScheduleByDay><DaysInterval>1</DaysInterval></ScheduleByDay></CalendarTrigger>' -f $today, $Schedule.PressureCheckTime) +
                ('<EventTrigger><Enabled>true</Enabled><Subscription>{0}</Subscription></EventTrigger>' -f $query)
        }
        'OnDemand' { $triggers = '' }
    }

    $battery = 'true'
    if ([int]$Schedule.AllowOnBattery -eq 1) { $battery = 'false' }
    $idle = 'false'
    if ($Name -eq 'Maintenance' -and [int]$Schedule.RunOnlyIfIdle -eq 1) { $idle = 'true' }
    $triggerBlock = '<Triggers />'
    if ($triggers) { $triggerBlock = '<Triggers>{0}</Triggers>' -f $triggers }

    return @"
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Author>DeadLoad</Author><Description>DeadLoad $Name run. $(ConvertTo-DLXmlText $Fingerprint)</Description><URI>$script:DLTaskFolder\$Name</URI></RegistrationInfo>
  $triggerBlock
  <Principals><Principal id="Author"><UserId>S-1-5-18</UserId><RunLevel>HighestAvailable</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>$battery</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>$battery</StopIfGoingOnBatteries>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfIdle>$idle</RunOnlyIfIdle>
    <IdleSettings><StopOnIdleEnd>false</StopOnIdleEnd><RestartOnIdle>false</RestartOnIdle></IdleSettings>
    <ExecutionTimeLimit>$limit</ExecutionTimeLimit>
    <Priority>7</Priority>
    <Enabled>true</Enabled>
  </Settings>
  <Actions Context="Author"><Exec><Command>$(ConvertTo-DLXmlText $powershell)</Command><Arguments>$(ConvertTo-DLXmlText $arguments)</Arguments></Exec></Actions>
</Task>
"@
}

function Get-DLScheduleFingerprint
{
    # A short hash of the inputs, stored in the task description so an unchanged schedule
    # is not re-registered on every run.
    param ([hashtable]$Schedule, [string]$InstallPath)

    $text = '{0}|{1}|{2}|{3}|{4}|{5}' -f $Schedule.MaintenanceDays, $Schedule.MaintenanceTime, $Schedule.PressureCheckTime, $Schedule.RunOnlyIfIdle, $Schedule.AllowOnBattery, $InstallPath
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $hash = [System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))) -replace '-', '' }
    finally { $sha.Dispose() }
    return 'schedule ' + $hash.Substring(0, 16).ToLowerInvariant()
}

function Get-DLTaskService
{
    # Task Scheduler COM: the only API that registers a task with a security descriptor.
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    return $service
}

function Get-DLTaskFolder
{
    param ($Service, [switch]$Create)

    try { return $Service.GetFolder($script:DLTaskFolder) }
    catch
    {
        if (-not $Create) { return $null }
        return $Service.GetFolder('\').CreateFolder($script:DLTaskFolder.TrimStart('\'), $null)
    }
}

function Get-DLInstallPath
{
    # Local registry first (written by the package), else two levels above the module.
    try
    {
        $value = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\DeadLoad' -Name 'InstallPath' -ErrorAction Stop).InstallPath
        if ($value) { return $value }
    }
    catch { Write-Verbose 'No InstallPath in HKLM\SOFTWARE\DeadLoad.' }
    return (Split-Path -Path (Split-Path -Path $script:DLModuleRoot -Parent) -Parent)
}
