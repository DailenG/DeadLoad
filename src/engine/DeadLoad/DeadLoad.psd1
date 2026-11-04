@{
    RootModule           = 'DeadLoad.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = '6a1f0d63-5b77-4f2c-9a0e-3d7c2a41b9e5'
    Author               = 'Dailen Gunter'
    CompanyName          = 'DeadLoad'
    Copyright            = '(c) Dailen Gunter. GPL-3.0.'
    Description          = 'Manages disk space used by Autodesk Revit and AutoCAD on Windows workstations: retention for journals, caches, crash data and temp files, safe to run as SYSTEM.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')
    FunctionsToExport    = @('Invoke-DeadLoad', 'Get-DeadLoadConfiguration', 'Get-DeadLoadStatus', 'Export-DeadLoadSupportBundle', 'Sync-DeadLoadSchedule')
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()
    FileList             = @('DeadLoad.psm1', 'Data\Defaults.psd1', 'Data\Settings.psd1')
    PrivateData          = @{
        PSData = @{
            Tags       = @('Autodesk', 'Revit', 'AutoCAD', 'DiskSpace', 'Cleanup', 'Windows')
            LicenseUri = 'https://www.gnu.org/licenses/gpl-3.0.html'
        }
    }
}
