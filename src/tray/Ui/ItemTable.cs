using System;
using System.Collections;
using System.Collections.Generic;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;

namespace DeadLoad.Tray.Ui
{
    internal sealed class TableColumn
    {
        public string Title;
        /// <summary>Width at 96 DPI; ignored for the fill column, which takes what is left.</summary>
        public int Width;
        public bool Right;
        public bool Path;
        public bool Fill;
        public bool Numeric;

        public static TableColumn PathColumn(string title) { return new TableColumn { Title = title, Path = true, Fill = true, Width = 200 }; }
        public static TableColumn FillColumn(string title) { return new TableColumn { Title = title, Fill = true, Width = 200 }; }
        public static TableColumn Text(string title, int width) { return new TableColumn { Title = title, Width = width }; }
        public static TableColumn Number(string title, int width) { return new TableColumn { Title = title, Width = width, Right = true, Numeric = true }; }
    }

    /// <summary>
    /// A sortable details list: paths in the monospaced font with a middle ellipsis and the full
    /// path as tooltip, sizes right aligned in tabular digits, Ctrl+C (or the context menu)
    /// copies the selected paths, Ctrl+A selects every row. Under high contrast the list is
    /// drawn by Windows with the system colors.
    /// </summary>
    internal sealed class ItemTable : Panel
    {
        private const int LVM_GETHEADER = 0x101F;
        private readonly ListView list;
        private readonly List<TableColumn> columns;
        private readonly int maxRows;
        private int sortColumn = -1;
        private bool sortAscending = true;
        private readonly Font cellFont = ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppBodyPx);
        private readonly Font numberFont = ThemeManager.Font(FontRole.Numeric, ThemeTokens.FontSizeAppBodyPx);
        private readonly Font pathFont = ThemeManager.Font(FontRole.Mono, 13);
        private readonly Font headerFont = ThemeManager.Semibold(FontRole.Text, ThemeTokens.FontSizeAppCaptionPx);
        private readonly ImageList rowHeight;

        [DllImport("user32.dll")]
        private static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

        [DllImport("user32.dll")]
        private static extern bool GetClientRect(IntPtr hWnd, out NativeMethods.RECT rect);

        private sealed class Row
        {
            public IComparable[] Keys;
            public string CopyText;
        }

