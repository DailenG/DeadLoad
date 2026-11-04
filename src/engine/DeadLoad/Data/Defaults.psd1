# DeadLoad shipped defaults (ARCHITECTURE section 7). Signed with the module; the engine refuses
# to run a signed module whose data files are unsigned, re-signed or modified (SR-7, D14).
# Category definitions (roots, unit, patterns) are fixed here; every value under Settings is a
# policy-tunable default (settings catalog in Settings.psd1).
@{
    SchemaVersion     = 1

    General           = @{
        Enabled           = 1
        ReportOnly        = 0
        TimeBudgetMinutes = 20
        MaxDeleteMBPerRun = 0
        MaxItemsPerRun    = 100000
        UseLastAccess     = 1
        LogRetentionDays  = 90
        OnDemandMode      = 'Maintenance'
    }

    # D10: the larger of each pair applies, in bytes.
    Pressure          = @{
        FloorPercent  = 5
        FloorGB       = 30
        TargetPercent = 8
        TargetGB      = 45
    }

    Schedule          = @{
        MaintenanceDays   = 'Sunday'
        MaintenanceTime   = '03:00'
        PressureCheckTime = '12:30'
        RunOnlyIfIdle     = 0
        AllowOnBattery    = 0
    }

    Tray              = @{
        ShowTray             = 1
        AllowCleanTemp       = 1
        AllowRequestCleanup  = 1
        AllowCollectLogs     = 1
        LowDiskNotifications = 1
        NotifyBelowGB        = 10
        NotifyBelowPercent   = 10
        NotifyOnCompletion   = 0
        SupportShare         = ''
        CollectDays          = 7
        CleanTempMinAgeDays  = 1
    }

    # User data types. Never acted on in any category except where ProtectedPatternsApply is
    # false (a cache of exactly those types).
    ProtectedPatterns = @('*.rvt', '*.rfa', '*.rte', '*.rft', '*.dwg', '*.dwt', '*.dws', '*.dxf', '*.bak', '*.nwd', '*.nwf', '*.nwc', '*.ifc', '*.pdf')

    # Never entered. Desktop Connector WorkspaceLocation overrides are added at run time.
    ProtectedPaths    = @('{UserProfile}\DC', '{UserProfile}\ACCDocs', '{UserProfile}\BIM 360', '{UserProfile}\Documents', '{UserProfile}\Desktop', '{UserProfile}\OneDrive*')

    # A profile whose owner runs one of these is skipped for guarded categories (SR-2). Desktop
    # Connector's tray runs for every signed-in user and is not listed (D21).
    GuardedProcesses  = @('Revit', 'RevitWorker', 'acad', 'AcCoreConsole', 'Roamer', 'dwgviewr')

    # Roots a policy custom target may use (FR-2).
    CustomTargetRoots = @('{LocalAppData}', '{Temp}', '{WindowsTemp}', '{SystemDrive}\Autodesk', '{ProgramData}\Autodesk')

    # Risk tiers (ARCHITECTURE D22): how the user's cleanup review offers a category. The text is
    # shown in the ADMX explain text and the review; one source for both.
    RiskTiers         = @{
        Routine    = 'Routine: offered and selected by default in the user''s cleanup review; files that programs recreate or no longer need.'
        Review     = 'Review: offered but not selected in the user''s cleanup review; removing them can cause reprocessing or a download.'
        Restricted = 'Restricted: never offered in the user''s cleanup review; only the scheduled runs act on it, as policy configures.'
    }

    # DisplayName and Description are the user-facing text of a category (review window, ADMX).
    Categories        = @(
        @{
            Id = 'revit.journals'; Risk = 'Restricted'
            DisplayName = 'Revit journals'
            Description = 'Session logs Revit writes every time it runs. Support uses them to diagnose problems, and Revit may save backup copies of models beside them.'
            Scope = 'User'; Unit = 'File'; Recurse = $false; Guarded = $true
            Roots = @('{LocalAppData}\Autodesk\Revit\Autodesk Revit *\Journals')
            ArchivePath = '{Root}\Archive\journals-{yyyy}-{MM}.zip'
            # D19: no protected-newest count for compression; pressure deletion keeps 20.
            Settings = @{ Enabled = 1; AgeDays = 3; AgeBasis = 'Modified'; RoutineAction = 'Compress'; MinAgeHours = 48; ProtectNewest = 0; PressureEnabled = 1; PressureTier = 5; PressureAction = 'Delete'; PressureAgeDays = 2; PressureKeepNewest = 20 }
        }
        @{
            Id = 'revit.journals.archive'; Risk = 'Restricted'
            DisplayName = 'Revit journal archives'
            Description = 'Monthly zip archives of compressed Revit journals, kept as support records.'
            Scope = 'User'; Unit = 'File'; Recurse = $false; Guarded = $true
            Roots = @('{LocalAppData}\Autodesk\Revit\Autodesk Revit *\Journals\Archive'); Include = @('*.zip')
            Settings = @{ Enabled = 1; AgeDays = 180; AgeBasis = 'Modified'; RoutineAction = 'Delete'; MinAgeHours = 0; ProtectNewest = 1; PressureEnabled = 1; PressureTier = 1; PressureAction = 'Delete'; PressureAgeDays = 30 }
        }
        @{
            Id = 'revit.webcache'; Risk = 'Review'
            DisplayName = 'Revit web cache'
            Description = 'Browser cache of the Revit sign-in, start and help pages. Revit rebuilds it, so pages may load slower the next time.'
            Scope = 'User'; Unit = 'File'; Recurse = $true; Guarded = $true
            Roots = @('{LocalAppData}\Autodesk\Revit\Autodesk Revit *\CefCache', '{LocalAppData}\Autodesk\Revit\Autodesk Revit *\WebBrowserControl')
            Settings = @{ Enabled = 1; AgeDays = 14; AgeBasis = 'Newest'; RoutineAction = 'Delete'; MinAgeHours = 24; PressureEnabled = 1; PressureTier = 2; PressureAction = 'Delete'; PressureAgeDays = 3 }
        }
        @{
            Id = 'revit.paccache'; Risk = 'Review'
            DisplayName = 'Revit content cache'
            Description = 'Content Revit downloaded and keeps locally (PacCache). Revit downloads it again when it is needed.'
            Scope = 'User'; Unit = 'File'; Recurse = $true; Guarded = $true
            Roots = @('{LocalAppData}\Autodesk\Revit\PacCache'); Exclude = @('*.json'); ExcludeDirectory = @('Logs')
            Settings = @{ Enabled = 1; RoutineAction = 'None'; MinAgeHours = 24; PressureEnabled = 1; PressureTier = 3; PressureAction = 'Delete'; PressureAgeDays = 7 }
        }
        @{
            Id = 'revit.collabcache'; Risk = 'Restricted'
            DisplayName = 'Revit collaboration cache'
            Description = 'Local copies of cloud workshared models. Removing it can lose changes that were saved but not yet synchronized.'
            Scope = 'User'; Unit = 'Folder'; Guarded = $true; ProtectedPatternsApply = $false
            Roots = @('{LocalAppData}\Autodesk\Revit\Autodesk Revit *\CollaborationCache\*')
            Settings = @{ Enabled = 0; RoutineAction = 'None'; MinAgeHours = 2160; PressureEnabled = 1; PressureTier = 6; PressureAction = 'Delete'; PressureAgeDays = 90 }
        }
        @{
            Id = 'revit.oldversions'; Risk = 'Restricted'
            DisplayName = 'Data of Revit versions no longer installed'
            Description = 'Folders of Revit versions that are not installed any more: journals, crash dumps and model backups.'
            Scope = 'User'; Unit = 'Root'; Guarded = $true; RootFilter = 'RevitYearNotInstalled'
            Roots = @('{LocalAppData}\Autodesk\Revit\Autodesk Revit *'); ExcludeDirectory = @('CollaborationCache')
            Settings = @{ Enabled = 0; AgeDays = 90; AgeBasis = 'Newest'; RoutineAction = 'Delete'; MinAgeHours = 720; PressureEnabled = 1; PressureTier = 2; PressureAction = 'Delete'; PressureAgeDays = 30 }
        }
        @{
            Id = 'revit.ini.journalshelf'; Risk = 'Restricted'
            DisplayName = 'Revit journal retention setting'
            Description = 'Raises how long Revit itself keeps journals (Revit.ini). A setting change, not a file cleanup.'
            Scope = 'User'; Kind = 'RevitIniShelf'; Guarded = $true
            Roots = @('{AppData}\Autodesk\Revit\Autodesk Revit *')
            # D18: raise the shelf life past the compress window; keep Revit's own count cap.
            Settings = @{ Enabled = 1; ShelfCapacity = 10; ShelfLifeDays = 14 }
        }
        @{
            Id = 'autocad.graphicscache'; Risk = 'Review'
            DisplayName = 'AutoCAD graphics cache'
            Description = 'Display cache AutoCAD builds for drawings. AutoCAD rebuilds it, so drawings may open slower the next time.'
            Scope = 'User'; Unit = 'File'; Recurse = $true; Guarded = $true
            Roots = @('{LocalAppData}\Autodesk\AutoCAD *\R*\*\GraphicsCache', '{LocalAppData}\Autodesk\C3D *\*\GraphicsCache')
            Settings = @{ Enabled = 0; AgeDays = 30; AgeBasis = 'Newest'; RoutineAction = 'Delete'; MinAgeHours = 24; PressureEnabled = 1; PressureTier = 2; PressureAction = 'Delete'; PressureAgeDays = 7 }
        }
        @{
            Id = 'autocad.recovery'; Risk = 'Restricted'
            DisplayName = 'AutoCAD automatic save files'
            Description = 'Automatic save files (*.sv$, *.ac$) that can recover a drawing after AutoCAD closes unexpectedly.'
            # D25: Restricted, so never in a user-started cleanup (no UserAction).
            Scope = 'User'; Unit = 'File'; Recurse = $false; Guarded = $true
            Roots = @('{Temp}'); Include = @('*.sv$', '*.ac$')
            Settings = @{ Enabled = 0; AgeDays = 30; AgeBasis = 'Modified'; RoutineAction = 'Delete'; MinAgeHours = 72; PressureEnabled = 1; PressureTier = 2; PressureAction = 'Delete'; PressureAgeDays = 7 }
        }
        @{
            Id = 'autocad.errorlogs'; Risk = 'Routine'
            DisplayName = 'AutoCAD error logs'
            Description = 'Error logs and crash dumps AutoCAD wrote after a problem.'
            Scope = 'User'; Unit = 'File'; Recurse = $false; Guarded = $false
            Roots = @('{Temp}', '{LocalAppData}\CrashDumps'); Include = @('acad*.err', 'acadstk*.dmp', 'acad*.dmp')
            Settings = @{ Enabled = 0; AgeDays = 30; AgeBasis = 'Modified'; RoutineAction = 'Delete'; MinAgeHours = 24; PressureEnabled = 1; PressureTier = 2; PressureAction = 'Delete'; PressureAgeDays = 7 }
        }
        @{
            # Items are the crash-signature folders; each holds its logs and dated reports.
            Id = 'autodesk.cer'; Risk = 'Routine'
            DisplayName = 'Autodesk crash reports'
            Description = 'Reports the Autodesk crash reporter kept after a program closed unexpectedly. The newest reports are kept.'
            Scope = 'User'; Unit = 'Folder'; Guarded = $false
            Roots = @('{LocalAppData}\Autodesk\CER')
            Settings = @{ Enabled = 1; AgeDays = 30; AgeBasis = 'Newest'; RoutineAction = 'Delete'; MinAgeHours = 24; ProtectNewest = 5; PressureEnabled = 1; PressureTier = 2; PressureAction = 'Delete'; PressureAgeDays = 7 }
        }
        @{
            # IHT (install history) is left to ODIS.
            Id = 'autodesk.installlogs'; Risk = 'Routine'
            DisplayName = 'Autodesk installer logs'
            Description = 'Logs written while Autodesk products were installed or updated. The newest logs are kept.'
            Scope = 'User'; Unit = 'File'; Recurse = $true; Guarded = $false
            Roots = @('{LocalAppData}\Autodesk\ODIS'); Include = @('*.log', '*.log.*'); Exclude = @('*.lock'); ExcludeDirectory = @('IHT')
            Settings = @{ Enabled = 1; AgeDays = 90; AgeBasis = 'Modified'; RoutineAction = 'Delete'; MinAgeHours = 24; ProtectNewest = 5; PressureEnabled = 1; PressureTier = 2; PressureAction = 'Delete'; PressureAgeDays = 30 }
        }
        @{
            Id = 'autodesk.installers'; Risk = 'Restricted'
            DisplayName = 'Autodesk installation files'
            Description = 'Installation files extracted to the Autodesk folder on the system drive. Updates, repairs and reinstalls may need them.'
            Scope = 'Machine'; Unit = 'Folder'; Guarded = $true; RootFilter = 'NotInstallSource'
            Roots = @('{SystemDrive}\Autodesk'); Exclude = @('Network License Manager')
            GuardProcessesAnyOwner = @('AdODIS*', 'AdskAccess*', 'Setup', 'Installer')
            Settings = @{ Enabled = 0; RoutineAction = 'None'; MinAgeHours = 2160; PressureEnabled = 1; PressureTier = 4; PressureAction = 'Delete'; PressureAgeDays = 90 }
        }
        @{
            # D20: a running Revit or AutoCAD session's own temp files stay while it runs.
            Id = 'user.temp'; Risk = 'Routine'
            DisplayName = 'Temporary files'
            Description = 'Files programs left in the temp folder. Files of a Revit or AutoCAD session that is still running are kept.'
            Scope = 'User'; Unit = 'File'; Recurse = $true; Guarded = $false; UserAction = $true
            GuardedPatterns = @('*revit*', '*acad*')
            Roots = @('{Temp}'); Exclude = @('*.sv$', '*.ac$', 'acad*.err', 'acadstk*.dmp', 'acad*.dmp')
            Settings = @{ Enabled = 1; AgeDays = 7; AgeBasis = 'Newest'; RoutineAction = 'Delete'; MinAgeHours = 24; PressureEnabled = 1; PressureTier = 2; PressureAction = 'Delete'; PressureAgeDays = 1 }
        }
        @{
            Id = 'windows.temp'; Risk = 'Routine'
            DisplayName = 'Windows temporary files'
            Description = 'Temporary files in the Windows folder, left by installers and system components.'
            Scope = 'Machine'; Unit = 'File'; Recurse = $true; Guarded = $false
            Roots = @('{WindowsTemp}')
            Settings = @{ Enabled = 1; AgeDays = 7; AgeBasis = 'Newest'; RoutineAction = 'Delete'; MinAgeHours = 24; PressureEnabled = 1; PressureTier = 2; PressureAction = 'Delete'; PressureAgeDays = 1 }
        }
    )

    # Every category setting not given in a category's Settings above takes this value.
    CategorySettingDefaults = @{
        Enabled = 0; AgeDays = 0; AgeBasis = 'Newest'; KeepNewest = 0; MaxTotalMB = 0; MaxSharePercent = 0
        ShareBase = 'Free'; LimitScope = 'Group'; RoutineAction = 'None'; Destination = ''
        ActivateBelowGB = 0; ActivateBelowPercent = 0; MinAgeHours = 24; ProtectNewest = 0
        PressureEnabled = 0; PressureTier = 9; PressureAction = 'Delete'; PressureAgeDays = 7; PressureKeepNewest = 0
        ShelfCapacity = 0; ShelfLifeDays = 0
    }
}
