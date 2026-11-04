using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Windows.Forms;

namespace DeadLoad.Tray
{
    internal static class Program
    {
        private const string MutexName = @"Local\DeadLoadTray";

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool AttachConsole(int processId);

        private const int AttachParentProcess = -1;

        [STAThread]
        private static int Main(string[] args)
        {
            foreach (string arg in args)
            {
                if (string.Equals(arg, "--self-test", StringComparison.OrdinalIgnoreCase) ||
                    string.Equals(arg, "/self-test", StringComparison.OrdinalIgnoreCase))
                {
                    return SelfTest();
                }
            }

            TraySettings settings = TraySettings.Load();
            if (!settings.ShowTray) { return 0; }

            // One tray per user session: the Run key starts it at every sign-in, and a user may
            // also start it by hand. Local\ scopes the mutex to this session.
            bool created;
            using (var mutex = new Mutex(true, MutexName, out created))
            {
                if (!created) { return 0; }
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                // Awaited user actions resume on the UI thread through this context.
                SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
                using (var context = new TrayContext(settings))
                {
                    Application.Run(context);
                }
                mutex.ReleaseMutex();
            }
            return 0;
        }

        /// <summary>
        /// Resolves everything the tray would use and prints it, without showing UI, touching the
        /// Task Scheduler or writing state. Used by the build and by support to check an install.
        /// </summary>
        private static int SelfTest()
        {
            // A WinExe has no console of its own; borrow the caller's unless output is redirected.
            if (!Console.IsOutputRedirected) { AttachConsole(AttachParentProcess); }

            var lines = new List<string>();
            try
            {
                TraySettings settings = TraySettings.Load();
                lines.Add("DeadLoadTray self-test");
                lines.Add("Version=" + typeof(Program).Assembly.GetName().Version);
                lines.Add("InstallRoot=" + TrayPaths.InstallRoot);
                lines.Add("UserActionScript=" + TrayPaths.UserActionScript + " (exists=" + File.Exists(TrayPaths.UserActionScript) + ")");
                lines.Add("WindowsPowerShell=" + TrayPaths.WindowsPowerShell + " (exists=" + File.Exists(TrayPaths.WindowsPowerShell) + ")");
                lines.Add("LastRunReport=" + TrayPaths.LastRunReport + " (exists=" + File.Exists(TrayPaths.LastRunReport) + ")");
                string error;
                LastRunReport report = LastRunReport.TryLoad(TrayPaths.LastRunReport, out error);
                if (report != null)
                {
                    lines.Add("LastRunResult=" + report.Result);
                    lines.Add("LastRunEndTime=" + report.EndTimeText);
                }
                else
                {
                    lines.Add("LastRunResult=(none: " + error + ")");
                }
                string journals = TrayPaths.NewestJournalsFolder();
                lines.Add("JournalsFolder=" + (journals ?? "(none found)"));
                lines.Add("TrayStateFile=" + TrayPaths.TrayStateFile + " (exists=" + File.Exists(TrayPaths.TrayStateFile) + ")");
                lines.Add("OnDemandTask=" + TaskStarter.FolderPath + "\\" + TaskStarter.TaskName +
                    " (Schedule.Service registered=" + (Type.GetTypeFromProgID("Schedule.Service", false) != null) + ")");

                DiskStatus disk = DiskStatus.Read(TrayPaths.SystemDrive);
                if (disk != null)
                {
                    long threshold = settings.LowDiskThresholdBytes(disk.SizeBytes);
                    lines.Add("SystemDrive=" + disk.Drive + " Free=" + disk.FreeBytes + " Size=" + disk.SizeBytes +
                        " LowDiskThreshold=" + threshold + " BelowThreshold=" + (disk.FreeBytes < threshold));
                }
                else
                {
                    lines.Add("SystemDrive=" + TrayPaths.SystemDrive + " (not readable)");
                }

                AddSetting(lines, settings, "ShowTray", settings.ShowTray);
                AddSetting(lines, settings, "AllowCleanTemp", settings.AllowCleanTemp);
                AddSetting(lines, settings, "AllowRequestCleanup", settings.AllowRequestCleanup);
                AddSetting(lines, settings, "AllowCollectLogs", settings.AllowCollectLogs);
                AddSetting(lines, settings, "LowDiskNotifications", settings.LowDiskNotifications);
                AddSetting(lines, settings, "NotifyBelowGB", settings.NotifyBelowGB);
                AddSetting(lines, settings, "NotifyBelowPercent", settings.NotifyBelowPercent);
                AddSetting(lines, settings, "NotifyOnCompletion", settings.NotifyOnCompletion);
                AddSetting(lines, settings, "SupportShare", settings.SupportShare);
                AddSetting(lines, settings, "CollectDays", settings.CollectDays);
                AddSetting(lines, settings, "CleanTempMinAgeDays", settings.CleanTempMinAgeDays);
                string parser = ParserCheck();
                lines.Add("ParserCheck=" + parser);
                if (parser != "OK")
                {
                    lines.Add("SelfTest=FAILED parser");
                    Write(lines);
                    return 1;
                }
                lines.Add("SelfTest=OK");
            }
            catch (Exception ex)
            {
                lines.Add("SelfTest=FAILED " + ex.GetType().Name + ": " + ex.Message);
                Write(lines);
                return 1;
            }
            Write(lines);
            return 0;
        }

