<#
    .SYNOPSIS
        Standard-user half of the sandbox acceptance run (docs/OPERATIONS.md section 9, step 5).
        Started by Invoke-DeadLoadSandboxAcceptance.ps1 as a non-admin local account; writes its
        checks as JSON to -OutFile. Never run it outside a disposable machine.
#>
[CmdletBinding()]
param
(
    [Parameter(Mandatory)] [string]$OutFile,
    [string]$InstallPath = (Join-Path $env:ProgramFiles 'DeadLoad')
)

$ErrorActionPreference = 'Stop'
$checks = New-Object 'System.Collections.Generic.List[object]'

function Add-Check
{
    param ([string]$Check, [bool]$Pass, [string]$Actual)
    $checks.Add([pscustomobject]@{ Step = 'StandardUser'; Check = $Check; Pass = $Pass; Actual = $Actual })
}

function Invoke-Safely
{
    param ([string]$Check, [scriptblock]$Body)
    try { & $Body }
    catch { Add-Check -Check $Check -Pass $false -Actual ('error: {0}' -f $_.Exception.Message) }
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Check -Check 'runs without admin rights' -Pass (-not $isAdmin) -Actual ('{0}, admin {1}' -f [Security.Principal.WindowsIdentity]::GetCurrent().Name, $isAdmin)

$powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$userAction = Join-Path $InstallPath 'engine\Invoke-DeadLoadUserAction.ps1'

Invoke-Safely -Check 'tray CleanTemp' -Body {
    $old = @()
    for ($i = 1; $i -le 3; $i++)
    {
        $path = Join-Path $env:TEMP ('dlseed-user-old-{0}.tmp' -f $i)
        [IO.File]::WriteAllBytes($path, (New-Object byte[] 4096))
        $stamp = (Get-Date).AddDays(-30)
        [IO.File]::SetCreationTime($path, $stamp); [IO.File]::SetLastWriteTime($path, $stamp); [IO.File]::SetLastAccessTime($path, $stamp)
        $old += $path
    }
    $young = Join-Path $env:TEMP 'dlseed-user-young.tmp'
    [IO.File]::WriteAllBytes($young, (New-Object byte[] 4096))
    $stamp = (Get-Date).AddHours(-2)
    [IO.File]::SetCreationTime($young, $stamp); [IO.File]::SetLastWriteTime($young, $stamp); [IO.File]::SetLastAccessTime($young, $stamp)

    $stdout = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $userAction -Action CleanTemp
    $exit = $LASTEXITCODE
    $result = ($stdout | Select-Object -Last 1) | ConvertFrom-Json
    $remaining = @($old | Where-Object { Test-Path -LiteralPath $_ }).Count
    Add-Check -Check 'CleanTemp result Success' -Pass ($exit -eq 0 -and $result.Result -eq 'Success') -Actual ('exit {0}; {1}' -f $exit, ($stdout -join ' '))
    Add-Check -Check 'CleanTemp removed the 30-day files, kept the 2-hour file' -Pass ($remaining -eq 0 -and (Test-Path -LiteralPath $young)) -Actual ('old left {0}, young kept {1}' -f $remaining, (Test-Path -LiteralPath $young))
    $userReport = @(Get-ChildItem -LiteralPath $env:LOCALAPPDATA -Filter 'last-user-action.json' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
    $where = 'none found under LocalAppData'
    if ($userReport.Count -gt 0) { $where = $userReport[0].FullName }
    Add-Check -Check 'user run reported to its own file' -Pass ($userReport.Count -gt 0) -Actual $where
}

Invoke-Safely -Check 'tray CollectLogs' -Body {
    $stdout = & $powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $userAction -Action CollectLogs
    $result = ($stdout | Select-Object -Last 1) | ConvertFrom-Json
    $exists = $false
    if ($result.Path) { $exists = Test-Path -LiteralPath $result.Path }
    Add-Check -Check 'CollectLogs wrote a bundle' -Pass ($result.Result -eq 'Success' -and $exists) -Actual ($stdout -join ' ')
}

Invoke-Safely -Check 'start OnDemand' -Body {
    $service = New-Object -ComObject 'Schedule.Service'
    $service.Connect()
    $task = $service.GetFolder('\DeadLoad').GetTask('OnDemand')
    [void]$task.Run($null)
    Add-Check -Check 'standard user can start \DeadLoad\OnDemand' -Pass $true -Actual 'Run accepted'
}

Invoke-Safely -Check 'disable OnDemand' -Body {
    # Merged inside cmd: with ErrorActionPreference Stop, Windows PowerShell 5.1 turns a native
    # command's stderr line into a terminating error, and access denied is the expected answer.
    $output = & cmd.exe /d /c 'schtasks.exe /Change /TN \DeadLoad\OnDemand /DISABLE 2>&1'
    $exit = $LASTEXITCODE
    Add-Check -Check 'standard user cannot disable OnDemand' -Pass ($exit -ne 0) -Actual ('exit {0}: {1}' -f $exit, (($output | Out-String).Trim()))
}

Invoke-Safely -Check 'read last-run.json' -Body {
    $path = Join-Path $env:ProgramData 'DeadLoad\last-run.json'
    $last = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    Add-Check -Check 'standard user can read last-run.json' -Pass ($null -ne $last.Result) -Actual ('Result {0}, RunId {1}' -f $last.Result, $last.RunId)
}

$probe = Join-Path $env:ProgramData 'DeadLoad\standard-user-write-probe.txt'
try
{
    [IO.File]::WriteAllText($probe, 'x')
    Add-Check -Check 'standard user cannot write to ProgramData\DeadLoad' -Pass $false -Actual 'write succeeded'
}
catch [System.UnauthorizedAccessException]
{
    Add-Check -Check 'standard user cannot write to ProgramData\DeadLoad' -Pass $true -Actual 'access denied'
}
catch
{
    Add-Check -Check 'standard user cannot write to ProgramData\DeadLoad' -Pass $false -Actual ('unexpected: {0}' -f $_.Exception.Message)
}

Invoke-Safely -Check 'tray self-test' -Body {
    $exe = Join-Path $InstallPath 'tray\DeadLoadTray.exe'
    $log = Join-Path (Split-Path -Parent $OutFile) 'tray-self-test.txt'
    $process = Start-Process -FilePath $exe -ArgumentList '--self-test' -Wait -PassThru -RedirectStandardOutput $log -WindowStyle Hidden
    $text = ''
    if (Test-Path -LiteralPath $log) { $text = (Get-Content -LiteralPath $log -Raw) }
    Add-Check -Check 'tray --self-test exits 0 as a standard user' -Pass ($process.ExitCode -eq 0) -Actual ('exit {0}; {1}' -f $process.ExitCode, ($text -replace '\s+', ' ').Trim())
}

$checks | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $OutFile -Encoding UTF8
