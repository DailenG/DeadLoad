using System;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Windows.Forms;
using DeadLoad.Tray.Ui;

namespace DeadLoad.Tray
{
    /// <summary>
    /// The tray icon and its menu. Owns the poll timer: every poll re-reads policy (so a GPO
    /// change shows without a sign-out), refreshes the tooltip, and decides on notifications.
    /// Owns the one DeadLoad window and the requested-run watch the window shares.
    /// </summary>
    internal sealed class TrayContext : ApplicationContext, ITrayHost
    {
        private static readonly TimeSpan PollInterval = TimeSpan.FromMinutes(10);
        // After "Request a cleanup": look for the finished run this often, for at most this long.
        private static readonly TimeSpan RequestedRunPollInterval = TimeSpan.FromSeconds(30);
        private static readonly TimeSpan RequestedRunWatchLimit = TimeSpan.FromMinutes(90);
        private static readonly TimeSpan LowDiskQuietPeriod = TimeSpan.FromHours(4);
        private const int BalloonMilliseconds = 10000;
        private bool balloonVisible;
        private DateTime? watchRequestedRunUntilUtc;

        private readonly NotifyIcon icon;
        private readonly ContextMenuStrip menu;
        private readonly ToolStripMenuItem cleanTempItem;
        private readonly ToolStripMenuItem requestCleanupItem;
        private readonly ToolStripMenuItem collectLogsItem;
        private readonly ToolStripMenuItem journalsItem;
        private readonly ToolStripMenuItem reportItem;
        private readonly ToolStripMenuItem openItem;
        private readonly Timer timer;
        private readonly TrayState state;
        private TraySettings settings;
        private MainWindow window;
        private bool cleanTempRunning;
        private bool collectLogsRunning;

        public TrayContext(TraySettings initialSettings)
        {
            settings = initialSettings;
            state = TrayState.Load(TrayPaths.TrayStateFile);

            menu = new ContextMenuStrip();
            openItem = new ToolStripMenuItem("Open DeadLoad", null, (sender, args) => OpenWindow(PageId.Cleanup));
            // Bold marks the default item, the one a double-click on the icon runs.
            openItem.Font = new Font(menu.Font, FontStyle.Bold);
            cleanTempItem = new ToolStripMenuItem("Clean my temp files", null, OnCleanTemp);
            requestCleanupItem = new ToolStripMenuItem("Request a cleanup", null, OnRequestCleanup);
            collectLogsItem = new ToolStripMenuItem("Collect my logs for support", null, OnCollectLogs);
            journalsItem = new ToolStripMenuItem("Open my journals folder", null, OnOpenJournals);
            reportItem = new ToolStripMenuItem("View last report", null, (sender, args) => OpenWindow(PageId.Details));
            menu.Items.Add(openItem);
            menu.Items.Add(new ToolStripSeparator());
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
            icon.DoubleClick += (sender, args) => OpenWindow(PageId.Cleanup);
            icon.BalloonTipShown += (sender, args) => balloonVisible = true;
            icon.BalloonTipClosed += (sender, args) => balloonVisible = false;
            icon.BalloonTipClicked += (sender, args) => balloonVisible = false;

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
            // The embedded ICO gives the frame drawn for the notification area's own size (16, 20
            // or 24 px by DPI); the exe's associated icon is the 32 px frame shrunk by Windows.
            try
            {
                using (Stream stream = typeof(TrayContext).Assembly.GetManifestResourceStream("DeadLoad.ico"))
                {
                    if (stream != null) { return new Icon(stream, SystemInformation.SmallIconSize); }
                }
            }
            catch (Exception)
            {
                // Fall through to the exe's own icon.
            }
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
            if (watchRequestedRunUntilUtc.HasValue && DateTime.UtcNow > watchRequestedRunUntilUtc.Value) { StopWatchingRequestedRun(); }
        }

        /// <summary>
        /// Shows one notification. Windows queues a new balloon behind one still on screen
        /// until the user closes it (measured: the result stayed hidden behind a "started"
        /// notice), so a visible one is dismissed first; hiding the icon for a moment is the
        /// only way NotifyIcon offers to do that.
        /// </summary>
        private void Notify(string title, string text, ToolTipIcon level)
        {
            if (balloonVisible)
            {
                icon.Visible = false;
                icon.Visible = true;
                balloonVisible = false;
            }
            icon.ShowBalloonTip(BalloonMilliseconds, title, text, level);
        }

        private void StartWatchingRequestedRun()
        {
            watchRequestedRunUntilUtc = DateTime.UtcNow + RequestedRunWatchLimit;
            timer.Interval = (int)RequestedRunPollInterval.TotalMilliseconds;
        }