        public ItemTable(string accessibleName, int maxVisibleRows, params TableColumn[] columns)
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw | ControlStyles.UserPaint, true);
            this.columns = new List<TableColumn>(columns);
            maxRows = Math.Max(1, maxVisibleRows);
            MinFillShare = 0.45;
            Padding = new Padding(2);
            Margin = Padding.Empty;
            Palette p = ThemeManager.Palette;

            list = new ListView
            {
                Dock = DockStyle.Fill,
                View = View.Details,
                FullRowSelect = true,
                HideSelection = false,
                MultiSelect = true,
                BorderStyle = BorderStyle.None,
                ShowItemToolTips = true,
                HeaderStyle = ColumnHeaderStyle.Clickable,
                OwnerDraw = !p.IsHighContrast,
                Font = cellFont,
                AccessibleName = accessibleName,
                TabStop = true,
            };
            if (!p.IsHighContrast)
            {
                list.BackColor = p.Card;
                list.ForeColor = p.TextPrimary;
            }
            // A one-pixel-wide image list is the documented way to set the row height.
            rowHeight = new ImageList { ImageSize = new Size(1, ThemeManager.S(30)) };
            list.SmallImageList = rowHeight;
            foreach (TableColumn c in columns)
            {
                list.Columns.Add(c.Title, ThemeManager.S(c.Width), c.Right ? HorizontalAlignment.Right : HorizontalAlignment.Left);
            }
            list.DrawColumnHeader += OnDrawColumnHeader;
            list.DrawItem += (sender, e) => { e.DrawDefault = false; };
            list.DrawSubItem += OnDrawSubItem;
            list.ColumnClick += OnColumnClick;
            list.KeyDown += OnListKeyDown;
            list.Resize += (sender, e) => FitColumns();
            list.GotFocus += (sender, e) => Invalidate();
            list.LostFocus += (sender, e) => Invalidate();
            list.HandleCreated += (sender, e) => OnListHandleCreated();
            var menu = new ContextMenuStrip();
            menu.Items.Add("Copy path", null, (sender, e) => CopySelection());
            menu.Items.Add("Select all", null, (sender, e) => SelectAll());
            list.ContextMenuStrip = menu;
            Controls.Add(list);
        }

        /// <summary>Share of the width the fill column keeps at least (0.45 for paths).</summary>
        public double MinFillShare { get; set; }

        public void AddRow(string[] texts, IComparable[] keys, string copyText, string tooltip)
        {
            var item = new ListViewItem(texts[0]);
            for (int i = 1; i < texts.Length; i++) { item.SubItems.Add(texts[i] ?? string.Empty); }
            item.Tag = new Row { Keys = keys, CopyText = copyText ?? texts[0] };
            if (!string.IsNullOrEmpty(tooltip)) { item.ToolTipText = tooltip; }
            list.Items.Add(item);
        }

        public void Sort(int column, bool ascending)
        {
            sortColumn = column;
            sortAscending = ascending;
            list.ListViewItemSorter = new RowComparer(column, ascending);
            list.Sort();
            list.Invalidate();
        }

        private int HeaderHeight
        {
            get
            {
                if (list.IsHandleCreated)
                {
                    IntPtr header = SendMessage(list.Handle, LVM_GETHEADER, IntPtr.Zero, IntPtr.Zero);
                    NativeMethods.RECT rect;
                    if (header != IntPtr.Zero && GetClientRect(header, out rect) && rect.Bottom > 0) { return rect.Bottom; }
                }
                return cellFont.Height + ThemeManager.S(10);
            }
        }

        /// <summary>The real row pitch once the list exists (measured: image height plus 1 px).</summary>
        private int RowHeight
        {
            get
            {
                if (list.IsHandleCreated && list.Items.Count > 0)
                {
                    Rectangle row = list.GetItemRect(0);
                    if (row.Height > 0) { return row.Height; }
                }
                return rowHeight.ImageSize.Height + 1;
            }
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            int rows = Math.Max(1, Math.Min(maxRows, list.Items.Count));
            int height = HeaderHeight + (rows * RowHeight) + Padding.Vertical + ThemeManager.S(2);
            // A horizontal scroll bar never appears (the fill column takes the remaining width).
            return new Size(proposedSize.Width > 0 ? proposedSize.Width : ThemeManager.S(480), height);
        }

        /// <summary>
        /// Heights are estimated until the list has a handle; then the page is laid out again
        /// with the measured header and row heights, so all rows up to the maximum are visible
        /// without a scroll bar.
        /// </summary>
        private void OnListHandleCreated()
        {
            NativeMethods.SetControlTheme(list, ThemeManager.Palette.IsDark);
            list.BeginInvoke((MethodInvoker)delegate
            {
                Control host = this;
                while (host != null && !(host is ScrollHost)) { host = host.Parent; }
                if (host != null && !host.IsDisposed) { host.PerformLayout(); }
            });
        }

        protected override void OnLayout(LayoutEventArgs levent)
        {
            base.OnLayout(levent);
            FitColumns();
        }

        private void FitColumns()
        {
            if (list == null || list.Columns.Count == 0) { return; }
            int fill = -1;
            int used = 0;
            for (int i = 0; i < columns.Count; i++)
            {
                if (columns[i].Fill && fill < 0) { fill = i; continue; }
                used += ThemeManager.S(columns[i].Width);
            }
            if (fill < 0) { return; }
            int client = list.ClientSize.Width;
            // The fill column (the path) keeps at least 45 percent of the width: the other
            // columns give up room in proportion, down to a floor that still shows a few letters.
            double scale = 1.0;
            int reserve = (int)(client * MinFillShare);
            if (client - used < reserve && used > 0) { scale = Math.Max(0.0, (client - reserve) / (double)used); }
            int floor = ThemeManager.S(56);
            int total = 0;
            for (int i = 0; i < columns.Count; i++)
            {
                if (i == fill) { continue; }
                int width = Math.Max(floor, (int)(ThemeManager.S(columns[i].Width) * scale));
                if (list.Columns[i].Width != width) { list.Columns[i].Width = width; }
                total += width;
            }
            int fillWidth = Math.Max(ThemeManager.S(120), client - total);
            if (list.Columns[fill].Width != fillWidth) { list.Columns[fill].Width = fillWidth; }
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Palette p = ThemeManager.Palette;
            e.Graphics.Clear(BackColor);
            if (list.Focused)
            {
                using (var pen = new Pen(p.Focus, 2f))
                {
                    e.Graphics.DrawRectangle(pen, 1, 1, Width - 2, Height - 2);
                }
            }
            else
            {
                using (var pen = new Pen(p.Border, 1f))
                {
                    e.Graphics.DrawRectangle(pen, 1, 1, Width - 3, Height - 3);
                }
            }
        }

        private void OnDrawColumnHeader(object sender, DrawListViewColumnHeaderEventArgs e)
        {
            Palette p = ThemeManager.Palette;
            Color back = p.IsDark ? p.Raised : p.Canvas;
            using (var brush = new SolidBrush(back)) { e.Graphics.FillRectangle(brush, e.Bounds); }
            using (var pen = new Pen(p.Border)) { e.Graphics.DrawLine(pen, e.Bounds.Left, e.Bounds.Bottom - 1, e.Bounds.Right, e.Bounds.Bottom - 1); }
            TableColumn column = columns[e.ColumnIndex];
            int pad = ThemeManager.S(8);
            var text = new Rectangle(e.Bounds.X + pad, e.Bounds.Y, Math.Max(0, e.Bounds.Width - (pad * 2)), e.Bounds.Height);
            int arrow = ThemeManager.S(12);
            if (e.ColumnIndex == sortColumn)
            {
                var glyphBox = column.Right
                    ? new Rectangle(text.X, e.Bounds.Y + ((e.Bounds.Height - arrow) / 2), arrow, arrow)
                    : new Rectangle(text.Right - arrow, e.Bounds.Y + ((e.Bounds.Height - arrow) / 2), arrow, arrow);
                DrawSortGlyph(e.Graphics, glyphBox, sortAscending, p.TextSecondary);
                if (column.Right) { text.X += arrow + ThemeManager.S(4); }
                text.Width -= arrow + ThemeManager.S(4);
            }
            TextFormatFlags flags = Draw.SingleLine | TextFormatFlags.VerticalCenter | (column.Right ? TextFormatFlags.Right : TextFormatFlags.Left);
            TextRenderer.DrawText(e.Graphics, column.Title, headerFont, text, p.TextSecondary, back, flags);
        }

        private static void DrawSortGlyph(Graphics g, Rectangle box, bool ascending, Color color)
        {
            Draw.Smooth(g);
            using (var pen = new Pen(color, ThemeManager.SF(1.5f)))
            {
                float cx = box.X + (box.Width / 2f);
                float top = box.Y + (box.Height * 0.35f);
                float bottom = box.Y + (box.Height * 0.65f);
                float half = box.Width * 0.25f;
                if (ascending) { g.DrawLines(pen, new[] { new PointF(cx - half, bottom), new PointF(cx, top), new PointF(cx + half, bottom) }); }
                else { g.DrawLines(pen, new[] { new PointF(cx - half, top), new PointF(cx, bottom), new PointF(cx + half, top) }); }
            }
        }

        private void OnDrawSubItem(object sender, DrawListViewSubItemEventArgs e)
        {
            Palette p = ThemeManager.Palette;
            TableColumn column = columns[e.ColumnIndex];
            bool selected = e.Item.Selected;
            Color back = selected ? p.RowSelected : p.Card;
            using (var brush = new SolidBrush(back)) { e.Graphics.FillRectangle(brush, e.Bounds); }
            int pad = ThemeManager.S(8);
            var rect = new Rectangle(e.Bounds.X + pad, e.Bounds.Y, Math.Max(0, e.Bounds.Width - (pad * 2)), e.Bounds.Height);
            TextFormatFlags flags = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix | TextFormatFlags.VerticalCenter;
            flags |= column.Path ? TextFormatFlags.PathEllipsis : TextFormatFlags.EndEllipsis;
            if (column.Right) { flags |= TextFormatFlags.Right; }
            Font font = column.Path ? pathFont : (column.Numeric ? numberFont : cellFont);
            TextRenderer.DrawText(e.Graphics, e.SubItem.Text, font, rect, p.TextPrimary, back, flags);
            if (e.ColumnIndex == 0 && e.Item.Focused && list.Focused)
            {
                // The focused row inside the focused list: a 1 px inset outline across the row.
                Rectangle row = e.Item.Bounds;
                using (var pen = new Pen(p.Focus))
                {
                    e.Graphics.DrawRectangle(pen, row.X, row.Y, row.Width - 1, row.Height - 1);
                }
            }
        }

        private void OnColumnClick(object sender, ColumnClickEventArgs e)
        {
            bool ascending = e.Column == sortColumn ? !sortAscending : !(columns[e.Column].Numeric);
            Sort(e.Column, ascending);
        }

        private void OnListKeyDown(object sender, KeyEventArgs e)
        {
            if (e.Control && e.KeyCode == Keys.C) { CopySelection(); e.Handled = true; e.SuppressKeyPress = true; }
            else if (e.Control && e.KeyCode == Keys.A) { SelectAll(); e.Handled = true; e.SuppressKeyPress = true; }
        }

        private void SelectAll()
        {
            list.BeginUpdate();
            foreach (ListViewItem item in list.Items) { item.Selected = true; }
            list.EndUpdate();
        }

        private void CopySelection()
        {
            var text = new StringBuilder();
            foreach (ListViewItem item in list.SelectedItems)
            {
                var row = item.Tag as Row;
                if (text.Length > 0) { text.AppendLine(); }
                text.Append(row != null ? row.CopyText : item.Text);
            }
            if (text.Length == 0) { return; }
            try { Clipboard.SetText(text.ToString()); }
            catch (ExternalException) { /* the clipboard is held by another program; nothing copied */ }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing)
            {
                rowHeight.Dispose();
                if (list.ContextMenuStrip != null) { list.ContextMenuStrip.Dispose(); }
            }
            base.Dispose(disposing);
        }

        private sealed class RowComparer : IComparer
        {
            private readonly int column;
            private readonly bool ascending;

            public RowComparer(int column, bool ascending)
            {
                this.column = column;
                this.ascending = ascending;
            }

            public int Compare(object x, object y)
            {
                var a = ((ListViewItem)x).Tag as Row;
                var b = ((ListViewItem)y).Tag as Row;
                IComparable ka = a != null && column < a.Keys.Length ? a.Keys[column] : null;
                IComparable kb = b != null && column < b.Keys.Length ? b.Keys[column] : null;
                int result;
                if (ka == null && kb == null) { result = 0; }
                else if (ka == null) { result = -1; }
                else if (kb == null) { result = 1; }
                else if (ka is string && kb is string) { result = string.Compare((string)ka, (string)kb, StringComparison.CurrentCultureIgnoreCase); }
                else { result = ka.CompareTo(kb); }
                return ascending ? result : -result;
            }
        }
    }
}
