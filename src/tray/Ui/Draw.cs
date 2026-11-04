using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace DeadLoad.Tray.Ui
{
    internal enum Glyph
    {
        None,
        Check,
        Info,
        Lock,
        Warning,
        Error,
        Success,
        Layers,
        Chart,
        Clock,
        Sliders,
        ChevronDown,
        ChevronRight,
    }

    /// <summary>
    /// Drawing helpers: color mixing, rounded shapes, the focus ring and the line glyphs. Glyphs
    /// are simple vectors (1.5 px strokes at 96 DPI), so no icon font has to be installed.
    /// </summary>
    internal static class Draw
    {
        public const TextFormatFlags SingleLine = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix;
        public const TextFormatFlags Wrapped = TextFormatFlags.NoPadding | TextFormatFlags.WordBreak | TextFormatFlags.TextBoxControl | TextFormatFlags.NoPrefix;
        private const TextFormatFlags MeasureLine = TextFormatFlags.NoPadding | TextFormatFlags.SingleLine | TextFormatFlags.NoPrefix;
        // MeasureText without a device context keeps GDI's side padding despite NoPadding
        // (measured: "8.0" at 28 px semibold, 56 px without a Graphics, 39 px with one), so every
        // measurement goes through one small bitmap's Graphics, as the drawing does.
        private static readonly Bitmap MeasureBitmap = new Bitmap(1, 1);
        private static readonly Graphics MeasureGraphics = Graphics.FromImage(MeasureBitmap);

        public static Color Blend(Color background, Color foreground, double amount)
        {
            amount = Math.Max(0, Math.Min(1, amount));
            return Color.FromArgb(
                (int)Math.Round(background.R + (foreground.R - background.R) * amount),
                (int)Math.Round(background.G + (foreground.G - background.G) * amount),
                (int)Math.Round(background.B + (foreground.B - background.B) * amount));
        }

        public static GraphicsPath RoundedRect(RectangleF rect, float radius)
        {
            var path = new GraphicsPath();
            float d = Math.Min(radius * 2, Math.Min(rect.Width, rect.Height));
            if (d <= 0.5f)
            {
                path.AddRectangle(rect);
                return path;
            }
            path.AddArc(rect.X, rect.Y, d, d, 180, 90);
            path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
            path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
            path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
            path.CloseFigure();
            return path;
        }

        public static void FillRounded(Graphics g, Rectangle rect, int radius, Color fill)
        {
            using (var path = RoundedRect(rect, radius))
            using (var brush = new SolidBrush(fill))
            {
                g.FillPath(brush, path);
            }
        }

        /// <summary>A rounded fill with a 1 px outline drawn inside the rectangle.</summary>
        public static void FillRounded(Graphics g, Rectangle rect, int radius, Color fill, Color border)
        {
            var outer = new RectangleF(rect.X + 0.5f, rect.Y + 0.5f, rect.Width - 1f, rect.Height - 1f);
            using (var path = RoundedRect(outer, radius))
            using (var brush = new SolidBrush(fill))
            using (var pen = new Pen(border, 1f))
            {
                g.FillPath(brush, path);
                g.DrawPath(pen, path);
            }
        }

        /// <summary>The 2 px focus ring, drawn 2 px outside the control body.</summary>
        public static void FocusRing(Graphics g, Rectangle body, int radius)
        {
            int width = ThemeManager.S(ThemeTokens.FocusWidth);
            int offset = ThemeManager.S(ThemeTokens.FocusOffset);
            float half = width / 2f;
            var ring = new RectangleF(body.X - offset - half, body.Y - offset - half, body.Width + (offset * 2) + width - 1, body.Height + (offset * 2) + width - 1);
            using (var path = RoundedRect(ring, radius + offset))
            using (var pen = new Pen(ThemeManager.Palette.Focus, width))
            {
                g.DrawPath(pen, path);
            }
        }

        /// <summary>Space reserved around a focusable body for its ring (focus width plus offset).</summary>
        public static int FocusInset
        {
            get { return ThemeManager.S(ThemeTokens.FocusWidth + ThemeTokens.FocusOffset); }
        }

        public static void Smooth(Graphics g)
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        }

        public static Size Measure(string text, Font font)
        {
            if (string.IsNullOrEmpty(text)) { return new Size(0, font.Height); }
            return TextRenderer.MeasureText(MeasureGraphics, text, font, new Size(int.MaxValue, int.MaxValue), MeasureLine);
        }

        public static Size MeasureWrapped(string text, Font font, int width)
        {
            if (string.IsNullOrEmpty(text)) { return new Size(0, 0); }
            if (width <= 0) { return Measure(text, font); }
            return TextRenderer.MeasureText(MeasureGraphics, text, font, new Size(width, int.MaxValue), Wrapped);
        }

        /// <summary>Pixels from the top of a text cell to its baseline, for baseline-aligned runs.</summary>
        public static int Ascent(Font font)
        {
            FontFamily family = font.FontFamily;
            float ascent = family.GetCellAscent(font.Style);
            float em = family.GetEmHeight(font.Style);
            return (int)Math.Round(font.Size * ascent / em);
        }

        /// <summary>Draws a line glyph into a square box (16 units at 96 DPI, scaled to the box).</summary>
        public static void Icon(Graphics g, Glyph glyph, Rectangle box, Color color)
        {
            if (glyph == Glyph.None) { return; }
            GraphicsState state = g.Save();
            try
            {
                Smooth(g);
                float unit = box.Width / 16f;
                g.TranslateTransform(box.X, box.Y);
                g.ScaleTransform(unit, unit);
                using (var pen = new Pen(color, 1.5f))
                using (var brush = new SolidBrush(color))
                {
                    pen.StartCap = LineCap.Round;
                    pen.EndCap = LineCap.Round;
                    pen.LineJoin = LineJoin.Round;
                    DrawGlyph(g, glyph, pen, brush);
                }
            }
            finally
            {
                g.Restore(state);
            }
        }

        private static void DrawGlyph(Graphics g, Glyph glyph, Pen pen, Brush brush)
        {
            switch (glyph)
            {
                case Glyph.Check:
                    g.DrawLines(pen, new[] { new PointF(3f, 8.5f), new PointF(6.5f, 12f), new PointF(13f, 4.5f) });
                    break;
                case Glyph.Success:
                    g.DrawEllipse(pen, 1.75f, 1.75f, 12.5f, 12.5f);
                    g.DrawLines(pen, new[] { new PointF(5f, 8.25f), new PointF(7.25f, 10.5f), new PointF(11f, 6f) });
                    break;
                case Glyph.Info:
                    g.DrawEllipse(pen, 1.75f, 1.75f, 12.5f, 12.5f);
                    g.DrawLine(pen, 8f, 7.25f, 8f, 11.25f);
                    g.FillEllipse(brush, 7.1f, 4.1f, 1.8f, 1.8f);
                    break;
                case Glyph.Error:
                    g.DrawEllipse(pen, 1.75f, 1.75f, 12.5f, 12.5f);
                    g.DrawLine(pen, 5.75f, 5.75f, 10.25f, 10.25f);
                    g.DrawLine(pen, 10.25f, 5.75f, 5.75f, 10.25f);
                    break;
                case Glyph.Warning:
                    using (var path = new GraphicsPath())
                    {
                        path.AddLines(new[] { new PointF(8f, 2f), new PointF(14.5f, 13.5f), new PointF(1.5f, 13.5f) });
                        path.CloseFigure();
                        g.DrawPath(pen, path);
                    }
                    g.DrawLine(pen, 8f, 6.25f, 8f, 9.25f);
                    g.FillEllipse(brush, 7.1f, 10.6f, 1.8f, 1.8f);
                    break;
                case Glyph.Lock:
                    using (var body = RoundedRect(new RectangleF(3f, 7f, 10f, 7.5f), 1.5f))
                    {
                        g.DrawPath(pen, body);
                    }
                    g.DrawArc(pen, 5f, 2f, 6f, 7f, 180, 180);
                    g.DrawLine(pen, 5f, 5.5f, 5f, 7f);
                    g.DrawLine(pen, 11f, 5.5f, 11f, 7f);
                    g.DrawLine(pen, 8f, 9.75f, 8f, 11.5f);
                    break;
                case Glyph.Layers:
                    g.DrawPolygon(pen, new[] { new PointF(8f, 1.75f), new PointF(14.5f, 5f), new PointF(8f, 8.25f), new PointF(1.5f, 5f) });
                    g.DrawLines(pen, new[] { new PointF(1.5f, 8.25f), new PointF(8f, 11.5f), new PointF(14.5f, 8.25f) });
                    g.DrawLines(pen, new[] { new PointF(1.5f, 11.25f), new PointF(8f, 14.5f), new PointF(14.5f, 11.25f) });
                    break;
                case Glyph.Chart:
                    g.DrawLine(pen, 3f, 14f, 3f, 9f);
                    g.DrawLine(pen, 8f, 14f, 8f, 3f);
                    g.DrawLine(pen, 13f, 14f, 13f, 6.5f);
                    break;
                case Glyph.Clock:
                    g.DrawEllipse(pen, 1.75f, 1.75f, 12.5f, 12.5f);
                    g.DrawLines(pen, new[] { new PointF(8f, 4.5f), new PointF(8f, 8f), new PointF(10.75f, 9.75f) });
                    break;
                case Glyph.Sliders:
                    g.DrawLine(pen, 2f, 4f, 14f, 4f);
                    g.DrawLine(pen, 2f, 8f, 14f, 8f);
                    g.DrawLine(pen, 2f, 12f, 14f, 12f);
                    g.FillEllipse(brush, 8.5f, 2.25f, 3.5f, 3.5f);
                    g.FillEllipse(brush, 3.5f, 6.25f, 3.5f, 3.5f);
                    g.FillEllipse(brush, 9.5f, 10.25f, 3.5f, 3.5f);
                    break;
                case Glyph.ChevronDown:
                    g.DrawLines(pen, new[] { new PointF(4f, 6f), new PointF(8f, 10f), new PointF(12f, 6f) });
                    break;
                case Glyph.ChevronRight:
                    g.DrawLines(pen, new[] { new PointF(6f, 4f), new PointF(10f, 8f), new PointF(6f, 12f) });
                    break;
            }
        }
    }
}
