<#
    .SYNOPSIS
        Phase 3 install acceptance (docs/OPERATIONS.md section 9) inside Windows Sandbox.

    .DESCRIPTION
        Runs as the sandbox's administrator at logon (Start-DeadLoadSandboxTest.ps1 writes the
        .wsb). It installs Chocolatey offline, seeds aged test files and legacy Get-FreeSpace
        leftovers, then installs, runs, tests as a standard user, tests AllSigned, upgrades with
        the tray running, applies package parameters, uninstalls and purges. Every check is one
        row in results.json; summary.txt counts them; DONE marks the end.

        It changes the machine it runs on in every way a real install does, plus a local test
        account and machine execution policy: it refuses to run anywhere but Windows Sandbox.

    .PARAMETER InputPath
        Read-only folder with the packages, chocolatey.nupkg and the standard-user script.

    .PARAMETER OutputPath
        Writable folder mapped to the host for the results.
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory)] [string]$InstallVersion,
    [Parameter(Mandatory)] [string]$UpgradeVersion,
    [string]$InputPath = 'C:\DeadLoadTest\in',
    [string]$OutputPath = 'C:\DeadLoadTest\out'
)

$ErrorActionPreference = 'Stop'
if ($env:USERNAME -ne 'WDAGUtilityAccount')
{
    throw 'This script installs software and changes machine policy: it runs only inside Windows Sandbox.'
}

New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
Start-Transcript -LiteralPath (Join-Path $OutputPath 'transcript.txt') -Force | Out-Null

$script:checks = New-Object 'System.Collections.Generic.List[object]'
$installDir = Join-Path $env:ProgramFiles 'DeadLoad'
$dataDir = Join-Path $env:ProgramData 'DeadLoad'
$choco = Join-Path $env:ProgramData 'chocolatey\bin\choco.exe'
$publicDir = 'C:\Users\Public\DeadLoadTest'

function Add-Check
{
    param ([string]$Step, [string]$Check, [bool]$Pass, [string]$Actual)
    $row = [pscustomobject]@{ Step = $Step; Check = $Check; Pass = $Pass; Actual = $Actual }
    $script:checks.Add($row)
    $mark = 'FAIL'
    if ($Pass) { $mark = 'pass' }
    Write-Host ('[{0}] {1}: {2} ({3})' -f $mark, $Step, $Check, $Actual)
}

function Invoke-Step
{
    param ([string]$Step, [scriptblock]$Body)
    Write-Host ('=== {0} ===' -f $Step)
    try { & $Body }
    catch { Add-Check -Step $Step -Check 'step completed without error' -Pass $false -Actual ('{0} at {1}' -f $_.Exception.Message, $_.InvocationInfo.PositionMessage) }
}

function Invoke-Choco
{
    param ([string]$Name, [string[]]$Arguments)
    $output = & $choco @Arguments 2>&1 | Out-String
    $exit = $LASTEXITCODE
    Set-Content -LiteralPath (Join-Path $OutputPath ('choco-{0}.log' -f $Name)) -Value $output -Encoding UTF8
    return [pscustomobject]@{ Exit = $exit; Output = $output }
}

function Set-AgedFile
{
    param ([string]$Path, [double]$AgeDays, [int]$Bytes = 4096)
    $parent = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [IO.File]::WriteAllBytes($Path, (New-Object byte[] $Bytes))
    $stamp = (Get-Date).AddDays(-$AgeDays)
    [IO.File]::SetCreationTime($Path, $stamp); [IO.File]::SetLastWriteTime($Path, $stamp); [IO.File]::SetLastAccessTime($Path, $stamp)
}

function Set-AgedFolder
{
    param ([string]$Path, [double]$AgeDays)
    $stamp = (Get-Date).AddDays(-$AgeDays)
    [IO.Directory]::SetCreationTime($Path, $stamp); [IO.Directory]::SetLastWriteTime($Path, $stamp); [IO.Directory]::SetLastAccessTime($Path, $stamp)
}

function Get-LastRun
{
    $path = Join-Path $dataDir 'last-run.json'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
}

