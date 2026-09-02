// Colour tokens and shared brushes for both themes.
//
// One place defines the palette; every control pulls its colours from here, so the
// light/dark toggle is a single swap. Brushes are frozen (immutable, cross-thread,
// cheaper to render) and rebuilt when the theme changes.
//
// The three theme states mirror the rest of the app: system follows the OS, light and
// dark are explicit. System is resolved once at load from the OS setting.

using System;
using System.Collections.Generic;
using System.Windows.Media;

static class Theme
{
    public static bool Dark = false;

    // Named tokens. Neutrals are Windows 11's, with a steel-blue accent chosen for a
    // backup/data tool rather than the default blue.
    public static SolidColorBrush Bg, Surface, Sunken, Ink, Ink2, Ink3, Line, LineStrong;
    public static SolidColorBrush Accent, AccentDeep, AccentBg, OnAccent;
    public static SolidColorBrush Ok, OkBg, Warn, WarnBg, Bad, BadBg;

    public static event EventHandler Changed;

    static SolidColorBrush B(byte r, byte g, byte b)
    {
        SolidColorBrush br = new SolidColorBrush(Color.FromRgb(r, g, b));
        br.Freeze();
        return br;
    }

    public static void Apply()
    {
        if (Dark)
        {
            Bg = B(0x1E, 0x24, 0x2E); Surface = B(0x26, 0x2D, 0x38); Sunken = B(0x1A, 0x20, 0x29);
            Ink = B(0xE7, 0xEC, 0xF4); Ink2 = B(0xBB, 0xC5, 0xD3); Ink3 = B(0x8A, 0x96, 0xA8);
            Line = B(0x33, 0x3C, 0x49); LineStrong = B(0x44, 0x4F, 0x5E);
            Accent = B(0x5B, 0x92, 0xF6); AccentDeep = B(0x8F, 0xB4, 0xFA); AccentBg = B(0x1B, 0x2B, 0x42); OnAccent = B(0x0C, 0x14, 0x22);
            Ok = B(0x49, 0xC4, 0x89); OkBg = B(0x14, 0x2C, 0x21); Warn = B(0xE0, 0xA4, 0x4A); WarnBg = B(0x2E, 0x26, 0x14); Bad = B(0xF0, 0x77, 0x6A); BadBg = B(0x30, 0x1A, 0x17);
        }
        else
        {
            Bg = B(0xF1, 0xF3, 0xF6); Surface = B(0xFF, 0xFF, 0xFF); Sunken = B(0xF7, 0xF9, 0xFB);
            Ink = B(0x16, 0x1B, 0x22); Ink2 = B(0x46, 0x4E, 0x5B); Ink3 = B(0x77, 0x82, 0x92);
            Line = B(0xE2, 0xE7, 0xEE); LineStrong = B(0xCB, 0xD3, 0xDE);
            Accent = B(0x2C, 0x63, 0xD8); AccentDeep = B(0x1B, 0x47, 0xA8); AccentBg = B(0xE8, 0xEF, 0xFC); OnAccent = B(0xFF, 0xFF, 0xFF);
            Ok = B(0x1C, 0x8A, 0x54); OkBg = B(0xDE, 0xF1, 0xE6); Warn = B(0x9A, 0x64, 0x10); WarnBg = B(0xFB, 0xEF, 0xD8); Bad = B(0xC4, 0x39, 0x2C); BadBg = B(0xFB, 0xE7, 0xE2);
        }
        if (Changed != null) { Changed(null, EventArgs.Empty); }
    }

    // Resolve "system|light|dark" to a concrete theme and apply it.
    public static void Load(string setting)
    {
        if (setting == "dark") { Dark = true; }
        else if (setting == "light") { Dark = false; }
        else { Dark = SystemPrefersDark(); }
        Apply();
    }

    public static void SetDark(bool dark) { Dark = dark; Apply(); }

    static bool SystemPrefersDark()
    {
        try
        {
            object v = Microsoft.Win32.Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme", 1);
            if (v is int) { return ((int)v) == 0; }
        }
        catch { }
        return false;
    }

    // A lighter/darker shade of a brush, for hover and pressed states.
    public static SolidColorBrush Shade(SolidColorBrush src, double amount)
    {
        Color c = src.Color;
        Color t = amount >= 0 ? Colors.White : Colors.Black;
        double a = Math.Abs(amount);
        SolidColorBrush br = new SolidColorBrush(Color.FromRgb(
            (byte)(c.R + (t.R - c.R) * a),
            (byte)(c.G + (t.G - c.G) * a),
            (byte)(c.B + (t.B - c.B) * a)));
        br.Freeze();
        return br;
    }
}
