using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using System.Windows.Forms;
using Microsoft.Win32;

namespace DeadLoad.Tray.Ui
{
    internal enum ThemeMode
    {
        Light,
        Dark,
        HighContrast,
    }

    internal enum Tone
    {
        Neutral,
        Info,
        Success,
        Warning,
        Danger,
    }

    internal enum FontRole
    {
        /// <summary>Body and labels: Segoe UI Variable Text, else Segoe UI.</summary>
        Text,
        /// <summary>Headings and the result metric: Segoe UI Variable Display, else Segoe UI.</summary>
        Display,
        /// <summary>Sizes and counts in columns: Segoe UI, whose digits all have one width (measured).</summary>
        Numeric,
        /// <summary>Paths and raw JSON: Cascadia Code, else Consolas.</summary>
        Mono,
    }

    /// <summary>
    /// The resolved colors of one theme. Light and Dark come from the generated tokens
    /// (ThemeTokens); High Contrast uses SystemColors only, so the user's high contrast theme
    /// decides every color.
    /// </summary>
    internal sealed class Palette
    {
        public ThemeMode Mode;
        public Color Canvas;
        public Color Card;
        public Color Raised;
        public Color Border;
        public Color ControlBorder;
        public Color Heading;
        public Color TextPrimary;
        public Color TextSecondary;
        public Color TextMuted;
        public Color Accent;
        public Color AccentHover;
        public Color AccentPressed;
        public Color OnAccent;
        public Color Focus;
        public Color Success;
        public Color Warning;
        public Color Danger;
        public Color SecondaryBack;
        public Color SecondaryHover;
        public Color SecondaryPressed;
        public Color SecondaryText;
        public Color DisabledBack;
        public Color DisabledText;
        public Color RailBack;
        public Color RailText;
        public Color RailHover;
        public Color RailSelectedBack;
        public Color RailSelectedText;
        public Color Track;
        public Color CapacityUsed;
        public Color RowHover;
        public Color RowSelected;
        public Color Link;
        public Color CheckBorder;

        public bool IsHighContrast { get { return Mode == ThemeMode.HighContrast; } }
        public bool IsDark { get { return Mode == ThemeMode.Dark; } }

        /// <summary>The token color of a semantic tone (icons, guarded text).</summary>
        public Color ToneBase(Tone tone)
        {
            if (IsHighContrast) { return SystemColors.WindowText; }
            switch (tone)
            {
                case Tone.Success: return Success;
                case Tone.Warning: return Warning;
                case Tone.Danger: return Danger;
                case Tone.Info: return Accent;
                default: return TextSecondary;
            }
        }

        /// <summary>
        /// The foreground of a tone on its tinted background (badge text, notice icon): the token
        /// color 15 percent deeper (light) or brighter (dark). The plain tokens on their tints
        /// measured 3.86 to 4.27:1, below the 4.5:1 that 12 px text needs (docs/design/UI-NOTES.md).
        /// </summary>
        public Color ToneText(Tone tone)
        {
            if (IsHighContrast) { return SystemColors.WindowText; }
            return Draw.Blend(ToneBase(tone), IsDark ? Color.White : Color.Black, 0.15);
        }

        /// <summary>
        /// The low-emphasis background of a tone: the token mixed into the card surface (10
        /// percent light, 14 percent dark). Derived, not a token.
        /// </summary>
        public Color ToneBack(Tone tone)
        {
            if (IsHighContrast) { return SystemColors.Window; }
            Color baseColor = tone == Tone.Neutral ? TextMuted : ToneBase(tone);
            return Draw.Blend(Card, baseColor, IsDark ? 0.14 : 0.10);
        }