function Wait-OnDemand
{
    # Waits for an OnDemand run that started at or after $Since to finish.
    param ([datetime]$Since, [int]$TimeoutSeconds = 900)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do
    {
        Start-Sleep -Seconds 5
        $info = Get-ScheduledTaskInfo -TaskPath '\DeadLoad\' -TaskName 'OnDemand'
        $state = (Get-ScheduledTask -TaskPath '\DeadLoad\' -TaskName 'OnDemand').State
        if ($info.LastRunTime -ge $Since.AddSeconds(-2) -and [string]$state -ne 'Running') { return $info }
    } while ((Get-Date) -lt $deadline)
    throw ('OnDemand did not finish within {0} s.' -f $TimeoutSeconds)
}

function Invoke-OnDemand
{
    param ([string]$Step)
    $since = Get-Date
    Start-ScheduledTask -TaskPath '\DeadLoad\' -TaskName 'OnDemand'
    $info = Wait-OnDemand -Since $since
    $last = Get-LastRun
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'DeadLoad'; StartTime = $since.AddSeconds(-2) } -ErrorAction SilentlyContinue)
    return [pscustomobject]@{ Since = $since; Info = $info; Last = $last; EventIds = @($events | ForEach-Object { $_.Id } | Sort-Object -Unique) }
}

function Get-InstalledSignatureFailures
{
    $extensions = @('.ps1', '.psm1', '.psd1', '.exe', '.dll')
    return @(Get-ChildItem -LiteralPath $installDir -Recurse -File |
        Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
        Where-Object { (Get-AuthenticodeSignature -FilePath $_.FullName).Status -ne 'Valid' } |
        ForEach-Object { $_.FullName.Substring($installDir.Length + 1) })
}

function Test-InstalledState
{
    param ([string]$Step, [string]$Version, [bool]$ExpectRunValue = $true, [bool]$TrayRunning = $false)
    foreach ($folder in 'engine', 'tray', 'policy')
    {
        Add-Check -Step $Step -Check ('{0} folder installed' -f $folder) -Pass (Test-Path -LiteralPath (Join-Path $installDir $folder)) -Actual $folder
    }
    # A tray running from the old folder keeps tray.old-<id> until the next install.
    $siblings = @(Get-ChildItem -LiteralPath $installDir -Directory | Where-Object { $_.Name -match '\.(new|old)-' } |
        Where-Object { -not ($TrayRunning -and $_.Name -match '^tray\.old-') } | ForEach-Object { $_.Name })
    Add-Check -Step $Step -Check 'no .new-/.old- folder siblings (other than a running tray''s)' -Pass ($siblings.Count -eq 0) -Actual ($siblings -join ', ')

    $unsigned = Get-InstalledSignatureFailures
    Add-Check -Step $Step -Check 'every installed script and binary has a Valid signature' -Pass ($unsigned.Count -eq 0) -Actual ('{0} not Valid: {1}' -f $unsigned.Count, (($unsigned | Select-Object -First 5) -join ', '))

    $tasks = @(Get-ScheduledTask -TaskPath '\DeadLoad\' -ErrorAction SilentlyContinue)
    $names = @($tasks | ForEach-Object { $_.TaskName } | Sort-Object)
    $system = @($tasks | Where-Object { $_.Principal.UserId -eq 'SYSTEM' -or $_.Principal.UserId -eq 'S-1-5-18' })
    Add-Check -Step $Step -Check 'three tasks in \DeadLoad\ running as SYSTEM' -Pass (($names -join ',') -eq 'Maintenance,OnDemand,PressureCheck' -and $system.Count -eq 3) -Actual ('{0}; SYSTEM {1}' -f ($names -join ','), $system.Count)

    $acl = Get-Acl -LiteralPath $dataDir
    $rules = @($acl.Access | ForEach-Object {
            '{0}={1}{2}' -f $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value, $_.FileSystemRights, $(if ($_.IsInherited) { '(inherited)' } else { '' })
        })
    $sids = @($acl.Access | ForEach-Object { $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } | Sort-Object -Unique)
    $usersWrite = @($acl.Access | Where-Object {
            $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value -eq 'S-1-5-32-545' -and
            ($_.FileSystemRights -band [Security.AccessControl.FileSystemRights]::Write) -ne 0
        })
    $aclOk = $acl.AreAccessRulesProtected -and (($sids -join ',') -eq 'S-1-5-18,S-1-5-32-544,S-1-5-32-545') -and $usersWrite.Count -eq 0
    Add-Check -Step $Step -Check 'ProgramData\DeadLoad ACL protected: SYSTEM, Administrators full, Users read' -Pass $aclOk -Actual ('protected {0}; owner {1}; {2}' -f $acl.AreAccessRulesProtected, $acl.Owner, ($rules -join '; '))

    $source = [Diagnostics.EventLog]::SourceExists('DeadLoad')
    Add-Check -Step $Step -Check 'event source DeadLoad registered' -Pass $source -Actual $source

    $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\DeadLoad' -ErrorAction SilentlyContinue
    $keyVersion = $null; $keyPath = $null
    if ($key) { $keyVersion = $key.Version; $keyPath = $key.InstallPath }
    Add-Check -Step $Step -Check ('HKLM\SOFTWARE\DeadLoad Version {0} and InstallPath' -f $Version) -Pass ($keyVersion -eq $Version -and $keyPath -eq $installDir) -Actual ('Version {0}; InstallPath {1}' -f $keyVersion, $keyPath)

    $run = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).DeadLoadTray
    $expected = '"{0}"' -f (Join-Path $installDir 'tray\DeadLoadTray.exe')
    if ($ExpectRunValue) { Add-Check -Step $Step -Check 'tray Run value is the quoted exe path' -Pass ($run -eq $expected) -Actual ([string]$run) }
    else { Add-Check -Step $Step -Check 'tray Run value absent' -Pass ($null -eq $run) -Actual ([string]$run) }
}

