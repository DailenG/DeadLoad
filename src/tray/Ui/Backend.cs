using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;

namespace DeadLoad.Tray.Ui
{
    /// <summary>
    /// Everything the DeadLoad window reads or starts. The live backend runs the user actions
    /// and reads the real reports; the render harness uses embedded samples and refuses to run
    /// anything.
    /// </summary>
    internal interface IWindowBackend
    {
        bool IsSample { get; }

        /// <summary>Tray.AllowCleanTemp: gates Analyze and Clean (the script re-checks it).</summary>
        bool AllowClean { get; }

        /// <summary>Tray.AllowRequestCleanup: the "Request a cleanup" button.</summary>
        bool AllowRequestCleanup { get; }

        string EngineVersion { get; }

        DiskStatus ReadDisk();

        Task<UserActionResult> AnalyzeAsync(CancellationToken token);

        Task<UserActionResult> CleanAsync(IList<string> categories, string analysisId);

        Task<UserActionResult> ConfigurationAsync();

        AnalysisDocument LoadAnalysis(string path);

        CleanupReport LoadCleanup(string path);

        ConfigurationSnapshot LoadConfiguration(string path);

        /// <summary>The user's last-cleanup.json, or null with the reason.</summary>
        CleanupReport LoadLastCleanup(out string error);

        /// <summary>The machine's last-run.json, or null with the reason.</summary>
        LastRunReport LoadLastRun(out string error);

        Task<HistoryLoad> LoadHistoryAsync();

        /// <summary>Starts the SYSTEM on-demand task; null on success, else the message to show.</summary>
        string RequestCleanup();

        /// <summary>Raised when the machine's last-run.json changes (the tray's poll saw a new run).</summary>
        event EventHandler MachineReportChanged;
    }

    /// <summary>Hooks the window needs from the tray: the shared requested-run watch.</summary>
    internal interface ITrayHost
    {
        string RequestCleanup();

        event EventHandler MachineReportChanged;
    }

    internal sealed class LiveBackend : IWindowBackend
    {
        // Category ids and analysis ids go on a command line: accept only their known alphabet.
        private static readonly Regex SafeId = new Regex("^[A-Za-z0-9._-]{1,128}$", RegexOptions.CultureInvariant);
        private readonly ITrayHost host;

        public LiveBackend(ITrayHost host)
        {
            this.host = host;
        }

        public bool IsSample { get { return false; } }

        public bool AllowClean { get { return TraySettings.Load().AllowCleanTemp; } }

        public bool AllowRequestCleanup { get { return TraySettings.Load().AllowRequestCleanup; } }

        public string EngineVersion { get { return EngineInfo.ModuleVersion(); } }

        public event EventHandler MachineReportChanged
        {
            add { host.MachineReportChanged += value; }
            remove { host.MachineReportChanged -= value; }
        }

        public DiskStatus ReadDisk()
        {
            return DiskStatus.Read(TrayPaths.SystemDrive);
        }

        public Task<UserActionResult> AnalyzeAsync(CancellationToken token)
        {
            return UserActionRunner.RunAsync("Analyze", null, token);
        }

        public Task<UserActionResult> CleanAsync(IList<string> categories, string analysisId)
        {
            foreach (string id in categories)
            {
                if (!SafeId.IsMatch(id)) { throw new ArgumentException("Unexpected category id: " + id); }
            }
            if (categories.Count == 0) { throw new ArgumentException("No category selected."); }
            string arguments = "-Categories " + string.Join(",", categories);
            if (!string.IsNullOrEmpty(analysisId))
            {
                if (!SafeId.IsMatch(analysisId)) { throw new ArgumentException("Unexpected analysis id."); }
                arguments += " -AnalysisId " + analysisId;
            }
            return UserActionRunner.RunAsync("Clean", arguments, CancellationToken.None);
        }

        public Task<UserActionResult> ConfigurationAsync()
        {
            return UserActionRunner.RunAsync("Configuration", null, CancellationToken.None);
        }

        public AnalysisDocument LoadAnalysis(string path)
        {
            return AnalysisDocument.Load(path);
        }

        public CleanupReport LoadCleanup(string path)
        {
            return CleanupReport.Load(path);
        }

        public ConfigurationSnapshot LoadConfiguration(string path)
        {
            return ConfigurationSnapshot.Load(path);
        }

        public CleanupReport LoadLastCleanup(out string error)
        {
            error = null;
            string path = Path.Combine(TrayPaths.UserDataRoot, "last-cleanup.json");
            try
            {
                if (!File.Exists(path))
                {
                    error = "You have not cleaned anything from this window yet.";
                    return null;
                }
                return CleanupReport.Load(path);
            }
            catch (Exception ex)
            {
                error = "Your last cleanup report could not be read: " + ex.Message;
                return null;
            }
        }

        public LastRunReport LoadLastRun(out string error)
        {
            return LastRunReport.TryLoad(TrayPaths.LastRunReport, out error);
        }

        public Task<HistoryLoad> LoadHistoryAsync()
        {
            string machineRuns = Path.Combine(Path.GetDirectoryName(TrayPaths.LastRunReport), "runs");
            string userRuns = Path.Combine(TrayPaths.UserDataRoot, "runs");
            string lastCleanup = Path.Combine(TrayPaths.UserDataRoot, "last-cleanup.json");
            return Task.Run(() => HistoryReader.Load(machineRuns, userRuns, lastCleanup));
        }

        public string RequestCleanup()
        {
            return host.RequestCleanup();
        }
    }
}
