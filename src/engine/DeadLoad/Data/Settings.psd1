# DeadLoad settings catalog: every setting's registry location, type, range and display text.
# The config reader validates against it and build/New-DeadLoadAdmx.ps1 generates the ADMX/ADML
# from it, so the policy templates cannot drift from the engine (ARCHITECTURE section 5).
#
# Section  registry subkey under ...\DeadLoad ('' = the key itself); 'Category' settings repeat
#          under Categories\<id> for every built-in category.
# Type     Bool (DWORD 0/1), Int (DWORD, Min..Max), Enum (string from Values), String, Time
#          (HH:mm), Days (comma-separated day names).
# Scope    Machine (HKLM policy only) or Both (tray settings: machine or user policy).
@{
    SchemaVersion = 1

    Sections      = @(
        @{ Name = 'General'; SubKey = ''; Display = 'General' }
        @{ Name = 'Pressure'; SubKey = 'Pressure'; Display = 'Disk pressure' }
        @{ Name = 'Schedule'; SubKey = 'Schedule'; Display = 'Schedule' }
        @{ Name = 'Tray'; SubKey = 'Tray'; Display = 'Tray app' }
        @{ Name = 'Category'; SubKey = 'Categories\{Id}'; Display = 'Categories' }
    )

    Settings      = @(
        @{ Section = 'General'; Name = 'Enabled'; Type = 'Bool'; Scope = 'Machine'; Display = 'Enable the cleanup engine'; Explain = 'When disabled, every run ends at once with result Disabled and changes nothing.' }
        @{ Section = 'General'; Name = 'ReportOnly'; Type = 'Bool'; Scope = 'Machine'; Display = 'Report only (change nothing)'; Explain = 'Runs scan and plan every category and log what would be done, without deleting, compressing, copying or moving anything.' }
        @{ Section = 'General'; Name = 'TimeBudgetMinutes'; Type = 'Int'; Min = 1; Max = 600; Scope = 'Machine'; Display = 'Time budget per run (minutes)'; Explain = 'A run stops cleanly between items when this time is used; the result is Partial.' }
        @{ Section = 'General'; Name = 'MaxDeleteMBPerRun'; Type = 'Int'; Min = 0; Max = 10000000; Scope = 'Machine'; Display = 'Maximum megabytes acted on per run'; Explain = '0 means no limit.' }
        @{ Section = 'General'; Name = 'MaxItemsPerRun'; Type = 'Int'; Min = 0; Max = 10000000; Scope = 'Machine'; Display = 'Maximum items acted on per run'; Explain = '0 means no limit.' }
        @{ Section = 'General'; Name = 'UseLastAccess'; Type = 'Bool'; Scope = 'Machine'; Display = 'Use last access time as activity'; Explain = 'When enabled and NTFS records last access, a file read recently counts as active. Disable where scanners or backup inflate last access.' }
        @{ Section = 'General'; Name = 'LogRetentionDays'; Type = 'Int'; Min = 1; Max = 3650; Scope = 'Machine'; Display = 'Keep run logs (days)'; Explain = 'Run logs and run reports older than this are removed from the data folder.' }
        @{ Section = 'General'; Name = 'OnDemandMode'; Type = 'Enum'; Values = @('Maintenance', 'PressureCheck'); Scope = 'Machine'; Display = 'What a user-requested cleanup runs'; Explain = 'The OnDemand task, which users may start, runs this mode. It takes no input from the user.' }

        @{ Section = 'Pressure'; Name = 'FloorPercent'; Type = 'Int'; Min = 0; Max = 90; Scope = 'Machine'; Display = 'Pressure floor (percent free)'; Explain = 'Below the floor (the larger of the percent and GB values, in bytes) pressure tiers run until the target is reached.' }
        @{ Section = 'Pressure'; Name = 'FloorGB'; Type = 'Int'; Min = 0; Max = 100000; Scope = 'Machine'; Display = 'Pressure floor (GB free)'; Explain = 'See the floor percent setting.' }
        @{ Section = 'Pressure'; Name = 'TargetPercent'; Type = 'Int'; Min = 0; Max = 95; Scope = 'Machine'; Display = 'Pressure target (percent free)'; Explain = 'Pressure tiers stop as soon as free space reaches the larger of the percent and GB values.' }
        @{ Section = 'Pressure'; Name = 'TargetGB'; Type = 'Int'; Min = 0; Max = 100000; Scope = 'Machine'; Display = 'Pressure target (GB free)'; Explain = 'See the target percent setting.' }

        @{ Section = 'Schedule'; Name = 'MaintenanceDays'; Type = 'Days'; Scope = 'Machine'; Display = 'Maintenance days'; Explain = 'Comma-separated day names, for example Sunday or Monday,Thursday.' }
        @{ Section = 'Schedule'; Name = 'MaintenanceTime'; Type = 'Time'; Scope = 'Machine'; Display = 'Maintenance time (HH:mm)'; Explain = 'Local time. A missed run starts when the machine is next available.' }
        @{ Section = 'Schedule'; Name = 'PressureCheckTime'; Type = 'Time'; Scope = 'Machine'; Display = 'Daily pressure check time (HH:mm)'; Explain = 'The pressure check also runs on low disk events.' }
        @{ Section = 'Schedule'; Name = 'RunOnlyIfIdle'; Type = 'Bool'; Scope = 'Machine'; Display = 'Run maintenance only when idle'; Explain = 'Adds an idle condition to the Maintenance task.' }
        @{ Section = 'Schedule'; Name = 'AllowOnBattery'; Type = 'Bool'; Scope = 'Machine'; Display = 'Allow runs on battery'; Explain = 'Off: scheduled runs do not start on battery power.' }

        @{ Section = 'Tray'; Name = 'ShowTray'; Type = 'Bool'; Scope = 'Both'; Display = 'Show the tray app'; Explain = 'Off: the tray app exits at start.' }
        @{ Section = 'Tray'; Name = 'AllowCleanTemp'; Type = 'Bool'; Scope = 'Both'; Display = 'Allow users to clean their own files ("Clean my temp files" and the cleanup review)'; Explain = 'Users may delete their own eligible temp files ("Clean my temp files"), and analyze, review and clean their own profile''s Routine and Review categories in the DeadLoad window. Restricted and machine-wide categories are never offered there. Off: both are turned off.' }
        @{ Section = 'Tray'; Name = 'AllowRequestCleanup'; Type = 'Bool'; Scope = 'Both'; Display = 'Allow "Request a cleanup"'; Explain = 'Users may start the OnDemand task.' }
        @{ Section = 'Tray'; Name = 'AllowCollectLogs'; Type = 'Bool'; Scope = 'Both'; Display = 'Allow "Collect my logs for support"'; Explain = 'Users may zip their recent journals and error logs.' }
        @{ Section = 'Tray'; Name = 'LowDiskNotifications'; Type = 'Bool'; Scope = 'Both'; Display = 'Low disk notifications'; Explain = 'At most one notification every 4 hours.' }
        @{ Section = 'Tray'; Name = 'NotifyBelowGB'; Type = 'Int'; Min = 0; Max = 100000; Scope = 'Both'; Display = 'Notify below (GB free)'; Explain = 'The larger of the GB and percent values applies.' }
        @{ Section = 'Tray'; Name = 'NotifyBelowPercent'; Type = 'Int'; Min = 0; Max = 90; Scope = 'Both'; Display = 'Notify below (percent free)'; Explain = 'The larger of the GB and percent values applies.' }
        @{ Section = 'Tray'; Name = 'NotifyOnCompletion'; Type = 'Bool'; Scope = 'Both'; Display = 'Notify when a cleanup completes'; Explain = 'Shown when the last run report changes.' }
        @{ Section = 'Tray'; Name = 'SupportShare'; Type = 'String'; Scope = 'Both'; Display = 'Support share for collected logs'; Explain = 'UNC folder for "Collect my logs"; empty means the Desktop.' }
        @{ Section = 'Tray'; Name = 'CollectDays'; Type = 'Int'; Min = 1; Max = 365; Scope = 'Both'; Display = 'Days of logs to collect'; Explain = 'How far back "Collect my logs" reaches.' }
        @{ Section = 'Tray'; Name = 'CleanTempMinAgeDays'; Type = 'Int'; Min = 0; Max = 365; Scope = 'Both'; Display = 'Minimum age for "Clean my temp files" (days)'; Explain = 'Files newer than this are kept by "Clean my temp files" and by the cleanup review in the DeadLoad window.' }

        @{ Section = 'Category'; Name = 'Enabled'; Type = 'Bool'; Display = 'Enabled'; Explain = 'Whether the category is processed.' }
        @{ Section = 'Category'; Name = 'AgeDays'; Type = 'Int'; Min = 0; Max = 36500; Display = 'Age limit (days)'; Explain = 'Items whose activity is older are selected. 0 means not set.' }
        @{ Section = 'Category'; Name = 'AgeBasis'; Type = 'Enum'; Values = @('Created', 'Modified', 'Accessed', 'Newest'); Display = 'Age basis'; Explain = 'Which time stamp is activity. Accessed falls back to Modified when last access is not usable.' }
        @{ Section = 'Category'; Name = 'KeepNewest'; Type = 'Int'; Min = 0; Max = 1000000; Display = 'Keep newest (count)'; Explain = 'Items ranked beyond this count (newest first) are selected. 0 means not set.' }
        @{ Section = 'Category'; Name = 'MaxTotalMB'; Type = 'Int'; Min = 0; Max = 10000000; Display = 'Maximum total size (MB)'; Explain = 'Oldest items beyond this size are selected. 0 means not set.' }
        @{ Section = 'Category'; Name = 'MaxSharePercent'; Type = 'Int'; Min = 0; Max = 100; Display = 'Maximum share of free or disk space (percent)'; Explain = 'Oldest items beyond this share are selected. 0 means not set.' }
        @{ Section = 'Category'; Name = 'ShareBase'; Type = 'Enum'; Values = @('Free', 'Disk'); Display = 'Share base'; Explain = 'Whether the share limit is of free space or of disk size.' }
        @{ Section = 'Category'; Name = 'LimitScope'; Type = 'Enum'; Values = @('Group', 'User', 'Machine'); Display = 'Limit scope'; Explain = 'Count, size and share limits per group (user and version), per user, or per machine.' }
        @{ Section = 'Category'; Name = 'RoutineAction'; Type = 'Enum'; Values = @('None', 'Delete', 'Compress', 'Copy', 'Move'); Display = 'Routine action'; Explain = 'What happens to items a routine limit selects.' }
        @{ Section = 'Category'; Name = 'Destination'; Type = 'String'; Display = 'Copy or move destination'; Explain = 'Folder template for Copy and Move; tokens {Computer}, {User}, {Category}, {Version}.' }
        @{ Section = 'Category'; Name = 'ActivateBelowGB'; Type = 'Int'; Min = 0; Max = 100000; Display = 'Routine only below (GB free)'; Explain = 'Routine limits apply only while free space is below this. 0 means always.' }
        @{ Section = 'Category'; Name = 'ActivateBelowPercent'; Type = 'Int'; Min = 0; Max = 100; Display = 'Routine only below (percent free)'; Explain = 'Routine limits apply only while free space is below this. 0 means always.' }
        @{ Section = 'Category'; Name = 'MinAgeHours'; Type = 'Int'; Min = 0; Max = 87600; Display = 'Protect items newer than (hours)'; Explain = 'Never acted on, by any rule.' }
        @{ Section = 'Category'; Name = 'ProtectNewest'; Type = 'Int'; Min = 0; Max = 1000000; Display = 'Protect newest (count)'; Explain = 'The newest items of each group are never acted on, by any rule.' }
        @{ Section = 'Category'; Name = 'PressureEnabled'; Type = 'Bool'; Display = 'Use under disk pressure'; Explain = 'Whether the category gives up items below the pressure floor.' }
        @{ Section = 'Category'; Name = 'PressureTier'; Type = 'Int'; Min = 1; Max = 99; Display = 'Pressure tier'; Explain = 'Lower tiers give up items first.' }
        @{ Section = 'Category'; Name = 'PressureAction'; Type = 'Enum'; Values = @('Delete', 'Compress', 'Copy', 'Move'); Display = 'Pressure action'; Explain = 'What happens to items given up under pressure.' }
        @{ Section = 'Category'; Name = 'PressureAgeDays'; Type = 'Int'; Min = 0; Max = 36500; Display = 'Pressure minimum age (days)'; Explain = 'Only items older than this are given up under pressure.' }
        @{ Section = 'Category'; Name = 'PressureKeepNewest'; Type = 'Int'; Min = 0; Max = 1000000; Display = 'Pressure keeps newest (count)'; Explain = 'The newest items of each group are kept under pressure.' }
        @{ Section = 'Category'; Name = 'ShelfCapacity'; Type = 'Int'; Min = 0; Max = 100000; Display = 'Revit journal shelf capacity (files)'; Explain = 'revit.ini.journalshelf only: raise JournalShelfCapacity to at least this.'; Categories = @('revit.ini.journalshelf') }
        @{ Section = 'Category'; Name = 'ShelfLifeDays'; Type = 'Int'; Min = 0; Max = 100000; Display = 'Revit journal shelf life (days)'; Explain = 'revit.ini.journalshelf only: raise JournalShelfLife to at least this.'; Categories = @('revit.ini.journalshelf') }
    )
}