# --------------------------------------------------------------------------------------------
$os = Get-CimInstance -ClassName Win32_OperatingSystem
$volume = Get-CimInstance -ClassName Win32_LogicalDisk -Filter "DeviceID='C:'"
Add-Check -Step 'Environment' -Check 'sandbox host' -Pass $true -Actual ('{0} build {1}; PowerShell {2}; 64-bit process {3}; C: {4:N1} GB free of {5:N1} GB' -f $os.Caption, $os.BuildNumber, $PSVersionTable.PSVersion, [Environment]::Is64BitProcess, ($volume.FreeSpace / 1GB), ($volume.Size / 1GB))

Invoke-Step -Step 'Chocolatey' -Body {
    $zip = Join-Path $env:TEMP 'chocolatey.zip'
    $unpacked = Join-Path $env:TEMP 'chocolatey-package'
    Copy-Item -LiteralPath (Join-Path $InputPath 'chocolatey.nupkg') -Destination $zip -Force
    Expand-Archive -LiteralPath $zip -DestinationPath $unpacked -Force
    $installer = Join-Path $unpacked 'tools\chocolateyInstall.ps1'
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $installer *> (Join-Path $OutputPath 'chocolatey-bootstrap.log')
    Add-Check -Step 'Chocolatey' -Check 'Chocolatey installed offline' -Pass (Test-Path -LiteralPath $choco) -Actual $choco
}

Invoke-Step -Step 'Seed' -Body {
    $temp = [IO.Path]::GetTempPath()
    for ($i = 1; $i -le 5; $i++) { Set-AgedFile -Path (Join-Path $temp ('dlseed-old-{0}.tmp' -f $i)) -AgeDays 30 }
    Set-AgedFile -Path (Join-Path $temp 'dlseed-young.tmp') -AgeDays 2
    $cer = Join-Path $env:LOCALAPPDATA 'Autodesk\CER'
    for ($i = 1; $i -le 8; $i++)
    {
        $folder = Join-Path $cer ('sig{0:00}' -f $i)
        Set-AgedFile -Path (Join-Path $folder 'report.log') -AgeDays (39 + $i)
        Set-AgedFolder -Path $folder -AgeDays (39 + $i)
    }
    $odis = Join-Path $env:LOCALAPPDATA 'Autodesk\ODIS'
    for ($i = 1; $i -le 8; $i++) { Set-AgedFile -Path (Join-Path $odis ('install-{0}.log' -f $i)) -AgeDays (99 + $i) }
    Set-AgedFile -Path (Join-Path $env:SystemRoot 'Temp\dlseed-machine-old.tmp') -AgeDays 30

    # Legacy Get-FreeSpace leftovers: a folder, a task that runs its script (removed) and a
    # FreeSpace-named task that does not (kept). The MSI itself is not available here.
    $legacy = Join-Path $env:ProgramFiles 'Get-FreeSpace'
    Set-AgedFile -Path (Join-Path $legacy 'Get-FreeSpace.ps1') -AgeDays 400
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-File "{0}"' -f (Join-Path $legacy 'Get-FreeSpace.ps1'))
    $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddYears(5)
    Register-ScheduledTask -TaskName 'Get-FreeSpace Cleanup' -TaskPath '\' -Action $action -Trigger $trigger -User 'SYSTEM' -Force | Out-Null
    $other = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c echo FreeSpace report'
    Register-ScheduledTask -TaskName 'FreeSpace Report Unrelated' -TaskPath '\' -Action $other -Trigger $trigger -User 'SYSTEM' -Force | Out-Null
    Add-Check -Step 'Seed' -Check 'aged files and legacy leftovers created' -Pass $true -Actual ('temp, CER 8, ODIS 8, Windows Temp 1, legacy folder and 2 tasks')
}