        /// <summary>
        /// Feeds fixed samples of both JSON contracts (last-run.json and the user action result)
        /// through the real parsers, so a self-test proves more than path resolution.
        /// </summary>
        private static string ParserCheck()
        {
            const string report = "{\"SchemaVersion\":1,\"Result\":\"Partial\",\"Reason\":null,\"Mode\":\"Maintenance\"," +
                "\"EndTime\":\"2026-01-02T03:04:05.0000000Z\",\"DurationSeconds\":12.5,\"ReportOnly\":false," +
                "\"Volume\":{\"Drive\":\"C:\",\"SizeBytes\":500000000000,\"FreeBytesBefore\":1000,\"FreeBytesAfter\":3000,\"TargetReached\":true}," +
                "\"Totals\":{\"FreedBytes\":2000,\"DeletedCount\":4,\"SkippedCount\":1,\"FailedCount\":0}}";
            LastRunReport parsed = LastRunReport.Parse(report);
            if (parsed.Result != "Partial" || parsed.FreedBytes != 2000 || parsed.SizeBytes != 500000000000L ||
                parsed.TargetReached != true || !parsed.EndTimeUtc.HasValue ||
                parsed.EndTimeUtc.Value != new DateTime(2026, 1, 2, 3, 4, 5, DateTimeKind.Utc))
            {
                return "FAILED last-run.json sample";
            }

            const string action = "banner line\r\n{\"Action\":\"CollectLogs\",\"Result\":\"Success\",\"Message\":\"Logs collected.\",\"Path\":\"C:\\\\Users\\\\x\\\\Desktop\\\\b\\u00e9.zip\"}\r\n";
            UserActionResult result = UserActionRunner.Parse("CollectLogs", action);
            if (result.Result != "Success" || result.Path != "C:\\Users\\x\\Desktop\\b\u00e9.zip" || !result.Succeeded)
            {
                return "FAILED user action sample";
            }
            return "OK";
        }

        private static void AddSetting(List<string> lines, TraySettings settings, string name, object value)
        {
            string source;
            settings.Sources.TryGetValue(name, out source);
            string text = value is bool ? (((bool)value) ? "1" : "0") : Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
            lines.Add("Setting." + name + "=" + text + " (" + (source ?? "Default") + ")");
        }

        private static void Write(List<string> lines)
        {
            foreach (string line in lines) { Console.Out.WriteLine(line); }
            Console.Out.Flush();
        }
    }
}
