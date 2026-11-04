using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace DeadLoad.Tray.Ui
{
    /// <summary>The sample JSON files embedded in the exe (src/tray/Samples; marked as samples inside).</summary>
    internal static class Samples
    {
        public static string Read(string name)
        {
            using (Stream stream = typeof(Samples).Assembly.GetManifestResourceStream("Samples." + name))
            {
                if (stream == null) { throw new FileNotFoundException("Embedded sample not found: " + name); }
                using (var reader = new StreamReader(stream, Encoding.UTF8, true))
                {
                    return reader.ReadToEnd();
                }
            }
        }
    }

    /// <summary>
    /// Backend of the render harness: sample reports only. It never starts a user action, the
    /// on-demand task or a browser; every such call throws or does nothing.
    /// </summary>
    internal sealed class SampleBackend : IWindowBackend
    {
        public bool IsSample { get { return true; } }
        public bool AllowClean { get { return true; } }
        public bool AllowRequestCleanup { get { return true; } }
        public string EngineVersion { get { return "0.1.0"; } }

        public event EventHandler MachineReportChanged
        {
            add { }
            remove { }
        }

        public DiskStatus ReadDisk()
        {
            AnalysisDocument sample = AnalysisDocument.Parse(Samples.Read("analysis.json"));
            return new DiskStatus { Drive = sample.Drive, SizeBytes = sample.SizeBytes ?? 0, FreeBytes = sample.FreeBytes ?? 0 };
        }

        public Task<UserActionResult> AnalyzeAsync(CancellationToken token) { throw Refuse(); }
        public Task<UserActionResult> CleanAsync(IList<string> categories, string analysisId) { throw Refuse(); }
        public Task<UserActionResult> ConfigurationAsync() { throw Refuse(); }
        public AnalysisDocument LoadAnalysis(string path) { throw Refuse(); }
        public CleanupReport LoadCleanup(string path) { throw Refuse(); }
        public ConfigurationSnapshot LoadConfiguration(string path) { throw Refuse(); }

        public CleanupReport LoadLastCleanup(out string error)
        {
            error = null;
            return CleanupReport.Parse(Samples.Read("last-cleanup.json"));
        }

        public LastRunReport LoadLastRun(out string error)
        {
            error = null;
            return LastRunReport.Parse(Samples.Read("last-run.json"));
        }

        public Task<HistoryLoad> LoadHistoryAsync()
        {
            return Task.FromResult(SampleHistory());
        }

        public static HistoryLoad SampleHistory()
        {
            var load = new HistoryLoad();
            LastRunReport run = LastRunReport.Parse(Samples.Read("last-run.json"));
            CleanupReport cleanup = CleanupReport.Parse(Samples.Read("last-cleanup.json"));
            load.Entries.Add(new HistoryEntry { EndUtc = cleanup.EndUtc, Who = "You", Mode = "Cleanup review", Result = cleanup.Result, FreedBytes = cleanup.FreedBytes, DeletedCount = cleanup.DeletedCount, SkippedCount = cleanup.SkippedCount });
            load.Entries.Add(new HistoryEntry { EndUtc = cleanup.StartUtc.Value.AddSeconds(-3), Who = "You", Mode = "User (report only)", Result = "Success", FreedBytes = 0, DeletedCount = 0, SkippedCount = 0 });
            load.Entries.Add(HistoryReader.FromRun(run, "This computer"));
            // Invented earlier runs (sample data): a quiet week of scheduled maintenance.
            for (int day = 1; day <= 6; day++)
            {
                load.Entries.Add(new HistoryEntry
                {
                    EndUtc = run.EndTimeUtc.Value.AddDays(-day),
                    Who = "This computer",
                    Mode = day == 3 ? "PressureCheck" : "Maintenance",
                    Result = day == 5 ? "Skipped" : "Success",
                    FreedBytes = day == 5 ? 0 : 52428800L * day,
                    DeletedCount = day == 5 ? 0 : 20 + day,
                    SkippedCount = day % 2,
                });
            }
            load.Unreadable = 1;
            return load;
        }

        public string RequestCleanup()
        {
            return "Samples never start the cleanup task.";
        }

        private static InvalidOperationException Refuse()
        {
            return new InvalidOperationException("The render harness never runs an action or reads a real file.");
        }
    }

    /// <summary>
    /// --render-samples &lt;outdir&gt;: builds every view and state from the embedded samples in
    /// light and dark (plus the high contrast code path), at 100 and 150 percent, and saves PNGs
    /// with DrawToBitmap. 150 percent is the window's own scale factor at 1.5 (what a 144 DPI
    /// monitor gives it), applied at 96 DPI. Nothing is analyzed or cleaned.
    /// </summary>
    internal static class RenderHarness
    {
        private const int Width96 = 1000;
        private const int Height96 = 700;

        public static int Run(string outDir)
        {
            Directory.CreateDirectory(outDir);
            Format.FixedNowUtc = new DateTime(2026, 11, 4, 17, 0, 0, DateTimeKind.Utc);
            ThemeManager.ForceReducedMotion = true;
            var written = new List<string>();
            var backend = new SampleBackend();
            foreach (ThemeMode mode in new[] { ThemeMode.Light, ThemeMode.Dark })
            {
                foreach (float scale in new[] { 1f, 1.5f })
                {
                    RenderSet(backend, mode, scale, outDir, written, false);
                }
            }
            // The high contrast path (system colors, standard buttons). With high contrast off the
            // system colors are the ordinary ones, so this shows the layout, not a contrast theme.
            RenderSet(backend, ThemeMode.HighContrast, 1f, outDir, written, true);
            File.WriteAllLines(Path.Combine(outDir, "index.txt"), written.ToArray());
            return 0;
        }

        private static void RenderSet(SampleBackend backend, ThemeMode mode, float scale, string outDir, List<string> written, bool subset)
        {
            ThemeManager.ForcedMode = mode;
            ThemeManager.RenderScale = scale;
            string suffix = "-" + mode.ToString().ToLowerInvariant() + "-" + (int)Math.Round(scale * 100);
            var analysis = AnalysisDocument.Parse(Samples.Read("analysis.json"));
            var cleanup = CleanupReport.Parse(Samples.Read("last-cleanup.json"));
            var configuration = ConfigurationSnapshot.Parse(Samples.Read("configuration.json"));
            using (var window = new MainWindow(backend, 96))
            {
                window.StartPosition = FormStartPosition.Manual;
                window.Location = new Point(-30000, -30000);
                window.ShowInTaskbar = false;
                window.ClientSize = new Size(ThemeManager.S(Width96), ThemeManager.S(Height96));
                window.Show();
                Pump();
                CleanupPage page = window.Cleanup;

                window.ShowPage(PageId.Cleanup);
                page.ShowPhase(CleanupPhase.Idle);
                Save(window, outDir, "01-cleanup-idle" + suffix, written);
                page.ShowPhase(CleanupPhase.Analyzing);
                Save(window, outDir, "02-cleanup-analyzing" + suffix, written);
                page.ShowResults(analysis, TimeSpan.FromSeconds(3));
                Save(window, outDir, "03-cleanup-results" + suffix, written);
                if (!subset)
                {
                    page.ExpandForPreview("user.temp");
                    Save(window, outDir, "04-cleanup-results-expanded" + suffix, written);
                    page.ShowResults(GuardedVariant(), TimeSpan.FromSeconds(41));
                    Save(window, outDir, "05-cleanup-results-partial-guarded" + suffix, written);
                    page.ShowResults(EmptyVariant(), TimeSpan.FromSeconds(2));
                    Save(window, outDir, "06-cleanup-results-empty" + suffix, written);
                }
                page.ShowResults(analysis, TimeSpan.FromSeconds(3));
                page.ShowReview();
                Save(window, outDir, "07-cleanup-review" + suffix, written);
                SaveDialog(outDir, "08-confirm-dialog" + suffix, written);
                page.ShowPhase(CleanupPhase.Cleaning);
                Save(window, outDir, "09-cleanup-cleaning" + suffix, written);
                page.ShowComplete(cleanup);
                Save(window, outDir, "10-cleanup-complete" + suffix, written);
                if (!subset)
                {
                    UserActionResult refused = UserActionRunner.Parse("Clean", Samples.Read("clean-refused-changed.json"));
                    page.ShowProblem("Nothing was deleted.", CleanupPage.WithoutPrefix(refused.Message, "Nothing was deleted: "), null, false);
                    Save(window, outDir, "11-cleanup-refused" + suffix, written);
                    page.ShowPhase(CleanupPhase.Disabled);
                    Save(window, outDir, "12-cleanup-disabled" + suffix, written);
                }
                window.Details.UserFirst = false;
                window.ShowPage(PageId.Details);
                Save(window, outDir, "13-details" + suffix, written);
                if (!subset)
                {
                    window.Details.SetRawVisible(true, false);
                    window.ShowPage(PageId.Cleanup);
                    window.ShowPage(PageId.Details);
                    Save(window, outDir, "13b-details-raw" + suffix, written);
                    window.Details.SetRawVisible(false, false);
                }
                window.ShowPage(PageId.History);
                Save(window, outDir, "14-history" + suffix, written);
                window.SettingsView.SetSnapshot(configuration);
                window.ShowPage(PageId.Settings);
                Save(window, outDir, "15-settings" + suffix, written);
                window.ShowPage(PageId.About);
                Save(window, outDir, "16-about" + suffix, written);

                if (!subset && scale == 1f)
                {
                    window.ShowPage(PageId.Cleanup);
                    page.ShowResults(analysis, TimeSpan.FromSeconds(3));
                    window.ClientSize = new Size(ThemeManager.S(760), ThemeManager.S(Height96));
                    Pump();
                    Save(window, outDir, "17-cleanup-results-narrow" + suffix, written);
                }
                window.Close();
            }
        }

        /// <summary>Sample variant: the scan stopped early and a running Revit held temp files back.</summary>
        private static AnalysisDocument GuardedVariant()
        {
            AnalysisDocument doc = AnalysisDocument.Parse(Samples.Read("analysis.json"));
            doc.Result = "Partial";
            AnalysisCategory temp = doc.Find("user.temp");
            temp.GuardedMessage = "Revit is running in this session, so 12 of its temporary files (38.0 MB) are skipped.";
            temp.GuardedItemCount = 12;
            return doc;
        }

        /// <summary>Sample variant: nothing to clean anywhere.</summary>
        private static AnalysisDocument EmptyVariant()
        {
            AnalysisDocument doc = AnalysisDocument.Parse(Samples.Read("analysis.json"));
            foreach (AnalysisCategory c in doc.Categories)
            {
                c.Items.Clear();
                c.EstimatedBytes = 0;
                c.ItemCount = 0;
            }
            doc.ItemCount = 0;
            doc.EstimatedBytes = 0;
            return doc;
        }

        private static void Pump()
        {
            for (int i = 0; i < 5; i++)
            {
                Application.DoEvents();
                Thread.Sleep(10);
            }
        }

        /// <summary>
        /// One full-length capture: the rail, the whole page (not only the part in the viewport)
        /// and the footer, so a reviewer sees every state top to bottom.
        /// </summary>
        private static void Save(MainWindow window, string outDir, string name, List<string> written)
        {
            Pump();
            Control rail = window.ClientParts[0];
            Control page = window.PageView;
            Control footer = window.FooterControl;
            int viewport = window.ClientSize.Height;
            int content = Math.Max(page.Height, viewport - footer.Height);
            int height = content + footer.Height;
            int width = window.ClientSize.Width;
            using (var bitmap = new Bitmap(width, height, PixelFormat.Format32bppArgb))
            {
                using (Graphics g = Graphics.FromImage(bitmap))
                {
                    g.Clear(ThemeManager.Palette.Canvas);
                    using (var railBrush = new SolidBrush(ThemeManager.Palette.RailBack))
                    {
                        g.FillRectangle(railBrush, 0, 0, rail.Width, height);
                    }
                }
                rail.DrawToBitmap(bitmap, new Rectangle(0, 0, rail.Width, rail.Height));
                page.DrawToBitmap(bitmap, new Rectangle(rail.Width, 0, page.Width, page.Height));
                footer.DrawToBitmap(bitmap, new Rectangle(rail.Width, height - footer.Height, footer.Width, footer.Height));
                string path = Path.Combine(outDir, name + ".png");
                bitmap.Save(path, ImageFormat.Png);
                int preferred = page.GetPreferredSize(new Size(page.Width, 0)).Height;
                written.Add(name + ".png " + width + "x" + height + " page=" + page.Width + "x" + page.Height + " preferred=" + preferred +
                    (preferred != page.Height ? " MISMATCH" : string.Empty) +
                    " viewport=" + page.Parent.ClientSize.Width + "x" + page.Parent.ClientSize.Height +
                    " vscroll=" + ((ScrollableControl)page.Parent).VerticalScroll.Visible +
                    " hscroll=" + ((ScrollableControl)page.Parent).HorizontalScroll.Visible);
            }
        }

        private static void SaveDialog(string outDir, string name, List<string> written)
        {
            // Totals of the sample's preselected rows: user.temp (3 files) and autodesk.cer (one folder, 2 files).
            using (var dialog = new ConfirmCleanDialog(5, 2, 6299648))
            {
                dialog.StartPosition = FormStartPosition.Manual;
                dialog.Location = new Point(-30000, -30000);
                dialog.Show();
                Pump();
                using (var bitmap = new Bitmap(dialog.Width, dialog.Height, PixelFormat.Format32bppArgb))
                {
                    dialog.DrawToBitmap(bitmap, new Rectangle(0, 0, dialog.Width, dialog.Height));
                    bitmap.Save(Path.Combine(outDir, name + ".png"), ImageFormat.Png);
                    written.Add(name + ".png " + dialog.Width + "x" + dialog.Height);
                }
                dialog.Close();
            }
        }
    }
}