Invoke-Step -Step 'Install' -Body {
    $result = Invoke-Choco -Name 'install' -Arguments @('install', 'deadload', '--source', $InputPath, '--version', $InstallVersion, '-y', '--no-progress')
    Add-Check -Step 'Install' -Check ('choco install {0} exit 0, no restart' -f $InstallVersion) -Pass ($result.Exit -eq 0 -and $result.Output -notmatch '(?i)reboot is required|restart required') -Actual ('exit {0}' -f $result.Exit)
    Test-InstalledState -Step 'Install' -Version $InstallVersion
    Add-Check -Step 'Install' -Check 'legacy folder removed' -Pass (-not (Test-Path -LiteralPath (Join-Path $env:ProgramFiles 'Get-FreeSpace'))) -Actual ''
    $legacyTask = Get-ScheduledTask -TaskPath '\' -TaskName 'Get-FreeSpace Cleanup' -ErrorAction SilentlyContinue
    $otherTask = Get-ScheduledTask -TaskPath '\' -TaskName 'FreeSpace Report Unrelated' -ErrorAction SilentlyContinue
    Add-Check -Step 'Install' -Check 'legacy task removed, unrelated FreeSpace task kept' -Pass ($null -eq $legacyTask -and $null -ne $otherTask) -Actual ('legacy present {0}; unrelated present {1}' -f ($null -ne $legacyTask), ($null -ne $otherTask))
}

Invoke-Step -Step 'Run' -Body {
    $run = Invoke-OnDemand -Step 'Run'
    Add-Check -Step 'Run' -Check 'OnDemand task result 0' -Pass ($run.Info.LastTaskResult -eq 0) -Actual ('LastTaskResult {0}' -f $run.Info.LastTaskResult)
    Add-Check -Step 'Run' -Check 'events 1000 and 1001 written' -Pass (($run.EventIds -contains 1000) -and ($run.EventIds -contains 1001)) -Actual ($run.EventIds -join ',')
    $resultText = 'none'
    if ($run.Last) { $resultText = '{0} {1}; version {2}; mode {3}; freed {4}' -f $run.Last.Result, $run.Last.Reason, $run.Last.Version, $run.Last.Mode, $run.Last.Totals.FreedBytes }
    Add-Check -Step 'Run' -Check 'last-run.json Success' -Pass ($null -ne $run.Last -and $run.Last.Result -eq 'Success') -Actual $resultText
    $temp = [IO.Path]::GetTempPath()
    $oldLeft = @(1..5 | Where-Object { Test-Path -LiteralPath (Join-Path $temp ('dlseed-old-{0}.tmp' -f $_)) }).Count
    Add-Check -Step 'Run' -Check 'user temp: 30-day files removed, 2-day file kept' -Pass ($oldLeft -eq 0 -and (Test-Path -LiteralPath (Join-Path $temp 'dlseed-young.tmp'))) -Actual ('old left {0}' -f $oldLeft)
    $cerLeft = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Autodesk\CER') -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name } | Sort-Object)
    Add-Check -Step 'Run' -Check 'CER keeps the newest 5 of 8 old folders' -Pass (($cerLeft -join ',') -eq 'sig01,sig02,sig03,sig04,sig05') -Actual ($cerLeft -join ',')
    $odisLeft = @(Get-ChildItem -LiteralPath (Join-Path $env:LOCALAPPDATA 'Autodesk\ODIS') -File -ErrorAction SilentlyContinue).Count
    Add-Check -Step 'Run' -Check 'ODIS logs keep the newest 5 of 8 old logs' -Pass ($odisLeft -eq 5) -Actual ('{0} left' -f $odisLeft)
    Add-Check -Step 'Run' -Check 'Windows Temp 30-day file removed' -Pass (-not (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'Temp\dlseed-machine-old.tmp'))) -Actual ''
    $script:firstRunId = $run.Last.RunId
}