        private void StopWatchingRequestedRun()
        {
            watchRequestedRunUntilUtc = null;
            timer.Interval = (int)PollInterval.TotalMilliseconds;
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
            Notify("Low disk space",
                "Drive " + disk.Drive.TrimEnd('\\') + " has " + LastRunReport.FormatBytes(disk.FreeBytes) + " free." + hint,
                ToolTipIcon.Warning);
            return true;
        }

        private bool CheckCompletion(LastRunReport report)
        {
            if (report == null || string.IsNullOrEmpty(report.EndTimeText)) { return false; }
            if (string.Equals(report.EndTimeText, state.LastSeenEndTime, StringComparison.Ordinal)) { return false; }
            // The first report this user ever sees is history, not news, unless they asked for it.
            bool requested = watchRequestedRunUntilUtc.HasValue;
            bool firstSighting = state.LastSeenEndTime == null;
            state.LastSeenEndTime = report.EndTimeText;
            if (requested) { StopWatchingRequestedRun(); }
            // A run the user requested is always reported; other runs only when policy asks.
            if (requested || (!firstSighting && settings.NotifyOnCompletion))
            {
                string freed = report.FreedBytes.HasValue ? LastRunReport.FormatBytes(report.FreedBytes.Value) : "nothing";
                Notify("Cleanup finished", "Result: " + report.Result + ". Freed " + freed + ".", ToolTipIcon.Info);
            }
            if (MachineReportChanged != null) { MachineReportChanged(this, EventArgs.Empty); }
            return true;
        }

        /// <summary>Raised when last-run.json shows a new run; the window refreshes "This computer".</summary>
        public event EventHandler MachineReportChanged;

        /// <summary>
        /// Starts the on-demand task and watches for its report, for the menu and the window
        /// alike. Null on success, else the message to show.
        /// </summary>
        public string RequestCleanup()
        {
            string error = TaskStarter.StartOnDemand();
            if (error == null) { StartWatchingRequestedRun(); }
            return error;
        }

        private void OpenWindow(PageId page)
        {
            if (window == null || window.IsDisposed)
            {
                window = new MainWindow(new LiveBackend(this), null);
                window.FormClosed += (sender, args) => window = null;
            }
            if (page == PageId.Details) { window.Details.UserFirst = false; }
            window.ShowPage(page);
            if (!window.Visible) { window.Show(); }
            if (window.WindowState == FormWindowState.Minimized) { window.WindowState = FormWindowState.Normal; }
            window.Activate();
        }

        private async void OnCleanTemp(object sender, EventArgs e)
        {
            if (cleanTempRunning) { return; }
            cleanTempRunning = true;
            // Progress shows on the menu item, not in a notification that would hide the result.
            string label = cleanTempItem.Text;
            cleanTempItem.Text = "Cleaning your temp files...";
            cleanTempItem.Enabled = false;
            try
            {
                UserActionResult result = await UserActionRunner.RunAsync("CleanTemp");
                ShowActionResult("Temp cleanup", result, false);
                Poll();
            }
            finally
            {
                cleanTempRunning = false;
                cleanTempItem.Text = label;
                cleanTempItem.Enabled = true;
            }
        }

        private async void OnCollectLogs(object sender, EventArgs e)
        {
            if (collectLogsRunning) { return; }
            collectLogsRunning = true;
            string label = collectLogsItem.Text;
            collectLogsItem.Text = "Collecting your logs...";
            collectLogsItem.Enabled = false;
            try
            {
                UserActionResult result = await UserActionRunner.RunAsync("CollectLogs");
                ShowActionResult("Log collection", result, true);
            }
            finally
            {
                collectLogsRunning = false;
                collectLogsItem.Text = label;
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
            Notify(title + ": " + result.Result, text, level);
        }

        private void OnRequestCleanup(object sender, EventArgs e)
        {
            string error = RequestCleanup();
            if (error == null)
            {
                Notify("Cleanup requested",
                    "A cleanup has started in the background. You can keep working; you will be told when it finishes.", ToolTipIcon.Info);
            }
            else
            {
                Notify("Cleanup not started", error, ToolTipIcon.Warning);
            }
        }

        private void OnOpenJournals(object sender, EventArgs e)
        {
            string folder = TrayPaths.NewestJournalsFolder();
            if (folder == null)
            {
                Notify("No journals folder", "No Revit journals folder was found for your account.", ToolTipIcon.Info);
                return;
            }
            try
            {
                string explorer = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "explorer.exe");
                Process.Start(new ProcessStartInfo(explorer, "\"" + folder + "\"") { UseShellExecute = false });
            }
            catch (Exception ex)
            {
                Notify("Could not open the folder", ex.Message, ToolTipIcon.Warning);
            }
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
            // Dispose, not Close: closing a window with a cleanup running only hides it.
            if (window != null && !window.IsDisposed) { window.Dispose(); }
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
