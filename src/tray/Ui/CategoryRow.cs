using System;
using System.Drawing;
using System.Windows.Forms;

namespace DeadLoad.Tray.Ui
{
    /// <summary>
    /// One category of the analysis: [checkbox] title and explanation, estimated size, item
    /// count, risk badge, expander. One tab stop: Space toggles the checkbox, Enter or the arrow
    /// keys expand and collapse the item list, Up and Down move between rows. A row the engine
    /// did not offer (Restricted, machine-wide, not deleting) has a lock instead of a checkbox
    /// and can never be selected.
    /// </summary>
    internal sealed class CategoryRow : Control
    {
        private const int PadX = 16;
        private const int PadY = 12;
        private const int Box = 18;
        private const int SizeColumn = 92;
        private const int CountColumn = 84;
        private const int BadgeColumn = 104;
        private const int ChevronColumn = 20;
        private const int Gap = 12;
        private const int CompactBelow = 600;

        private readonly Font titleFont = ThemeManager.Semibold(FontRole.Text, ThemeTokens.FontSizeAppBodyPx);
        private readonly Font bodyFont = ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppCaptionPx);
        private readonly Font numberFont = ThemeManager.Font(FontRole.Numeric, ThemeTokens.FontSizeAppBodyPx);
        private readonly Font metaFont = ThemeManager.Font(FontRole.Numeric, ThemeTokens.FontSizeAppCaptionPx);
        private ItemTable table;
        private bool isChecked;
        private bool expanded;
        private bool hover;

