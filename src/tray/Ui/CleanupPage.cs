using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Threading;
using System.Windows.Forms;

namespace DeadLoad.Tray.Ui
{
    internal enum CleanupPhase
    {
        Idle,
        Analyzing,
        Results,
        Review,
        Cleaning,
        Complete,
        Problem,
        Disabled,
    }

    /// <summary>
    /// Analyze, Review, Clean (design system sections 6 and 9; docs/design/ENGINE-UI-CONTRACT.md).
    /// Analyze is report-only and may be canceled. The only Clean button is on the Review view,
    /// behind the confirmation dialog; Restricted and other unavailable categories can never be
    /// selected. Below the user's own cleanup, "This computer" shows the last machine
    /// maintenance and can request one (the SYSTEM task; nothing here elevates).
    /// </summary>
    internal sealed class CleanupPage : Page
    {
        private const string HeaderTitle = "System Cleanup";
        private const string HeaderSubtitle = "Find and review unnecessary files before removing them.";
        private readonly HashSet<string> selected = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private readonly HashSet<string> expanded = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        private CleanupPhase phase = CleanupPhase.Idle;
        private AnalysisDocument analysis;
        private TimeSpan? analysisDuration;
        private CleanupReport cleanup;
        private string note;
        private string problemTitle;
        private string problemMessage;
        private string problemDetail;
        private bool problemAfterClean;
        private CancellationTokenSource analyzeCancel;
        private string requestMessage;
        private bool requestPending;
        private TextBlock selectionLine;
        private ThemedButton reviewButton;

        public CleanupPage(MainWindow window, IWindowBackend backend) : base(window, backend)
        {
            if (!backend.AllowClean) { phase = CleanupPhase.Disabled; }
            backend.MachineReportChanged += OnMachineReportChanged;
        }

        public CleanupPhase Phase { get { return phase; } }

        public override bool Busy
        {
            get { return phase == CleanupPhase.Analyzing || phase == CleanupPhase.Cleaning; }
        }

        public override string Status
        {
            get
            {
                switch (phase)
                {
                    case CleanupPhase.Analyzing: return "Analyzing storage...";
                    case CleanupPhase.Results: return SelectionSummary();
                    case CleanupPhase.Review: return "Reviewing " + SelectionSummary();
                    case CleanupPhase.Cleaning: return "Removing the selected files...";
                    case CleanupPhase.Complete: return "Cleanup complete.";
                    case CleanupPhase.Problem: return problemTitle;
                    case CleanupPhase.Disabled: return "Cleanup is turned off by your administrator.";
                    default: return "Ready. Nothing is removed until you review and confirm.";
                }
            }
        }

        public override void OnShown()
        {
            // Policy may have changed since the window opened (the tray re-reads it every poll).
            bool allowed = Backend.AllowClean;
            if (!allowed && !Busy) { phase = CleanupPhase.Disabled; }
            else if (allowed && phase == CleanupPhase.Disabled) { phase = CleanupPhase.Idle; }
        }

        // ---- state entry points (also used by the render harness with sample data) ----

        public void ShowResults(AnalysisDocument document, TimeSpan? duration)
        {
            analysis = document;
            analysisDuration = duration;
            CategoryNames.Learn(document);
            selected.Clear();
            expanded.Clear();
            foreach (AnalysisCategory c in document.Categories)
            {
                if (c.DefaultSelected && c.Selectable) { selected.Add(c.Id); }
            }
            phase = CleanupPhase.Results;
            Render(false);
        }

        public void ExpandForPreview(string id)
        {
            expanded.Add(id);
            Render(false);
        }

        public void ShowReview()
        {
            if (analysis == null || CountSelected() == 0) { return; }
            phase = CleanupPhase.Review;
            Render(false);
        }

        public void ShowComplete(CleanupReport report)
        {
            cleanup = report;
            phase = CleanupPhase.Complete;
            Render(false);
        }

        public void ShowProblem(string title, string message, string detail, bool afterClean)
        {
            problemTitle = title;
            problemMessage = message;
            problemDetail = detail;
            problemAfterClean = afterClean;
            phase = CleanupPhase.Problem;
            Render(false);
        }

