using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace DeadLoad.Tray
{
    /// <summary>
    /// Read-only view of %ProgramData%\DeadLoad\last-run.json (ARCHITECTURE section 10). Only the
    /// fields the tray shows are lifted out; the raw text is kept for the report window.
    /// </summary>
    internal sealed class LastRunReport
    {
        public string RawJson;
        public string Result;
        public string Reason;
        public string Mode;
        public string Version;
        public string Computer;
        public string EndTimeText;
        public DateTime? EndTimeUtc;
        public double? DurationSeconds;
        public bool ReportOnly;
        public string Drive;
        public long? SizeBytes;
        public long? FreeBytesBefore;
        public long? FreeBytesAfter;
        public long? FloorBytes;
        public bool? TargetReached;
        public long? FreedBytes;
        public long? DeletedCount;
        public long? SkippedCount;
        public long? FailedCount;
        /// <summary>Per category: what the run found and did (ARCHITECTURE section 10).</summary>
        public readonly List<RunCategory> Categories = new List<RunCategory>();

        /// <summary>The report, or null when it is absent or unreadable (the tray just shows "no run yet").</summary>
        public static LastRunReport TryLoad(string path, out string error)
        {
            error = null;
            try
            {
                if (!File.Exists(path))
                {
                    error = "No cleanup has run yet.";
                    return null;
                }
                // The engine may be rewriting the file; share it so the read never blocks a run.
                string text;
                using (var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
                using (var reader = new StreamReader(stream, Encoding.UTF8, true))
                {
                    text = reader.ReadToEnd();
                }
                return Parse(text);
            }
            catch (Exception ex)
            {
                error = "The last report could not be read: " + ex.Message;
                return null;
            }
        }

        public static LastRunReport Parse(string text)
        {
            var serializer = new JavaScriptSerializer { MaxJsonLength = 64 * 1024 * 1024 };
            var root = serializer.DeserializeObject(text) as Dictionary<string, object>;
            if (root == null) { throw new FormatException("The report is not a JSON object."); }

            var report = new LastRunReport { RawJson = text };
            report.Result = Str(root, "Result");
            report.Reason = Str(root, "Reason");
            report.Mode = Str(root, "Mode");
            report.Version = Str(root, "Version");
            report.Computer = Str(root, "Computer");
            report.EndTimeText = Str(root, "EndTime");
            report.EndTimeUtc = Time(report.EndTimeText);
            report.DurationSeconds = Dbl(root, "DurationSeconds");
            report.ReportOnly = Bool(root, "ReportOnly") == true;

            var volume = Obj(root, "Volume");
            if (volume != null)
            {
                report.Drive = Str(volume, "Drive");
                report.SizeBytes = Lng(volume, "SizeBytes");
                report.FreeBytesBefore = Lng(volume, "FreeBytesBefore");
                report.FreeBytesAfter = Lng(volume, "FreeBytesAfter");
                report.FloorBytes = Lng(volume, "FloorBytes");
                report.TargetReached = Bool(volume, "TargetReached");
            }
            var totals = Obj(root, "Totals");
            if (totals != null)
            {
                report.FreedBytes = Lng(totals, "FreedBytes");
                report.DeletedCount = Lng(totals, "DeletedCount");
                report.SkippedCount = Lng(totals, "SkippedCount");
                report.FailedCount = Lng(totals, "FailedCount");
            }
            object categories;
            if (root.TryGetValue("Categories", out categories) && categories is System.Collections.IEnumerable && !(categories is string))
            {
                foreach (object item in (System.Collections.IEnumerable)categories)
                {
                    var c = item as Dictionary<string, object>;
                    if (c == null || Str(c, "Id") == null) { continue; }
                    report.Categories.Add(new RunCategory
                    {
                        Id = Str(c, "Id"),
                        Enabled = Bool(c, "Enabled") != false,
                        CandidateCount = Lng(c, "CandidateCount") ?? 0,
                        CandidateBytes = Lng(c, "CandidateBytes") ?? 0,
                        ActedCount = Lng(c, "ActedCount") ?? 0,
                        FreedBytes = Lng(c, "FreedBytes") ?? 0,
                        SkippedCount = Lng(c, "SkippedCount") ?? 0,
                        FailedCount = Lng(c, "FailedCount") ?? 0,
                    });
                }
            }
            return report;
        }

        /// <summary>The key fields as label/value pairs, in the order the report window shows them.</summary>
        public List<KeyValuePair<string, string>> Summary()
        {
            var rows = new List<KeyValuePair<string, string>>();
            rows.Add(Row("Result", Result + (string.IsNullOrEmpty(Reason) ? string.Empty : " (" + Reason + ")")));
            rows.Add(Row("Finished", EndTimeUtc.HasValue ? EndTimeUtc.Value.ToLocalTime().ToString("g", CultureInfo.CurrentCulture) : EndTimeText));
            rows.Add(Row("Mode", Mode + (ReportOnly ? " (report only)" : string.Empty)));
            rows.Add(Row("Duration", DurationSeconds.HasValue ? DurationSeconds.Value.ToString("0", CultureInfo.CurrentCulture) + " s" : null));
            rows.Add(Row("Drive", Drive));
            rows.Add(Row("Free before", Bytes(FreeBytesBefore)));
            rows.Add(Row("Free after", Bytes(FreeBytesAfter)));
            rows.Add(Row("Disk size", Bytes(SizeBytes)));
            rows.Add(Row("Floor", Bytes(FloorBytes)));
            rows.Add(Row("Target reached", TargetReached.HasValue ? (TargetReached.Value ? "Yes" : "No") : null));
            rows.Add(Row("Freed", Bytes(FreedBytes)));
            rows.Add(Row("Items deleted", Count(DeletedCount)));
            rows.Add(Row("Items skipped", Count(SkippedCount)));
            rows.Add(Row("Items failed", Count(FailedCount)));
            rows.Add(Row("Engine version", Version));
            rows.Add(Row("Computer", Computer));
            return rows;
        }

        public static string Bytes(long? bytes)
        {
            if (!bytes.HasValue) { return null; }
            return FormatBytes(bytes.Value);
        }

        public static string FormatBytes(long bytes)
        {
            const double kb = 1024.0;
            if (bytes >= kb * kb * kb) { return (bytes / (kb * kb * kb)).ToString("0.0", CultureInfo.CurrentCulture) + " GB"; }
            if (bytes >= kb * kb) { return (bytes / (kb * kb)).ToString("0.0", CultureInfo.CurrentCulture) + " MB"; }
            if (bytes >= kb) { return (bytes / kb).ToString("0", CultureInfo.CurrentCulture) + " KB"; }
            return bytes.ToString(CultureInfo.CurrentCulture) + " bytes";
        }

        private static string Count(long? value)
        {
            return value.HasValue ? value.Value.ToString("N0", CultureInfo.CurrentCulture) : null;
        }

        private static KeyValuePair<string, string> Row(string label, string value)
        {
            return new KeyValuePair<string, string>(label, string.IsNullOrEmpty(value) ? "-" : value);
        }

        private static Dictionary<string, object> Obj(Dictionary<string, object> parent, string name)
        {
            object value;
            return parent.TryGetValue(name, out value) ? value as Dictionary<string, object> : null;
        }

        private static string Str(Dictionary<string, object> parent, string name)
        {
            object value;
            if (!parent.TryGetValue(name, out value) || value == null) { return null; }
            return Convert.ToString(value, CultureInfo.InvariantCulture);
        }

        private static long? Lng(Dictionary<string, object> parent, string name)
        {
            object value;
            if (!parent.TryGetValue(name, out value) || value == null) { return null; }
            try { return Convert.ToInt64(value, CultureInfo.InvariantCulture); }
            catch (Exception) { return null; }
        }

        private static double? Dbl(Dictionary<string, object> parent, string name)
        {
            object value;
            if (!parent.TryGetValue(name, out value) || value == null) { return null; }
            try { return Convert.ToDouble(value, CultureInfo.InvariantCulture); }
            catch (Exception) { return null; }
        }

        private static bool? Bool(Dictionary<string, object> parent, string name)
        {
            object value;
            if (!parent.TryGetValue(name, out value) || value == null) { return null; }
            if (value is bool) { return (bool)value; }
            return null;
        }

        private static DateTime? Time(string text)
        {
            DateTime parsed;
            if (string.IsNullOrEmpty(text)) { return null; }
            if (DateTime.TryParse(text, CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out parsed))
            {
                return DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
            }
            return null;
        }
    }
}

namespace DeadLoad.Tray
{
    /// <summary>One entry of last-run.json Categories.</summary>
    internal sealed class RunCategory
    {
        public string Id;
        public bool Enabled;
        public long CandidateCount;
        public long CandidateBytes;
        public long ActedCount;
        public long FreedBytes;
        public long SkippedCount;
        public long FailedCount;

        /// <summary>The outcome in words, for the Details table.</summary>
        public string Outcome(bool reportOnly)
        {
            if (!Enabled) { return "Turned off"; }
            if (FailedCount > 0) { return ActedCount > 0 ? "Partly failed" : "Failed"; }
            if (CandidateCount == 0) { return "Nothing to clean"; }
            if (reportOnly) { return "Report only"; }
            if (ActedCount > 0 && SkippedCount > 0) { return "Partly cleaned"; }
            if (ActedCount > 0) { return "Cleaned"; }
            return SkippedCount > 0 ? "Skipped" : "Nothing done";
        }
    }
}