        public static Palette Light()
        {
            var p = new Palette { Mode = ThemeMode.Light };
            p.Canvas = ThemeTokens.LightCanvas;
            p.Card = ThemeTokens.LightCard;
            p.Raised = ThemeTokens.LightRaised;
            p.Border = ThemeTokens.LightBorder;
            // A button outline at 3:1 against the card (WCAG 1.4.11), not the 1.2:1 divider gray.
            p.ControlBorder = Draw.Blend(ThemeTokens.LightBorder, ThemeTokens.LightSlate, 0.55);
            p.Heading = ThemeTokens.LightBrandNavy;
            p.TextPrimary = ThemeTokens.LightTextPrimary;
            p.TextSecondary = ThemeTokens.LightTextSecondary;
            p.TextMuted = ThemeTokens.LightTextMuted;
            p.Accent = ThemeTokens.LightBrandBlue;
            p.AccentHover = Draw.Blend(ThemeTokens.LightBrandBlue, Color.Black, 0.12);
            p.AccentPressed = Draw.Blend(ThemeTokens.LightBrandBlue, Color.Black, 0.24);
            p.OnAccent = ThemeTokens.LightOnBrand;
            p.Focus = ThemeTokens.LightFocusRing;
            p.Success = ThemeTokens.LightSuccess;
            p.Warning = ThemeTokens.LightWarning;
            p.Danger = ThemeTokens.LightDanger;
            p.SecondaryBack = ThemeTokens.LightCard;
            p.SecondaryHover = Draw.Blend(ThemeTokens.LightCard, ThemeTokens.LightSlate, 0.06);
            p.SecondaryPressed = Draw.Blend(ThemeTokens.LightCard, ThemeTokens.LightSlate, 0.12);
            p.SecondaryText = ThemeTokens.LightBrandNavy;
            p.DisabledBack = ThemeTokens.LightConcrete;
            p.DisabledText = ThemeTokens.LightTextMuted;
            p.RailBack = ThemeTokens.LightBrandNavy;
            p.RailText = ThemeTokens.LightOnBrand;
            p.RailHover = Draw.Blend(ThemeTokens.LightBrandNavy, Color.White, 0.10);
            p.RailSelectedBack = ThemeTokens.LightBrandBlue;
            p.RailSelectedText = ThemeTokens.LightOnBrand;
            p.Track = ThemeTokens.LightConcrete;
            p.CapacityUsed = ThemeTokens.LightBrandNavy;
            p.RowHover = Draw.Blend(ThemeTokens.LightCard, ThemeTokens.LightSlate, 0.04);
            p.RowSelected = Draw.Blend(ThemeTokens.LightCard, ThemeTokens.LightBrandBlue, 0.14);
            p.Link = ThemeTokens.LightBrandBlue;
            p.CheckBorder = ThemeTokens.LightTextMuted;
            return p;
        }