        public void ShowPhase(CleanupPhase value)
        {
            phase = value;
            Render(false);
        }

        // ---- actions ----

        private async void StartAnalyze()
        {
            if (Busy || Backend.IsSample) { return; }
            if (!Backend.AllowClean) { phase = CleanupPhase.Disabled; Render(false); return; }
            note = null;
            phase = CleanupPhase.Analyzing;
            analyzeCancel = new CancellationTokenSource();
            Render(false);
            Stopwatch watch = Stopwatch.StartNew();
            UserActionResult result;
            try
            {
                result = await Backend.AnalyzeAsync(analyzeCancel.Token);
            }
            finally
            {
                analyzeCancel.Dispose();
                analyzeCancel = null;
            }
            watch.Stop();
            if (Window.IsDisposed) { return; }
            HandleAnalyze(result, watch.Elapsed);
        }

        private void HandleAnalyze(UserActionResult result, TimeSpan elapsed)
        {
            if (result.Is(UserActionRunner.Canceled))
            {
                note = "The analysis was canceled. Nothing was changed.";
                phase = CleanupPhase.Idle;
                Render(false);
                return;
            }
            if (result.Is("Disabled"))
            {
                phase = CleanupPhase.Disabled;
                Render(false);
                return;
            }
            AnalysisDocument document = null;
            string error = null;
            if (!string.IsNullOrEmpty(result.Path))
            {
                try { document = Backend.LoadAnalysis(result.Path); }
                catch (Exception ex) { error = "The analysis file could not be read: " + ex.Message; }
            }
            if (result.Is("Failed") || document == null)
            {
                ShowProblem("The analysis failed.", result.Message ?? error ?? "No analysis was written.", result.Stderr, false);
                return;
            }
            ShowResults(document, elapsed);
        }

        private void CancelAnalyze()
        {
            // Safe: Analyze is report-only, and analysis.json is replaced atomically or not at all.
            if (analyzeCancel != null) { analyzeCancel.Cancel(); }
        }

        private async void StartClean()
        {
            if (Busy || analysis == null || Backend.IsSample) { return; }
            List<string> ids = SelectedIds();
            if (ids.Count == 0) { return; }
            long bytes;
            int items;
            int files;
            Totals(out items, out files, out bytes);
            using (var dialog = new ConfirmCleanDialog(files, ids.Count, bytes))
            {
                if (dialog.ShowDialog(Window) != DialogResult.OK) { return; }
            }
            if (!Backend.AllowClean) { phase = CleanupPhase.Disabled; Render(false); return; }
            phase = CleanupPhase.Cleaning;
            Render(false);
            UserActionResult result;
            try
            {
                result = await Backend.CleanAsync(ids, analysis.AnalysisId);
            }
            catch (ArgumentException ex)
            {
                result = new UserActionResult { Action = "Clean", Result = "Refused", Message = "Nothing was deleted: " + ex.Message };
            }
            if (Window.IsDisposed) { return; }
            HandleClean(result);
        }

        private void HandleClean(UserActionResult result)
        {
            if (result.Is("Disabled")) { phase = CleanupPhase.Disabled; Render(false); return; }
            if (result.Is("Refused"))
            {
                // Nothing was deleted and the reviewed list may be stale: offer a new analysis.
                ShowProblem("Nothing was deleted.", WithoutPrefix(result.Message, "Nothing was deleted: "), null, false);
                return;
            }
            CleanupReport report = null;
            if (!string.IsNullOrEmpty(result.Path))
            {
                try { report = Backend.LoadCleanup(result.Path); }
                catch (Exception) { report = null; }
            }
            cleanup = report;
            if (result.Is("Failed"))
            {
                ShowProblem("The cleanup failed.", result.Message, result.Stderr, report != null);
                return;
            }
            if (report == null)
            {
                report = new CleanupReport
                {
                    Result = result.Result,
                    FreedBytes = result.FreedBytes ?? 0,
                    DeletedCount = result.DeletedCount ?? 0,
                    SkippedCount = result.SkippedCount ?? 0,
                    EndUtc = DateTime.UtcNow,
                };
            }
            ShowComplete(report);
        }