Invoke-Step -Step 'StandardUser' -Body {
    New-Item -ItemType Directory -Path $publicDir -Force | Out-Null
    & icacls.exe $publicDir /grant '*S-1-5-32-545:(OI)(CI)M' | Out-Null
    $script:userScript = Join-Path $publicDir 'Invoke-DeadLoadSandboxStandardUser.ps1'
    Copy-Item -LiteralPath (Join-Path $InputPath 'Invoke-DeadLoadSandboxStandardUser.ps1') -Destination $script:userScript -Force

    # A throwaway local account; the password lives only in this process and this sandbox.
    $alphabet = [char[]]'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
    $plain = (-join (1..20 | ForEach-Object { $alphabet | Get-Random })) + '#7a'
    $secure = ConvertTo-SecureString -String $plain -AsPlainText -Force
    $plain = $null
    New-LocalUser -Name 'dltest' -Password $secure -AccountNeverExpires -PasswordNeverExpires -Description 'DeadLoad sandbox test' | Out-Null
    Add-LocalGroupMember -SID 'S-1-5-32-545' -Member 'dltest'
    $script:userCredential = New-Object Management.Automation.PSCredential ('{0}\dltest' -f $env:COMPUTERNAME), $secure

    $since = Get-Date
    $out = Join-Path $publicDir 'standard-user.json'
    $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -OutFile "{1}"' -f $script:userScript, $out
    Start-Process -FilePath (Join-Path $PSHOME 'powershell.exe') -ArgumentList $arguments -Credential $script:userCredential -LoadUserProfile -WorkingDirectory $publicDir -Wait -WindowStyle Hidden
    if (-not (Test-Path -LiteralPath $out)) { throw 'The standard-user script wrote no results.' }
    # Assign first: on Windows PowerShell 5.1 ConvertFrom-Json emits a JSON array as ONE object,
    # so @(... | ConvertFrom-Json) is a one-element array holding every row.
    $rows = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json
    foreach ($row in $rows) { Add-Check -Step 'StandardUser' -Check $row.Check -Pass ([bool]$row.Pass) -Actual $row.Actual }
    Copy-Item -LiteralPath (Join-Path $publicDir 'tray-self-test.txt') -Destination $OutputPath -ErrorAction SilentlyContinue

    $info = Wait-OnDemand -Since $since
    $last = Get-LastRun
    Add-Check -Step 'StandardUser' -Check 'the run the standard user started completed as SYSTEM' -Pass ($info.LastTaskResult -eq 0 -and $last.RunId -ne $script:firstRunId -and $last.Result -eq 'Success') -Actual ('LastTaskResult {0}; RunId {1}; Result {2}' -f $info.LastTaskResult, $last.RunId, $last.Result)
}

