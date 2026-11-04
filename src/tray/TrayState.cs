using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

namespace DeadLoad.Tray
{
    /// <summary>
    /// What the tray has already told the user, kept in %LOCALAPPDATA%\DeadLoad\tray-state.json
    /// so a sign-in, a crash or a restart does not repeat the same balloon.
    /// </summary>
    internal sealed class TrayState
    {
        public DateTime? LastLowDiskNotificationUtc;
        public string LastSeenEndTime;

        private readonly string path;

        private TrayState(string path)
        {
            this.path = path;
        }

        public static TrayState Load(string path)
        {
            var state = new TrayState(path);
            try
            {
                if (!File.Exists(path)) { return state; }
                var json = new JavaScriptSerializer().DeserializeObject(File.ReadAllText(path, Encoding.UTF8)) as Dictionary<string, object>;
                if (json == null) { return state; }
                object value;
                DateTime parsed;
                if (json.TryGetValue("LastLowDiskNotificationUtc", out value) && value is string &&
                    DateTime.TryParse((string)value, CultureInfo.InvariantCulture,
                        DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out parsed))
                {
                    state.LastLowDiskNotificationUtc = DateTime.SpecifyKind(parsed, DateTimeKind.Utc);
                }
                if (json.TryGetValue("LastSeenEndTime", out value) && value is string)
                {
                    state.LastSeenEndTime = (string)value;
                }
            }
            catch (Exception)
            {
                // A corrupt state file only costs one repeated notification; start clean.
            }
            return state;
        }

        public void Save()
        {
            try
            {
                var data = new Dictionary<string, object>
                {
                    { "SchemaVersion", 1 },
                    { "LastLowDiskNotificationUtc", LastLowDiskNotificationUtc.HasValue ? LastLowDiskNotificationUtc.Value.ToString("o", CultureInfo.InvariantCulture) : null },
                    { "LastSeenEndTime", LastSeenEndTime },
                };
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                // Write then replace so a crash mid-write never leaves a half file behind.
                string temp = path + ".tmp";
                File.WriteAllText(temp, new JavaScriptSerializer().Serialize(data), new UTF8Encoding(false));
                if (File.Exists(path)) { File.Replace(temp, path, null); }
                else { File.Move(temp, path); }
            }
            catch (Exception)
            {
                // Losing the state is harmless beyond one repeated balloon.
            }
        }
    }
}