        public CategoryRow(AnalysisCategory category, bool initiallyChecked)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable | ControlStyles.StandardClick, true);
            Category = category;
            isChecked = initiallyChecked && category.Selectable;
            TabStop = true;
            Margin = Padding.Empty;
            AccessibleName = category.DisplayName;
            AccessibleRole = AccessibleRole.CheckButton;
        }

        public AnalysisCategory Category { get; private set; }

        public event EventHandler CheckedChanged;

        public event EventHandler ExpandedChanged;

        public bool Checked
        {
            get { return isChecked; }
            set
            {
                bool next = value && Category.Selectable;
                if (next == isChecked) { return; }
                isChecked = next;
                Invalidate();
                AccessibilityNotifyClients(AccessibleEvents.StateChange, -1);
                if (CheckedChanged != null) { CheckedChanged(this, EventArgs.Empty); }
            }
        }

        public bool Expanded
        {
            get { return expanded; }
            set
            {
                bool next = value && Category.Items.Count > 0;
                if (next == expanded) { return; }
                expanded = next;
                if (expanded) { EnsureTable(); }
                if (table != null) { table.Visible = expanded; }
                AccessibilityNotifyClients(AccessibleEvents.StateChange, -1);
                if (ExpandedChanged != null) { ExpandedChanged(this, EventArgs.Empty); }
                Invalidate();
            }
        }

        private bool Compact
        {
            get { return Width > 0 && Width < ThemeManager.S(CompactBelow); }
        }

        /// <summary>The plain sentence under the description for an unavailable, guarded or empty row.</summary>
        private string StatusLine(out Tone tone, out Glyph glyph)
        {
            tone = Tone.Neutral;
            glyph = Glyph.None;
            if (!Category.Available)
            {
                // The lock already stands in the checkbox column; the sentence needs no second one.
                if (string.Equals(Category.UnavailableReason, "Restricted", StringComparison.OrdinalIgnoreCase))
                {
                    return "Managed by your administrator; not cleaned from here.";
                }
                return string.IsNullOrEmpty(Category.UnavailableText) ? "Not cleaned from here." : Category.UnavailableText;
            }
            if (!string.IsNullOrEmpty(Category.GuardedMessage))
            {
                tone = Tone.Warning;
                glyph = Glyph.Warning;
                return Category.GuardedMessage;
            }
            if (Category.Items.Count == 0)
            {
                return "Nothing to clean here right now.";
            }
            return null;
        }

        private int TextLeft { get { return ThemeManager.S(PadX + Box + Gap); } }

        private int RightColumnsWidth
        {
            get
            {
                int columns = Compact ? SizeColumn + Gap + ChevronColumn : SizeColumn + Gap + CountColumn + Gap + BadgeColumn + Gap + ChevronColumn;
                return ThemeManager.S(columns + PadX);
            }
        }

        /// <summary>Width of the title: it shares its line with the size, count and badge columns.</summary>
        private int TextWidth(int width)
        {
            return Math.Max(ThemeManager.S(80), width - TextLeft - RightColumnsWidth - ThemeManager.S(Gap));
        }

        /// <summary>Width of the explanation lines below the title: up to the expander column.</summary>
        private int BodyWidth(int width)
        {
            return Math.Max(ThemeManager.S(80), width - TextLeft - ThemeManager.S(PadX + ChevronColumn + Gap));
        }

        private int HeaderHeight(int width)
        {
            int textWidth = BodyWidth(width);
            int height = ThemeManager.S(PadY) + titleFont.Height;
            if (!string.IsNullOrEmpty(Category.Description))
            {
                height += ThemeManager.S(2) + Draw.MeasureWrapped(Category.Description, bodyFont, textWidth).Height;
            }
            Tone tone;
            Glyph glyph;
            string status = StatusLine(out tone, out glyph);
            if (status != null)
            {
                int iconRoom = glyph == Glyph.None ? 0 : ThemeManager.S(16);
                height += ThemeManager.S(6) + Math.Max(bodyFont.Height, Draw.MeasureWrapped(status, bodyFont, textWidth - iconRoom).Height);
            }
            if (width > 0 && width < ThemeManager.S(CompactBelow))
            {
                height += ThemeManager.S(8) + ThemeManager.S(22);
            }
            height += ThemeManager.S(PadY);
            return Math.Max(height, ThemeManager.S(56));
        }

        private void EnsureTable()
        {
            if (table != null) { return; }
            table = new ItemTable("Items in " + Category.DisplayName, 8,
                TableColumn.PathColumn("Path"),
                TableColumn.Number("Size", 88),
                TableColumn.Text("Last used", 120),
                TableColumn.Text("Why it is listed", 200));
            foreach (AnalysisItem item in Category.Items)
            {
                table.AddRow(
                    new[] { item.DisplayPath, Format.Bytes(item.Bytes), Format.Age(item.LastWriteUtc), item.DisplayReason },
                    new IComparable[] { item.Path, item.Bytes, item.LastWriteUtc.HasValue ? (IComparable)item.LastWriteUtc.Value : null, item.ReasonText },
                    item.Path, item.Path);
            }
            table.BackColor = ThemeManager.Palette.Card;
            Controls.Add(table);
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            int width = proposedSize.Width > 0 ? proposedSize.Width : ThemeManager.S(720);
            int height = HeaderHeight(width);
            if (expanded && table != null)
            {
                height += table.GetPreferredSize(new Size(TableWidth(width), 0)).Height + ThemeManager.S(PadY);
            }
            return new Size(width, height);
        }

        private int TableWidth(int width)
        {
            return Math.Max(ThemeManager.S(200), width - TextLeft - ThemeManager.S(PadX));
        }

        protected override void OnLayout(LayoutEventArgs levent)
        {
            base.OnLayout(levent);
            if (table == null) { return; }
            int top = HeaderHeight(Width);
            int width = TableWidth(Width);
            table.SetBounds(TextLeft, top, width, table.GetPreferredSize(new Size(width, 0)).Height);
        }

        protected override bool IsInputKey(Keys keyData)
        {
            switch (keyData & Keys.KeyCode)
            {
                case Keys.Up:
                case Keys.Down:
                case Keys.Left:
                case Keys.Right:
                case Keys.Space:
                case Keys.Enter:
                    return (keyData & (Keys.Alt | Keys.Control)) == 0;
            }
            return base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            switch (e.KeyCode)
            {
                case Keys.Space: Checked = !Checked; e.Handled = true; break;
                case Keys.Enter: Expanded = !Expanded; e.Handled = true; break;
                case Keys.Right: Expanded = true; e.Handled = true; break;
                case Keys.Left: Expanded = false; e.Handled = true; break;
                case Keys.Up: MoveFocus(false); e.Handled = true; break;
                case Keys.Down: MoveFocus(true); e.Handled = true; break;
            }
            base.OnKeyDown(e);
        }

        private void MoveFocus(bool forward)
        {
            if (Parent == null) { return; }
            int index = Parent.Controls.GetChildIndex(this);
            int step = forward ? 1 : -1;
            for (int i = index + step; i >= 0 && i < Parent.Controls.Count; i += step)
            {
                var row = Parent.Controls[i] as CategoryRow;
                if (row != null) { row.Focus(); return; }
            }
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            Focus();
            base.OnMouseDown(e);
        }

        protected override void OnMouseClick(MouseEventArgs e)
        {
            base.OnMouseClick(e);
            if (e.Button != MouseButtons.Left || e.Y > HeaderHeight(Width)) { return; }
            if (e.X < TextLeft && Category.Selectable) { Checked = !Checked; }
            else if (Category.Items.Count > 0) { Expanded = !Expanded; }
            else if (Category.Selectable) { Checked = !Checked; }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            bool over = e.Y <= HeaderHeight(Width);
            if (over != hover) { hover = over; Invalidate(); }
            base.OnMouseMove(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            hover = false;
            Invalidate();
            base.OnMouseLeave(e);
        }

        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Palette p = ThemeManager.Palette;
            Graphics g = e.Graphics;
            int header = HeaderHeight(Width);
            g.Clear(BackColor);
            if (hover && !p.IsHighContrast)
            {
                Draw.Smooth(g);
                Draw.FillRounded(g, new Rectangle(ThemeManager.S(4), ThemeManager.S(4), Width - ThemeManager.S(8), header - ThemeManager.S(8)), ThemeManager.S(ThemeTokens.RadiusControl), p.RowHover);
            }

            int y = ThemeManager.S(PadY);
            int boxSize = ThemeManager.S(Box);
            var box = new Rectangle(ThemeManager.S(PadX), y + ((titleFont.Height - boxSize) / 2), boxSize, boxSize);
            DrawCheck(g, box, p);

            int textLeft = TextLeft;
            int titleWidth = TextWidth(Width);
            int textWidth = BodyWidth(Width);
            bool enabled = Category.Available;
            Color titleColor = enabled ? p.TextPrimary : p.TextSecondary;
            Color back = hover && !p.IsHighContrast ? p.RowHover : BackColor;
            TextRenderer.DrawText(g, Category.DisplayName, titleFont, new Rectangle(textLeft, y, titleWidth, titleFont.Height), titleColor, back, Draw.SingleLine);
            y += titleFont.Height;
            if (!string.IsNullOrEmpty(Category.Description))
            {
                y += ThemeManager.S(2);
                int h = Draw.MeasureWrapped(Category.Description, bodyFont, textWidth).Height;
                TextRenderer.DrawText(g, Category.Description, bodyFont, new Rectangle(textLeft, y, textWidth, h), p.TextSecondary, back, Draw.Wrapped);
                y += h;
            }
            Tone tone;
            Glyph glyph;
            string status = StatusLine(out tone, out glyph);
            if (status != null)
            {
                y += ThemeManager.S(6);
                int x = textLeft;
                Color color = tone == Tone.Neutral ? p.TextSecondary : p.ToneText(tone);
                if (glyph != Glyph.None)
                {
                    int icon = ThemeManager.S(12);
                    Draw.Icon(g, glyph, new Rectangle(x, y + ((bodyFont.Height - icon) / 2), icon, icon), color);
                    x += ThemeManager.S(16);
                }
                int h = Math.Max(bodyFont.Height, Draw.MeasureWrapped(status, bodyFont, textWidth - (x - textLeft)).Height);
                TextRenderer.DrawText(g, status, bodyFont, new Rectangle(x, y, textWidth - (x - textLeft), h), color, back, Draw.Wrapped);
                y += h;
            }

            // Right-hand columns, on the title line.
            int right = Width - ThemeManager.S(PadX);
            int lineTop = ThemeManager.S(PadY);
            var chevron = new Rectangle(right - ThemeManager.S(ChevronColumn), lineTop + ((titleFont.Height - ThemeManager.S(16)) / 2), ThemeManager.S(16), ThemeManager.S(16));
            if (Category.Items.Count > 0)
            {
                Draw.Icon(g, expanded ? Glyph.ChevronDown : Glyph.ChevronRight, chevron, p.TextSecondary);
            }
            int x2 = right - ThemeManager.S(ChevronColumn + Gap);
            string size = Category.Available ? Format.Bytes(Category.EstimatedBytes) : "-";
            string count = Category.Available ? Format.Count(Category.Items.Count, "item", "items") : string.Empty;
            Color sizeColor = Category.Available && Category.Items.Count > 0 ? p.TextPrimary : p.TextMuted;
            if (Compact)
            {
                var sizeRect = new Rectangle(x2 - ThemeManager.S(SizeColumn), lineTop, ThemeManager.S(SizeColumn), titleFont.Height);
                TextRenderer.DrawText(g, size, numberFont, sizeRect, sizeColor, back, Draw.SingleLine | TextFormatFlags.Right);
                int metaTop = y + ThemeManager.S(8);
                RiskBadge.DrawBadge(g, new Point(textLeft, metaTop), Category.Risk);
                int badgeWidth = RiskBadge.BadgeSize(Category.Risk).Width;
                TextRenderer.DrawText(g, count, metaFont, new Rectangle(textLeft + badgeWidth + ThemeManager.S(12), metaTop, ThemeManager.S(120), ThemeManager.S(22)), p.TextSecondary, back, Draw.SingleLine | TextFormatFlags.VerticalCenter);
            }
            else
            {
                int badgeX = x2 - ThemeManager.S(BadgeColumn);
                Size badge = RiskBadge.BadgeSize(Category.Risk);
                RiskBadge.DrawBadge(g, new Point(badgeX, lineTop + ((titleFont.Height - badge.Height) / 2)), Category.Risk);
                int countRight = badgeX - ThemeManager.S(Gap);
                TextRenderer.DrawText(g, count, numberFont, new Rectangle(countRight - ThemeManager.S(CountColumn), lineTop, ThemeManager.S(CountColumn), titleFont.Height), p.TextSecondary, back, Draw.SingleLine | TextFormatFlags.Right);
                int sizeRight = countRight - ThemeManager.S(CountColumn + Gap);
                TextRenderer.DrawText(g, size, numberFont, new Rectangle(sizeRight - ThemeManager.S(SizeColumn), lineTop, ThemeManager.S(SizeColumn), titleFont.Height), sizeColor, back, Draw.SingleLine | TextFormatFlags.Right);
            }

            if (Focused)
            {
                Draw.Smooth(g);
                int inset = ThemeManager.S(ThemeTokens.FocusWidth + ThemeTokens.FocusOffset);
                var body = new Rectangle(inset, inset, Width - (inset * 2), header - (inset * 2));
                Draw.FocusRing(g, body, ThemeManager.S(ThemeTokens.RadiusControl));
            }
        }

        private void DrawCheck(Graphics g, Rectangle box, Palette p)
        {
            Draw.Smooth(g);
            int radius = ThemeManager.S(4);
            if (!Category.Available)
            {
                Draw.Icon(g, Glyph.Lock, box, p.TextSecondary);
                return;
            }
            if (!Category.Selectable)
            {
                Draw.FillRounded(g, box, radius, p.DisabledBack, p.IsHighContrast ? p.DisabledText : p.Border);
                return;
            }
            if (isChecked)
            {
                Draw.FillRounded(g, box, radius, p.Accent);
                var mark = new Rectangle(box.X + ThemeManager.S(2), box.Y + ThemeManager.S(2), box.Width - ThemeManager.S(4), box.Height - ThemeManager.S(4));
                Draw.Icon(g, Glyph.Check, mark, p.OnAccent);
            }
            else
            {
                Draw.FillRounded(g, box, radius, p.Card, p.CheckBorder);
            }
        }

        protected override AccessibleObject CreateAccessibilityInstance()
        {
            return new RowAccessible(this);
        }

        private sealed class RowAccessible : ControlAccessibleObject
        {
            private readonly CategoryRow row;

            public RowAccessible(CategoryRow row) : base(row)
            {
                this.row = row;
            }

            public override AccessibleRole Role { get { return AccessibleRole.CheckButton; } }

            public override string Name { get { return row.Category.DisplayName; } set { } }

            public override string Value
            {
                get
                {
                    if (!row.Category.Available) { return "Not available"; }
                    return Format.Bytes(row.Category.EstimatedBytes) + ", " + Format.Count(row.Category.Items.Count, "item", "items");
                }
                set { }
            }

            public override string Description
            {
                get
                {
                    Tone tone;
                    Glyph glyph;
                    string status = row.StatusLine(out tone, out glyph);
                    string text = "Risk: " + RiskBadge.Label(row.Category.Risk) + ". " + (row.Category.Description ?? string.Empty);
                    if (status != null) { text += " " + status; }
                    if (row.Category.Items.Count > 0) { text += " Press Enter to show or hide the items."; }
                    return text;
                }
            }

            public override AccessibleStates State
            {
                get
                {
                    AccessibleStates state = AccessibleStates.Focusable;
                    if (row.Focused) { state |= AccessibleStates.Focused; }
                    if (row.isChecked) { state |= AccessibleStates.Checked; }
                    if (!row.Category.Selectable) { state |= AccessibleStates.Unavailable; }
                    if (row.Category.Items.Count > 0) { state |= row.expanded ? AccessibleStates.Expanded : AccessibleStates.Collapsed; }
                    return state;
                }
            }

            public override string DefaultAction
            {
                get { return row.Category.Selectable ? (row.isChecked ? "Uncheck" : "Check") : string.Empty; }
            }

            public override void DoDefaultAction()
            {
                if (row.Category.Selectable) { row.Checked = !row.Checked; }
            }
        }
    }
}
