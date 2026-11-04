using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.IO;
using System.Windows.Forms;

namespace DeadLoad.Tray.Ui
{
    /// <summary>A container whose children sit on its own surface color (a card, the page).</summary>
    internal interface ISurface
    {
        Color Surface { get; }
    }

    /// <summary>A control that sets its own colors (lists, text boxes); surfaces leave it alone.</summary>
    internal interface ISelfColored
    {
    }

    internal static class Surfaces
    {
        /// <summary>
        /// Gives every child the surface color of the container it sits in, so rounded corners,
        /// text backgrounds and ClearType all blend with the card or page behind them.
        /// </summary>
        public static void Apply(Control root)
        {
            var surface = root as ISurface;
            Color color = surface != null ? surface.Surface : root.BackColor;
            foreach (Control child in root.Controls)
            {
                if (child is ISelfColored || child is ListView || child is TextBoxBase) { continue; }
                child.BackColor = color;
                Apply(child);
            }
        }
    }

    /// <summary>
    /// Lays its children out top to bottom at its full width, each as tall as it asks to be for
    /// that width (GetPreferredSize), with a fixed gap. Lists, text boxes and other controls
    /// without a meaningful preferred height keep the height they were given.
    /// </summary>
    internal class StackPanel : Panel, ISurface
    {
        private bool laying;

        public StackPanel()
        {
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.ResizeRedraw, true);
        }

        /// <summary>Gap between children, already scaled.</summary>
        public int Spacing { get; set; }

        public virtual Color Surface
        {
            get { return BackColor; }
        }

        protected override void OnLayout(LayoutEventArgs levent)
        {
            if (laying) { return; }
            laying = true;
            try
            {
                Arrange(ClientSize.Width, true);
            }
            finally
            {
                laying = false;
            }
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            int width = proposedSize.Width > 0 && proposedSize.Width < int.MaxValue / 2 ? proposedSize.Width : Width;
            return new Size(width, Arrange(width, false));
        }

        private int Arrange(int width, bool apply)
        {
            int inner = Math.Max(0, width - Padding.Horizontal);
            int y = Padding.Top;
            bool first = true;
            for (int i = 0; i < Controls.Count; i++)
            {
                Control child = Controls[i];
                if (!first) { y += Spacing; }
                first = false;
                // A bleeding child (a button bar) extends past the content edge by the focus ring
                // room its buttons reserve, so the button bodies line up with the text.
                var bleeding = child as IBleed;
                int bleed = bleeding == null ? 0 : bleeding.Bleed;
                int w = Math.Max(0, inner - child.Margin.Horizontal + (bleed * 2));
                int h = PreferredHeight(child, w);
                if (apply)
                {
                    child.SetBounds(Padding.Left + child.Margin.Left - bleed, y + child.Margin.Top - bleed, w, h);
                    // Nested content can change height without this child changing size.
                    if (child is StackPanel || child is CategoryRow) { child.PerformLayout(); }
                }
                y += Math.Max(0, h - (bleed * 2)) + child.Margin.Vertical;
            }
            return y + Padding.Bottom;
        }