        /// <summary>The engine's message without a lead-in the title already says.</summary>
        internal static string WithoutPrefix(string message, string prefix)
        {
            if (string.IsNullOrEmpty(message) || !message.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) { return message; }
            string rest = message.Substring(prefix.Length).Trim();
            return rest.Length == 0 ? message : char.ToUpperInvariant(rest[0]) + rest.Substring(1);
        }

        private void RequestMachineCleanup()
        {
            if (Backend.IsSample) { return; }
            string error = Backend.RequestCleanup();
            if (error == null)
            {
                requestPending = true;
                requestMessage = "Cleanup requested. It runs in the background; this card updates when it finishes.";
            }
            else
            {
                requestPending = false;
                requestMessage = error;
            }
            Render(true);
        }

        private void OnMachineReportChanged(object sender, EventArgs e)
        {
            if (requestPending)
            {
                requestPending = false;
                requestMessage = "The requested cleanup finished.";
            }
            if (!Busy) { Render(true); }
        }

        // ---- selection ----

        private List<string> SelectedIds()
        {
            var ids = new List<string>();
            if (analysis == null) { return ids; }
            foreach (AnalysisCategory c in analysis.Categories)
            {
                // Only rows the engine offered; a Restricted id would be refused as a whole.
                if (selected.Contains(c.Id) && c.Selectable) { ids.Add(c.Id); }
            }
            return ids;
        }

        private int CountSelected()
        {
            return SelectedIds().Count;
        }

        private void Totals(out int items, out int files, out long bytes)
        {
            items = 0;
            files = 0;
            bytes = 0;
            if (analysis == null) { return; }
            foreach (AnalysisCategory c in analysis.Categories)
            {
                if (!selected.Contains(c.Id) || !c.Selectable) { continue; }
                items += c.Items.Count;
                files += c.FileCount;
                bytes += c.EstimatedBytes;
            }
        }

        private string SelectionSummary()
        {
            int items;
            int files;
            long bytes;
            Totals(out items, out files, out bytes);
            int categories = CountSelected();
            if (categories == 0) { return "Nothing selected."; }
            return Format.Count(items, "item", "items") + " selected in " + Format.Count(categories, "category", "categories") + " \u00B7 estimated " + Format.Bytes(bytes);
        }

        private void OnRowChecked(object sender, EventArgs e)
        {
            var row = (CategoryRow)sender;
            if (row.Checked) { selected.Add(row.Category.Id); } else { selected.Remove(row.Category.Id); }
            if (selectionLine != null) { selectionLine.Text = SelectionSummary(); }
            if (reviewButton != null) { reviewButton.Enabled = CountSelected() > 0 && !analysis.ReportOnly; }
            Window.UpdateStatus();
        }

        private void OnRowExpanded(object sender, EventArgs e)
        {
            var row = (CategoryRow)sender;
            if (row.Expanded) { expanded.Add(row.Category.Id); } else { expanded.Remove(row.Category.Id); }
            Window.RelayoutContent();
        }

        // ---- views ----

        public override StackPanel Build()
        {
            selectionLine = null;
            reviewButton = null;
            FocusTarget = null;
            StackPanel root = Views.PageRoot();
            switch (phase)
            {
                case CleanupPhase.Analyzing: BuildAnalyzing(root); break;
                case CleanupPhase.Results: BuildResults(root); break;
                case CleanupPhase.Review: BuildReview(root); break;
                case CleanupPhase.Cleaning: BuildCleaning(root); break;
                case CleanupPhase.Complete: BuildComplete(root); break;
                case CleanupPhase.Problem: BuildProblem(root); break;
                case CleanupPhase.Disabled: BuildDisabled(root); break;
                default: BuildIdle(root); break;
            }
            return root;
        }

        private ThemedButton Button(string text, ButtonKind kind, EventHandler click)
        {
            var button = new ThemedButton(text, kind, true);
            button.Click += click;
            return button;
        }

