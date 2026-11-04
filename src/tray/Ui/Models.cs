using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

namespace DeadLoad.Tray.Ui
{
    /// <summary>Lenient readers over JavaScriptSerializer output (dictionaries and object arrays).</summary>
    internal static class Json
    {
        public static Dictionary<string, object> ParseObject(string text)
        {
            var serializer = new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024, RecursionLimit = 64 };
            var root = serializer.DeserializeObject(text) as Dictionary<string, object>;
            if (root == null) { throw new FormatException("The file is not a JSON object."); }
            return root;
        }

        /// <summary>Reads a file another process may be replacing, without locking it.</summary>
        public static string ReadShared(string path)
        {
            using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            using (var reader = new StreamReader(stream, Encoding.UTF8, true))
            {
                return reader.ReadToEnd();
            }
        }

        public static Dictionary<string, object> Obj(Dictionary<string, object> parent, string name)
        {
            object value;
            return parent != null && parent.TryGetValue(name, out value) ? value as Dictionary<string, object> : null;
        }

        public static IEnumerable<Dictionary<string, object>> Objects(Dictionary<string, object> parent, string name)
        {
            object value;
            if (parent == null || !parent.TryGetValue(name, out value) || value == null) { yield break; }
            var list = value as System.Collections.IEnumerable;
            if (list == null || value is string) { yield break; }
            foreach (object item in list)
            {
                var entry = item as Dictionary<string, object>;
                if (entry != null) { yield return entry; }
            }
        }

        public static List<string> Strings(Dictionary<string, object> parent, string name)
        {
            var result = new List<string>();
            object value;
            if (parent == null || !parent.TryGetValue(name, out value) || value == null) { return result; }
            var list = value as System.Collections.IEnumerable;
            if (list == null || value is string) { result.Add(Convert.ToString(value, CultureInfo.InvariantCulture)); return result; }
            foreach (object item in list)
            {
                if (item != null) { result.Add(Convert.ToString(item, CultureInfo.InvariantCulture)); }
            }
            return result;
        }

        public static string Str(Dictionary<string, object> parent, string name)
        {
            object value;
            if (parent == null || !parent.TryGetValue(name, out value) || value == null) { return null; }
            return Convert.ToString(value, CultureInfo.InvariantCulture);
        }

        public static long Lng(Dictionary<string, object> parent, string name)
        {
            long? value = LngOrNull(parent, name);
            return value.HasValue ? value.Value : 0;
        }

        public static long? LngOrNull(Dictionary<string, object> parent, string name)
        {
            object value;
            if (parent == null || !parent.TryGetValue(name, out value) || value == null) { return null; }
            try { return Convert.ToInt64(value, CultureInfo.InvariantCulture); }
            catch (Exception) { return null; }
        }

        public static bool Bool(Dictionary<string, object> parent, string name)
        {
            object value;
            if (parent == null || !parent.TryGetValue(name, out value) || value == null) { return false; }
            return value is bool && (bool)value;
        }

