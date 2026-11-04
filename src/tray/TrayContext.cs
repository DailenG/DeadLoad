using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace DeadLoad.Tray
{
    /// <summary>
    /// The tray icon and its menu. Owns the poll timer: every poll re-reads policy (so a GPO
    /// change shows without a sign-out), refreshes the tooltip, and decides on notifications.
    /// </summary>
    internal sealed class TrayContext : ApplicationContext
    {
        private static readonly TimeSpan PollInterval = TimeSpan.FromMinutes(10);
        private static readonly TimeSpan LowDiskQuietPeriod = TimeSpan.FromHours(4);
        private const int BalloonMilliseconds = 10000;

        private readonly NotifyIcon icon;
        private readonly ContextMenuStrip menu;
        private readonly ToolStripMenuItem cleanTempItem;
        private readonly ToolStripMenuItem requestCleanupItem;
        private readonly ToolStripMenuItem collectLogsItem;
        private readonly ToolStripMenuItem journalsItem;
        private readonly ToolStripMenuItem reportItem;
        private readonly Timer timer;
        private readonly TrayState state;
        private TraySettings settings;
        private ReportForm reportForm;
        private bool cleanTempRunning;
        private bool collectLogsRunning;

        public TrayContext(TraySettings initialSettings)
        {
            settings = initialSettings;
            state = TrayState.Load(TrayPaths.TrayStateFile);

            menu = new ContextMenuStrip();
            cleanTempItem = new ToolStripMenuItem("Clean my temp files", null, OnCleanTemp);
            requestCleanupItem = new ToolStripMenuItem("Request a cleanup", null, OnRequestCleanup);
            collectLogsItem = new ToolStripMenuItem("Collect my logs for support", null, OnCollectLogs);
            journalsItem = new ToolStripMenuItem("Open my journals folder", null, OnOpenJournals);
            reportItem = new ToolStripMenuItem("View last report", null, OnViewReport);
            menu.Items.Add(cleanTempItem);
            menu.Items.Add(requestCleanupItem);
            menu.Items.Add(collectLogsItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(journalsItem);
            menu.Items.Add(reportItem);
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add(new ToolStripMenuItem("Exit", null, OnExit));
            // The journals folder can appear after start (a first Revit launch); look again on open.
            menu.Opening += (sender, args) => journalsItem.Enabled = TrayPaths.NewestJournalsFolder() != null;

            icon = new NotifyIcon
            {
                Icon = LoadIcon(),
                ContextMenuStrip = menu,
                Text = "DeadLoad",
                Visible = true,
            };
            icon.DoubleClick += OnViewReport;

            timer = new Timer { Interval = (int)PollInterval.TotalMilliseconds };
            timer.Tick += (sender, args) => Poll();
            timer.Start();

            // Program already checked ShowTray with these settings; ExitThread here, before the
            // message loop runs, would be lost, so the first pass skips the policy reload.
            ApplyMenuPolicy();
            Refresh();
        }

        private static Icon LoadIcon()
        {
            try
            {
                Icon own = Icon.ExtractAssociatedIcon(typeof(TrayContext).Assembly.Location);
                if (own != null) { return own; }
            }
            catch (Exception)
            {
                // Fall through to the stock icon; a missing icon must not stop the tray.
            }
            return SystemIcons.Application;
        }

        private void ApplyMenuPolicy()
        {
            // A disabled action is hidden, not grayed, so users are not invited to ask for it.
            cleanTempItem.Visible = settings.AllowCleanTemp;
            requestCleanupItem.Visible = settings.AllowRequestCleanup;
            collectLogsItem.Visible = settings.AllowCollectLogs;
        }

        private void Poll()
        {
            settings = TraySettings.Load();
            if (!settings.ShowTray)
            {
                // Policy turned the tray off while it was running: leave as if never started.
                ExitThread();
                return;
            }
            ApplyMenuPolicy();
            Refresh();
        }

        private void Refresh()
        {
            DiskStatus disk = DiskStatus.Read(TrayPaths.SystemDrive);
            string error;
            LastRunReport report = LastRunReport.TryLoad(TrayPaths.LastRunReport, out error);
            icon.Text = BuildTooltip(disk, report);

            bool changed = CheckLowDisk(disk);
            changed |= CheckCompletion(report);
            if (changed) { state.Save(); }
        }

        private static string BuildTooltip(DiskStatus disk, LastRunReport report)
        {
            string text = "DeadLoad";
            if (disk != null)
            {
                text += "\n" + disk.Drive.TrimEnd('\\') + " " + LastRunReport.FormatBytes(disk.FreeBytes) + " free";
            }
            if (report != null && report.EndTimeUtc.HasValue)
            {
                text += "\nLast run " + report.EndTimeUtc.Value.ToLocalTime().ToString("g", System.Globalization.CultureInfo.CurrentCulture) + ": " + report.Result;
            }
            else
            {
                text += "\nNo cleanup has run yet";
            }
            // NotifyIcon.Text throws above 63 characters on .NET Framework.
            return text.Length > 63 ? text.Substring(0, 63) : text;
        }

        private bool CheckLowDisk(DiskStatus disk)
        {
            if (disk == null || !settings.LowDiskNotifications) { return false; }
            long threshold = settings.LowDiskThresholdBytes(disk.SizeBytes);
            if (disk.FreeBytes >= threshold) { return false; }
            DateTime now = DateTime.UtcNow;
            if (state.LastLowDiskNotificationUtc.HasValue && now - state.LastLowDiskNotificationUtc.Value < LowDiskQuietPeriod)
            {
                return false;
            }
            state.LastLowDiskNotificationUtc = now;
            string hint = settings.AllowCleanTemp ? " Use \"Clean my temp files\" from this icon to free some space." : string.Empty;
            icon.ShowBalloonTip(BalloonMilliseconds, "Low disk space",
                "Drive " + disk.Drive.TrimEnd('\\') + " has " + LastRunReport.FormatBytes(disk.FreeBytes) + " free." + hint,
                ToolTipIcon.Warning);
            return true;
        }

        private bool CheckCompletion(LastRunReport report)
        {
            if (report == null || string.IsNullOrEmpty(report.EndTimeText)) { return false; }
            if (string.Equals(report.EndTimeText, state.LastSeenEndTime, StringComparison.Ordinal)) { return false; }
            // The first report this user ever sees is history, not news.
            bool firstSighting = state.LastSeenEndTime == null;
            state.LastSeenEndTime = report.EndTimeText;
            if (!firstSighting && settings.NotifyOnCompletion)
            {
                string freed = report.FreedBytes.HasValue ? LastRunReport.FormatBytes(report.FreedBytes.Value) : "nothing";
                icon.ShowBalloonTip(BalloonMilliseconds, "Cleanup finished",
                    "Result: " + report.Result + ". Freed " + freed + ".", ToolTipIcon.Info);
            }
            return true;
        }

        private async void OnCleanTemp(object sender, EventArgs e)
        {
            if (cleanTempRunning) { return; }
            cleanTempRunning = true;
            cleanTempItem.Enabled = false;
            try
            {
                icon.ShowBalloonTip(BalloonMilliseconds, "Cleaning your temp files", "This runs in the background.", ToolTipIcon.Info);
                UserActionResult result = await UserActionRunner.RunAsync("CleanTemp");
                ShowActionResult("Temp cleanup", result, false);
                Poll();
            }
            finally
            {
                cleanTempRunning = false;
                cleanTempItem.Enabled = true;
            }
        }

        private async void OnCollectLogs(object sender, EventArgs e)
        {
            if (collectLogsRunning) { return; }
            collectLogsRunning = true;
            collectLogsItem.Enabled = false;
            try
            {
                icon.ShowBalloonTip(BalloonMilliseconds, "Collecting your logs", "This can take a minute.", ToolTipIcon.Info);
                UserActionResult result = await UserActionRunner.RunAsync("CollectLogs");
                ShowActionResult("Log collection", result, true);
            }
            finally
            {
                collectLogsRunning = false;
                collectLogsItem.Enabled = true;
            }
        }

        private void ShowActionResult(string title, UserActionResult result, bool showPath)
        {
            string text = string.IsNullOrEmpty(result.Message) ? result.Result : result.Message;
            if (showPath && !string.IsNullOrEmpty(result.Path))
            {
                text += "\nSaved to " + result.Path;
            }
            ToolTipIcon level = ToolTipIcon.Info;
            if (string.Equals(result.Result, "Partial", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(result.Result, "Disabled", StringComparison.OrdinalIgnoreCase))
            {
                level = ToolTipIcon.Warning;
            }
            else if (!result.Succeeded)
            {
                level = ToolTipIcon.Error;
            }
            // The balloon text is limited to 255 characters; the path matters most, so keep the end.
            if (text.Length > 255) { text = "..." + text.Substring(text.Length - 252); }
            icon.ShowBalloonTip(BalloonMilliseconds, title + ": " + result.Result, text, level);
        }

        private void OnRequestCleanup(object sender, EventArgs e)
        {
            string error = TaskStarter.StartOnDemand();
            if (error == null)
            {
                icon.ShowBalloonTip(BalloonMilliseconds, "Cleanup requested",
                    "A cleanup has started in the background. You can keep working.", ToolTipIcon.Info);
            }
            else
            {
                icon.ShowBalloonTip(BalloonMilliseconds, "Cleanup not started", error, ToolTipIcon.Warning);
            }
        }

        private void OnOpenJournals(object sender, EventArgs e)
        {
            string folder = TrayPaths.NewestJournalsFolder();
            if (folder == null)
            {
                icon.ShowBalloonTip(BalloonMilliseconds, "No journals folder", "No Revit journals folder was found for your account.", ToolTipIcon.Info);
                return;
            }
            try
            {
                string explorer = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
                Process.Start(new ProcessStartInfo(explorer, "\"" + folder + "\"") { UseShellExecute = false });
            }
            catch (Exception ex)
            {
                icon.ShowBalloonTip(BalloonMilliseconds, "Could not open the folder", ex.Message, ToolTipIcon.Warning);
            }
        }

        private void OnViewReport(object sender, EventArgs e)
        {
            if (reportForm != null && !reportForm.IsDisposed)
            {
                reportForm.Activate();
                return;
            }
            string error;
            LastRunReport report = LastRunReport.TryLoad(TrayPaths.LastRunReport, out error);
            reportForm = new ReportForm(report, error);
            reportForm.FormClosed += (s, args) => reportForm = null;
            reportForm.Show();
            reportForm.Activate();
        }

        private void OnExit(object sender, EventArgs e)
        {
            ExitThread();
        }

        protected override void ExitThreadCore()
        {
            timer.Stop();
            // Hide first, or the icon lingers in the notification area until the mouse passes over it.
            icon.Visible = false;
            if (reportForm != null && !reportForm.IsDisposed) { reportForm.Close(); }
            base.ExitThreadCore();
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                timer.Dispose();
                icon.Dispose();
                menu.Dispose();
            }
            base.Dispose(disposing);
        }
    }

    /// <summary>Free and total bytes of one volume; null when it cannot be read.</summary>
    internal sealed class DiskStatus
    {
        public string Drive;
        public long FreeBytes;
        public long SizeBytes;

        public static DiskStatus Read(string drive)
        {
            try
            {
                var info = new DriveInfo(drive);
                if (!info.IsReady) { return null; }
                // AvailableFreeSpace honors the user's quota, which is what this user can fill.
                return new DiskStatus { Drive = drive, FreeBytes = info.AvailableFreeSpace, SizeBytes = info.TotalSize };
            }
            catch (Exception)
            {
                return null;
            }
        }
    }
}
