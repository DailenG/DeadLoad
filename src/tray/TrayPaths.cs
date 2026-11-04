using System;
using System.IO;
using System.Text.RegularExpressions;

namespace DeadLoad.Tray
{
    /// <summary>
    /// Every path the tray touches, resolved from the install layout and the user's profile so
    /// nothing is hard-coded to one machine.
    /// </summary>
    internal static class TrayPaths
    {
        /// <summary>The install root: the exe lives in &lt;install&gt;\tray\DeadLoadTray.exe.</summary>
        public static string InstallRoot
        {
            get
            {
                string exeDir = Path.GetDirectoryName(typeof(TrayPaths).Assembly.Location);
                DirectoryInfo parent = Directory.GetParent(exeDir);
                return parent == null ? exeDir : parent.FullName;
            }
        }

        public static string UserActionScript
        {
            get { return Path.Combine(InstallRoot, "engine", "Invoke-DeadLoadUserAction.ps1"); }
        }

        /// <summary>
        /// Windows PowerShell by full path: the user actions are proven on 5.1, and a full path
        /// keeps a writable folder earlier in PATH from supplying a different powershell.exe.
        /// </summary>
        public static string WindowsPowerShell
        {
            get
            {
                string system = Environment.GetFolderPath(Environment.SpecialFolder.System);
                return Path.Combine(system, "WindowsPowerShell", "v1.0", "powershell.exe");
            }
        }

        public static string LastRunReport
        {
            get
            {
                string data = Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData);
                return Path.Combine(data, "DeadLoad", "last-run.json");
            }
        }

        public static string UserDataRoot
        {
            get
            {
                string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                return Path.Combine(local, "DeadLoad");
            }
        }

        public static string TrayStateFile
        {
            get { return Path.Combine(UserDataRoot, "tray-state.json"); }
        }

        /// <summary>The volume the engine guards: the one Windows runs from.</summary>
        public static string SystemDrive
        {
            get
            {
                string drive = Environment.GetEnvironmentVariable("SystemDrive");
                if (string.IsNullOrEmpty(drive))
                {
                    drive = Path.GetPathRoot(Environment.GetFolderPath(Environment.SpecialFolder.Windows));
                }
                return drive.TrimEnd('\\') + "\\";
            }
        }

        private static readonly Regex RevitFolder = new Regex(@"^Autodesk Revit (\d{4})$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);

        /// <summary>
        /// The Journals folder of the highest Revit year present for this user, or null. The
        /// newest release is the one a user is most likely asking support about.
        /// </summary>
        public static string NewestJournalsFolder()
        {
            string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            string revitRoot = Path.Combine(local, "Autodesk", "Revit");
            if (!Directory.Exists(revitRoot)) { return null; }

            int bestYear = -1;
            string best = null;
            string[] candidates;
            try
            {
                candidates = Directory.GetDirectories(revitRoot);
            }
            catch (Exception)
            {
                return null;
            }
            foreach (string dir in candidates)
            {
                Match match = RevitFolder.Match(Path.GetFileName(dir));
                if (!match.Success) { continue; }
                int year = int.Parse(match.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture);
                string journals = Path.Combine(dir, "Journals");
                if (year > bestYear && Directory.Exists(journals))
                {
                    bestYear = year;
                    best = journals;
                }
            }
            return best;
        }
    }
}