        public static Palette Dark()
        {
            var p = new Palette { Mode = ThemeMode.Dark };
            p.Canvas = ThemeTokens.DarkCanvas;
            p.Card = ThemeTokens.DarkCard;
            p.Raised = ThemeTokens.DarkRaised;
            p.Border = ThemeTokens.DarkBorder;
            p.ControlBorder = Draw.Blend(ThemeTokens.DarkBorder, ThemeTokens.DarkTextSecondary, 0.35);
            p.Heading = ThemeTokens.DarkTextPrimary;
            p.TextPrimary = ThemeTokens.DarkTextPrimary;
            p.TextSecondary = ThemeTokens.DarkTextSecondary;
            p.TextMuted = ThemeTokens.DarkTextMuted;
            p.Accent = ThemeTokens.DarkBrandBlue;
            p.AccentHover = Draw.Blend(ThemeTokens.DarkBrandBlue, Color.White, 0.14);
            p.AccentPressed = Draw.Blend(ThemeTokens.DarkBrandBlue, Color.Black, 0.14);
            p.OnAccent = ThemeTokens.DarkOnBrand;
            p.Focus = ThemeTokens.DarkFocusRing;
            p.Success = ThemeTokens.DarkSuccess;
            p.Warning = ThemeTokens.DarkWarning;
            p.Danger = ThemeTokens.DarkDanger;
            p.SecondaryBack = ThemeTokens.DarkRaised;
            p.SecondaryHover = Draw.Blend(ThemeTokens.DarkRaised, Color.White, 0.06);
            p.SecondaryPressed = Draw.Blend(ThemeTokens.DarkRaised, Color.White, 0.12);
            p.SecondaryText = ThemeTokens.DarkTextPrimary;
            p.DisabledBack = ThemeTokens.DarkConcrete;
            p.DisabledText = ThemeTokens.DarkTextMuted;
            p.RailBack = ThemeTokens.DarkBrandNavy;
            p.RailText = ThemeTokens.DarkTextPrimary;
            p.RailHover = Draw.Blend(ThemeTokens.DarkBrandNavy, Color.White, 0.10);
            p.RailSelectedBack = ThemeTokens.DarkBrandBlue;
            p.RailSelectedText = ThemeTokens.DarkOnBrand;
            p.Track = ThemeTokens.DarkConcrete;
            p.CapacityUsed = ThemeTokens.DarkBrandBlue;
            p.RowHover = Draw.Blend(ThemeTokens.DarkCard, Color.White, 0.04);
            p.RowSelected = Draw.Blend(ThemeTokens.DarkCard, ThemeTokens.DarkBrandBlue, 0.22);
            p.Link = ThemeTokens.DarkBrandBlue;
            p.CheckBorder = ThemeTokens.DarkTextMuted;
            return p;
        }

        public static Palette HighContrast()
        {
            var p = new Palette { Mode = ThemeMode.HighContrast };
            p.Canvas = SystemColors.Window;
            p.Card = SystemColors.Window;
            p.Raised = SystemColors.Window;
            p.Border = SystemColors.WindowText;
            p.ControlBorder = SystemColors.WindowText;
            p.Heading = SystemColors.WindowText;
            p.TextPrimary = SystemColors.WindowText;
            // High contrast themes define no "secondary" text color; every text is WindowText.
            p.TextSecondary = SystemColors.WindowText;
            p.TextMuted = SystemColors.WindowText;
            p.Accent = SystemColors.Highlight;
            p.AccentHover = SystemColors.Highlight;
            p.AccentPressed = SystemColors.Highlight;
            p.OnAccent = SystemColors.HighlightText;
            p.Focus = SystemColors.WindowText;
            p.Success = SystemColors.WindowText;
            p.Warning = SystemColors.WindowText;
            p.Danger = SystemColors.WindowText;
            p.SecondaryBack = SystemColors.Control;
            p.SecondaryHover = SystemColors.Control;
            p.SecondaryPressed = SystemColors.Control;
            p.SecondaryText = SystemColors.ControlText;
            p.DisabledBack = SystemColors.Window;
            p.DisabledText = SystemColors.GrayText;
            p.RailBack = SystemColors.Window;
            p.RailText = SystemColors.WindowText;
            p.RailHover = SystemColors.Window;
            p.RailSelectedBack = SystemColors.Highlight;
            p.RailSelectedText = SystemColors.HighlightText;
            p.Track = SystemColors.Window;
            p.CapacityUsed = SystemColors.Highlight;
            p.RowHover = SystemColors.Window;
            p.RowSelected = SystemColors.Highlight;
            p.Link = SystemColors.HotTrack;
            p.CheckBorder = SystemColors.WindowText;
            return p;
        }
    }

    /// <summary>
    /// Which theme applies, the scale factor, and the fonts. The DeadLoad window scales itself:
    /// every pixel metric goes through <see cref="S(int)"/> and every font is created in pixels,
    /// so a control added after the window loaded (a category row, a table) is scaled the same
    /// way as the rest, and a move to a monitor with another DPI rebuilds the view at the new
    /// factor (MainWindow handles WM_DPICHANGED).
    /// </summary>
    internal static class ThemeManager
    {
        private const string PersonalizeKey = @"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize";
        private static readonly Dictionary<string, Font> FontCache = new Dictionary<string, Font>(StringComparer.Ordinal);
        private static HashSet<string> installedFamilies;