        private CapacityBar LiveCapacity()
        {
            DiskStatus disk = Backend.ReadDisk();
            return disk == null ? new CapacityBar(TrayPaths.SystemDrive, null, null) : new CapacityBar(disk.Drive, disk.SizeBytes, disk.FreeBytes);
        }

        private void BuildIdle(StackPanel root)
        {
            Views.Header(root, HeaderTitle, HeaderSubtitle);
            if (!string.IsNullOrEmpty(note)) { root.Controls.Add(new Notice(Tone.Info, null, note)); }
            Card card = Views.Card(null);
            card.Controls.Add(LiveCapacity());
            card.Controls.Add(Views.Secondary("Analyze is report-only: it lists what could be removed from your own profile, with sizes and reasons, and removes nothing."));
            var bar = new ButtonBar(false);
            ThemedButton analyze = bar.Add(Button("Analyze Storage", ButtonKind.Primary, (s, e) => StartAnalyze()));
            card.Controls.Add(bar);
            root.Controls.Add(card);
            FocusTarget = analyze;
            root.Controls.Add(MachineCard());
        }

        private void BuildDisabled(StackPanel root)
        {
            Views.Header(root, HeaderTitle, HeaderSubtitle);
            Card card = Views.Card(null);
            card.Controls.Add(new Notice(Tone.Info, "Cleanup is turned off by your administrator.",
                "Analyze and clean are not available on this computer. The scheduled maintenance still runs as your administrator configures it."));
            card.Controls.Add(LiveCapacity());
            root.Controls.Add(card);
            root.Controls.Add(MachineCard());
        }

        private void BuildAnalyzing(StackPanel root)
        {
            Views.Header(root, HeaderTitle, HeaderSubtitle);
            Card card = Views.Card(null);
            card.Controls.Add(new ProgressStrip("Analyzing storage...",
                "Measuring the temporary files, caches and logs in your profile. Nothing is removed during the analysis, so it is safe to cancel."));
            var bar = new ButtonBar(false);
            ThemedButton cancel = bar.Add(Button("Cancel", ButtonKind.Secondary, (s, e) => CancelAnalyze()));
            card.Controls.Add(bar);
            root.Controls.Add(card);
            FocusTarget = cancel;
        }

        private string AnalyzedLine()
        {
            string text = Format.Count(analysis.ItemCount, "item", "items");
            if (analysis.CreatedUtc.HasValue) { text += " \u00B7 analyzed " + Format.TimeOfDay(analysis.CreatedUtc.Value); }
            if (analysisDuration.HasValue) { text += " in " + Math.Max(1, (int)Math.Round(analysisDuration.Value.TotalSeconds)) + " s"; }
            return text;
        }

