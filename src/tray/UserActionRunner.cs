using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace DeadLoad.Tray
{
    /// <summary>The JSON object Invoke-DeadLoadUserAction.ps1 writes to stdout.</summary>
    internal sealed class UserActionResult
    {
        public string Action;
        public string Result;
        public string Message;
        public string Path;
        public long? FreedBytes;
        public int ExitCode;

        public bool Succeeded
        {
            get { return string.Equals(Result, "Success", StringComparison.OrdinalIgnoreCase); }
        }
    }

    /// <summary>
    /// Runs one user action through Windows PowerShell in the user's own context. The action
    /// runs on a worker thread so the tray menu never freezes while a bundle is zipped.
    /// </summary>
    internal static class UserActionRunner
    {
        // Generous: a support bundle on a slow disk can take minutes; a hung run must not leave a
        // hidden powershell.exe behind forever.
        private static readonly TimeSpan Timeout = TimeSpan.FromMinutes(30);

        public static Task<UserActionResult> RunAsync(string action)
        {
            return Task.Run(() => Run(action));
        }

        public static UserActionResult Run(string action)
        {
            string script = TrayPaths.UserActionScript;
            if (!File.Exists(script))
            {
                return Fail(action, "DeadLoad is not fully installed: " + script + " is missing.");
            }

            var info = new ProcessStartInfo
            {
                FileName = TrayPaths.WindowsPowerShell,
                Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\" -Action " + action,
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
                {
                    // Nothing is ever typed into the action; closing stdin stops any prompt waiting.
                    process.StandardInput.Close();
                    Task<string> stdout = process.StandardOutput.ReadToEndAsync();
                    Task<string> stderr = process.StandardError.ReadToEndAsync();
                    if (!process.WaitForExit((int)Timeout.TotalMilliseconds))
                    {
                        try { process.Kill(); } catch (Exception) { }
                        return Fail(action, "The action did not finish within " + (int)Timeout.TotalMinutes + " minutes.");
                    }
                    process.WaitForExit();
                    UserActionResult result = Parse(action, stdout.Result);
                    result.ExitCode = process.ExitCode;
                    if (result.Result == null)
                    {
                        string detail = (stderr.Result ?? string.Empty).Trim();
                        if (detail.Length > 300) { detail = detail.Substring(0, 300); }
                        result.Result = "Failed";
                        result.Message = "The action returned no result" + (detail.Length > 0 ? ": " + detail : ".");
                    }
                    return result;
                }
            }
            catch (Exception ex)
            {
                return Fail(action, "The action could not be started: " + ex.Message);
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
            var serializer = new JavaScriptSerializer();
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
                object freed;
                if (json.TryGetValue("FreedBytes", out freed) && freed != null)
                {
                    try { result.FreedBytes = Convert.ToInt64(freed, System.Globalization.CultureInfo.InvariantCulture); }
                    catch (Exception) { }
                }
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

        private static UserActionResult Fail(string action, string message)
        {
            return new UserActionResult { Action = action, Result = "Failed", Message = message, ExitCode = -1 };
        }
    }
}