Invoke-Step -Step 'AllSigned' -Body {
    $policyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\PowerShell'
    New-Item -Path $policyKey -Force | Out-Null
    New-ItemProperty -LiteralPath $policyKey -Name 'EnableScripts' -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty -LiteralPath $policyKey -Name 'ExecutionPolicy' -Value 'AllSigned' -PropertyType String -Force | Out-Null
    try
    {
        $before = (Get-LastRun).RunId
        $untrusted = Invoke-OnDemand -Step 'AllSigned'
        $after = (Get-LastRun).RunId
        Add-Check -Step 'AllSigned' -Check 'publisher not trusted: the run is refused (documented prerequisite)' -Pass ($after -eq $before -and $untrusted.Info.LastTaskResult -ne 0) -Actual ('LastTaskResult {0}; new run {1}' -f $untrusted.Info.LastTaskResult, ($after -ne $before))

        $certificate = (Get-AuthenticodeSignature -FilePath (Join-Path $installDir 'engine\Start-DeadLoad.ps1')).SignerCertificate
        $store = New-Object Security.Cryptography.X509Certificates.X509Store 'TrustedPublisher', 'LocalMachine'
        $store.Open('ReadWrite'); $store.Add($certificate); $store.Close()
        $trusted = Invoke-OnDemand -Step 'AllSigned'
        Add-Check -Step 'AllSigned' -Check 'publisher trusted: OnDemand succeeds under machine policy AllSigned' -Pass ($trusted.Info.LastTaskResult -eq 0 -and $trusted.Last.RunId -ne $before -and $trusted.Last.Result -eq 'Success') -Actual ('LastTaskResult {0}; Result {1}' -f $trusted.Info.LastTaskResult, $trusted.Last.Result)
    }
    finally
    {
        Remove-Item -LiteralPath $policyKey -Recurse -Force
    }
}

Invoke-Step -Step 'Upgrade' -Body {
    $tray = Join-Path $installDir 'tray\DeadLoadTray.exe'
    Start-Process -FilePath $tray -Credential $script:userCredential -LoadUserProfile -WorkingDirectory $publicDir
    Start-Sleep -Seconds 8
    $before = @(Get-Process -Name 'DeadLoadTray' -ErrorAction SilentlyContinue)
    Add-Check -Step 'Upgrade' -Check 'tray running as the standard user before upgrade' -Pass ($before.Count -eq 1) -Actual ('{0} process(es)' -f $before.Count)
    $runsBefore = @(Get-ChildItem -LiteralPath (Join-Path $dataDir 'runs') -File).Count

    $result = Invoke-Choco -Name 'upgrade' -Arguments @('upgrade', 'deadload', '--source', $InputPath, '--version', $UpgradeVersion, '-y', '--no-progress')
    Add-Check -Step 'Upgrade' -Check ('choco upgrade to {0} exit 0' -f $UpgradeVersion) -Pass ($result.Exit -eq 0) -Actual ('exit {0}' -f $result.Exit)
    $modes = ($result.Output -split "`r?`n" | Where-Object { $_ -match '^(engine|tray|policy): ' }) -join '; '
    $after = @(Get-Process -Name 'DeadLoadTray' -ErrorAction SilentlyContinue)
    $samePid = $before.Count -eq 1 -and $after.Count -eq 1 -and $before[0].Id -eq $after[0].Id
    Add-Check -Step 'Upgrade' -Check 'running tray not stopped' -Pass $samePid -Actual ('before {0}; after {1}' -f (($before | ForEach-Object { $_.Id }) -join ','), (($after | ForEach-Object { $_.Id }) -join ','))
    $aside = @(Get-ChildItem -LiteralPath (Join-Path $installDir 'tray') -File | Where-Object { $_.Name -match '\.dlold-' })
    $oldFolders = @(Get-ChildItem -LiteralPath $installDir -Directory | Where-Object { $_.Name -match '^tray\.old-' })
    $swapped = ($modes -match 'tray: Replaced' -and $oldFolders.Count -eq 1) -or ($modes -match 'tray: InPlace' -and $aside.Count -ge 1)
    Add-Check -Step 'Upgrade' -Check 'new tray installed beside the running one (old folder or *.dlold-* kept)' -Pass $swapped -Actual ('{0}; tray.old folders {1}; dlold files {2}' -f $modes, $oldFolders.Count, $aside.Count)
    Test-InstalledState -Step 'Upgrade' -Version $UpgradeVersion -TrayRunning $true
    $runsAfter = @(Get-ChildItem -LiteralPath (Join-Path $dataDir 'runs') -File).Count
    Add-Check -Step 'Upgrade' -Check 'reports kept across upgrade' -Pass ($runsAfter -ge $runsBefore -and $runsBefore -gt 0) -Actual ('runs before {0}, after {1}' -f $runsBefore, $runsAfter)
    $run = Invoke-OnDemand -Step 'Upgrade'
    Add-Check -Step 'Upgrade' -Check ('OnDemand after upgrade reports version {0}' -f $UpgradeVersion) -Pass ($run.Info.LastTaskResult -eq 0 -and $run.Last.Version -eq $UpgradeVersion) -Actual ('LastTaskResult {0}; Version {1}; Result {2}' -f $run.Info.LastTaskResult, $run.Last.Version, $run.Last.Result)
    foreach ($process in $after) { Stop-Process -Id $process.Id -Force }
}