        internal static int PreferredHeight(Control child, int width)
        {
            if (child is TextBoxBase || child is ListView) { return child.Height; }
            return child.GetPreferredSize(new Size(width, 0)).Height;
        }
    }

    /// <summary>A child that draws outside the content edge by this many pixels on every side.</summary>
    internal interface IBleed
    {
        int Bleed { get; }
    }

    /// <summary>A card: rounded 10 px surface with a 1 px border, children on the card color.</summary>
    internal sealed class Card : StackPanel
    {
        public Card()
        {
            Palette p = ThemeManager.Palette;
            CardColor = p.Card;
            Padding = new Padding(ThemeManager.S(20), ThemeManager.S(16), ThemeManager.S(20), ThemeManager.S(20));
            Spacing = ThemeManager.S(12);
        }

        public Color CardColor { get; set; }

        public override Color Surface
        {
            get { return CardColor; }
        }

        protected override void OnPaintBackground(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
            Draw.Smooth(e.Graphics);
            Draw.FillRounded(e.Graphics, ClientRectangle, ThemeManager.S(ThemeTokens.RadiusCard), CardColor, ThemeManager.Palette.Border);
        }
    }

    /// <summary>
    /// The scrolling page area. Holds one StackPanel as wide as the viewport and as tall as its
    /// content; the vertical scroll bar appears when the content is taller.
    /// </summary>
    internal sealed class ScrollHost : Panel
    {
        private bool laying;
        private StackPanel content;

        public ScrollHost()
        {
            AutoScroll = true;
            SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint, true);
        }

        public StackPanel Content
        {
            get { return content; }
            set
            {
                SuspendLayout();
                Control old = content;
                content = value;
                if (old != null) { Controls.Remove(old); old.Dispose(); }
                if (content != null) { Controls.Add(content); }
                AutoScrollPosition = Point.Empty;
                ResumeLayout(true);
            }
        }

        protected override void OnLayout(LayoutEventArgs levent)
        {
            if (laying || content == null)
            {
                base.OnLayout(levent);
                return;
            }
            laying = true;
            try
            {
                // Up to three passes: showing the vertical scroll bar narrows the client area,
                // which can make the text wrap and the content grow.
                for (int pass = 0; pass < 3; pass++)
                {
                    int width = ClientSize.Width;
                    int height = content.GetPreferredSize(new Size(width, 0)).Height;
                    content.SetBounds(0, AutoScrollPosition.Y, width, height);
                    AutoScrollMinSize = new Size(0, height);
                    // ScrollableControl shows or hides the scroll bars here.
                    base.OnLayout(levent);
                    if (ClientSize.Width == width) { break; }
                }
                content.PerformLayout();
            }
            finally
            {
                laying = false;
            }
        }
    }

    /// <summary>Static or wrapped text, drawn with GDI (TextRenderer) like native labels.</summary>
    internal sealed class TextBlock : Control
    {
        public TextBlock(string text, Font font, Color color, bool wrap)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            SetStyle(ControlStyles.Selectable, false);
            TabStop = false;
            Text = text ?? string.Empty;
            Font = font;
            ForeColor = color;
            Wrap = wrap;
            AccessibleRole = AccessibleRole.StaticText;
            AccessibleName = Text;
            Margin = Padding.Empty;
        }

        public bool Wrap { get; set; }

        public bool AlignRight { get; set; }

        protected override void OnTextChanged(EventArgs e)
        {
            base.OnTextChanged(e);
            AccessibleName = Text;
            Invalidate();
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            Size single = Draw.Measure(Text, Font);
            if (!Wrap || proposedSize.Width <= 0 || proposedSize.Width >= int.MaxValue / 2 || single.Width <= proposedSize.Width)
            {
                return new Size(single.Width, Math.Max(single.Height, Font.Height));
            }
            Size wrapped = Draw.MeasureWrapped(Text, Font, proposedSize.Width);
            return new Size(proposedSize.Width, wrapped.Height);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
            TextFormatFlags flags = Wrap ? Draw.Wrapped : Draw.SingleLine;
            if (AlignRight) { flags |= TextFormatFlags.Right; }
            TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, Enabled ? ForeColor : ThemeManager.Palette.DisabledText, BackColor, flags);
        }
    }

    internal enum ButtonKind
    {
        Primary,
        Secondary,
    }

    /// <summary>
    /// Primary (solid blue) or secondary (outlined) button with hover, pressed, focus and disabled
    /// states. The focus ring is drawn outside the body, so the control reserves the ring's
    /// width on every side. Under high contrast it is a standard system button.
    /// </summary>
    internal sealed class ThemedButton : Button
    {
        private bool hover;
        private bool pressed;
        private readonly bool large;

        public ThemedButton(string text, ButtonKind kind, bool large)
        {
            this.large = large;
            Kind = kind;
            Text = text;
            Font = ThemeManager.Semibold(FontRole.Text, ThemeTokens.FontSizeAppBodyPx);
            AutoSize = true;
            AutoSizeMode = AutoSizeMode.GrowAndShrink;
            Margin = Padding.Empty;
            if (ThemeManager.Palette.IsHighContrast)
            {
                FlatStyle = FlatStyle.System;
                UseVisualStyleBackColor = true;
                Margin = new Padding(ThemeManager.S(4));
            }
            else
            {
                FlatStyle = FlatStyle.Flat;
                FlatAppearance.BorderSize = 0;
                SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            }
            AccessibleName = text;
        }

        public ButtonKind Kind { get; private set; }

        private int Inset
        {
            get { return ThemeManager.Palette.IsHighContrast ? 0 : Draw.FocusInset; }
        }

        protected override bool ShowFocusCues
        {
            get { return true; }
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            Size text = Draw.Measure(Text, Font);
            int height = ThemeManager.S(large ? ThemeTokens.ControlHeightPrimary : ThemeTokens.ControlHeight);
            int width = Math.Max(ThemeManager.S(96), text.Width + ThemeManager.S(large ? 40 : 32));
            return new Size(width + (Inset * 2), height + (Inset * 2));
        }

        protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
        protected override void OnMouseLeave(EventArgs e) { hover = false; pressed = false; Invalidate(); base.OnMouseLeave(e); }
        protected override void OnMouseDown(MouseEventArgs mevent) { if (mevent.Button == MouseButtons.Left) { pressed = true; Invalidate(); } base.OnMouseDown(mevent); }
        protected override void OnMouseUp(MouseEventArgs mevent) { pressed = false; Invalidate(); base.OnMouseUp(mevent); }
        protected override void OnKeyDown(KeyEventArgs kevent) { if (kevent.KeyCode == Keys.Space) { pressed = true; Invalidate(); } base.OnKeyDown(kevent); }
        protected override void OnKeyUp(KeyEventArgs kevent) { pressed = false; Invalidate(); base.OnKeyUp(kevent); }
        protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
        protected override void OnGotFocus(EventArgs e) { Invalidate(); base.OnGotFocus(e); }
        protected override void OnLostFocus(EventArgs e) { Invalidate(); base.OnLostFocus(e); }

        protected override void OnPaint(PaintEventArgs pevent)
        {
            Palette p = ThemeManager.Palette;
            if (p.IsHighContrast)
            {
                base.OnPaint(pevent);
                return;
            }
            Graphics g = pevent.Graphics;
            g.Clear(BackColor);
            Draw.Smooth(g);
            int inset = Inset;
            var body = new Rectangle(inset, inset, Width - (inset * 2), Height - (inset * 2));
            int radius = ThemeManager.S(ThemeTokens.RadiusControl);
            Color fill;
            Color text;
            Color border = Color.Empty;
            if (!Enabled)
            {
                fill = p.DisabledBack;
                text = p.DisabledText;
            }
            else if (Kind == ButtonKind.Primary)
            {
                fill = pressed ? p.AccentPressed : (hover ? p.AccentHover : p.Accent);
                text = p.OnAccent;
            }
            else
            {
                fill = pressed ? p.SecondaryPressed : (hover ? p.SecondaryHover : p.SecondaryBack);
                text = p.SecondaryText;
                border = p.ControlBorder;
            }
            if (border.IsEmpty) { Draw.FillRounded(g, body, radius, fill); }
            else { Draw.FillRounded(g, body, radius, fill, border); }
            TextRenderer.DrawText(g, Text, Font, body, text, fill,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
            if (Focused && Enabled) { Draw.FocusRing(g, body, radius); }
        }
    }

    /// <summary>A row of buttons that wraps when the window is narrow.</summary>
    internal sealed class ButtonBar : FlowLayoutPanel, IBleed
    {
        public ButtonBar(bool rightAligned)
        {
            WrapContents = true;
            AutoSize = false;
            FlowDirection = rightAligned ? FlowDirection.RightToLeft : FlowDirection.LeftToRight;
            Margin = Padding.Empty;
            Padding = Padding.Empty;
        }

        /// <summary>
        /// Buttons reserve their focus ring; the bar reaches out by that much so the button
        /// bodies line up with the text above and below (a negative Margin did not move the bar in
        /// the first renders, so StackPanel applies the bleed itself).
        /// </summary>
        public int Bleed
        {
            get { return ThemeManager.Palette.IsHighContrast ? 0 : Draw.FocusInset; }
        }

        public ThemedButton Add(ThemedButton button)
        {
            Controls.Add(button);
            return button;
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            Size size = base.GetPreferredSize(proposedSize);
            return new Size(proposedSize.Width > 0 ? proposedSize.Width : size.Width, size.Height);
        }
    }

    /// <summary>A 1 px horizontal rule in the border color.</summary>
    internal sealed class Divider : Control
    {
        public Divider()
        {
            SetStyle(ControlStyles.Selectable, false);
            TabStop = false;
            Margin = Padding.Empty;
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            return new Size(proposedSize.Width, 1);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(ThemeManager.Palette.Border);
        }
    }

    /// <summary>
    /// The risk label of a category: glyph plus text (Routine: check, Review: info, Restricted:
    /// lock), on a low-emphasis tone background, so the tier never depends on color alone.
    /// </summary>
    internal sealed class RiskBadge : Control
    {
        public RiskBadge(string risk)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            SetStyle(ControlStyles.Selectable, false);
            TabStop = false;
            Text = Label(risk);
            Font = ThemeManager.Semibold(FontRole.Text, ThemeTokens.FontSizeAppCaptionPx);
            AccessibleRole = AccessibleRole.StaticText;
            AccessibleName = "Risk: " + Text;
            Margin = Padding.Empty;
        }

        public static string Label(string risk)
        {
            if (string.Equals(risk, "Routine", StringComparison.OrdinalIgnoreCase)) { return "Routine"; }
            if (string.Equals(risk, "Review", StringComparison.OrdinalIgnoreCase)) { return "Review"; }
            if (string.Equals(risk, "Restricted", StringComparison.OrdinalIgnoreCase)) { return "Restricted"; }
            return string.IsNullOrEmpty(risk) ? "Unknown" : risk;
        }

        public static void Describe(string risk, out Tone tone, out Glyph glyph)
        {
            // tokens.json risk tones: Routine success, Review warning, Restricted danger.
            switch (Label(risk))
            {
                case "Routine": tone = Tone.Success; glyph = Glyph.Check; break;
                case "Review": tone = Tone.Warning; glyph = Glyph.Info; break;
                case "Restricted": tone = Tone.Danger; glyph = Glyph.Lock; break;
                default: tone = Tone.Neutral; glyph = Glyph.Info; break;
            }
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            return BadgeSize(Text);
        }

        public static Size BadgeSize(string risk)
        {
            Size text = Draw.Measure(Label(risk), ThemeManager.Semibold(FontRole.Text, ThemeTokens.FontSizeAppCaptionPx));
            return new Size(ThemeManager.S(8 + 12 + 4 + 8) + text.Width, ThemeManager.S(22));
        }

        /// <summary>Draws a badge with its top left corner at the given point (rows draw it inline).</summary>
        public static void DrawBadge(Graphics g, Point location, string risk)
        {
            Palette p = ThemeManager.Palette;
            Tone tone;
            Glyph glyph;
            Describe(risk, out tone, out glyph);
            Font font = ThemeManager.Semibold(FontRole.Text, ThemeTokens.FontSizeAppCaptionPx);
            Size size = BadgeSize(risk);
            var body = new Rectangle(location, size);
            Color back = p.ToneBack(tone);
            Color fore = p.ToneText(tone);
            Draw.Smooth(g);
            if (p.IsHighContrast) { Draw.FillRounded(g, body, ThemeManager.S(4), back, p.Border); }
            else { Draw.FillRounded(g, body, ThemeManager.S(4), back); }
            int icon = ThemeManager.S(12);
            Draw.Icon(g, glyph, new Rectangle(body.X + ThemeManager.S(8), body.Y + ((body.Height - icon) / 2), icon, icon), fore);
            var textRect = new Rectangle(body.X + ThemeManager.S(8 + 12 + 4), body.Y, body.Width - ThemeManager.S(8 + 12 + 4), body.Height);
            TextRenderer.DrawText(g, Label(risk), font, textRect, fore, back, Draw.SingleLine | TextFormatFlags.VerticalCenter);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
            Size size = BadgeSize(Text);
            DrawBadge(e.Graphics, new Point(0, (Height - size.Height) / 2), Text);
        }
    }

    /// <summary>
    /// A large number with its unit, a caption, and the qualifier that says what kind of number
    /// it is: "Estimated" before a cleanup, "Recovered" after it (never one number for both).
    /// </summary>
    internal sealed class ResultMetric : Control
    {
        private readonly string value;
        private readonly string unit;
        private readonly string caption;
        private readonly string qualifier;
        private readonly string detail;
        private readonly Tone qualifierTone;
        private readonly Font valueFont = ThemeManager.Semibold(FontRole.Display, ThemeTokens.FontSizeAppHeadlinePx);
        private readonly Font unitFont = ThemeManager.Semibold(FontRole.Display, ThemeTokens.FontSizeAppTitlePx);
        private readonly Font captionFont = ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppSubtitlePx);
        private readonly Font qualifierFont = ThemeManager.Semibold(FontRole.Text, ThemeTokens.FontSizeAppCaptionPx);
        private readonly Font detailFont = ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppBodyPx);

        public ResultMetric(long bytes, string caption, bool recovered, string detail)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            SetStyle(ControlStyles.Selectable, false);
            TabStop = false;
            string text = LastRunReport.FormatBytes(bytes);
            int space = text.LastIndexOf(' ');
            value = space > 0 ? text.Substring(0, space) : text;
            unit = space > 0 ? text.Substring(space + 1) : string.Empty;
            this.caption = caption ?? string.Empty;
            qualifier = recovered ? "Recovered" : "Estimated";
            qualifierTone = recovered ? Tone.Success : Tone.Info;
            this.detail = detail ?? string.Empty;
            AccessibleRole = AccessibleRole.StaticText;
            AccessibleName = text + " " + this.caption + " (" + qualifier.ToLowerInvariant() + "). " + this.detail;
            Margin = Padding.Empty;
        }

        private bool CaptionOnOwnLine(int width)
        {
            int line = Draw.Measure(value, valueFont).Width + ThemeManager.S(4) + Draw.Measure(unit, unitFont).Width + ThemeManager.S(8) + Draw.Measure(caption, captionFont).Width;
            return line > width;
        }

        private int QualifierHeight
        {
            get { return ThemeManager.S(22); }
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            int width = proposedSize.Width > 0 ? proposedSize.Width : int.MaxValue;
            int height = valueFont.Height;
            if (CaptionOnOwnLine(width)) { height += captionFont.Height; }
            height += ThemeManager.S(8) + QualifierHeight;
            if (DetailOnOwnLine(width)) { height += ThemeManager.S(6) + Draw.MeasureWrapped(detail, detailFont, Math.Max(1, width == int.MaxValue ? ThemeManager.S(360) : width)).Height; }
            return new Size(proposedSize.Width > 0 ? proposedSize.Width : ThemeManager.S(360), height);
        }

        private int PillWidth
        {
            get { return ThemeManager.S(8 + 12 + 4 + 8) + Draw.Measure(qualifier, qualifierFont).Width; }
        }

        /// <summary>The detail goes under the qualifier when both do not fit on one line.</summary>
        private bool DetailOnOwnLine(int width)
        {
            return detail.Length > 0 && PillWidth + ThemeManager.S(12) + Draw.Measure(detail, detailFont).Width > width;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Palette p = ThemeManager.Palette;
            Graphics g = e.Graphics;
            g.Clear(BackColor);
            int baseline = Draw.Ascent(valueFont);
            int x = 0;
            Size valueSize = Draw.Measure(value, valueFont);
            TextRenderer.DrawText(g, value, valueFont, new Point(x, 0), p.Heading, BackColor, Draw.SingleLine);
            x += valueSize.Width + ThemeManager.S(4);
            int unitTop = baseline - Draw.Ascent(unitFont);
            TextRenderer.DrawText(g, unit, unitFont, new Point(x, unitTop), p.Heading, BackColor, Draw.SingleLine);
            x += Draw.Measure(unit, unitFont).Width + ThemeManager.S(8);
            int y = valueFont.Height;
            if (CaptionOnOwnLine(Width))
            {
                TextRenderer.DrawText(g, caption, captionFont, new Rectangle(0, y, Width, captionFont.Height), p.TextSecondary, BackColor, Draw.SingleLine);
                y += captionFont.Height;
            }
            else
            {
                int captionTop = baseline - Draw.Ascent(captionFont);
                TextRenderer.DrawText(g, caption, captionFont, new Rectangle(x, captionTop, Width - x, captionFont.Height), p.TextSecondary, BackColor, Draw.SingleLine);
            }
            y += ThemeManager.S(8);

            Draw.Smooth(g);
            Size q = Draw.Measure(qualifier, qualifierFont);
            int icon = ThemeManager.S(12);
            var pill = new Rectangle(0, y, ThemeManager.S(8 + 12 + 4 + 8) + q.Width, QualifierHeight);
            Color back = p.ToneBack(qualifierTone);
            Color fore = p.ToneText(qualifierTone);
            if (p.IsHighContrast) { Draw.FillRounded(g, pill, ThemeManager.S(4), back, p.Border); }
            else { Draw.FillRounded(g, pill, ThemeManager.S(4), back); }
            Draw.Icon(g, qualifierTone == Tone.Success ? Glyph.Check : Glyph.Info, new Rectangle(pill.X + ThemeManager.S(8), pill.Y + ((pill.Height - icon) / 2), icon, icon), fore);
            TextRenderer.DrawText(g, qualifier, qualifierFont, new Rectangle(pill.X + ThemeManager.S(24), pill.Y, q.Width + ThemeManager.S(8), pill.Height), fore, back, Draw.SingleLine | TextFormatFlags.VerticalCenter);
            if (DetailOnOwnLine(Width))
            {
                int top = pill.Bottom + ThemeManager.S(6);
                TextRenderer.DrawText(g, detail, detailFont, new Rectangle(0, top, Width, Math.Max(0, Height - top)), p.TextSecondary, BackColor, Draw.Wrapped);
            }
            else
            {
                int detailX = pill.Right + ThemeManager.S(12);
                TextRenderer.DrawText(g, detail, detailFont, new Rectangle(detailX, pill.Y, Math.Max(0, Width - detailX), pill.Height), p.TextSecondary, BackColor, Draw.SingleLine | TextFormatFlags.VerticalCenter);
            }
        }
    }

    /// <summary>
    /// The system volume as used and free space with the denominator stated in words
    /// ("41.0 GB free of 476 GB"), not a ring that implies a percentage of anything else.
    /// </summary>
    internal sealed class CapacityBar : Control
    {
        private readonly string title;
        private readonly string summary;
        private readonly string legend;
        private readonly double usedFraction;
        private readonly bool known;
        private readonly Font titleFont = ThemeManager.Semibold(FontRole.Text, ThemeTokens.FontSizeAppBodyPx);
        private readonly Font textFont = ThemeManager.Font(FontRole.Numeric, ThemeTokens.FontSizeAppBodyPx);
        private readonly Font legendFont = ThemeManager.Font(FontRole.Numeric, ThemeTokens.FontSizeAppCaptionPx);

        public CapacityBar(string drive, long? sizeBytes, long? freeBytes)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            SetStyle(ControlStyles.Selectable, false);
            TabStop = false;
            string letter = string.IsNullOrEmpty(drive) ? "C:" : drive.TrimEnd('\\');
            title = "Local disk (" + letter + ")";
            known = sizeBytes.HasValue && freeBytes.HasValue && sizeBytes.Value > 0;
            if (known)
            {
                long used = Math.Max(0, sizeBytes.Value - freeBytes.Value);
                usedFraction = Math.Min(1.0, used / (double)sizeBytes.Value);
                summary = LastRunReport.FormatBytes(freeBytes.Value) + " free of " + LastRunReport.FormatBytes(sizeBytes.Value);
                legend = LastRunReport.FormatBytes(used) + " used";
            }
            else
            {
                summary = "Drive space is not available.";
                legend = string.Empty;
            }
            AccessibleRole = AccessibleRole.ProgressBar;
            AccessibleName = title + ": " + summary + (legend.Length > 0 ? ", " + legend : string.Empty);
            Margin = Padding.Empty;
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            int height = titleFont.Height + ThemeManager.S(8) + ThemeManager.S(8) + ThemeManager.S(6) + legendFont.Height;
            return new Size(proposedSize.Width > 0 ? proposedSize.Width : ThemeManager.S(320), height);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Palette p = ThemeManager.Palette;
            Graphics g = e.Graphics;
            g.Clear(BackColor);
            TextRenderer.DrawText(g, title, titleFont, new Rectangle(0, 0, Width, titleFont.Height), p.TextPrimary, BackColor, Draw.SingleLine);
            int summaryWidth = Draw.Measure(summary, textFont).Width;
            int titleWidth = Draw.Measure(title, titleFont).Width;
            int y = titleFont.Height;
            if (titleWidth + ThemeManager.S(16) + summaryWidth <= Width)
            {
                TextRenderer.DrawText(g, summary, textFont, new Rectangle(0, 0, Width, titleFont.Height), p.TextSecondary, BackColor, Draw.SingleLine | TextFormatFlags.Right | TextFormatFlags.Bottom);
            }
            y += ThemeManager.S(8);
            if (!known) { return; }
            int barHeight = ThemeManager.S(8);
            var track = new Rectangle(0, y, Width, barHeight);
            Draw.Smooth(g);
            if (p.IsHighContrast) { Draw.FillRounded(g, track, barHeight / 2, p.Track, p.Border); }
            else { Draw.FillRounded(g, track, barHeight / 2, p.Track); }
            int usedWidth = (int)Math.Round(Width * usedFraction);
            if (usedWidth > 0)
            {
                Draw.FillRounded(g, new Rectangle(0, y, Math.Max(barHeight, usedWidth), barHeight), barHeight / 2, p.CapacityUsed);
            }
            y += barHeight + ThemeManager.S(6);
            TextRenderer.DrawText(g, legend, legendFont, new Rectangle(0, y, Width, legendFont.Height), p.TextMuted, BackColor, Draw.SingleLine);
            if (titleWidth + ThemeManager.S(16) + summaryWidth > Width)
            {
                TextRenderer.DrawText(g, summary, legendFont, new Rectangle(0, y, Width, legendFont.Height), p.TextMuted, BackColor, Draw.SingleLine | TextFormatFlags.Right);
            }
        }
    }

    /// <summary>
    /// Indeterminate progress: a calm blue segment moving along a track, with the status line.
    /// With Windows animations off it shows evenly spaced static marks instead (no motion, and
    /// no partial fill that would read as a percentage).
    /// </summary>
    internal sealed class ProgressStrip : Control
    {
        private readonly Timer timer;
        private readonly string status;
        private readonly string detail;
        private readonly Font statusFont = ThemeManager.Semibold(FontRole.Text, ThemeTokens.FontSizeAppBodyPx);
        private readonly Font detailFont = ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppCaptionPx);
        private int phase;

        public ProgressStrip(string status, string detail)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            SetStyle(ControlStyles.Selectable, false);
            TabStop = false;
            this.status = status;
            this.detail = detail ?? string.Empty;
            AccessibleRole = AccessibleRole.ProgressBar;
            AccessibleName = status;
            AccessibleDescription = this.detail;
            Margin = Padding.Empty;
            timer = new Timer { Interval = 33 };
            timer.Tick += (sender, args) => { phase = (phase + 1) % 60; Invalidate(); };
        }

        protected override AccessibleObject CreateAccessibilityInstance()
        {
            return new ProgressAccessible(this);
        }

        private sealed class ProgressAccessible : ControlAccessibleObject
        {
            public ProgressAccessible(ProgressStrip owner) : base(owner) { }
            public override string Value { get { return "In progress"; } set { } }
        }

        protected override void OnVisibleChanged(EventArgs e)
        {
            base.OnVisibleChanged(e);
            UpdateTimer();
        }

        protected override void OnHandleCreated(EventArgs e)
        {
            base.OnHandleCreated(e);
            UpdateTimer();
        }

        private void UpdateTimer()
        {
            timer.Enabled = Visible && IsHandleCreated && !ThemeManager.ReducedMotion;
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            int height = statusFont.Height + ThemeManager.S(12) + ThemeManager.S(4) + ThemeManager.S(8);
            if (detail.Length > 0)
            {
                int width = proposedSize.Width > 0 ? proposedSize.Width : ThemeManager.S(400);
                height += Draw.MeasureWrapped(detail, detailFont, width).Height;
            }
            return new Size(proposedSize.Width > 0 ? proposedSize.Width : ThemeManager.S(400), height);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Palette p = ThemeManager.Palette;
            Graphics g = e.Graphics;
            g.Clear(BackColor);
            TextRenderer.DrawText(g, status, statusFont, new Rectangle(0, 0, Width, statusFont.Height), p.TextPrimary, BackColor, Draw.SingleLine);
            int y = statusFont.Height + ThemeManager.S(12);
            int barHeight = ThemeManager.S(4);
            var track = new Rectangle(0, y, Width, barHeight);
            Draw.Smooth(g);
            Draw.FillRounded(g, track, barHeight / 2, p.Track);
            if (ThemeManager.ReducedMotion)
            {
                int mark = ThemeManager.S(24);
                for (int x = 0; x + mark <= Width; x += mark * 3)
                {
                    Draw.FillRounded(g, new Rectangle(x, y, mark, barHeight), barHeight / 2, p.Accent);
                }
            }
            else
            {
                int segment = Math.Max(ThemeManager.S(48), Width / 4);
                int travel = Width + segment;
                int left = (int)(travel * (phase / 60.0)) - segment;
                var region = Rectangle.Intersect(track, new Rectangle(left, y, segment, barHeight));
                if (region.Width > 0) { Draw.FillRounded(g, region, barHeight / 2, p.Accent); }
            }
            y += barHeight + ThemeManager.S(8);
            if (detail.Length > 0)
            {
                TextRenderer.DrawText(g, detail, detailFont, new Rectangle(0, y, Width, Height - y), p.TextSecondary, BackColor, Draw.Wrapped);
            }
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) { timer.Dispose(); }
            base.Dispose(disposing);
        }
    }

    /// <summary>An inline message with a tone glyph: information, a warning, a success, an error.</summary>
    internal sealed class Notice : Control
    {
        private readonly Tone tone;
        private readonly string title;
        private readonly string body;
        private readonly Font titleFont = ThemeManager.Semibold(FontRole.Text, ThemeTokens.FontSizeAppBodyPx);
        private readonly Font bodyFont = ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppBodyPx);

        public Notice(Tone tone, string title, string body)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            SetStyle(ControlStyles.Selectable, false);
            TabStop = false;
            this.tone = tone;
            this.title = title ?? string.Empty;
            this.body = body ?? string.Empty;
            AccessibleRole = AccessibleRole.StaticText;
            AccessibleName = (this.title + " " + this.body).Trim();
            Margin = Padding.Empty;
        }

        private Glyph Glyph
        {
            get
            {
                switch (tone)
                {
                    case Tone.Warning: return Glyph.Warning;
                    case Tone.Danger: return Glyph.Error;
                    case Tone.Success: return Glyph.Success;
                    default: return Glyph.Info;
                }
            }
        }

        private int TextLeft { get { return ThemeManager.S(12 + 16 + 10); } }

        public override Size GetPreferredSize(Size proposedSize)
        {
            int width = proposedSize.Width > 0 ? proposedSize.Width : ThemeManager.S(480);
            int textWidth = Math.Max(1, width - TextLeft - ThemeManager.S(12));
            int height = ThemeManager.S(10) * 2;
            if (title.Length > 0) { height += Draw.MeasureWrapped(title, titleFont, textWidth).Height; }
            if (title.Length > 0 && body.Length > 0) { height += ThemeManager.S(2); }
            if (body.Length > 0) { height += Draw.MeasureWrapped(body, bodyFont, textWidth).Height; }
            return new Size(width, Math.Max(height, ThemeManager.S(40)));
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Palette p = ThemeManager.Palette;
            Graphics g = e.Graphics;
            g.Clear(BackColor);
            Draw.Smooth(g);
            Color back = p.ToneBack(tone);
            Color border = p.IsHighContrast ? p.Border : Draw.Blend(back, p.ToneText(tone), 0.25);
            Draw.FillRounded(g, ClientRectangle, ThemeManager.S(ThemeTokens.RadiusControl), back, border);
            int icon = ThemeManager.S(16);
            int y = ThemeManager.S(10);
            int lineOffset = Math.Max(0, ((title.Length > 0 ? titleFont.Height : bodyFont.Height) - icon) / 2);
            Draw.Icon(g, Glyph, new Rectangle(ThemeManager.S(12), y + lineOffset, icon, icon), p.ToneText(tone));
            int textWidth = Math.Max(1, Width - TextLeft - ThemeManager.S(12));
            if (title.Length > 0)
            {
                int h = Draw.MeasureWrapped(title, titleFont, textWidth).Height;
                TextRenderer.DrawText(g, title, titleFont, new Rectangle(TextLeft, y, textWidth, h), p.TextPrimary, back, Draw.Wrapped);
                y += h + ThemeManager.S(2);
            }
            if (body.Length > 0)
            {
                int h = Draw.MeasureWrapped(body, bodyFont, textWidth).Height;
                TextRenderer.DrawText(g, body, bodyFont, new Rectangle(TextLeft, y, textWidth, h), p.TextPrimary, back, Draw.Wrapped);
            }
        }
    }

    /// <summary>One label and value pair; FactList aligns the labels in one column.</summary>
    internal sealed class FactRow : Control
    {
        private readonly string label;
        private readonly string value;
        private readonly bool numeric;
        private readonly Font labelFont = ThemeManager.Font(FontRole.Text, ThemeTokens.FontSizeAppBodyPx);

        public FactRow(string label, string value, bool numeric)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.ResizeRedraw | ControlStyles.SupportsTransparentBackColor, true);
            SetStyle(ControlStyles.Selectable, false);
            TabStop = false;
            this.label = label;
            this.value = string.IsNullOrEmpty(value) ? "-" : value;
            this.numeric = numeric;
            AccessibleRole = AccessibleRole.StaticText;
            AccessibleName = label + ": " + this.value;
            Margin = Padding.Empty;
        }

        public int LabelWidth { get; set; }

        public int MeasureLabel()
        {
            return Draw.Measure(label, labelFont).Width;
        }

        private Font ValueFont
        {
            get { return ThemeManager.Font(numeric ? FontRole.Numeric : FontRole.Text, ThemeTokens.FontSizeAppBodyPx); }
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            int width = proposedSize.Width > 0 ? proposedSize.Width : ThemeManager.S(400);
            int valueWidth = Math.Max(1, width - LabelWidth - ThemeManager.S(16));
            int height = Math.Max(labelFont.Height, Draw.MeasureWrapped(value, ValueFont, valueWidth).Height);
            return new Size(width, height);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            Palette p = ThemeManager.Palette;
            e.Graphics.Clear(BackColor);
            TextRenderer.DrawText(e.Graphics, label, labelFont, new Rectangle(0, 0, LabelWidth, labelFont.Height), p.TextSecondary, BackColor, Draw.SingleLine);
            int x = LabelWidth + ThemeManager.S(16);
            TextRenderer.DrawText(e.Graphics, value, ValueFont, new Rectangle(x, 0, Math.Max(1, Width - x), Height), p.TextPrimary, BackColor, Draw.Wrapped);
        }
    }

    /// <summary>A list of label and value pairs with the labels in one aligned column.</summary>
    internal sealed class FactList : StackPanel
    {
        public FactList()
        {
            Spacing = ThemeManager.S(6);
            Margin = Padding.Empty;
        }

        public void Add(string label, string value, bool numeric)
        {
            var row = new FactRow(label, value, numeric);
            Controls.Add(row);
            int width = 0;
            foreach (Control c in Controls)
            {
                var r = c as FactRow;
                if (r != null) { width = Math.Max(width, r.MeasureLabel()); }
            }
            foreach (Control c in Controls)
            {
                var r = c as FactRow;
                if (r != null) { r.LabelWidth = width; }
            }
        }
    }

    /// <summary>The DeadLoad mark from the embedded icon at a given size.</summary>
    internal sealed class BrandMark : Control
    {
        private readonly Bitmap image;
        private readonly int size;

        public BrandMark(int size)
        {
            SetStyle(ControlStyles.UserPaint | ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.SupportsTransparentBackColor, true);
            SetStyle(ControlStyles.Selectable, false);
            TabStop = false;
            this.size = size;
            image = Load(256);
            AccessibleRole = AccessibleRole.Graphic;
            AccessibleName = "DeadLoad mark";
            Margin = Padding.Empty;
        }

        public static Icon LoadIcon(int pixels)
        {
            try
            {
                using (Stream stream = typeof(BrandMark).Assembly.GetManifestResourceStream("DeadLoad.ico"))
                {
                    if (stream != null) { return new Icon(stream, pixels, pixels); }
                }
            }
            catch (Exception)
            {
                // No embedded icon: the caller falls back.
            }
            return null;
        }

        private static Bitmap Load(int pixels)
        {
            using (Icon icon = LoadIcon(pixels))
            {
                return icon == null ? null : icon.ToBitmap();
            }
        }

        public override Size GetPreferredSize(Size proposedSize)
        {
            return new Size(size, size);
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            e.Graphics.Clear(BackColor);
            if (image == null) { return; }
            e.Graphics.InterpolationMode = InterpolationMode.HighQualityBicubic;
            e.Graphics.PixelOffsetMode = PixelOffsetMode.HighQuality;
            e.Graphics.DrawImage(image, new Rectangle(0, 0, size, size));
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing && image != null) { image.Dispose(); }
            base.Dispose(disposing);
        }
    }
}
