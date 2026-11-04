using System;
using System.Collections.Generic;
using Microsoft.Win32;

namespace DeadLoad.Tray
{
    /// <summary>
    /// Effective tray settings: machine policy, then user policy, then the local key the package
    /// writes, then the built-in defaults. Mirrors the engine's reader and the user action
    /// script: an invalid value in one layer is ignored so the next layer wins.
    /// </summary>
    internal sealed class TraySettings
    {
        internal const string MachinePolicyKey = @"SOFTWARE\Policies\DeadLoad\Tray";
        internal const string UserPolicyKey = @"SOFTWARE\Policies\DeadLoad\Tray";
        internal const string LocalKey = @"SOFTWARE\DeadLoad\Tray";

        // Defaults from the settings contract (Data\Defaults.psd1 Tray section).
        public bool ShowTray = true;
        public bool AllowCleanTemp = true;
        public bool AllowRequestCleanup = true;
        public bool AllowCollectLogs = true;
        public bool LowDiskNotifications = true;
        public int NotifyBelowGB = 10;
        public int NotifyBelowPercent = 10;
        public bool NotifyOnCompletion = false;
        public string SupportShare = string.Empty;
        public int CollectDays = 7;
        public int CleanTempMinAgeDays = 1;

        /// <summary>Name to source (Policy, UserPolicy, Local, Default) for the self-test and diagnostics.</summary>
        public readonly Dictionary<string, string> Sources = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

        private sealed class Layer
        {
            public string Source;
            public Dictionary<string, object> Values;
        }

        public static TraySettings Load()
        {
            var layers = new List<Layer>
            {
                new Layer { Source = "Policy", Values = ReadKey(RegistryHive.LocalMachine, MachinePolicyKey) },
                new Layer { Source = "UserPolicy", Values = ReadKey(RegistryHive.CurrentUser, UserPolicyKey) },
                new Layer { Source = "Local", Values = ReadKey(RegistryHive.LocalMachine, LocalKey) },
            };
            return Resolve(layers);
        }

        private static TraySettings Resolve(List<Layer> layers)
        {
            var s = new TraySettings();
            s.ShowTray = ResolveBool(layers, s.Sources, "ShowTray", s.ShowTray);
            s.AllowCleanTemp = ResolveBool(layers, s.Sources, "AllowCleanTemp", s.AllowCleanTemp);
            s.AllowRequestCleanup = ResolveBool(layers, s.Sources, "AllowRequestCleanup", s.AllowRequestCleanup);
            s.AllowCollectLogs = ResolveBool(layers, s.Sources, "AllowCollectLogs", s.AllowCollectLogs);
            s.LowDiskNotifications = ResolveBool(layers, s.Sources, "LowDiskNotifications", s.LowDiskNotifications);
            s.NotifyBelowGB = ResolveInt(layers, s.Sources, "NotifyBelowGB", s.NotifyBelowGB, 0, 100000);
            s.NotifyBelowPercent = ResolveInt(layers, s.Sources, "NotifyBelowPercent", s.NotifyBelowPercent, 0, 90);
            s.NotifyOnCompletion = ResolveBool(layers, s.Sources, "NotifyOnCompletion", s.NotifyOnCompletion);
            s.SupportShare = ResolveString(layers, s.Sources, "SupportShare", s.SupportShare);
            s.CollectDays = ResolveInt(layers, s.Sources, "CollectDays", s.CollectDays, 1, 365);
            s.CleanTempMinAgeDays = ResolveInt(layers, s.Sources, "CleanTempMinAgeDays", s.CleanTempMinAgeDays, 0, 365);
            return s;
        }

        /// <summary>
        /// The free-space threshold in bytes: the larger of the GB and percent values, so a small
        /// disk is not judged by a fixed GB figure alone and a large one not by percent alone.
        /// </summary>
        public long LowDiskThresholdBytes(long volumeSizeBytes)
        {
            long byGb = (long)NotifyBelowGB * 1024L * 1024L * 1024L;
            long byPercent = (long)(volumeSizeBytes * (NotifyBelowPercent / 100.0));
            return Math.Max(byGb, byPercent);
        }

        private static Dictionary<string, object> ReadKey(RegistryHive hive, string subKey)
        {
            var values = new Dictionary<string, object>(StringComparer.OrdinalIgnoreCase);
            // The 64-bit view so HKLM\SOFTWARE\DeadLoad is the key the installer wrote even if
            // this process were ever started as 32-bit.
            RegistryView view = Environment.Is64BitOperatingSystem ? RegistryView.Registry64 : RegistryView.Default;
            try
            {
                using (RegistryKey root = RegistryKey.OpenBaseKey(hive, view))
                using (RegistryKey key = root.OpenSubKey(subKey, false))
                {
                    if (key == null) { return values; }
                    foreach (string name in key.GetValueNames())
                    {
                        values[name] = key.GetValue(name);
                    }
                }
            }
            catch (Exception)
            {
                // A key the user cannot read is treated as absent; the next layer applies.
            }
            return values;
        }

        private static bool TryInt(object raw, out int value)
        {
            value = 0;
            if (raw == null) { return false; }
            if (raw is int) { value = (int)raw; return true; }
            return int.TryParse(Convert.ToString(raw, System.Globalization.CultureInfo.InvariantCulture).Trim(),
                System.Globalization.NumberStyles.Integer, System.Globalization.CultureInfo.InvariantCulture, out value);
        }

        private static bool ResolveBool(List<Layer> layers, Dictionary<string, string> sources, string name, bool fallback)
        {
            foreach (Layer layer in layers)
            {
                object raw;
                int number;
                if (!layer.Values.TryGetValue(name, out raw)) { continue; }
                if (!TryInt(raw, out number) || (number != 0 && number != 1)) { continue; }
                sources[name] = layer.Source;
                return number == 1;
            }
            sources[name] = "Default";
            return fallback;
        }

        private static int ResolveInt(List<Layer> layers, Dictionary<string, string> sources, string name, int fallback, int min, int max)
        {
            foreach (Layer layer in layers)
            {
                object raw;
                int number;
                if (!layer.Values.TryGetValue(name, out raw)) { continue; }
                if (!TryInt(raw, out number) || number < min || number > max) { continue; }
                sources[name] = layer.Source;
                return number;
            }
            sources[name] = "Default";
            return fallback;
        }

        private static string ResolveString(List<Layer> layers, Dictionary<string, string> sources, string name, string fallback)
        {
            foreach (Layer layer in layers)
            {
                object raw;
                if (!layer.Values.TryGetValue(name, out raw) || raw == null) { continue; }
                if (raw is string[]) { continue; }
                sources[name] = layer.Source;
                return Convert.ToString(raw, System.Globalization.CultureInfo.InvariantCulture).Trim();
            }
            sources[name] = "Default";
            return fallback;
        }
    }
}