        private void BuildResults(StackPanel root)
        {
            Views.Header(root, HeaderTitle, HeaderSubtitle);
            if (analysis.ReportOnly)
            {
                root.Controls.Add(new Notice(Tone.Info, "Report-only mode is on.", "Your administrator has set DeadLoad to report only, so nothing can be removed from here. The list shows what a cleanup would find."));
            }
            if (string.Equals(analysis.Result, "Partial", StringComparison.OrdinalIgnoreCase))
            {
                root.Controls.Add(new Notice(Tone.Warning, "The analysis stopped early.", "It reached its time or item limit, so the list shows what was found so far."));
            }

            Card summary = Views.Card(null);
            var capacity = new CapacityBar(analysis.Drive, analysis.SizeBytes, analysis.FreeBytes);
            var bar = new ButtonBar(true);
            if (analysis.ItemCount == 0)
            {
                var empty = new StackPanel { Spacing = ThemeManager.S(4) };
                empty.Controls.Add(Views.Section("No unnecessary files found in the selected locations."));
                empty.Controls.Add(Views.Secondary(analysis.CreatedUtc.HasValue ? "Analyzed " + Format.TimeOfDay(analysis.CreatedUtc.Value) + "." : string.Empty));
                summary.Controls.Add(new Columns(empty, capacity, 0.55f));
                ThemedButton again = bar.Add(Button("Analyze Again", ButtonKind.Secondary, (s, e) => StartAnalyze()));
                summary.Controls.Add(bar);
                FocusTarget = again;
            }
            else
            {
                var metric = new ResultMetric(analysis.EstimatedBytes, "potentially reclaimable", false, AnalyzedLine());
                summary.Controls.Add(new Columns(metric, capacity, 0.55f));
                summary.Controls.Add(new Divider());
                selectionLine = Views.Secondary(SelectionSummary());
                summary.Controls.Add(selectionLine);
                reviewButton = bar.Add(Button("Review Cleanup", ButtonKind.Primary, (s, e) => ShowReview()));
                ThemedButton again = bar.Add(Button("Analyze Again", ButtonKind.Secondary, (s, e) => StartAnalyze()));
                // Right-to-left flow puts the primary rightmost; tab order stays left to right.
                again.TabIndex = 0;
                reviewButton.TabIndex = 1;
                reviewButton.Enabled = CountSelected() > 0 && !analysis.ReportOnly;
                summary.Controls.Add(bar);
                FocusTarget = reviewButton.Enabled ? (Control)reviewButton : again;
            }
            root.Controls.Add(summary);

            var heading = new StackPanel { Spacing = ThemeManager.S(4), Margin = new Padding(0, ThemeManager.S(8), 0, 0) };
            heading.Controls.Add(Views.Section("Categories"));
            heading.Controls.Add(Views.Caption("Routine items start selected. Review items start unselected: removing them can mean a rebuild or a download. Restricted items are managed by your administrator."));
            root.Controls.Add(heading);

            Card list = Views.Card(null);
            list.Padding = new Padding(ThemeManager.S(4));
            list.Spacing = 0;
            bool first = true;
            foreach (AnalysisCategory category in Ordered(analysis.Categories))
            {
                if (!first) { list.Controls.Add(new Divider { Margin = new Padding(ThemeManager.S(16), 0, ThemeManager.S(16), 0) }); }
                first = false;
                var row = new CategoryRow(category, selected.Contains(category.Id));
                if (expanded.Contains(category.Id)) { row.Expanded = true; }
                row.CheckedChanged += OnRowChecked;
                row.ExpandedChanged += OnRowExpanded;
                list.Controls.Add(row);
            }
            root.Controls.Add(list);
            root.Controls.Add(MachineCard());
        }

        /// <summary>Offered rows with items first (Routine, then Review), then empty ones, then unavailable ones.</summary>
        private static IEnumerable<AnalysisCategory> Ordered(List<AnalysisCategory> categories)
        {
            var result = new List<AnalysisCategory>();
            foreach (string risk in new[] { "Routine", "Review" })
            {
                foreach (AnalysisCategory c in categories)
                {
                    if (c.Available && c.Items.Count > 0 && string.Equals(c.Risk, risk, StringComparison.OrdinalIgnoreCase)) { result.Add(c); }
                }
            }
            foreach (AnalysisCategory c in categories)
            {
                if (c.Available && c.Items.Count > 0 && !result.Contains(c)) { result.Add(c); }
            }
            foreach (AnalysisCategory c in categories)
            {
                if (c.Available && c.Items.Count == 0) { result.Add(c); }
            }
            foreach (AnalysisCategory c in categories)
            {
                if (!c.Available) { result.Add(c); }
            }
            return result;
        }

