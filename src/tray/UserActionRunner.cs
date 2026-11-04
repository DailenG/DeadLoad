using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace DeadLoad.Tray
{
    /// <summary>
    /// The JSON object Invoke-DeadLoadUserAction.ps1 writes to stdout
    /// (docs/design/ENGINE-UI-CONTRACT.md section 2). Every action's fields are lifted out; a
    /// field the action does not have stays null.
    /// </summary>
    internal sealed class UserActionResult
    {
        public string Action;
        public string Result;
        public string Message;
        public string Path;
        public long? FreedBytes;
        public string AnalysisId;
        public long? EstimatedBytes;
        public long? ItemCount;
        public long? DeletedCount;
        public long? SkippedCount;
        public string EngineVersion;
        public int ExitCode;
        /// <summary>stderr of the run (cut to 2000 characters), for the Details of a failure.</summary>
        public string Stderr;

        public bool Succeeded
        {
            get { return string.Equals(Result, "Success", StringComparison.OrdinalIgnoreCase); }
        }

        public bool Is(string result)
        {
            return string.Equals(Result, result, StringComparison.OrdinalIgnoreCase);
        }
    }

    /// <summary>
    /// Runs one user action through Windows PowerShell in the user's own context. The action
    /// runs on a worker thread so the tray menu and the DeadLoad window never freeze.
    /// </summary>
    internal static class UserActionRunner
    {
        // Generous: a support bundle on a slow disk, or a large temp folder to enumerate, can take
        // minutes; a hung run must not leave a hidden powershell.exe behind forever.
        private static readonly TimeSpan Timeout = TimeSpan.FromMinutes(30);

        /// <summary>Result of a run the window canceled (Analyze only; it is report-only).</summary>
        public const string Canceled = "Canceled";

        public static Task<UserActionResult> RunAsync(string action)
        {
            return RunAsync(action, null, CancellationToken.None);
        }

        /// <summary>
        /// Runs the action with extra arguments (already validated and quoted by the caller).
        /// Canceling kills the process; only report-only actions may be canceled.
        /// </summary>
        public static Task<UserActionResult> RunAsync(string action, string arguments, CancellationToken token)
        {
            return Task.Run(() => Run(action, arguments, token));
        }

        public static UserActionResult Run(string action)
        {
            return Run(action, null, CancellationToken.None);
        }

        public static UserActionResult Run(string action, string arguments, CancellationToken token)
        {
            string script = TrayPaths.UserActionScript;
            if (!File.Exists(script))
            {
                return Fail(action, "DeadLoad is not fully installed: " + script + " is missing.");
            }

            var info = new ProcessStartInfo
            {
                FileName = TrayPaths.WindowsPowerShell,
                Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\" -Action " + action +
                    (string.IsNullOrEmpty(arguments) ? string.Empty : " " + arguments),
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                RedirectStandardInput = true,
                // The script escapes non-ASCII as \uXXXX, so ASCII is exact whatever the OEM code page.
                StandardOutputEncoding = Encoding.ASCII,
                StandardErrorEncoding = Encoding.Default,
                WorkingDirectory = TrayPaths.InstallRoot,
            };

            try
            {
                using (var process = Process.Start(info))
                using (token.Register(() => Kill(process)))
                {
                    // Nothing is ever typed into the action; closing stdin stops any prompt waiting.
                    process.StandardInput.Close();
                    Task<string> stdout = process.StandardOutput.ReadToEndAsync();
                    Task<string> stderr = process.StandardError.ReadToEndAsync();
                    if (!process.WaitForExit((int)Timeout.TotalMilliseconds))
                    {
                        Kill(process);
                        return Fail(action, "The action did not finish within " + (int)Timeout.TotalMinutes + " minutes.");
                    }
                    process.WaitForExit();
                    if (token.IsCancellationRequested)
                    {
                        return new UserActionResult { Action = action, Result = Canceled, Message = "Canceled.", ExitCode = -1 };
                    }
                    UserActionResult result = Parse(action, stdout.Result);
                    result.ExitCode = process.ExitCode;
                    string detail = (stderr.Result ?? string.Empty).Trim();
                    if (detail.Length > 2000) { detail = detail.Substring(0, 2000); }
                    result.Stderr = detail.Length > 0 ? detail : null;
                    if (result.Result == null)
                    {
                        string shortDetail = detail.Length > 300 ? detail.Substring(0, 300) : detail;
                        result.Result = "Failed";
                        result.Message = "The action returned no result" + (shortDetail.Length > 0 ? ": " + shortDetail : ".");
                    }
                    return result;
                }
            }
            catch (Exception ex)
            {
                return Fail(action, "The action could not be started: " + ex.Message);
            }
        }

        private static void Kill(Process process)
        {
            try
            {
                if (!process.HasExited) { process.Kill(); }
            }
            catch (Exception)
            {
                // Already gone.
            }
        }

        /// <summary>
        /// Takes the last line that parses as a JSON object: the script writes exactly one, and
        /// anything else on stdout (a host banner, a stray warning) must not break the result.
        /// </summary>
        internal static UserActionResult Parse(string action, string stdout)
        {
            var result = new UserActionResult { Action = action };
            if (string.IsNullOrEmpty(stdout)) { return result; }
            var serializer = new JavaScriptSerializer { MaxJsonLength = 16 * 1024 * 1024 };
            string[] lines = stdout.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries);
            for (int i = lines.Length - 1; i >= 0; i--)
            {
                string line = lines[i].Trim();
                if (!line.StartsWith("{", StringComparison.Ordinal)) { continue; }
                Dictionary<string, object> json;
                try { json = serializer.DeserializeObject(line) as Dictionary<string, object>; }
                catch (Exception) { continue; }
                if (json == null) { continue; }
                result.Action = Text(json, "Action") ?? action;
                result.Result = Text(json, "Result");
                result.Message = Text(json, "Message");
                result.Path = Text(json, "Path");
                result.FreedBytes = Number(json, "FreedBytes");
                result.AnalysisId = Text(json, "AnalysisId");
                result.EstimatedBytes = Number(json, "EstimatedBytes");
                result.ItemCount = Number(json, "ItemCount");
                result.DeletedCount = Number(json, "DeletedCount");
                result.SkippedCount = Number(json, "SkippedCount");
                result.EngineVersion = Text(json, "EngineVersion");
                return result;
            }
            return result;
        }

        private static string Text(Dictionary<string, object> json, string name)
        {
            object value;
            if (!json.TryGetValue(name, out value) || value == null) { return null; }
            return Convert.ToString(value, System.Globalization.CultureInfo.InvariantCulture);
        }

        private static long? Number(Dictionary<string, object> json, string name)
        {
            object value;
            if (!json.TryGetValue(name, out value) || value == null) { return null; }
            try { return Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture); }
            catch (Exception) { return null; }
        }

        private static UserActionResult Fail(string action, string message)
        {
            return new UserActionResult { Action = action, Result = "Failed", Message = message, ExitCode = -1 };
        }
    }
}