        /// <summary>Set by the render harness: a fixed theme instead of the user's.</summary>
        public static ThemeMode? ForcedMode;

        /// <summary>Set by the render harness: 1.5 simulates a 144 DPI monitor at 96 DPI.</summary>
        public static float RenderScale = 1f;

        /// <summary>Set by the render harness: no animation, so every capture is the same.</summary>
        public static bool ForceReducedMotion;

        public static Palette Palette = Palette.Light();
        public static float Factor = 1f;

        public static ThemeMode Detect()
        {
            if (ForcedMode.HasValue) { return ForcedMode.Value; }
            if (SystemInformation.HighContrast) { return ThemeMode.HighContrast; }
            try
            {
                using (RegistryKey key = Registry.CurrentUser.OpenSubKey(PersonalizeKey, false))
                {
                    object value = key == null ? null : key.GetValue("AppsUseLightTheme");
                    // Absent (older builds, a fresh profile): Windows treats apps as light.
                    if (value is int && (int)value == 0) { return ThemeMode.Dark; }
                }
            }
            catch (Exception)
            {
                // An unreadable key is the light default.
            }
            return ThemeMode.Light;
        }

        public static void Apply(ThemeMode mode, int dpi)
        {
            switch (mode)
            {
                case ThemeMode.Dark: Palette = Palette.Dark(); break;
                case ThemeMode.HighContrast: Palette = Palette.HighContrast(); break;
                default: Palette = Palette.Light(); break;
            }
            Factor = Math.Max(1f, dpi / 96f) * RenderScale;
        }

        /// <summary>No animation when Windows animations are off (Settings, Accessibility, Visual effects).</summary>
        public static bool ReducedMotion
        {
            get { return ForceReducedMotion || !SystemInformation.UIEffectsEnabled; }
        }

        /// <summary>A length in 96 DPI pixels, scaled to the window.</summary>
        public static int S(int value)
        {
            if (value == 0) { return 0; }
            int scaled = (int)Math.Round(value * Factor);
            return scaled == 0 ? (value > 0 ? 1 : -1) : scaled;
        }

        public static float SF(float value)
        {
            return value * Factor;
        }

        public static Font Font(FontRole role, int px)
        {
            return GetFont(role, px, false, false);
        }

        public static Font Semibold(FontRole role, int px)
        {
            return GetFont(role, px, true, false);
        }

        public static Font Bold(FontRole role, int px)
        {
            return GetFont(role, px, false, true);
        }

        private static Font GetFont(FontRole role, int px, bool semibold, bool bold)
        {
            float size = px * Factor;
            string key = role + "|" + size.ToString("0.00", System.Globalization.CultureInfo.InvariantCulture) + "|" + semibold + "|" + bold;
            Font font;
            if (FontCache.TryGetValue(key, out font)) { return font; }

            string family = Family(role);
            FontStyle style = FontStyle.Regular;
            if (semibold)
            {
                // GDI+ knows only regular and bold; a semibold face is its own family name.
                string face = SemiboldFamily(role, family);
                if (face != null) { family = face; }
                else { style = FontStyle.Bold; }
            }
            if (bold) { style = FontStyle.Bold; }
            font = new Font(family, size, style, GraphicsUnit.Pixel);
            FontCache[key] = font;
            return font;
        }

        public static string Family(FontRole role)
        {
            switch (role)
            {
                case FontRole.Display: return First(ThemeTokens.FontAppDisplay);
                case FontRole.Mono: return First(ThemeTokens.FontMono);
                // Segoe UI Variable draws a narrower "1" (measured: 59 versus 89 px for ten digits
                // at 14 px); Segoe UI keeps every digit one width, so columns of sizes line up.
                case FontRole.Numeric: return IsInstalled("Segoe UI") ? "Segoe UI" : First(ThemeTokens.FontApp);
                default: return First(ThemeTokens.FontApp);
            }
        }

