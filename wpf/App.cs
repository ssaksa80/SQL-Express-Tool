// SQL Express Backup — WPF shell, Phase 0.
//
// This phase proves the foundation only: a code-first WPF window that the in-box
// compiler builds, that is DPI-native and resizable, and that reopens exactly where
// and how it was left. The Modern and DBA views, the toggle, and the engine wiring
// arrive in Phase 1 - here the body is a placeholder so the geometry and settings
// plumbing can be proven on its own.
//
// C# 5 only (in-box csc): no string interpolation, no expression-bodied members, no
// async. Code-first, no XAML - the markup compiler needs MSBuild, which this host
// does not have.

using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

class SebWpf
{
    [STAThread]
    static int Main(string[] args)
    {
        string checkFile = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--check" && i + 1 < args.Length) { checkFile = args[++i]; }
        }

        AppSettings settings = AppSettings.Load();

        // Headless smoke check: construct the window without running the message loop,
        // and write findings to a file because a windowed exe has no console to print
        // to. This is what the test suite calls.
        if (checkFile != null)
        {
            try
            {
                Window probe = BuildWindow(settings);
                bool ok = probe.Content != null;
                File.WriteAllText(checkFile,
                    "WPF-CHECK-OK view=" + settings.View + " theme=" + settings.Theme +
                    " size=" + settings.WinWidth + "x" + settings.WinHeight +
                    " controls=" + ok.ToString().ToLowerInvariant());
                return ok ? 0 : 2;
            }
            catch (Exception ex)
            {
                try { File.WriteAllText(checkFile, "WPF-CHECK-FAIL " + ex.Message); } catch { }
                return 2;
            }
        }

        Application app = new Application();
        Window win = BuildWindow(settings);

        win.Closing += delegate
        {
            // Persist geometry on the way out. A maximized window keeps its previous
            // restored size so un-maximizing next launch returns somewhere sensible,
            // rather than recording the full-screen bounds as the restore size.
            if (win.WindowState == WindowState.Maximized)
            {
                settings.Maximized = true;
            }
            else
            {
                settings.Maximized = false;
                settings.WinLeft = win.Left;
                settings.WinTop = win.Top;
                settings.WinWidth = win.Width;
                settings.WinHeight = win.Height;
            }
            settings.Save();
        };

        app.Run(win);
        return 0;
    }

    static Window BuildWindow(AppSettings s)
    {
        Window win = new Window();
        win.Title = "SQL Express Backup";
        win.Width = s.WinWidth;
        win.Height = s.WinHeight;
        win.MinWidth = 900;
        win.MinHeight = 560;
        win.Background = new SolidColorBrush(Color.FromRgb(0x0E, 0x13, 0x1B));

        // Reopen where it was left - but only if that position is still on a screen.
        // A monitor that was unplugged since last run would otherwise strand the window
        // off in nowhere; fall back to centre.
        if (!double.IsNaN(s.WinLeft) && !double.IsNaN(s.WinTop) && OnScreen(s.WinLeft, s.WinTop))
        {
            win.WindowStartupLocation = WindowStartupLocation.Manual;
            win.Left = s.WinLeft;
            win.Top = s.WinTop;
        }
        else
        {
            win.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        }
        if (s.Maximized) { win.WindowState = WindowState.Maximized; }

        // Placeholder body for Phase 0. Replaced by the Modern / DBA views in Phase 1.
        StackPanel panel = new StackPanel();
        panel.HorizontalAlignment = HorizontalAlignment.Center;
        panel.VerticalAlignment = VerticalAlignment.Center;

        TextBlock title = new TextBlock();
        title.Text = "SQL Express Backup";
        title.Foreground = Brushes.White;
        title.FontSize = 28;
        title.FontWeight = FontWeights.SemiBold;
        title.TextAlignment = TextAlignment.Center;
        panel.Children.Add(title);

        TextBlock sub = new TextBlock();
        sub.Text = "Phase 0 — DPI-native, resizable, remembers where you left it";
        sub.Foreground = new SolidColorBrush(Color.FromRgb(0x8A, 0x96, 0xA8));
        sub.FontSize = 14;
        sub.Margin = new Thickness(0, 8, 0, 0);
        sub.TextAlignment = TextAlignment.Center;
        panel.Children.Add(sub);

        win.Content = panel;
        return win;
    }

    // Is the top-left corner within the virtual screen (all monitors), allowing a small
    // margin so a window nudged slightly off the edge still counts?
    static bool OnScreen(double left, double top)
    {
        double vx = SystemParameters.VirtualScreenLeft;
        double vy = SystemParameters.VirtualScreenTop;
        double vw = SystemParameters.VirtualScreenWidth;
        double vh = SystemParameters.VirtualScreenHeight;
        return left >= vx - 100 && top >= vy - 40 &&
               left <= vx + vw - 100 && top <= vy + vh - 40;
    }
}
