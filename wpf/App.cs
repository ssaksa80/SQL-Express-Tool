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
        bool openRestoreOnLoad = false;
        bool selfTestOnLoad = false;
        bool doInstall = false, doUninstall = false, quiet = false;
        string portableTo = null;
        // headless elevated jobs (spawned by the UI through UAC): each does its work and
        // writes a "exit=N\n<output>" result file the non-elevated UI polls.
        bool backupNow = false;
        string rescheduleJson = null, applySetupJson = null, liveFile = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--check" && i + 1 < args.Length) { checkFile = args[++i]; }
            if (args[i] == "--restore") { openRestoreOnLoad = true; }
            if (args[i] == "--selftest") { selfTestOnLoad = true; }
            if (args[i] == "--install") { doInstall = true; }
            if (args[i] == "--uninstall") { doUninstall = true; }
            if (args[i] == "--quiet") { quiet = true; }
            if (args[i] == "--portable" && i + 1 < args.Length) { portableTo = args[++i]; }
            if (args[i] == "--backup-now") { backupNow = true; }
            if (args[i] == "--reschedule" && i + 1 < args.Length) { rescheduleJson = args[++i]; }
            if (args[i] == "--apply-setup" && i + 1 < args.Length) { applySetupJson = args[++i]; }
            if (args[i] == "--live" && i + 1 < args.Length) { liveFile = args[++i]; }
        }

        // Silent portable setup: extract to a folder and launch it there. Also the path
        // the first-run chooser takes after picking a folder.
        if (portableTo != null)
        {
            try
            {
                string pexe = Install.DoPortable(portableTo);
                if (!quiet) { Install.Relaunch("", false, pexe); }
            }
            catch { }
            return 0;
        }

        // Install / uninstall run before any UI. Both need administrator; if we are not
        // elevated, relaunch with the same verb and let UAC prompt.
        if (doInstall)
        {
            if (!Install.IsElevated()) { Install.Relaunch("--install", true); return 0; }
            string installedExe = Install.DoInstall();
            Install.Relaunch("", false, installedExe); // launch the installed copy
            return 0;
        }
        if (doUninstall)
        {
            if (!Install.IsElevated()) { Install.Relaunch("--uninstall" + (quiet ? " --quiet" : ""), true); return 0; }
            // Remove the SYSTEM schedule first so app uninstall does not orphan it. The
            // engine inherits this process's elevation; config and backups are left alone
            // (no -Purge) - only the scheduled task/service is removed.
            try { AppSettings.Mode = Install.DetectMode(); Engine.Run("-Uninstall", null); } catch { }
            Install.DoUninstall();
            return 0;
        }

        // Headless elevated jobs, spawned by the UI through UAC. Each relaunches elevated
        // if needed, runs the engine (which inherits this process's elevation), writes a
        // result file the non-elevated UI polls, and exits without any window.
        if (backupNow)
        {
            if (!Install.IsElevated()) { Install.Relaunch("--backup-now" + LiveArg(liveFile), true); return 0; }
            AppSettings.Mode = Install.DetectMode();
            return RunEngineHeadless("-Run", liveFile);
        }
        if (rescheduleJson != null)
        {
            if (!Install.IsElevated()) { Install.Relaunch("--reschedule \"" + rescheduleJson + "\"" + LiveArg(liveFile), true); return 0; }
            AppSettings.Mode = Install.DetectMode();
            return RunEngineHeadless(BuildRescheduleArgs(rescheduleJson), liveFile);
        }
        if (applySetupJson != null)
        {
            if (!Install.IsElevated()) { Install.Relaunch("--apply-setup \"" + applySetupJson + "\"" + LiveArg(liveFile), true); return 0; }
            AppSettings.Mode = Install.DetectMode();
            return ApplySetup(applySetupJson, liveFile);
        }

        AppMode mode = Install.DetectMode();
        AppSettings.Mode = mode;
        settings = AppSettings.Load();
        Theme.Load(settings.Theme);
        // Make sure the engine is unpacked for this mode before any view queries it.
        try { Engine.FindEngine(); } catch { }

        if (checkFile != null)
        {
            try
            {
                Window probe = BuildWindow();
                // construct every view and the restore window headless — layout code
                // that never runs is the code most likely to throw on first use, and
                // the restore window can destroy a database, so its layout must not be
                // the first thing anyone runs live.
                FrameworkElement m = new ModernView(null).Build();
                FrameworkElement d = new DbaView(null).Build();
                FrameworkElement rw = new RestoreWindow().BuildRoot();
                File.WriteAllText(checkFile, "WPF-CHECK-OK view=" + settings.View + " theme=" + settings.Theme +
                    " modern=" + (m != null) + " dba=" + (d != null) + " restore=" + (rw != null));
                return 0;
            }
            catch (Exception ex)
            {
                try { File.WriteAllText(checkFile, "WPF-CHECK-FAIL " + ex.Message); } catch { }
                return 2;
            }
        }

        Application app = new Application();

        // An unhandled exception should be recorded and, on the UI thread, survived -
        // a single bad row or a malformed timestamp must not take the whole window down
        // with a silent 0xE0434352. Both handlers write the detail to a file, since a
        // windowed exe has no console to print to.
        app.DispatcherUnhandledException += delegate(object s, System.Windows.Threading.DispatcherUnhandledExceptionEventArgs e)
        {
            LogCrash("dispatcher", e.Exception);
            e.Handled = true;
        };
        AppDomain.CurrentDomain.UnhandledException += delegate(object s, UnhandledExceptionEventArgs e)
        {
            LogCrash("domain", e.ExceptionObject as Exception);
        };

        // A fresh download that has not chosen a mode gets the first-run chooser. "Just
        // run once" continues into the normal window; the other choices set up and
        // relaunch, then shut this instance down. A deep-link flag (--restore /
        // --selftest) means "just run now", so it skips the chooser.
        if (mode == AppMode.Fresh && !openRestoreOnLoad && !selfTestOnLoad)
        {
            FirstRun fr = new FirstRun(app, delegate { ShowMain(app, false, false); });
            app.Run(fr.Build());
            return 0;
        }

        ShowMain(app, openRestoreOnLoad, selfTestOnLoad);
        app.Run();
        return 0;
    }

    static string LiveArg(string liveFile)
    {
        return liveFile != null ? (" --live \"" + liveFile + "\"") : "";
    }

    // Run one engine mode, streaming each output line to the live file (append + flush)
    // so the UI can tail it in real time, then a final "[EXIT] N" sentinel that tells the
    // tailer the job is done and carries the exit code. Returns the engine exit code.
    static int RunEngineHeadless(string engineArgs, string liveFile)
    {
        int code = 9;
        using (System.IO.TextWriter w = OpenLive(liveFile))
        {
            try { code = Engine.Run(engineArgs, delegate(string line) { WriteLive(w, line); }); }
            catch (Exception ex) { WriteLive(w, "[ERROR] " + ex.Message); }
            WriteLive(w, "[EXIT] " + code);
        }
        return code;
    }

    static System.IO.TextWriter OpenLive(string liveFile)
    {
        if (liveFile == null) { return System.IO.TextWriter.Null; }
        try
        {
            System.IO.StreamWriter w = new System.IO.StreamWriter(
                new System.IO.FileStream(liveFile, System.IO.FileMode.Create, System.IO.FileAccess.Write, System.IO.FileShare.ReadWrite));
            w.AutoFlush = true;
            return w;
        }
        catch { return System.IO.TextWriter.Null; }
    }

    static void WriteLive(System.IO.TextWriter w, string line) { try { w.WriteLine(line); } catch { } }

    static System.Collections.Generic.Dictionary<string, object> ReadJson(string path)
    {
        try
        {
            System.Web.Script.Serialization.JavaScriptSerializer js = new System.Web.Script.Serialization.JavaScriptSerializer();
            return js.Deserialize<System.Collections.Generic.Dictionary<string, object>>(File.ReadAllText(path));
        }
        catch { return null; }
    }

    static string BuildRescheduleArgs(string jsonPath)
    {
        System.Collections.Generic.Dictionary<string, object> d = ReadJson(jsonPath);
        string a = "-Reschedule";
        if (d != null)
        {
            if (d.ContainsKey("IntervalHours")) { a += " -IntervalHours " + ToInt(d["IntervalHours"]); }
            if (d.ContainsKey("HourlyKeep")) { a += " -HourlyKeep " + ToInt(d["HourlyKeep"]); }
            if (d.ContainsKey("DailyKeepDays")) { a += " -DailyKeepDays " + ToInt(d["DailyKeepDays"]); }
        }
        return a;
    }

    // Configure and schedule a backup non-interactively: engine -Setup (Windows auth)
    // then -Reschedule to register the SYSTEM task from the new config. -Reschedule
    // creates the task if none exists and re-registers it if one does, so this same path
    // serves both a first setup and a later reconfigure. Both stream into one result file.
    static int ApplySetup(string jsonPath, string liveFile)
    {
        System.Collections.Generic.Dictionary<string, object> d = ReadJson(jsonPath);
        using (System.IO.TextWriter w = OpenLive(liveFile))
        {
            if (d == null) { WriteLive(w, "[ERROR] could not read the setup settings"); WriteLive(w, "[EXIT] 9"); return 9; }
            string setup = "-Setup -UseWindowsAuth";
            if (d.ContainsKey("Instance") && Str(d["Instance"]).Length > 0) { setup += " -Instance \"" + Str(d["Instance"]) + "\""; }
            if (d.ContainsKey("SharePath")) { setup += " -SharePath \"" + Str(d["SharePath"]) + "\""; }
            if (d.ContainsKey("StagingPath") && Str(d["StagingPath"]).Length > 0) { setup += " -StagingPath \"" + Str(d["StagingPath"]) + "\""; }
            if (d.ContainsKey("IntervalHours")) { setup += " -IntervalHours " + ToInt(d["IntervalHours"]); }
            if (d.ContainsKey("HourlyKeep")) { setup += " -HourlyKeep " + ToInt(d["HourlyKeep"]); }
            if (d.ContainsKey("DailyKeepDays")) { setup += " -DailyKeepDays " + ToInt(d["DailyKeepDays"]); }

            WriteLive(w, "== configuring ==");
            int code = 9;
            try { code = Engine.Run(setup, delegate(string line) { WriteLive(w, line); }); }
            catch (Exception ex) { WriteLive(w, "[ERROR] " + ex.Message); }
            if (code == 0)
            {
                WriteLive(w, "== scheduling ==");
                try { code = Engine.Run("-Reschedule", delegate(string line) { WriteLive(w, line); }); }
                catch (Exception ex) { WriteLive(w, "[ERROR] " + ex.Message); }
            }
            WriteLive(w, "[EXIT] " + code);
            return code;
        }
    }

    static int ToInt(object o) { try { return Convert.ToInt32(o); } catch { return 0; } }
    static string Str(object o) { return o == null ? "" : Convert.ToString(o); }

    static void LogCrash(string where, Exception ex)
    {
        try
        {
            string p = Path.Combine(Path.GetTempPath(), "SqlExpressBackupApp-wpf-error.txt");
            File.AppendAllText(p, DateTime.Now.ToString("s") + " [" + where + "] " +
                (ex == null ? "unknown" : ex.ToString()) + Environment.NewLine + Environment.NewLine);
        }
        catch { }
    }

    static void ShowMain(Application app, bool openRestoreOnLoad, bool selfTestOnLoad)
    {
        Window win = BuildWindow();
        win.Closing += delegate { SaveGeometry(win); };
        if (openRestoreOnLoad) { win.Loaded += delegate { OpenRestore(); }; }
        if (selfTestOnLoad) { win.Loaded += delegate { if (currentModern != null) { currentModern.StartSelfTest(); } }; }
        app.MainWindow = win;
        win.Show();
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
        mainWin = win;
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

    static ModernView currentModern;
    static void SwitchView()
    {
        if (settings.View == "dba") { host.Child = new DbaView(OpenRestore).Build(); currentModern = null; }
        else { ModernView mv = new ModernView(OpenRestore); currentModern = mv; host.Child = mv.Build(); }
    }

    // Restore is a separate window (decision locked). It drives the engine's restore
    // modes - the shell owns no restore logic of its own.
    static Window mainWin;
    static RestoreWindow restore;
    static void OpenRestore()
    {
        restore = new RestoreWindow();
        restore.Show(mainWin);
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
