// SQL Express Backup — WPF shell.
//
// The window hosts one of two views — Modern (the default) or DBA — chosen by a single
// toggle in the header, alongside a light/dark switch. Both choices persist, so the app
// always reopens the way it was left. The views are rebuilt on a theme change rather
// than data-bound to it, which keeps the code-first styling simple: each control reads
// its colours from Theme at build time.
//
// C# 5 only (in-box csc), code-first WPF (no XAML — the markup compiler needs MSBuild).

using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;

class SebWpf
{
    static AppSettings settings;
    static Grid rootGrid;
    static Border host;

    [STAThread]
    static int Main(string[] args)
    {
        string checkFile = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--check" && i + 1 < args.Length) { checkFile = args[++i]; }
        }

        settings = AppSettings.Load();
        Theme.Load(settings.Theme);

        if (checkFile != null)
        {
            try
            {
                Window probe = BuildWindow();
                // construct both views headless — layout code that never runs is the
                // code most likely to throw on first use.
                FrameworkElement m = new ModernView(null).Build();
                FrameworkElement d = new DbaView(null).Build();
                File.WriteAllText(checkFile, "WPF-CHECK-OK view=" + settings.View + " theme=" + settings.Theme +
                    " modern=" + (m != null) + " dba=" + (d != null));
                return 0;
            }
            catch (Exception ex)
            {
                try { File.WriteAllText(checkFile, "WPF-CHECK-FAIL " + ex.Message); } catch { }
                return 2;
            }
        }

