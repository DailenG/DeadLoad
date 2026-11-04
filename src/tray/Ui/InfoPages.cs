using System;
using System.Diagnostics;
using System.Globalization;
using System.Windows.Forms;

namespace DeadLoad.Tray.Ui
{
    /// <summary>
    /// Details: the machine's last maintenance per category (last-run.json) and the user's last
    /// cleanup (last-cleanup.json), each with its raw report behind a "Show raw report" button.
    /// </summary>
    internal sealed class DetailsPage : Page
    {
        private LastRunReport machine;
        private string machineError;
        private CleanupReport user;
        private string userError;
        private bool showMachineRaw;
        private bool showUserRaw;
        private bool loaded;

        public DetailsPage(MainWindow window, IWindowBackend backend) : base(window, backend)
        {
        }

        /// <summary>Set by "Open report": the user's own cleanup comes first.</summary>
        public bool UserFirst { get; set; }

        public override string Status
        {
            get { return machine != null && machine.EndTimeUtc.HasValue ? "Last maintenance " + Format.TimeOfDay(machine.EndTimeUtc.Value) + "." : "No maintenance report."; }
        }

        public override void OnShown()
        {
            Reload();
        }

        public void Reload()
        {
            machine = Backend.LoadLastRun(out machineError);
            user = Backend.LoadLastCleanup(out userError);
            loaded = true;
        }

        public void SetRawVisible(bool machineRaw, bool userRaw)
        {
            showMachineRaw = machineRaw;
            showUserRaw = userRaw;
        }

        public override StackPanel Build()
        {
            if (!loaded) { Reload(); }
            FocusTarget = null;
            StackPanel root = Views.PageRoot();
            Views.Header(root, "Details", "What the last runs found and did, per category. Recovered sizes are what the engine confirmed deleted.");
            if (UserFirst)
            {
                root.Controls.Add(UserCard());
                root.Controls.Add(MachineCard());
            }
            else
            {
                root.Controls.Add(MachineCard());
                root.Controls.Add(UserCard());
            }
            return root;
        }

        private Card MachineCard()
        {
            Card card = Views.Card("This computer's last maintenance");
            if (machine == null)
            {
                card.Controls.Add(Views.Secondary(machineError ?? "No cleanup has run yet."));
                return card;
            }
            var facts = new FactList();
            facts.Add("Result", machine.Result + (string.IsNullOrEmpty(machine.Reason) ? string.Empty : " (" + machine.Reason + ")"), false);
            facts.Add("Finished", Format.Local(machine.EndTimeUtc), false);
            facts.Add("Mode", (machine.Mode ?? "-") + (machine.ReportOnly ? " (report only)" : string.Empty), false);
            facts.Add("Recovered", machine.FreedBytes.HasValue ? Format.Bytes(machine.FreedBytes.Value) : "-", true);
            facts.Add("Items deleted, skipped, failed",
                Count(machine.DeletedCount) + ", " + Count(machine.SkippedCount) + ", " + Count(machine.FailedCount), true);
            if (machine.SizeBytes.HasValue && machine.FreeBytesAfter.HasValue)
            {
                facts.Add("Free space after", Format.Bytes(machine.FreeBytesAfter.Value) + " of " + Format.Bytes(machine.SizeBytes.Value), true);
            }
            facts.Add("Engine version", machine.Version, false);
            card.Controls.Add(facts);

            if (machine.Categories.Count > 0)
            {
                card.Controls.Add(Views.Section("Per category"));
                var table = new ItemTable("Categories of the last maintenance", 16,
                    TableColumn.FillColumn("Category"),
                    TableColumn.Text("Result", 140),
                    TableColumn.Number("Items found", 96),
                    TableColumn.Number("Recovered", 96),
                    TableColumn.Number("Skipped", 80));
                foreach (RunCategory c in machine.Categories)
                {
                    string name = CategoryNames.Name(c.Id);
                    string outcome = c.Outcome(machine.ReportOnly);
                    table.AddRow(
                        new[] { name, outcome, Format.Number(c.CandidateCount), Format.Bytes(c.FreedBytes), Format.Number(c.SkippedCount) },
                        new IComparable[] { name, outcome, c.CandidateCount, c.FreedBytes, c.SkippedCount },
                        name + " (" + c.Id + ")", c.Id);
                }
                card.Controls.Add(table);
            }
            AddRawToggle(card, machine.RawJson, showMachineRaw, value => showMachineRaw = value);
            return card;
        }