        public static DateTime? Time(string text)
        {
            DateTime parsed;
            if (string.IsNullOrEmpty(text)) { return null; }
            if (DateTime.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out parsed))
            {
                return DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
            }
            return null;
        }
    }

    /// <summary>Formatting shared by every view: sizes, counts, times, plural words.</summary>
    internal static class Format
    {
        /// <summary>Set by the render harness so "3 days ago" is the same in every capture.</summary>
        public static DateTime? FixedNowUtc;

        public static DateTime NowUtc
        {
            get { return FixedNowUtc.HasValue ? FixedNowUtc.Value : DateTime.UtcNow; }
        }

        public static string Bytes(long bytes)
        {
            return LastRunReport.FormatBytes(bytes);
        }

        public static string Count(long count, string singular, string plural)
        {
            return count.ToString("N0", CultureInfo.CurrentCulture) + " " + (count == 1 ? singular : plural);
        }

        public static string Number(long count)
        {
            return count.ToString("N0", CultureInfo.CurrentCulture);
        }

        public static string Local(DateTime? utc)
        {
            if (!utc.HasValue) { return "-"; }
            return utc.Value.ToLocalTime().ToString("g", CultureInfo.CurrentCulture);
        }

        public static string TimeOfDay(DateTime utc)
        {
            DateTime local = utc.ToLocalTime();
            DateTime today = NowUtc.ToLocalTime().Date;
            string time = local.ToString("t", CultureInfo.CurrentCulture);
            if (local.Date == today) { return "today at " + time; }
            if (local.Date == today.AddDays(-1)) { return "yesterday at " + time; }
            return local.ToString("d", CultureInfo.CurrentCulture) + " at " + time;
        }

        /// <summary>"21 days ago" style age of a last write time.</summary>
        public static string Age(DateTime? utc)
        {
            if (!utc.HasValue) { return "-"; }
            TimeSpan age = NowUtc - utc.Value;
            if (age.TotalMinutes < 1) { return "just now"; }
            if (age.TotalHours < 1) { return Count((long)age.TotalMinutes, "minute", "minutes") + " ago"; }
            if (age.TotalDays < 1) { return Count((long)age.TotalHours, "hour", "hours") + " ago"; }
            if (age.TotalDays < 60) { return Count((long)age.TotalDays, "day", "days") + " ago"; }
            return utc.Value.ToLocalTime().ToString("d", CultureInfo.CurrentCulture);
        }

        /// <summary>The plain sentence for a skip reason: the design system's copy for a locked file.</summary>
        public static string SkipReason(string reason, string reasonText)
        {
            if (string.Equals(reason, "Locked", StringComparison.OrdinalIgnoreCase)) { return "File in use; skipped."; }
            if (!string.IsNullOrEmpty(reasonText)) { return reasonText; }
            return string.IsNullOrEmpty(reason) ? "Skipped." : reason;
        }
    }

    internal sealed class AnalysisItem
    {
        public string Path;
        public string Kind;
        public long Bytes;
        public DateTime? LastWriteUtc;
        public string Reason;
        public string ReasonText;
        public int FileCount;

        public bool IsFolder { get { return string.Equals(Kind, "Folder", StringComparison.OrdinalIgnoreCase); } }

        /// <summary>Files this item stands for: a folder is judged as one item but holds several files.</summary>
        public int Files { get { return IsFolder ? Math.Max(FileCount, 1) : 1; } }

        /// <summary>The path as listed: a folder ends with a backslash, so the ellipsis keeps its name.</summary>
        public string DisplayPath { get { return IsFolder ? Path + "\\" : Path; } }

        /// <summary>Why it is listed; a folder also says how many files it holds.</summary>
        public string DisplayReason
        {
            get
            {
                string reason = ReasonText ?? Reason ?? string.Empty;
                return IsFolder ? "Folder of " + Format.Count(FileCount, "file", "files") + ". " + reason : reason;
            }
        }
    }

    internal sealed class AnalysisCategory
    {
        public string Id;
        public string DisplayName;
        public string Description;
        public string Risk;
        public string RiskText;
        public bool Available;
        public string UnavailableReason;
        public string UnavailableText;
        public bool DefaultSelected;
        public long ItemCount;
        public long EstimatedBytes;
        public string GuardedMessage;
        public long GuardedItemCount;
        public readonly List<AnalysisItem> Items = new List<AnalysisItem>();

        /// <summary>A row the user may check: offered by the engine and with something to clean.</summary>
        public bool Selectable { get { return Available && Items.Count > 0; } }

        public int FileCount
        {
            get
            {
                int count = 0;
                foreach (AnalysisItem item in Items) { count += item.Files; }
                return count;
            }
        }
    }

    /// <summary>analysis.json (docs/design/ENGINE-UI-CONTRACT.md section 3). Read-only; never rewritten.</summary>
    internal sealed class AnalysisDocument
    {
        public string RawJson;
        public string AnalysisId;
        public DateTime? CreatedUtc;
        public string Result;
        public string Reason;
        public bool ReportOnly;
        public string Drive;
        public long? SizeBytes;
        public long? FreeBytes;
        public long ItemCount;
        public long EstimatedBytes;
        public readonly List<AnalysisCategory> Categories = new List<AnalysisCategory>();

        public static AnalysisDocument Load(string path)
        {
            return Parse(Json.ReadShared(path));
        }

        public static AnalysisDocument Parse(string text)
        {
            Dictionary<string, object> root = Json.ParseObject(text);
            var doc = new AnalysisDocument { RawJson = text };
            doc.AnalysisId = Json.Str(root, "analysisId");
            doc.CreatedUtc = Json.Time(Json.Str(root, "createdUtc"));
            doc.Result = Json.Str(root, "result");
            doc.Reason = Json.Str(root, "reason");
            doc.ReportOnly = Json.Bool(root, "reportOnly");
            Dictionary<string, object> volume = Json.Obj(root, "volume");
            if (volume != null)
            {
                doc.Drive = Json.Str(volume, "drive");
                doc.SizeBytes = Json.LngOrNull(volume, "sizeBytes");
                doc.FreeBytes = Json.LngOrNull(volume, "freeBytes");
            }
            Dictionary<string, object> totals = Json.Obj(root, "totals");
            doc.ItemCount = Json.Lng(totals, "itemCount");
            doc.EstimatedBytes = Json.Lng(totals, "estimatedBytes");
            foreach (Dictionary<string, object> c in Json.Objects(root, "categories"))
            {
                var category = new AnalysisCategory
                {
                    Id = Json.Str(c, "id"),
                    DisplayName = Json.Str(c, "displayName"),
                    Description = Json.Str(c, "description"),
                    Risk = Json.Str(c, "risk"),
                    RiskText = Json.Str(c, "riskText"),
                    Available = Json.Bool(c, "available"),
                    UnavailableReason = Json.Str(c, "unavailableReason"),
                    UnavailableText = Json.Str(c, "unavailableText"),
                    DefaultSelected = Json.Bool(c, "defaultSelected"),
                    ItemCount = Json.Lng(c, "itemCount"),
                    EstimatedBytes = Json.Lng(c, "estimatedBytes"),
                };
                if (string.IsNullOrEmpty(category.Id)) { continue; }
                if (string.IsNullOrEmpty(category.DisplayName)) { category.DisplayName = category.Id; }
                Dictionary<string, object> guarded = Json.Obj(c, "guardedSkipped");
                if (guarded != null)
                {
                    category.GuardedMessage = Json.Str(guarded, "message");
                    category.GuardedItemCount = Json.Lng(guarded, "itemCount");
                }
                // A row the engine did not offer is never sent to Clean, whatever its items say.
                if (category.Available)
                {
                    foreach (Dictionary<string, object> i in Json.Objects(c, "items"))
                    {
                        category.Items.Add(new AnalysisItem
                        {
                            Path = Json.Str(i, "path"),
                            Kind = Json.Str(i, "kind"),
                            Bytes = Json.Lng(i, "bytes"),
                            LastWriteUtc = Json.Time(Json.Str(i, "lastWriteUtc")),
                            Reason = Json.Str(i, "reason"),
                            ReasonText = Json.Str(i, "reasonText"),
                            FileCount = (int)Json.Lng(i, "fileCount"),
                        });
                    }
                }
                doc.Categories.Add(category);
            }
            return doc;
        }

        public AnalysisCategory Find(string id)
        {
            foreach (AnalysisCategory c in Categories)
            {
                if (string.Equals(c.Id, id, StringComparison.OrdinalIgnoreCase)) { return c; }
            }
            return null;
        }
    }

    internal sealed class CleanupEntry
    {
        public string Category;
        public string Path;
        public string Kind;
        public long Bytes;
        public string Reason;
        public string ReasonText;
    }

    /// <summary>last-cleanup.json (ENGINE-UI-CONTRACT.md section 4).</summary>
    internal sealed class CleanupReport
    {
        public string RawJson;
        public string CleanupId;
        public string AnalysisId;
        public DateTime? StartUtc;
        public DateTime? EndUtc;
        public string Result;
        public string Reason;
        public readonly List<string> Categories = new List<string>();
        public long EstimatedBytes;
        public long FreedBytes;
        public long DeletedCount;
        public long SkippedCount;
        public long FailedCount;
        public readonly List<CleanupEntry> Deleted = new List<CleanupEntry>();
        public readonly List<CleanupEntry> Skipped = new List<CleanupEntry>();

        public static CleanupReport Load(string path)
        {
            return Parse(Json.ReadShared(path));
        }

        public static CleanupReport Parse(string text)
        {
            Dictionary<string, object> root = Json.ParseObject(text);
            var report = new CleanupReport { RawJson = text };
            report.CleanupId = Json.Str(root, "cleanupId");
            report.AnalysisId = Json.Str(root, "analysisId");
            report.StartUtc = Json.Time(Json.Str(root, "startUtc"));
            report.EndUtc = Json.Time(Json.Str(root, "endUtc"));
            report.Result = Json.Str(root, "result");
            report.Reason = Json.Str(root, "reason");
            report.Categories.AddRange(Json.Strings(root, "categories"));
            report.EstimatedBytes = Json.Lng(root, "estimatedBytes");
            report.FreedBytes = Json.Lng(root, "freedBytes");
            report.DeletedCount = Json.Lng(root, "deletedCount");
            report.SkippedCount = Json.Lng(root, "skippedCount");
            report.FailedCount = Json.Lng(root, "failedCount");
            foreach (Dictionary<string, object> e in Json.Objects(root, "deleted")) { report.Deleted.Add(Entry(e)); }
            foreach (Dictionary<string, object> e in Json.Objects(root, "skipped")) { report.Skipped.Add(Entry(e)); }
            return report;
        }

        private static CleanupEntry Entry(Dictionary<string, object> e)
        {
            return new CleanupEntry
            {
                Category = Json.Str(e, "category"),
                Path = Json.Str(e, "path"),
                Kind = Json.Str(e, "kind"),
                Bytes = Json.Lng(e, "bytes"),
                Reason = Json.Str(e, "reason"),
                ReasonText = Json.Str(e, "reasonText"),
            };
        }
    }

    internal sealed class ConfigurationSetting
    {
        public string Name;
        public string Value;
        public string Source;
        public string Reason;

        /// <summary>The registry subkey part of the name ("Pressure", "Categories\user.temp"); "General" when none.</summary>
        public string Section
        {
            get
            {
                int slash = Name == null ? -1 : Name.LastIndexOf('\\');
                return slash > 0 ? Name.Substring(0, slash) : "General";
            }
        }

        public string Setting
        {
            get
            {
                int slash = Name == null ? -1 : Name.LastIndexOf('\\');
                return slash >= 0 ? Name.Substring(slash + 1) : (Name ?? string.Empty);
            }
        }

        /// <summary>Policy, User policy, Local or Default; an ignored value says so and why.</summary>
        public string SourceText
        {
            get
            {
                string source = Source ?? "Default";
                if (source.StartsWith("Rejected:", StringComparison.OrdinalIgnoreCase))
                {
                    string from = Readable(source.Substring("Rejected:".Length));
                    return "Ignored (" + from + (string.IsNullOrEmpty(Reason) ? string.Empty : ": " + Reason) + ")";
                }
                return Readable(source);
            }
        }

        public bool Ignored
        {
            get { return Source != null && Source.StartsWith("Rejected:", StringComparison.OrdinalIgnoreCase); }
        }

        private static string Readable(string source)
        {
            if (string.Equals(source, "UserPolicy", StringComparison.OrdinalIgnoreCase)) { return "User policy"; }
            return source;
        }
    }

    /// <summary>configuration.json written by -Action Configuration (Get-DeadLoadConfiguration -Trace).</summary>
    internal sealed class ConfigurationSnapshot
    {
        public string EngineVersion;
        public DateTime? CreatedUtc;
        public readonly List<ConfigurationSetting> Settings = new List<ConfigurationSetting>();

        public static ConfigurationSnapshot Load(string path)
        {
            return Parse(Json.ReadShared(path));
        }

        public static ConfigurationSnapshot Parse(string text)
        {
            Dictionary<string, object> root = Json.ParseObject(text);
            var snapshot = new ConfigurationSnapshot();
            snapshot.EngineVersion = Json.Str(root, "engineVersion");
            snapshot.CreatedUtc = Json.Time(Json.Str(root, "createdUtc"));
            foreach (Dictionary<string, object> s in Json.Objects(root, "settings"))
            {
                snapshot.Settings.Add(new ConfigurationSetting
                {
                    Name = Json.Str(s, "name"),
                    Value = Json.Str(s, "value"),
                    Source = Json.Str(s, "source"),
                    Reason = Json.Str(s, "reason"),
                });
            }
            return snapshot;
        }
    }

    /// <summary>One row of the History page: a run report (machine or user) or the user's last cleanup.</summary>
    internal sealed class HistoryEntry
    {
        public DateTime? EndUtc;
        public string Who;
        public string Mode;
        public string Result;
        public long? FreedBytes;
        public long? DeletedCount;
        public long? SkippedCount;
    }

    internal sealed class HistoryLoad
    {
        public readonly List<HistoryEntry> Entries = new List<HistoryEntry>();
        public int Unreadable;
        public int FoldersMissing;
    }

    internal static class HistoryReader
    {
        /// <summary>At most this many run files per folder, newest by name (run ids start with the UTC time).</summary>
        private const int MaxRunsPerFolder = 200;

        public static HistoryLoad Load(string machineRuns, string userRuns, string lastCleanup)
        {
            var load = new HistoryLoad();
            ReadFolder(load, machineRuns, "This computer");
            ReadFolder(load, userRuns, "You");
            if (lastCleanup != null && File.Exists(lastCleanup))
            {
                try
                {
                    CleanupReport report = CleanupReport.Load(lastCleanup);
                    load.Entries.Add(new HistoryEntry
                    {
                        EndUtc = report.EndUtc,
                        Who = "You",
                        Mode = "Cleanup review",
                        Result = report.Result,
                        FreedBytes = report.FreedBytes,
                        DeletedCount = report.DeletedCount,
                        SkippedCount = report.SkippedCount,
                    });
                }
                catch (Exception)
                {
                    load.Unreadable++;
                }
            }
            load.Entries.Sort((a, b) => Nullable.Compare(b.EndUtc, a.EndUtc));
            return load;
        }

        private static void ReadFolder(HistoryLoad load, string folder, string who)
        {
            if (string.IsNullOrEmpty(folder) || !Directory.Exists(folder)) { load.FoldersMissing++; return; }
            string[] files;
            try { files = Directory.GetFiles(folder, "*.json"); }
            catch (Exception) { load.Unreadable++; return; }
            Array.Sort(files, StringComparer.OrdinalIgnoreCase);
            Array.Reverse(files);
            int taken = 0;
            foreach (string file in files)
            {
                if (taken++ >= MaxRunsPerFolder) { break; }
                try
                {
                    LastRunReport run = LastRunReport.Parse(Json.ReadShared(file));
                    load.Entries.Add(FromRun(run, who));
                }
                catch (Exception)
                {
                    load.Unreadable++;
                }
            }
        }

        public static HistoryEntry FromRun(LastRunReport run, string who)
        {
            string mode = run.Mode ?? "-";
            if (run.ReportOnly) { mode += " (report only)"; }
            return new HistoryEntry
            {
                EndUtc = run.EndTimeUtc,
                Who = who,
                Mode = mode,
                Result = run.Result,
                FreedBytes = run.FreedBytes,
                DeletedCount = run.DeletedCount,
                SkippedCount = run.SkippedCount,
            };
        }
    }

    /// <summary>
    /// Category display names from the installed engine's Data\Defaults.psd1 (the same text the
    /// ADMX and the analysis carry), for the machine report, which lists category ids only. The
    /// file is read as text with a pattern, never executed.
    /// </summary>
    internal static class CategoryNames
    {
        private static readonly Regex Entry = new Regex(@"Id\s*=\s*'(?<id>[^']+)'(?<rest>.*?)DisplayName\s*=\s*'(?<name>(?:[^']|'')*)'", RegexOptions.Singleline | RegexOptions.CultureInvariant);
        private static Dictionary<string, string> names;

        public static string Name(string id)
        {
            if (string.IsNullOrEmpty(id)) { return "-"; }
            if (names == null) { names = Load(); }
            string name;
            return names.TryGetValue(id, out name) ? name : id;
        }

        /// <summary>Adds names the window already knows (from an analysis), ahead of the file.</summary>
        public static void Learn(AnalysisDocument analysis)
        {
            if (analysis == null) { return; }
            if (names == null) { names = Load(); }
            foreach (AnalysisCategory c in analysis.Categories)
            {
                if (!string.IsNullOrEmpty(c.DisplayName)) { names[c.Id] = c.DisplayName; }
            }
        }

        private static Dictionary<string, string> Load()
        {
            var map = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            try
            {
                string path = Path.Combine(TrayPaths.InstallRoot, "engine", "DeadLoad", "Data", "Defaults.psd1");
                if (!File.Exists(path)) { return map; }
                string text = File.ReadAllText(path);
                foreach (Match match in Entry.Matches(text))
                {
                    // The next Id begins another category: a name after it is not this one's.
                    if (match.Groups["rest"].Value.Contains("Id =")) { continue; }
                    map[match.Groups["id"].Value] = match.Groups["name"].Value.Replace("''", "'");
                }
            }
            catch (Exception)
            {
                // Without the file the id is shown.
            }
            return map;
        }
    }

    internal static class EngineInfo
    {
        private static readonly Regex VersionPattern = new Regex(@"ModuleVersion\s*=\s*'(?<v>[0-9.]+)'", RegexOptions.CultureInvariant);

        /// <summary>ModuleVersion of the installed engine manifest, or null when it is not there.</summary>
        public static string ModuleVersion()
        {
            try
            {
                string path = Path.Combine(TrayPaths.InstallRoot, "engine", "DeadLoad", "DeadLoad.psd1");
                if (!File.Exists(path)) { return null; }
                Match match = VersionPattern.Match(File.ReadAllText(path));
                return match.Success ? match.Groups["v"].Value : null;
            }
            catch (Exception)
            {
                return null;
            }
        }
    }
}