Invoke-Step -Step 'Parameters' -Body {
    $result = Invoke-Choco -Name 'parameters' -Arguments @('upgrade', 'deadload', '--source', $InputPath, '--version', $UpgradeVersion, '-y', '--force', '--no-progress', '--params', "'/NoTray /ReportOnly /InstallAdmxLocally'")
    Add-Check -Step 'Parameters' -Check 'choco upgrade --force with /NoTray /ReportOnly /InstallAdmxLocally exit 0' -Pass ($result.Exit -eq 0) -Actual ('exit {0}' -f $result.Exit)
    Test-InstalledState -Step 'Parameters' -Version $UpgradeVersion -ExpectRunValue $false
    $aside = @(Get-ChildItem -LiteralPath (Join-Path $installDir 'tray') -File | Where-Object { $_.Name -match '\.dlold-' })
    $oldFolders = @(Get-ChildItem -LiteralPath $installDir -Directory | Where-Object { $_.Name -match '\.old-' })
    Add-Check -Step 'Parameters' -Check 'leftovers of the running-tray upgrade removed by the next install' -Pass ($aside.Count -eq 0 -and $oldFolders.Count -eq 0) -Actual ('dlold files {0}; old folders {1}' -f $aside.Count, $oldFolders.Count)
    $reportOnly = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\DeadLoad' -ErrorAction SilentlyContinue).ReportOnly
    Add-Check -Step 'Parameters' -Check 'ReportOnly = 1' -Pass ($reportOnly -eq 1) -Actual ([string]$reportOnly)
    $definitions = Join-Path $env:SystemRoot 'PolicyDefinitions'
    $admx = (Test-Path -LiteralPath (Join-Path $definitions 'DeadLoad.admx')) -and (Test-Path -LiteralPath (Join-Path $definitions 'en-US\DeadLoad.adml'))
    Add-Check -Step 'Parameters' -Check 'templates in PolicyDefinitions' -Pass $admx -Actual $admx

    Set-AgedFile -Path (Join-Path $env:SystemRoot 'Temp\dlseed-reportonly.tmp') -AgeDays 30
    $run = Invoke-OnDemand -Step 'Parameters'
    $kept = Test-Path -LiteralPath (Join-Path $env:SystemRoot 'Temp\dlseed-reportonly.tmp')
    Add-Check -Step 'Parameters' -Check 'report-only run deletes nothing' -Pass ($run.Last.ReportOnly -eq $true -and $kept) -Actual ('summary ReportOnly {0}; seeded file kept {1}; Result {2}' -f $run.Last.ReportOnly, $kept, $run.Last.Result)

    $records = Join-Path $OutputPath 'programdata'
    New-Item -ItemType Directory -Path $records -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $dataDir 'last-run.json') -Destination $records
    Copy-Item -Path (Join-Path $dataDir 'logs\*') -Destination $records -ErrorAction SilentlyContinue
}