        private Card UserCard()
        {
            Card card = Views.Card("Your last cleanup");
            if (user == null)
            {
                card.Controls.Add(Views.Secondary(userError ?? "You have not cleaned anything from this window yet."));
                return card;
            }
            var facts = new FactList();
            facts.Add("Result", user.Result + (string.IsNullOrEmpty(user.Reason) ? string.Empty : " (" + user.Reason + ")"), false);
            facts.Add("Finished", Format.Local(user.EndUtc), false);
            facts.Add("Recovered", Format.Bytes(user.FreedBytes) + " of an estimated " + Format.Bytes(user.EstimatedBytes), true);
            facts.Add("Items deleted, skipped, failed", Format.Number(user.DeletedCount) + ", " + Format.Number(user.SkippedCount) + ", " + Format.Number(user.FailedCount), true);
            var names = new System.Collections.Generic.List<string>();
            foreach (string id in user.Categories) { names.Add(CategoryNames.Name(id)); }
            facts.Add("Categories", string.Join(", ", names.ToArray()), false);
            card.Controls.Add(facts);

            if (user.Deleted.Count + user.Skipped.Count > 0)
            {
                var table = new ItemTable("Items of your last cleanup", 12,
                    TableColumn.PathColumn("Path"),
                    TableColumn.Text("Outcome", 96),
                    TableColumn.Number("Size", 88),
                    TableColumn.Text("Reason", 180));
                foreach (CleanupEntry e in user.Deleted)
                {
                    table.AddRow(new[] { e.Path, "Deleted", Format.Bytes(e.Bytes), string.Empty },
                        new IComparable[] { e.Path, "Deleted", e.Bytes, string.Empty }, e.Path, e.Path);
                }
                foreach (CleanupEntry e in user.Skipped)
                {
                    string reason = Format.SkipReason(e.Reason, e.ReasonText);
                    table.AddRow(new[] { e.Path, "Skipped", Format.Bytes(e.Bytes), reason },
                        new IComparable[] { e.Path, "Skipped", e.Bytes, reason }, e.Path, e.Path);
                }
                card.Controls.Add(table);
            }
            AddRawToggle(card, user.RawJson, showUserRaw, value => showUserRaw = value);
            return card;
        }

        private void AddRawToggle(Card card, string raw, bool visible, Action<bool> set)
        {
            var bar = new ButtonBar(false);
            ThemedButton toggle = bar.Add(new ThemedButton(visible ? "Hide raw report" : "Show raw report", ButtonKind.Secondary, false));
            toggle.AccessibleDescription = "Shows the report file as the engine wrote it.";
            toggle.Click += (s, e) =>
            {
                set(!visible);
                FocusTarget = null;
                Render(true);
            };
            card.Controls.Add(bar);
            if (visible) { card.Controls.Add(Views.Raw(raw, 280)); }
        }

        private static string Count(long? value)
        {
            return value.HasValue ? Format.Number(value.Value) : "-";
        }
    }

    /// <summary>History: every run report kept (machine and the user's own), newest first.</summary>
    internal sealed class HistoryPage : Page
    {
        private HistoryLoad load;
        private bool loading;

        public HistoryPage(MainWindow window, IWindowBackend backend) : base(window, backend)
        {
        }

        public override string Status
        {
            get { return load == null ? string.Empty : Format.Count(load.Entries.Count, "run", "runs") + " listed."; }
        }

        public override void OnShown()
        {
            Load();
        }

        public async void Load()
        {
            if (loading) { return; }
            loading = true;
            try
            {
                load = await Backend.LoadHistoryAsync();
            }
            catch (Exception)
            {
                load = new HistoryLoad { Unreadable = 1 };
            }
            finally
            {
                loading = false;
            }
            if (!Window.IsDisposed) { Render(true); }
        }

        public void SetLoaded(HistoryLoad value)
        {
            load = value;
            loading = false;
        }

