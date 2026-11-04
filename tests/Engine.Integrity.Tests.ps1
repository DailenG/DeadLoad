#Requires -Version 5.1
# PLAN 1.22: a signed module whose Defaults.psd1 was modified after signing refuses to run
# (event 3003). Signs a copy of the module with a throwaway self-signed certificate in the
# current user's store and runs it in a child process.

BeforeAll {
    $script:RepoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $PSScriptRoot 'TestHelpers.psm1') -Force

    function script:Invoke-DLChildRun
    {
        param ([string]$ModulePath, [string]$WorkRoot)

        $script = Join-Path $WorkRoot ('child-{0}.ps1' -f [guid]::NewGuid().ToString('N'))
        $output = Join-Path $WorkRoot 'child-result.json'
        $text = @'
param ([string]$ModulePath, [string]$DataRoot, [string]$Output)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath -Force
$config = @{ General = @{ Enabled = 1 }; Pressure = @{ FloorPercent = 0; FloorGB = 0; TargetPercent = 0; TargetGB = 0 }; Definitions = @() }
$summary = Invoke-DeadLoad -Configuration $config -DataRoot $DataRoot -NoEventLog -WhatIf
[System.IO.File]::WriteAllText($Output, (@{ Result = $summary.Result; Reason = [string]$summary.Reason } | ConvertTo-Json))
'@
        [System.IO.File]::WriteAllText($script, $text)
        if (Test-Path -LiteralPath $output) { Remove-Item -LiteralPath $output }
        $exe = (Get-Process -Id $PID).Path
        & $exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script -ModulePath $ModulePath -DataRoot (Join-Path $WorkRoot 'data') -Output $output | Out-Null
        return (Get-Content -LiteralPath $output -Raw | ConvertFrom-Json)
    }
}

Describe '1.22 Integrity of a signed module' {

    BeforeAll {
        $script:sb = New-DLSandbox
        $script:cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject 'CN=DeadLoad Integrity Test' -CertStoreLocation 'Cert:\CurrentUser\My' -NotAfter (Get-Date).AddDays(1)
        $script:moduleCopy = Join-Path $script:sb.Root 'DeadLoad'
        Copy-Item -LiteralPath (Join-Path $script:RepoRoot 'src\engine\DeadLoad') -Destination $script:moduleCopy -Recurse
        foreach ($file in @(Get-ChildItem -LiteralPath $script:moduleCopy -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.psd1' }))
        {
            $signature = Set-AuthenticodeSignature -FilePath $file.FullName -Certificate $script:cert -HashAlgorithm SHA256
            if (-not $signature.SignerCertificate) { throw ('not signed: {0}' -f $file.FullName) }
        }
    }

    AfterAll {
        if ($script:cert) { Remove-Item -LiteralPath ('Cert:\CurrentUser\My\{0}' -f $script:cert.Thumbprint) -ErrorAction SilentlyContinue }
        Remove-DLSandbox -Sandbox $script:sb
    }

    It 'runs when every data file carries the module signer (control)' {
        $result = Invoke-DLChildRun -ModulePath (Join-Path $script:moduleCopy 'DeadLoad.psd1') -WorkRoot $script:sb.Root
        $result.Result | Should -Not -Be 'Failed'
    }

    It 'refuses to run when Defaults.psd1 was modified after signing' {
        $defaults = Join-Path $script:moduleCopy 'Data\Defaults.psd1'
        $text = [System.IO.File]::ReadAllText($defaults)
        [System.IO.File]::WriteAllText($defaults, $text.Replace('FloorGB       = 30', 'FloorGB       = 0'))

        $result = Invoke-DLChildRun -ModulePath (Join-Path $script:moduleCopy 'DeadLoad.psd1') -WorkRoot $script:sb.Root

        $result.Result | Should -Be 'Failed'
        $result.Reason | Should -Match '^Integrity: Defaults\.psd1 was modified after signing'
    }
}