        private void BuildReview(StackPanel root)
        {
            Views.Header(root, "Review cleanup", "Only the files listed here can be removed. A file that is new, changed or in use when the cleanup runs is kept and reported.");
            int items;
            int files;
            long bytes;
            Totals(out items, out files, out bytes);
            List<string> ids = SelectedIds();

            Card summary = Views.Card(null);
            string detail = Format.Count(files, "file", "files") + " in " + Format.Count(ids.Count, "category", "categories");
            summary.Controls.Add(new ResultMetric(bytes, "selected for removal", false, detail));
            summary.Controls.Add(new Divider());
            var facts = new FactList();
            foreach (string id in ids)
            {
                AnalysisCategory c = analysis.Find(id);
                facts.Add(c.DisplayName, Format.Count(c.Items.Count, "item", "items") + " \u00B7 " + Format.Bytes(c.EstimatedBytes), true);
            }
            summary.Controls.Add(facts);
            root.Controls.Add(summary);

            root.Controls.Add(new Notice(Tone.Warning, null, "Deleted files are not moved to the Recycle Bin and cannot be restored by DeadLoad."));

            Card paths = Views.Card("Included paths");
            var table = new ItemTable("Files to remove", 12,
                TableColumn.PathColumn("Path"),
                TableColumn.Text("Category", 150),
                TableColumn.Number("Size", 88),
                TableColumn.Text("Last used", 112),
                TableColumn.Text("Why it is listed", 180));
            foreach (string id in ids)
            {
                AnalysisCategory c = analysis.Find(id);
                foreach (AnalysisItem item in c.Items)
                {
                    table.AddRow(
                        new[] { item.DisplayPath, c.DisplayName, Format.Bytes(item.Bytes), Format.Age(item.LastWriteUtc), item.DisplayReason },
                        new IComparable[] { item.Path, c.DisplayName, item.Bytes, item.LastWriteUtc.HasValue ? (IComparable)item.LastWriteUtc.Value : null, item.ReasonText },
                        item.Path, item.Path);
                }
            }
            paths.Controls.Add(table);
            paths.Controls.Add(Views.Caption("Select rows and press Ctrl+C to copy their paths. Hover a path to see it in full."));
            root.Controls.Add(paths);

            var bar = new ButtonBar(true);
            ThemedButton clean = bar.Add(Button("Clean Selected Items", ButtonKind.Primary, (s, e) => StartClean()));
            ThemedButton back = bar.Add(Button("Back", ButtonKind.Secondary, (s, e) => { phase = CleanupPhase.Results; Render(false); }));
            back.TabIndex = 0;
            clean.TabIndex = 1;
            clean.Enabled = ids.Count > 0 && !analysis.ReportOnly;
            root.Controls.Add(bar);
            FocusTarget = back;
        }

        private void BuildCleaning(StackPanel root)
        {
            Views.Header(root, "Cleaning selected items", "DeadLoad is removing the files you reviewed.");
            Card card = Views.Card(null);
            card.Controls.Add(new ProgressStrip("Removing the selected files...",
                "This cannot be canceled: stopping partway would leave no record of what was already removed. You can keep working or close this window; the cleanup continues and the result is shown when you open DeadLoad again."));
            root.Controls.Add(card);
        }

        private void BuildComplete(StackPanel root)
        {
            CleanupReport report = cleanup ?? new CleanupReport();
            bool reportOnly = string.Equals(report.Result, "ReportOnly", StringComparison.OrdinalIgnoreCase);
            if (reportOnly)
            {
                Views.Header(root, "Nothing was removed.", "Report-only mode is on by policy, so the cleanup only reported what it would remove.");
            }
            else
            {
                Views.Header(root, "Cleanup complete. " + Format.Bytes(report.FreedBytes) + " reclaimed.", null);
            }

            Card summary = Views.Card(null);
            string detail = report.EstimatedBytes > 0 ? "of an estimated " + Format.Bytes(report.EstimatedBytes) : string.Empty;
            if (report.EndUtc.HasValue) { detail += (detail.Length > 0 ? " \u00B7 " : string.Empty) + "finished " + Format.TimeOfDay(report.EndUtc.Value); }
            summary.Controls.Add(new ResultMetric(report.FreedBytes, "reclaimed", true, detail));
            summary.Controls.Add(new Divider());
            var facts = new FactList();
            facts.Add("Deleted", Format.Count(report.DeletedCount, "item", "items"), true);
            facts.Add("Skipped", Format.Count(report.SkippedCount, "item", "items"), true);
            if (report.FailedCount > 0) { facts.Add("Failed", Format.Count(report.FailedCount, "item", "items"), true); }
            summary.Controls.Add(facts);
            var bar = new ButtonBar(false);
            ThemedButton again = bar.Add(Button("Analyze Again", ButtonKind.Secondary, (s, e) => StartAnalyze()));
            bar.Add(Button("Open report", ButtonKind.Secondary, (s, e) => OpenReport()));
            summary.Controls.Add(bar);
            root.Controls.Add(summary);
            FocusTarget = again;

            if (report.Skipped.Count > 0)
            {
                root.Controls.Add(new Notice(Tone.Info, null, "Skipped items were left in place, never forced. Each one is listed with the reason."));
                Card skipped = Views.Card("Skipped items");
                var table = new ItemTable("Skipped items", 10,
                    TableColumn.PathColumn("Path"),
                    TableColumn.Text("Category", 150),
                    TableColumn.Number("Size", 88),
                    TableColumn.Text("Reason", 200));
                foreach (CleanupEntry entry in report.Skipped)
                {
                    string name = CategoryNames.Name(entry.Category);
                    string reason = Format.SkipReason(entry.Reason, entry.ReasonText);
                    table.AddRow(new[] { entry.Path, name, Format.Bytes(entry.Bytes), reason },
                        new IComparable[] { entry.Path, name, entry.Bytes, reason }, entry.Path, entry.Path);
                }
                skipped.Controls.Add(table);
                root.Controls.Add(skipped);
            }
            root.Controls.Add(MachineCard());
        }