        Application app = new Application();
        Window win = BuildWindow();
        win.Closing += delegate { SaveGeometry(win); };
        app.Run(win);
        return 0;
    }

    static Window BuildWindow()
    {
        Window win = new Window();
        win.Title = "SQL Express Backup";
        win.Width = settings.WinWidth; win.Height = settings.WinHeight;
        win.MinWidth = 940; win.MinHeight = 580;
        win.Background = Theme.Bg;
        win.FontFamily = Ui.Face;

        if (!double.IsNaN(settings.WinLeft) && !double.IsNaN(settings.WinTop) && OnScreen(settings.WinLeft, settings.WinTop))
        {
            win.WindowStartupLocation = WindowStartupLocation.Manual;
            win.Left = settings.WinLeft; win.Top = settings.WinTop;
        }
        else { win.WindowStartupLocation = WindowStartupLocation.CenterScreen; }
        if (settings.Maximized) { win.WindowState = WindowState.Maximized; }

        rootGrid = new Grid();
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(48) }); // header
        rootGrid.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // view
        Rebuild(win);
        win.Content = rootGrid;
        return win;
    }

    // Rebuild the header and the active view against the current theme.
    static void Rebuild(Window win)
    {
        if (win != null) { win.Background = Theme.Bg; }
        rootGrid.Children.Clear();

        Border header = BuildHeader(win);
        rootGrid.Children.Add(header);

        host = new Border();
        Grid.SetRow(host, 1);
        rootGrid.Children.Add(host);
        SwitchView();
    }

    static Border BuildHeader(Window win)
    {
        Border bar = new Border();
        bar.Background = Theme.Surface;
        bar.BorderBrush = Theme.Line; bar.BorderThickness = new Thickness(0, 0, 0, 1);
        DockPanel dp = new DockPanel();
        dp.Margin = new Thickness(14, 0, 12, 0); dp.LastChildFill = false;

        StackPanel brand = new StackPanel();
        brand.Orientation = Orientation.Horizontal;
        brand.VerticalAlignment = VerticalAlignment.Center;
        TextBlock logo = Ui.Icon("", 16, Theme.Accent); logo.Margin = new Thickness(0, 0, 8, 0);
        TextBlock name = Ui.Text("SQL Express Backup", 13, Theme.Ink, FontWeights.SemiBold);
        name.VerticalAlignment = VerticalAlignment.Center;
        brand.Children.Add(logo); brand.Children.Add(name);
        DockPanel.SetDock(brand, Dock.Left);
        dp.Children.Add(brand);

        StackPanel right = new StackPanel();
        right.Orientation = Orientation.Horizontal;
        right.VerticalAlignment = VerticalAlignment.Center;
        right.HorizontalAlignment = HorizontalAlignment.Right;
        right.Children.Add(ViewToggle(win));
        Border themeBtn = ThemeToggle(win);
        themeBtn.Margin = new Thickness(10, 0, 0, 0);
        right.Children.Add(themeBtn);
        DockPanel.SetDock(right, Dock.Right);
        dp.Children.Add(right);

        bar.Child = dp;
        return bar;
    }

    // The single toggle. A segmented control: Modern | DBA.
    static Border ViewToggle(Window win)
    {
        Border seg = new Border();
        seg.BorderBrush = Theme.LineStrong; seg.BorderThickness = new Thickness(1);
        seg.CornerRadius = new CornerRadius(7); seg.Height = 30;
        seg.VerticalAlignment = VerticalAlignment.Center;
        StackPanel sp = new StackPanel(); sp.Orientation = Orientation.Horizontal;
        sp.Children.Add(SegButton("Modern", settings.View != "dba", win));
        sp.Children.Add(SegButton("DBA", settings.View == "dba", win));
        seg.Child = sp;
        return seg;
    }

    static Border SegButton(string label, bool on, Window win)
    {
        Border b = new Border();
        b.Background = on ? Theme.Accent : Brushes.Transparent;
        b.CornerRadius = new CornerRadius(6);
        b.Padding = new Thickness(14, 0, 14, 0);
        b.Margin = new Thickness(2);
        b.Cursor = Cursors.Hand;
        TextBlock t = Ui.Text(label, 12, on ? Theme.OnAccent : Theme.Ink2, FontWeights.SemiBold);
        t.VerticalAlignment = VerticalAlignment.Center;
        b.Child = t;
        if (!on)
        {
            b.MouseLeftButtonUp += delegate
            {
                settings.View = (label == "DBA") ? "dba" : "modern";
                settings.Save();
                Rebuild(win);
            };
        }
        return b;
    }

    static Border ThemeToggle(Window win)
    {
        Border b = new Border();
        b.BorderBrush = Theme.LineStrong; b.BorderThickness = new Thickness(1);
        b.CornerRadius = new CornerRadius(7); b.Width = 34; b.Height = 30;
        b.VerticalAlignment = VerticalAlignment.Center; b.Cursor = Cursors.Hand;
        // sun in dark mode (click to go light), moon in light mode (click to go dark)
        TextBlock ic = Ui.Icon(Theme.Dark ? "" : "", 15, Theme.Ink2);
        ic.HorizontalAlignment = HorizontalAlignment.Center; ic.VerticalAlignment = VerticalAlignment.Center;
        b.Child = ic;
        b.MouseEnter += delegate { b.Background = Theme.Sunken; };
        b.MouseLeave += delegate { b.Background = Brushes.Transparent; };
        b.MouseLeftButtonUp += delegate
        {
            Theme.SetDark(!Theme.Dark);
            settings.Theme = Theme.Dark ? "dark" : "light";
            settings.Save();
            Rebuild(win);
        };
        return b;
    }

    static void SwitchView()
    {
        if (settings.View == "dba") { host.Child = new DbaView(OpenRestore).Build(); }
        else { host.Child = new ModernView(OpenRestore).Build(); }
    }

    // Restore is a separate window (decision locked). A full WPF restore window is a
    // later phase; for now this opens a lightweight placeholder so the entry point is
    // wired and testable.
    static void OpenRestore()
    {
        Window w = new Window();
        w.Title = "Restore — SQL Express Backup";
        w.Width = 720; w.Height = 480; w.Background = Theme.Bg; w.FontFamily = Ui.Face;
        w.WindowStartupLocation = WindowStartupLocation.CenterOwner;
        StackPanel sp = new StackPanel();
        sp.VerticalAlignment = VerticalAlignment.Center; sp.HorizontalAlignment = HorizontalAlignment.Center;
        sp.Children.Add(Ui.Text("Restore", 22, Theme.Ink, FontWeights.SemiBold));
        TextBlock s = Ui.Text("The full restore window arrives in the next phase.", 13, Theme.Ink3);
        s.Margin = new Thickness(0, 8, 0, 0); sp.Children.Add(s);
        w.Content = sp;
        w.Show();
    }

    static void SaveGeometry(Window win)
    {
        if (win.WindowState == WindowState.Maximized) { settings.Maximized = true; }
        else
        {
            settings.Maximized = false;
            settings.WinLeft = win.Left; settings.WinTop = win.Top;
            settings.WinWidth = win.Width; settings.WinHeight = win.Height;
        }
        settings.Save();
    }

    static bool OnScreen(double left, double top)
    {
        double vx = SystemParameters.VirtualScreenLeft, vy = SystemParameters.VirtualScreenTop;
        double vw = SystemParameters.VirtualScreenWidth, vh = SystemParameters.VirtualScreenHeight;
        return left >= vx - 100 && top >= vy - 40 && left <= vx + vw - 100 && top <= vy + vh - 40;
    }
}
