// Shared, styled building blocks for both views. Code-first WPF, so these are factory
// methods that return configured elements rather than XAML styles. Everything reads
// its colours from Theme at build time; the window rebuilds the active view when the
// theme changes, so there is no per-control rebinding to maintain.

using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

static class Ui
{
    // Segoe UI Variable is the Windows 11 UI face; Segoe UI is the fallback. Resolved
    // once - asking for a face that is absent substitutes something arbitrary.
    static FontFamily uiFace, iconFace;
    public static FontFamily Face
    {
        get
        {
            if (uiFace == null)
            {
                uiFace = new FontFamily("Segoe UI Variable Text, Segoe UI");
            }
            return uiFace;
        }
    }
    // Segoe Fluent Icons (Win11) / Segoe MDL2 Assets (Win10) - glyph icons, no image assets.
    public static FontFamily IconFace
    {
        get
        {
            if (iconFace == null) { iconFace = new FontFamily("Segoe Fluent Icons, Segoe MDL2 Assets"); }
            return iconFace;
        }
    }

    public static TextBlock Text(string s, double size, SolidColorBrush color)
    {
        TextBlock t = new TextBlock();
        t.Text = s; t.FontSize = size; t.Foreground = color;
        t.FontFamily = Face; t.TextWrapping = TextWrapping.NoWrap;
        return t;
    }

    public static TextBlock Text(string s, double size, SolidColorBrush color, FontWeight w)
    {
        TextBlock t = Text(s, size, color); t.FontWeight = w; return t;
    }

    // Uppercase eyebrow label.
    public static TextBlock Eyebrow(string s)
    {
        TextBlock t = Text(s.ToUpperInvariant(), 10.5, Theme.Ink3, FontWeights.SemiBold);
        return t;
    }

    public static TextBlock Icon(string glyph, double size, SolidColorBrush color)
    {
        TextBlock t = new TextBlock();
        t.Text = glyph; t.FontFamily = IconFace; t.FontSize = size; t.Foreground = color;
        t.VerticalAlignment = VerticalAlignment.Center;
        return t;
    }

    // A surface card with rounded corners and a hairline border.
    public static Border Card()
    {
        Border b = new Border();
        b.Background = Theme.Surface;
        b.BorderBrush = Theme.Line;
        b.BorderThickness = new Thickness(1);
        b.CornerRadius = new CornerRadius(10);
        b.Padding = new Thickness(16);
        return b;
    }

    // A status tile: big value over a small label, optional accent tone on the value.
    public static Border Tile(string value, string label, SolidColorBrush valueColor)
    {
        Border card = Card();
        StackPanel sp = new StackPanel();
        TextBlock v = Text(value, 26, valueColor, FontWeights.SemiBold);
        TextBlock l = Text(label, 12, Theme.Ink3);
        l.Margin = new Thickness(0, 3, 0, 0); l.TextWrapping = TextWrapping.Wrap;
        sp.Children.Add(v); sp.Children.Add(l);
        card.Child = sp;
        return card;
    }

    // A sidebar navigation row. Selected rows carry the accent wash.
    public static Border NavItem(string glyph, string text, bool selected, Action onClick)
    {
        Border b = new Border();
        b.CornerRadius = new CornerRadius(7);
        b.Padding = new Thickness(10, 7, 10, 7);
        b.Margin = new Thickness(0, 1, 0, 1);
        b.Background = selected ? Theme.AccentBg : Brushes.Transparent;
        b.Cursor = Cursors.Hand;

        StackPanel row = new StackPanel();
        row.Orientation = Orientation.Horizontal;
        TextBlock ic = Icon(glyph, 15, selected ? Theme.AccentDeep : Theme.Ink3);
        ic.Margin = new Thickness(0, 0, 9, 0);
        TextBlock tx = Text(text, 12.5, selected ? Theme.AccentDeep : Theme.Ink2, selected ? FontWeights.SemiBold : FontWeights.Normal);
        tx.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(ic); row.Children.Add(tx);
        b.Child = row;

        if (!selected)
        {
            b.MouseEnter += delegate { b.Background = Theme.Sunken; };
            b.MouseLeave += delegate { b.Background = Brushes.Transparent; };
        }
        if (onClick != null) { b.MouseLeftButtonUp += delegate { onClick(); }; }
        return b;
    }

    // Primary (accent) action button.
    public static Border PrimaryButton(string text, Action onClick) { return Btn(text, true, false, onClick); }
    public static Border GhostButton(string text, Action onClick) { return Btn(text, false, false, onClick); }
    public static Border DangerButton(string text, Action onClick) { return Btn(text, false, true, onClick); }

    static Border Btn(string text, bool primary, bool danger, Action onClick)
    {
        Border b = new Border();
        b.CornerRadius = new CornerRadius(6);
        b.Padding = new Thickness(15, 7, 15, 7);
        b.Cursor = Cursors.Hand;
        SolidColorBrush face = primary ? Theme.Accent : Theme.Surface;
        SolidColorBrush ink = primary ? Theme.OnAccent : (danger ? Theme.Bad : Theme.Ink);
        b.Background = face;
        b.BorderBrush = primary ? Theme.Accent : (danger ? Theme.Bad : Theme.LineStrong);
        b.BorderThickness = new Thickness(1);

        TextBlock t = Text(text, 12.5, ink, FontWeights.SemiBold);
        t.HorizontalAlignment = HorizontalAlignment.Center;
        b.Child = t;

        SolidColorBrush hover = primary ? Theme.Shade(Theme.Accent, Theme.Dark ? 0.10 : -0.10) : Theme.Sunken;
        b.MouseEnter += delegate { b.Background = hover; };
        b.MouseLeave += delegate { b.Background = face; };
        if (onClick != null) { b.MouseLeftButtonUp += delegate { onClick(); }; }
        return b;
    }

    // A thin horizontal divider.
    public static Border Divider()
    {
        Border b = new Border();
        b.Height = 1; b.Background = Theme.Line;
        b.Margin = new Thickness(0, 8, 0, 8);
        return b;
    }

    // A small status pill (Protected / Warning / Failed).
    public static Border Pill(string text, SolidColorBrush fg, SolidColorBrush bg)
    {
        Border b = new Border();
        b.Background = bg; b.CornerRadius = new CornerRadius(11);
        b.Padding = new Thickness(9, 2, 9, 2);
        b.HorizontalAlignment = HorizontalAlignment.Left;
        b.Child = Text(text, 11, fg, FontWeights.SemiBold);
        return b;
    }
}