        public override StackPanel Build()
        {
            FocusTarget = null;
            StackPanel root = Views.PageRoot();
            Views.Header(root, "History", "What was analyzed and cleaned on this computer, newest first. Recovered is what the engine confirmed deleted.");
            Card card = Views.Card(null);
            if (load == null)
            {
                card.Controls.Add(new ProgressStrip("Reading the run history...", null));
            }
            else if (load.Entries.Count == 0)
            {
                card.Controls.Add(new Notice(Tone.Info, "No runs are recorded yet.", "Runs appear here after the scheduled maintenance or your own cleanup has run."));
            }
            else
            {
                var table = new ItemTable("Run history", 18,
                    TableColumn.Text("When", 140),
                    TableColumn.Text("Who", 104),
                    TableColumn.FillColumn("Mode"),
                    TableColumn.Text("Result", 84),
                    TableColumn.Number("Recovered", 88),
                    TableColumn.Number("Deleted", 70),
                    TableColumn.Number("Skipped", 70));
                // Every column here is short text; the mode needs no more room than the others.
                table.MinFillShare = 0.15;
                foreach (HistoryEntry e in load.Entries)
                {
                    table.AddRow(
                        new[]
                        {
                            Format.Local(e.EndUtc), e.Who, e.Mode ?? "-", e.Result ?? "-",
                            e.FreedBytes.HasValue ? Format.Bytes(e.FreedBytes.Value) : "-",
                            e.DeletedCount.HasValue ? Format.Number(e.DeletedCount.Value) : "-",
                            e.SkippedCount.HasValue ? Format.Number(e.SkippedCount.Value) : "-",
                        },
                        new IComparable[]
                        {
                            e.EndUtc.HasValue ? (IComparable)e.EndUtc.Value : null, e.Who, e.Mode, e.Result,
                            e.FreedBytes ?? -1L, e.DeletedCount ?? -1L, e.SkippedCount ?? -1L,
                        },
                        Format.Local(e.EndUtc) + " " + e.Who + " " + e.Mode + " " + e.Result, null);
                }
                card.Controls.Add(table);
            }
            if (load != null && load.Unreadable > 0)
            {
                card.Controls.Add(Views.Caption(Format.Count(load.Unreadable, "report", "reports") + " could not be read and " + (load.Unreadable == 1 ? "is" : "are") + " not listed."));
            }
            root.Controls.Add(card);
            return root;
        }
    }

    /// <summary>Settings: the effective configuration, read-only, with where each value comes from.</summary>
    internal sealed class SettingsPage : Page
    {
        private ConfigurationSnapshot snapshot;
        private string error;
        private bool loading;

        public SettingsPage(MainWindow window, IWindowBackend backend) : base(window, backend)
        {
        }

        public override bool Busy { get { return false; } }

        public override string Status
        {
            get
            {
                if (snapshot == null) { return string.Empty; }
                int ignored = snapshot.Settings.FindAll(s => s.Ignored).Count;
                return Format.Count(snapshot.Settings.Count - ignored, "setting", "settings") + " read; settings are managed by Group Policy.";
            }
        }

        public override void OnShown()
        {
            if (snapshot == null && error == null) { Load(); }
        }

        public void SetSnapshot(ConfigurationSnapshot value)
        {
            snapshot = value;
            error = null;
            loading = false;
        }

        private async void Load()
        {
            if (loading || Backend.IsSample) { return; }
            loading = true;
            error = null;
            Render(false);
            UserActionResult result = await Backend.ConfigurationAsync();
            loading = false;
            if (Window.IsDisposed) { return; }
            if (!string.IsNullOrEmpty(result.Path) && !result.Is("Failed"))
            {
                try { snapshot = Backend.LoadConfiguration(result.Path); }
                catch (Exception ex) { error = "The configuration file could not be read: " + ex.Message; }
            }
            else
            {
                error = result.Message ?? "The configuration could not be read.";
            }
            Render(false);
        }