        private void BuildProblem(StackPanel root)
        {
            Views.Header(root, HeaderTitle, HeaderSubtitle);
            Card card = Views.Card(null);
            card.Controls.Add(new Notice(Tone.Danger, problemTitle, problemMessage));
            if (!string.IsNullOrEmpty(problemDetail))
            {
                card.Controls.Add(Views.Caption("Technical details"));
                card.Controls.Add(Views.Raw(problemDetail, 120));
            }
            var bar = new ButtonBar(false);
            ThemedButton again = bar.Add(Button("Analyze Again", ButtonKind.Primary, (s, e) => StartAnalyze()));
            if (problemAfterClean) { bar.Add(Button("Open report", ButtonKind.Secondary, (s, e) => OpenReport())); }
            card.Controls.Add(bar);
            root.Controls.Add(card);
            FocusTarget = again;
            root.Controls.Add(MachineCard());
        }

        private void OpenReport()
        {
            Window.Details.UserFirst = true;
            Window.ShowPage(PageId.Details);
        }

        private Card MachineCard()
        {
            Card card = Views.Card("This computer");
            card.Controls.Add(Views.Secondary("Scheduled maintenance cleans machine-wide locations, such as the Windows temporary folder, as your administrator configures. Those categories are not selectable here."));
            string error;
            LastRunReport run = Backend.LoadLastRun(out error);
            var facts = new FactList();
            if (run == null)
            {
                facts.Add("Last maintenance", error ?? "No cleanup has run yet.", false);
            }
            else
            {
                string when = run.EndTimeUtc.HasValue ? Format.TimeOfDay(run.EndTimeUtc.Value) : "-";
                string result = run.Result ?? "-";
                if (run.ReportOnly) { result += " (report only)"; }
                facts.Add("Last maintenance", result + " \u00B7 " + when, false);
                facts.Add("Recovered", run.FreedBytes.HasValue ? Format.Bytes(run.FreedBytes.Value) : "-", true);
                if (run.SkippedCount.HasValue && run.SkippedCount.Value > 0) { facts.Add("Skipped", Format.Count(run.SkippedCount.Value, "item", "items"), true); }
            }
            card.Controls.Add(facts);
            if (!string.IsNullOrEmpty(requestMessage))
            {
                card.Controls.Add(new Notice(requestPending ? Tone.Info : (requestMessage.StartsWith("The requested", StringComparison.Ordinal) ? Tone.Success : Tone.Warning), null, requestMessage));
            }
            if (Backend.AllowRequestCleanup)
            {
                var bar = new ButtonBar(false);
                ThemedButton request = bar.Add(new ThemedButton("Request a cleanup", ButtonKind.Secondary, false));
                request.Click += (s, e) => RequestMachineCleanup();
                request.Enabled = !requestPending;
                card.Controls.Add(bar);
            }
            return card;
        }
    }
}