Invoke-Step -Step 'Uninstall' -Body {
    New-Item -Path 'HKLM:\SOFTWARE\Policies\DeadLoad' -Force | Out-Null
    New-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\DeadLoad' -Name 'SandboxMarker' -Value 1 -PropertyType DWord -Force | Out-Null
    $result = Invoke-Choco -Name 'uninstall' -Arguments @('uninstall', 'deadload', '-y', '--no-progress')
    Add-Check -Step 'Uninstall' -Check 'choco uninstall exit 0' -Pass ($result.Exit -eq 0) -Actual ('exit {0}' -f $result.Exit)
    $tasks = @(Get-ScheduledTask -TaskPath '\DeadLoad\' -ErrorAction SilentlyContinue)
    $service = New-Object -ComObject 'Schedule.Service'; $service.Connect()
    $folderGone = $false
    try { [void]$service.GetFolder('\DeadLoad') } catch { $folderGone = $true }
    Add-Check -Step 'Uninstall' -Check 'tasks and task folder removed' -Pass ($tasks.Count -eq 0 -and $folderGone) -Actual ('tasks {0}; folder gone {1}' -f $tasks.Count, $folderGone)
    $run = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).DeadLoadTray
    Add-Check -Step 'Uninstall' -Check 'Run value absent' -Pass ($null -eq $run) -Actual ([string]$run)
    $source = [Diagnostics.EventLog]::SourceExists('DeadLoad')
    Add-Check -Step 'Uninstall' -Check 'event source removed' -Pass (-not $source) -Actual $source
    Add-Check -Step 'Uninstall' -Check 'Program Files\DeadLoad removed' -Pass (-not (Test-Path -LiteralPath $installDir)) -Actual ''
    Add-Check -Step 'Uninstall' -Check 'ProgramData\DeadLoad kept' -Pass (Test-Path -LiteralPath (Join-Path $dataDir 'last-run.json')) -Actual ''
    Add-Check -Step 'Uninstall' -Check 'policy key untouched' -Pass ((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Policies\DeadLoad' -ErrorAction SilentlyContinue).SandboxMarker -eq 1) -Actual ''
    $key = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\DeadLoad' -ErrorAction SilentlyContinue
    $leftover = 'key absent'
    if ($key) { $leftover = 'Version {0}; InstallPath {1}; ReportOnly {2}' -f $key.Version, $key.InstallPath, $key.ReportOnly }
    Add-Check -Step 'Uninstall' -Check 'Version and InstallPath removed (ReportOnly may stay)' -Pass ($null -eq $key -or ($null -eq $key.Version -and $null -eq $key.InstallPath)) -Actual $leftover
}

Invoke-Step -Step 'Purge' -Body {
    $install = Invoke-Choco -Name 'reinstall' -Arguments @('install', 'deadload', '--source', $InputPath, '--version', $UpgradeVersion, '-y', '--no-progress')
    Add-Check -Step 'Purge' -Check 'reinstall exit 0' -Pass ($install.Exit -eq 0) -Actual ('exit {0}' -f $install.Exit)
    $result = Invoke-Choco -Name 'purge' -Arguments @('uninstall', 'deadload', '-y', '--no-progress', '--params', "'/PurgeData'")
    Add-Check -Step 'Purge' -Check 'uninstall /PurgeData exit 0' -Pass ($result.Exit -eq 0) -Actual ('exit {0}' -f $result.Exit)
    Add-Check -Step 'Purge' -Check 'ProgramData\DeadLoad removed' -Pass (-not (Test-Path -LiteralPath $dataDir)) -Actual ''
    Add-Check -Step 'Purge' -Check 'HKLM\SOFTWARE\DeadLoad removed' -Pass (-not (Test-Path -LiteralPath 'HKLM:\SOFTWARE\DeadLoad')) -Actual ''
    Add-Check -Step 'Purge' -Check 'policy key still untouched' -Pass (Test-Path -LiteralPath 'HKLM:\SOFTWARE\Policies\DeadLoad') -Actual ''
}

Copy-Item -LiteralPath (Join-Path $env:ProgramData 'chocolatey\logs\chocolatey.log') -Destination $OutputPath -ErrorAction SilentlyContinue
$script:checks | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $OutputPath 'results.json') -Encoding UTF8
$failed = @($script:checks | Where-Object { -not $_.Pass })
$summary = @('DeadLoad sandbox acceptance: {0} checks, {1} passed, {2} failed' -f $script:checks.Count, ($script:checks.Count - $failed.Count), $failed.Count)
foreach ($row in $failed) { $summary += ('FAIL {0}: {1} ({2})' -f $row.Step, $row.Check, $row.Actual) }
Set-Content -LiteralPath (Join-Path $OutputPath 'summary.txt') -Value $summary -Encoding UTF8
Stop-Transcript | Out-Null
Set-Content -LiteralPath (Join-Path $OutputPath 'DONE') -Value (Get-Date).ToString('o') -Encoding ASCII
