using System;
using System.Collections.Generic;
using System.Drawing;
using System.Windows.Forms;

namespace DeadLoad.Tray.Ui
{
    internal enum PageId
    {
        Cleanup = 0,
        Details = 1,
        History = 2,
        Settings = 3,
        About = 4,
    }

    /// <summary>
    /// The compact left navigation: one tab stop; Up and Down (or Home and End) move the
    /// selection, Alt+1 to Alt+5 work from anywhere in the window (MainWindow). The selected
    /// page is a blue fill, as the design system asks, with its label, never color alone.
    /// </summary>
    internal sealed class NavRail : Control
    {
        private sealed class Item
        {
            public PageId Page;
            public string Text;
            public Glyph Glyph;
        }

        private readonly List<Item> items = new List<Item>();
        private readonly Font font = ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppBodyPx);
        private readonly Font selectedFont = ThemeManager.Semibold(FontRole.Text, ThemeTokens.FontSizeAppBodyPx);
        private int selected;
        private int hover = -1;

        public NavRail()
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.Selectable, true);
            TabStop = true;
            items.Add(new Item { Page = PageId.Cleanup, Text = "Cleanup", Glyph = Glyph.Layers });
            items.Add(new Item { Page = PageId.Details, Text = "Details", Glyph = Glyph.Chart });
            items.Add(new Item { Page = PageId.History, Text = "History", Glyph = Glyph.Clock });
            items.Add(new Item { Page = PageId.Settings, Text = "Settings", Glyph = Glyph.Sliders });
            items.Add(new Item { Page = PageId.About, Text = "About", Glyph = Glyph.Info });
            AccessibleName = "Pages";
            AccessibleRole = AccessibleRole.PageTabList;
            BackColor = ThemeManager.Palette.RailBack;
        }

        public event EventHandler SelectedPageChanged;

        public PageId SelectedPage
        {
            get { return items[selected].Page; }
            set
            {
                int index = items.FindIndex(i => i.Page == value);
                if (index < 0 || index == selected) { return; }
                selected = index;
                Invalidate();
                AccessibilityNotifyClients(AccessibleEvents.Selection, selected);
                if (SelectedPageChanged != null) { SelectedPageChanged(this, EventArgs.Empty); }
            }
        }

        private int ItemHeight { get { return ThemeManager.S(40); } }

        private int Top0 { get { return ThemeManager.S(12); } }

        private Rectangle ItemBounds(int index)
        {
            int margin = ThemeManager.S(8);
            return new Rectangle(margin, Top0 + (index * (ItemHeight + ThemeManager.S(4))), Width - (margin * 2), ItemHeight);
        }

        private int HitTest(Point point)
        {
            for (int i = 0; i < items.Count; i++)
            {
                if (ItemBounds(i).Contains(point)) { return i; }
            }
            return -1;
        }

        protected override bool IsInputKey(Keys keyData)
        {
            switch (keyData & Keys.KeyCode)
            {
                case Keys.Up:
                case Keys.Down:
                case Keys.Home:
                case Keys.End:
                    return (keyData & (Keys.Alt | Keys.Control)) == 0;
            }
            return base.IsInputKey(keyData);
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            int next = selected;
            switch (e.KeyCode)
            {
                case Keys.Up: next = (selected + items.Count - 1) % items.Count; break;
                case Keys.Down: next = (selected + 1) % items.Count; break;
                case Keys.Home: next = 0; break;
                case Keys.End: next = items.Count - 1; break;
            }
            if (next != selected)
            {
                SelectedPage = items[next].Page;
                e.Handled = true;
            }
            base.OnKeyDown(e);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            base.OnMouseDown(e);
            int index = HitTest(e.Location);
            if (index >= 0 && e.Button == MouseButtons.Left)
            {
                Focus();
                SelectedPage = items[index].Page;
            }
        }

        protected override void OnMouseMove(MouseEventArgs e)
        {
            int index = HitTest(e.Location);
            if (index != hover) { hover = index; Invalidate(); }
            base.OnMouseMove(e);
        }

        protected override void OnMouseLeave(EventArgs e)
        {
            hover = -1;
            Invalidate();
            base.OnMouseLeave(e);
        }

        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

        protected override void OnPaint(PaintEventArgs e)
        {
            Palette p = ThemeManager.Palette;
            Graphics g = e.Graphics;
            g.Clear(p.RailBack);
            Draw.Smooth(g);
            int radius = ThemeManager.S(ThemeTokens.RadiusControl);
            for (int i = 0; i < items.Count; i++)
            {
                Rectangle bounds = ItemBounds(i);
                bool isSelected = i == selected;
                Color back = p.RailBack;
                Color fore = p.RailText;
                if (isSelected)
                {
                    back = p.RailSelectedBack;
                    fore = p.RailSelectedText;
                    Draw.FillRounded(g, bounds, radius, back);
                }
                else if (i == hover && !p.IsHighContrast)
                {
                    back = p.RailHover;
                    Draw.FillRounded(g, bounds, radius, back);
                }
                if (p.IsHighContrast && isSelected)
                {
                    Draw.FillRounded(g, bounds, radius, back, p.Border);
                }
                int icon = ThemeManager.S(16);
                Draw.Icon(g, items[i].Glyph, new Rectangle(bounds.X + ThemeManager.S(12), bounds.Y + ((bounds.Height - icon) / 2), icon, icon), fore);
                var text = new Rectangle(bounds.X + ThemeManager.S(40), bounds.Y, bounds.Width - ThemeManager.S(48), bounds.Height);
                TextRenderer.DrawText(g, items[i].Text, isSelected ? selectedFont : font, text, fore, back, Draw.SingleLine | TextFormatFlags.VerticalCenter);
                if (isSelected && Focused)
                {
                    // The ring sits on the rail color, so it uses the rail text color (white on
                    // navy) rather than the blue it would vanish into.
                    int width = ThemeManager.S(ThemeTokens.FocusWidth);
                    var ring = Rectangle.Inflate(bounds, ThemeManager.S(ThemeTokens.FocusOffset), ThemeManager.S(ThemeTokens.FocusOffset));
                    using (var path = Draw.RoundedRect(new RectangleF(ring.X + (width / 2f), ring.Y + (width / 2f), ring.Width - width, ring.Height - width), radius + ThemeManager.S(1)))
                    using (var pen = new Pen(p.IsHighContrast ? p.Focus : p.RailText, width))
                    {
                        g.DrawPath(pen, path);
                    }
                }
            }
        }

        protected override AccessibleObject CreateAccessibilityInstance()
        {
            return new RailAccessible(this);
        }

        private sealed class RailAccessible : ControlAccessibleObject
        {
            private readonly NavRail rail;

            public RailAccessible(NavRail rail) : base(rail)
            {
                this.rail = rail;
            }

            public override AccessibleRole Role { get { return AccessibleRole.PageTabList; } }

            public override int GetChildCount()
            {
                return rail.items.Count;
            }

            public override AccessibleObject GetChild(int index)
            {
                return index >= 0 && index < rail.items.Count ? new TabAccessible(rail, index, this) : null;
            }

            public override AccessibleObject GetFocused()
            {
                return rail.Focused ? GetChild(rail.selected) : null;
            }

            public override AccessibleObject GetSelected()
            {
                return GetChild(rail.selected);
            }
        }

        private sealed class TabAccessible : AccessibleObject
        {
            private readonly NavRail rail;
            private readonly int index;
            private readonly AccessibleObject parent;

            public TabAccessible(NavRail rail, int index, AccessibleObject parent)
            {
                this.rail = rail;
                this.index = index;
                this.parent = parent;
            }

            public override AccessibleObject Parent { get { return parent; } }
            public override AccessibleRole Role { get { return AccessibleRole.PageTab; } }
            public override string Name { get { return rail.items[index].Text; } set { } }
            public override string Description { get { return "Alt+" + (index + 1); } }
            public override string KeyboardShortcut { get { return "Alt+" + (index + 1); } }
            public override string DefaultAction { get { return "Switch"; } }

            public override Rectangle Bounds
            {
                get { return rail.RectangleToScreen(rail.ItemBounds(index)); }
            }

            public override AccessibleStates State
            {
                get
                {
                    AccessibleStates state = AccessibleStates.Selectable | AccessibleStates.Focusable;
                    if (index == rail.selected)
                    {
                        state |= AccessibleStates.Selected;
                        if (rail.Focused) { state |= AccessibleStates.Focused; }
                    }
                    return state;
                }
            }

            public override void DoDefaultAction()
            {
                rail.SelectedPage = rail.items[index].Page;
            }

            public override void Select(AccessibleSelection flags)
            {
                if ((flags & (AccessibleSelection.TakeSelection | AccessibleSelection.AddSelection)) != 0) { DoDefaultAction(); }
                if ((flags & AccessibleSelection.TakeFocus) != 0) { rail.Focus(); }
            }
        }
    }
}
