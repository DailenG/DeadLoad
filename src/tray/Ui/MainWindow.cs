using System;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DeadLoad.Tray.Ui
{
    /// <summary>A page of the window: long-lived state, a view rebuilt from it on demand.</summary>
    internal abstract class Page
    {
        protected Page(MainWindow window, IWindowBackend backend)
        {
            Window = window;
            Backend = backend;
        }

        protected MainWindow Window { get; private set; }

        protected IWindowBackend Backend { get; private set; }

        /// <summary>Builds the view for the current state (called again after every theme or DPI change).</summary>
        public abstract StackPanel Build();

        /// <summary>The control that should take focus after the view changed state (null: keep).</summary>
        public Control FocusTarget { get; protected set; }

        /// <summary>One line for the window's status footer.</summary>
        public virtual string Status { get { return string.Empty; } }

        /// <summary>An action is running that must not be interrupted by closing the window.</summary>
        public virtual bool Busy { get { return false; } }

        /// <summary>The page was navigated to: refresh what it reads from disk.</summary>
        public virtual void OnShown()
        {
        }

        protected void Render(bool keepScroll)
        {
            Window.RenderPage(this, keepScroll);
        }
    }

    /// <summary>Shared building blocks for page views.</summary>
    internal static class Views
    {
        public static StackPanel PageRoot()
        {
            var root = new StackPanel
            {
                Padding = new Padding(ThemeManager.S(32), ThemeManager.S(24), ThemeManager.S(32), ThemeManager.S(32)),
                Spacing = ThemeManager.S(16),
                BackColor = ThemeManager.Palette.Canvas,
            };
            return root;
        }

        public static void Header(StackPanel root, string title, string subtitle)
        {
            var block = new StackPanel { Spacing = ThemeManager.S(4), Margin = new Padding(0, 0, 0, ThemeManager.S(4)) };
            var heading = new TextBlock(title, ThemeManager.Semibold(FontRole.Display, ThemeTokens.FontSizeAppPageTitlePx), ThemeManager.Palette.Heading, true);
            heading.AccessibleRole = AccessibleRole.StaticText;
            block.Controls.Add(heading);
            if (!string.IsNullOrEmpty(subtitle))
            {
                block.Controls.Add(new TextBlock(subtitle, ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppBodyPx), ThemeManager.Palette.TextSecondary, true));
            }
            root.Controls.Add(block);
        }

        public static TextBlock Section(string text)
        {
            return new TextBlock(text, ThemeManager.Semibold(FontRole.Text, ThemeTokens.FontSizeAppSubtitlePx), ThemeManager.Palette.TextPrimary, true);
        }

        public static TextBlock Body(string text)
        {
            return new TextBlock(text, ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppBodyPx), ThemeManager.Palette.TextPrimary, true);
        }

        public static TextBlock Secondary(string text)
        {
            return new TextBlock(text, ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppBodyPx), ThemeManager.Palette.TextSecondary, true);
        }

        public static TextBlock Caption(string text)
        {
            return new TextBlock(text, ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppCaptionPx), ThemeManager.Palette.TextSecondary, true);
        }

        public static Card Card(string title)
        {
            var card = new Card();
            if (!string.IsNullOrEmpty(title)) { card.Controls.Add(Section(title)); }
            return card;
        }

        /// <summary>Read-only monospaced text (raw JSON, technical detail), themed scroll bars.</summary>
        public static TextBox Raw(string text, int height)
        {
            Palette p = ThemeManager.Palette;
            var box = new TextBox
            {
                Multiline = true,
                ReadOnly = true,
                ScrollBars = ScrollBars.Both,
                WordWrap = false,
                Font = ThemeManager.Font(FontRole.Mono, 13),
                Text = (text ?? string.Empty).Replace("\r\n", "\n").Replace("\n", "\r\n"),
                Height = ThemeManager.S(height),
                BorderStyle = BorderStyle.FixedSingle,
                AccessibleName = "Raw report",
            };
            if (!p.IsHighContrast)
            {
                box.BackColor = p.Canvas;
                box.ForeColor = p.TextPrimary;
            }
            return box;
        }
    }

    /// <summary>
    /// Two children side by side (a share of the width each), stacked when the window is narrow.
    /// </summary>
    internal sealed class Columns : Control
    {
        private readonly Control left;
        private readonly Control right;
        private readonly float leftShare;

        public Columns(Control left, Control right, float leftShare)
        {
            this.left = left;
            this.right = right;
            this.leftShare = leftShare;
            SetStyle(ControlStyles.Selectable, false);
            TabStop = false;
            Margin = Padding.Empty;
            Controls.Add(left);
            Controls.Add(right);
        }

        private int Gap { get { return ThemeManager.S(32); } }

        private bool Stacked(int width)
        {
            return width < ThemeManager.S(640);
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            int width = proposedSize.Width > 0 ? proposedSize.Width : ThemeManager.S(720);
            if (Stacked(width))
            {
                return new Size(width, StackPanel.PreferredHeight(left, width) + ThemeManager.S(16) + StackPanel.PreferredHeight(right, width));
            }
            int lw = (int)((width - Gap) * leftShare);
            int rw = width - Gap - lw;
            return new Size(width, Math.Max(StackPanel.PreferredHeight(left, lw), StackPanel.PreferredHeight(right, rw)));
        }

        protected override void OnLayout(LayoutEventArgs levent)
        {
            int width = Width;
            if (Stacked(width))
            {
                int lh = StackPanel.PreferredHeight(left, width);
                left.SetBounds(0, 0, width, lh);
                right.SetBounds(0, lh + ThemeManager.S(16), width, StackPanel.PreferredHeight(right, width));
                return;
            }
            int lw = (int)((width - Gap) * leftShare);
            int rw = width - Gap - lw;
            left.SetBounds(0, 0, lw, StackPanel.PreferredHeight(left, lw));
            int rh = StackPanel.PreferredHeight(right, rw);
            // The right column (the capacity bar) sits on the left column's bottom line.
            int top = Math.Max(0, StackPanel.PreferredHeight(left, lw) - rh);
            right.SetBounds(lw + Gap, top, rw, rh);
        }
    }

    /// <summary>
    /// The DeadLoad window: native title bar with the brand icon, the left navigation rail, the
    /// page, and a status footer. One instance; the tray shows it again instead of opening a
    /// second. Theme (light, dark, high contrast) follows Windows and is re-read whenever the
    /// user's preferences change; a DPI change rebuilds the view at the new scale.
    /// </summary>
    internal sealed class MainWindow : Form
    {
        private readonly IWindowBackend backend;
        private readonly Dictionary<PageId, Page> pages = new Dictionary<PageId, Page>();
        private readonly bool sample;
        private NavRail rail;
        private ScrollHost host;
        private Panel footer;
        private TextBlock footerLeft;
        private TextBlock footerRight;
        private Panel right;
        private Page current;
        private int dpi;
        private ThemeMode mode;
        private bool subscribed;

        public MainWindow(IWindowBackend backend, int? fixedDpi)
        {
            this.backend = backend;
            sample = backend.IsSample;
            dpi = fixedDpi.HasValue ? fixedDpi.Value : DeviceDpi;
            mode = ThemeManager.Detect();
            ThemeManager.Apply(mode, dpi);

            Text = sample ? "DeadLoad (sample data)" : "DeadLoad";
            // The window scales itself (ThemeManager.S and pixel fonts); WinForms must not scale again.
            AutoScaleMode = AutoScaleMode.None;
            StartPosition = FormStartPosition.CenterScreen;
            ShowInTaskbar = true;
            KeyPreview = true;
            Icon icon = BrandMark.LoadIcon(0);
            if (icon != null) { Icon = icon; }

            pages[PageId.Cleanup] = new CleanupPage(this, backend);
            pages[PageId.Details] = new DetailsPage(this, backend);
            pages[PageId.History] = new HistoryPage(this, backend);
            pages[PageId.Settings] = new SettingsPage(this, backend);
            pages[PageId.About] = new AboutPage(this, backend);
            current = pages[PageId.Cleanup];

            BuildChrome(true);
            if (!sample)
            {
                SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;
                subscribed = true;
            }
        }

        public CleanupPage Cleanup { get { return (CleanupPage)pages[PageId.Cleanup]; } }

        public DetailsPage Details { get { return (DetailsPage)pages[PageId.Details]; } }

        public SettingsPage SettingsView { get { return (SettingsPage)pages[PageId.Settings]; } }

        /// <summary>The client area parts (rail, page with footer), for the render harness.</summary>
        public Control[] ClientParts { get { return new Control[] { rail, right }; } }

        /// <summary>The current page view (full height, inside the scrolling host).</summary>
        public Control PageView { get { return host.Content; } }

        public Control FooterControl { get { return footer; } }

        private void BuildChrome(bool initial)
        {
            SuspendLayout();
            Palette p = ThemeManager.Palette;
            if (!initial)
            {
                // Keep the window's outer size in proportion when the scale changes.
                Controls.Clear();
                if (rail != null) { rail.Dispose(); }
                if (right != null) { right.Dispose(); }
            }
            BackColor = p.Canvas;
            MinimumSize = new Size(ThemeManager.S(760), ThemeManager.S(540));
            if (initial) { ClientSize = new Size(ThemeManager.S(1000), ThemeManager.S(700)); }

            right = new Panel { Dock = DockStyle.Fill, BackColor = p.Canvas };
            host = new ScrollHost { Dock = DockStyle.Fill, BackColor = p.Canvas, TabStop = false };
            footer = new Panel { Dock = DockStyle.Bottom, Height = ThemeManager.S(36), BackColor = p.Card };
            footer.Paint += (sender, e) =>
            {
                using (var pen = new Pen(ThemeManager.Palette.Border)) { e.Graphics.DrawLine(pen, 0, 0, footer.Width, 0); }
            };
            Font footerFont = ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppCaptionPx);
            footerLeft = new TextBlock(string.Empty, footerFont, p.TextSecondary, false) { BackColor = footer.BackColor };
            string version = "DeadLoad " + VersionText();
            if (sample) { version = "Sample data \u00B7 " + version; }
            footerRight = new TextBlock(version, footerFont, p.TextMuted, false) { BackColor = footer.BackColor, AlignRight = true };
            footer.Controls.Add(footerLeft);
            footer.Controls.Add(footerRight);
            footer.Resize += (sender, e) => LayoutFooter();
            right.Controls.Add(host);
            right.Controls.Add(footer);

            rail = new NavRail { Dock = DockStyle.Left, Width = ThemeManager.S(200) };
            rail.SelectedPage = PageIdOf(current);
            rail.SelectedPageChanged += (sender, e) => Navigate(rail.SelectedPage);

            Controls.Add(right);
            Controls.Add(rail);
            ResumeLayout(true);
            LayoutFooter();
            RenderPage(current, false);
            if (IsHandleCreated) { NativeMethods.SetDarkTitleBar(Handle, p.IsDark); }
        }

        private void LayoutFooter()
        {
            if (footer == null) { return; }
            int pad = ThemeManager.S(16);
            int half = Math.Max(0, (footer.Width - (pad * 3)) / 2);
            int h = footerLeft.Font.Height;
            int top = Math.Max(0, (footer.Height - h) / 2);
            footerLeft.SetBounds(pad, top, footer.Width - (pad * 2) - Draw.Measure(footerRight.Text, footerRight.Font).Width - pad, h);
            footerRight.SetBounds(footer.Width - pad - half, top, half, h);
        }

        internal static string VersionText()
        {
            Version version = typeof(MainWindow).Assembly.GetName().Version;
            return version.Major + "." + version.Minor + "." + version.Build;
        }

        private PageId PageIdOf(Page page)
        {
            foreach (KeyValuePair<PageId, Page> pair in pages)
            {
                if (pair.Value == page) { return pair.Key; }
            }
            return PageId.Cleanup;
        }

        public void ShowPage(PageId id)
        {
            if (rail.SelectedPage != id) { rail.SelectedPage = id; }
            else if (current != pages[id]) { Navigate(id); }
        }

        private void Navigate(PageId id)
        {
            current = pages[id];
            current.OnShown();
            RenderPage(current, false);
        }

        /// <summary>Replaces the page view with a fresh build of the page's current state.</summary>
        internal void RenderPage(Page page, bool keepScroll)
        {
            if (page != current || host == null) { return; }
            bool focusInside = host.ContainsFocus || ActiveControl == null;
            int scroll = -host.AutoScrollPosition.Y;
            StackPanel view = page.Build();
            Surfaces.Apply(view);
            host.Content = view;
            if (keepScroll && scroll > 0)
            {
                host.AutoScrollPosition = new Point(0, scroll);
                host.PerformLayout();
            }
            UpdateStatus();
            if (focusInside && page.FocusTarget != null && page.FocusTarget.CanFocus)
            {
                page.FocusTarget.Focus();
            }
        }

        /// <summary>Lays the page out again after a row expanded or collapsed.</summary>
        internal void RelayoutContent()
        {
            host.PerformLayout();
            host.Invalidate(true);
        }

        internal void UpdateStatus()
        {
            if (footerLeft != null) { footerLeft.Text = current.Status; }
        }

        protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
        {
            Keys key = keyData & Keys.KeyCode;
            if ((keyData & Keys.Modifiers) == Keys.Alt && key >= Keys.D1 && key <= Keys.D5)
            {
                ShowPage((PageId)(key - Keys.D1));
                rail.Focus();
                return true;
            }
            return base.ProcessCmdKey(ref msg, keyData);
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            NativeMethods.SetDarkTitleBar(Handle, ThemeManager.Palette.IsDark);
            NativeMethods.ShowFocusCues(this);
            if (!sample && DeviceDpi != dpi)
            {
                // Created on a monitor whose DPI differs from the one the view was built for.
                dpi = DeviceDpi;
                ThemeManager.Apply(mode, dpi);
                ClientSize = new Size(ThemeManager.S(1000), ThemeManager.S(700));
                BuildChrome(false);
            }
        }

        protected override void OnShown(EventArgs e)
        {
            base.OnShown(e);
            NativeMethods.ShowFocusCues(this);
            rail.Focus();
        }

        protected override void WndProc(ref Message m)
        {
            if (m.Msg == NativeMethods.WM_DPICHANGED && !sample)
            {
                int newDpi = m.WParam.ToInt32() & 0xFFFF;
                var suggested = (NativeMethods.RECT)Marshal.PtrToStructure(m.LParam, typeof(NativeMethods.RECT));
                dpi = newDpi;
                ThemeManager.Apply(mode, dpi);
                SetBounds(suggested.Left, suggested.Top, suggested.Right - suggested.Left, suggested.Bottom - suggested.Top);
                BuildChrome(false);
                m.Result = IntPtr.Zero;
                return;
            }
            base.WndProc(ref m);
        }

        private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs e)
        {
            if (IsDisposed || !IsHandleCreated) { return; }
            BeginInvoke((MethodInvoker)delegate
            {
                if (IsDisposed) { return; }
                ThemeMode next = ThemeManager.Detect();
                if (next == mode) { return; }
                mode = next;
                ThemeManager.Apply(mode, dpi);
                BuildChrome(false);
            });
        }

        /// <summary>Closing while a cleanup runs hides the window; the tray shows it again.</summary>
        public bool AnyBusy
        {
            get
            {
                foreach (Page page in pages.Values)
                {
                    if (page.Busy) { return true; }
                }
                return false;
            }
        }

        protected override void OnFormClosing(FormClosingEventArgs e)
        {
            if (e.CloseReason == CloseReason.UserClosing && AnyBusy)
            {
                e.Cancel = true;
                Hide();
                return;
            }
            base.OnFormClosing(e);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && subscribed)
            {
                SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
                subscribed = false;
            }
            base.Dispose(disposing);
        }
    }
}