        public override StackPanel Build()
        {
            FocusTarget = null;
            StackPanel root = Views.PageRoot();
            Views.Header(root, "Settings", "Settings are managed by your administrator through Group Policy.");
            Card card = Views.Card(null);
            card.Controls.Add(Views.Secondary("The effective configuration of this computer: the value DeadLoad uses and where it comes from (Policy, User policy, Local or Default). Nothing here can be changed."));
            if (loading)
            {
                card.Controls.Add(new ProgressStrip("Reading the effective configuration...", null));
            }
            else if (error != null)
            {
                card.Controls.Add(new Notice(Tone.Danger, "The configuration could not be read.", error));
            }
            else if (snapshot != null)
            {
                int policy = 0;
                int ignored = 0;
                var table = new ItemTable("Effective configuration", 18,
                    TableColumn.Text("Section", 180),
                    TableColumn.Text("Setting", 190),
                    TableColumn.Text("Value", 120),
                    TableColumn.FillColumn("Source"));
                // Section and setting names matter as much as the source here.
                table.MinFillShare = 0.25;
                int order = 0;
                foreach (ConfigurationSetting s in snapshot.Settings)
                {
                    if (s.Ignored) { ignored++; }
                    else if (string.Equals(s.Source, "Policy", StringComparison.OrdinalIgnoreCase) || string.Equals(s.Source, "UserPolicy", StringComparison.OrdinalIgnoreCase)) { policy++; }
                    string value = s.Value ?? "(not set)";
                    table.AddRow(new[] { s.Section, s.Setting, value, s.SourceText },
                        new IComparable[] { order.ToString("D6", CultureInfo.InvariantCulture), s.Setting, value, s.SourceText },
                        s.Name + " = " + value + " (" + s.SourceText + ")", s.Name);
                    order++;
                }
                card.Controls.Add(table);
                string summary = Format.Count(snapshot.Settings.Count - ignored, "setting", "settings") + " \u00B7 " + Format.Number(policy) + " set by policy";
                if (ignored > 0) { summary += " \u00B7 " + Format.Count(ignored, "value", "values") + " ignored as invalid"; }
                if (snapshot.CreatedUtc.HasValue) { summary += " \u00B7 read " + Format.TimeOfDay(snapshot.CreatedUtc.Value); }
                card.Controls.Add(Views.Caption(summary));
            }
            var bar = new ButtonBar(false);
            ThemedButton refresh = bar.Add(new ThemedButton("Refresh", ButtonKind.Secondary, false));
            refresh.Enabled = !loading;
            refresh.Click += (s, e) => Load();
            card.Controls.Add(bar);
            root.Controls.Add(card);
            return root;
        }
    }

    internal sealed class AboutPage : Page
    {
        public const string RepositoryUrl = "https://github.com/DailenG/DeadLoad";

        public AboutPage(MainWindow window, IWindowBackend backend) : base(window, backend)
        {
        }

        public override StackPanel Build()
        {
            FocusTarget = null;
            Palette p = ThemeManager.Palette;
            StackPanel root = Views.PageRoot();
            Views.Header(root, "About", null);
            Card card = Views.Card(null);
            card.Spacing = ThemeManager.S(8);
            card.Controls.Add(new BrandMark(ThemeManager.S(64)));
            card.Controls.Add(new TextBlock("DeadLoad", ThemeManager.Semibold(FontRole.Display, ThemeTokens.FontSizeAppHeadlinePx), p.Heading, false));
            string engine = Backend.EngineVersion;
            card.Controls.Add(Views.Secondary("Version " + MainWindow.VersionText() + " \u00B7 engine " + (engine ?? "not found")));
            card.Controls.Add(Views.Body("A transparent Windows cleanup utility that helps identify and remove unnecessary files without putting engineering work at risk."));
            card.Controls.Add(new Divider());
            var facts = new FactList();
            facts.Add("License", "GPL-3.0 (GNU General Public License, version 3)", false);
            facts.Add("Privacy", "No telemetry is collected.", false);
            card.Controls.Add(facts);
            var link = new LinkLabel
            {
                Text = RepositoryUrl,
                AutoSize = true,
                Font = ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppBodyPx),
                TabStop = true,
                AccessibleName = "Source code on GitHub",
                Margin = Padding.Empty,
            };
            if (!p.IsHighContrast)
            {
                link.LinkColor = p.Link;
                link.ActiveLinkColor = p.AccentPressed;
                link.VisitedLinkColor = p.Link;
            }
            link.LinkClicked += (s, e) => OpenRepository();
            card.Controls.Add(Views.Caption("Source code"));
            card.Controls.Add(link);
            root.Controls.Add(card);
            return root;
        }

        private void OpenRepository()
        {
            if (Backend.IsSample) { return; }
            try
            {
                Process.Start(new ProcessStartInfo(RepositoryUrl) { UseShellExecute = true });
            }
            catch (Exception)
            {
                // No browser registered: the address is on screen to copy.
            }
        }
    }
}