        private static string SemiboldFamily(FontRole role, string family)
        {
            // GDI truncates family names to 31 characters ("Segoe UI Variable Display Semib").
            var candidates = new List<string>();
            string full = family + " Semibold";
            candidates.Add(full);
            if (full.Length > 31) { candidates.Add(full.Substring(0, 31)); }
            if (role == FontRole.Mono) { candidates.Add(family + " SemiBold"); }
            candidates.Add("Segoe UI Semibold");
            foreach (string candidate in candidates)
            {
                if (IsInstalled(candidate)) { return candidate; }
            }
            return null;
        }

        private static string First(string[] names)
        {
            foreach (string name in names)
            {
                if (IsInstalled(name)) { return name; }
            }
            return SystemFonts.MessageBoxFont.FontFamily.Name;
        }

        public static bool IsInstalled(string family)
        {
            if (installedFamilies == null)
            {
                var set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                try
                {
                    using (var collection = new InstalledFontCollection())
                    {
                        foreach (FontFamily f in collection.Families) { set.Add(f.Name); }
                    }
                }
                catch (Exception)
                {
                    // No font list: every lookup falls back to the message box font.
                }
                installedFamilies = set;
            }
            return installedFamilies.Contains(family);
        }
    }

    internal static class NativeMethods
    {
        public const int WM_CHANGEUISTATE = 0x0127;
        public const int WM_DPICHANGED = 0x02E0;
        public const int UIS_CLEAR = 2;
        public const int UISF_HIDEFOCUS = 0x1;
        public const int UISF_HIDEACCEL = 0x2;
        private const int DWMWA_USE_IMMERSIVE_DARK_MODE = 20;
        private const int DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1 = 19;

        [DllImport("user32.dll")]
        public static extern IntPtr SendMessage(IntPtr hWnd, int msg, IntPtr wParam, IntPtr lParam);

        [DllImport("dwmapi.dll")]
        private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

        [DllImport("uxtheme.dll", CharSet = CharSet.Unicode)]
        private static extern int SetWindowTheme(IntPtr hwnd, string subAppName, string subIdList);

        [StructLayout(LayoutKind.Sequential)]
        public struct RECT
        {
            public int Left;
            public int Top;
            public int Right;
            public int Bottom;
        }

        /// <summary>Dark or light title bar (Windows 10 2004 and later; attribute 19 before that).</summary>
        public static void SetDarkTitleBar(IntPtr hwnd, bool dark)
        {
            int value = dark ? 1 : 0;
            try
            {
                if (DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE, ref value, sizeof(int)) != 0)
                {
                    DwmSetWindowAttribute(hwnd, DWMWA_USE_IMMERSIVE_DARK_MODE_BEFORE_20H1, ref value, sizeof(int));
                }
            }
            catch (Exception)
            {
                // No DWM attribute on this build: the title bar stays light.
            }
        }

        /// <summary>Dark scroll bars for a list or text box in dark mode; light (default) otherwise.</summary>
        public static void SetControlTheme(Control control, bool dark)
        {
            try
            {
                SetWindowTheme(control.Handle, dark ? "DarkMode_Explorer" : "Explorer", null);
            }
            catch (Exception)
            {
                // Older uxtheme: the default theme applies.
            }
        }

        /// <summary>Keyboard focus cues on from the start, not only after the first Alt or Tab press.</summary>
        public static void ShowFocusCues(Control control)
        {
            int wParam = UIS_CLEAR | ((UISF_HIDEFOCUS | UISF_HIDEACCEL) << 16);
            SendMessage(control.Handle, WM_CHANGEUISTATE, (IntPtr)wParam, IntPtr.Zero);
        }
    }
}
