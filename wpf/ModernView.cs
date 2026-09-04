// The Modern view — the default look. A sidebar over a spacious content area: status
// tiles, the protected databases, and the primary actions. Data comes from the same
// engine the console uses; a backup run streams the same progress markers.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Threading;

class ModernView
{
    readonly Action openRestore;
    Grid root;
    StackPanel dbList;
    GlowBar glow;
    LogPane log;
    Border activityArea;
    TextBlock lastRunVal, schedVal, dbCountVal, instVal;
    bool busy;

    // schedule-window edit controls (built when the Schedule window is filled)
    ComboBox schedIntervalBox;
    TextBox schedHourlyBox, schedDailyBox;
    TextBlock schedStatus;
    Border schedApplyBtn;
    static readonly int[] schedHrs = new int[] { 1, 2, 3, 4, 6, 8, 12, 24 };

    public ModernView(Action openRestore) { this.openRestore = openRestore; }

    public FrameworkElement Build()
    {
        root = new Grid();
        root.Background = Theme.Bg;
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(190) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        root.Children.Add(Sidebar());
        FrameworkElement main = Main();
        Grid.SetColumn(main, 1);
        root.Children.Add(main);

        Refresh();
        return root;
    }

    Border Sidebar()
    {
        Border b = new Border();
        b.Background = Theme.Surface;
        b.BorderBrush = Theme.Line;
        b.BorderThickness = new Thickness(0, 0, 1, 0);
        StackPanel sp = new StackPanel();
        sp.Margin = new Thickness(12, 18, 12, 12);

        StackPanel brand = new StackPanel();
        brand.Orientation = Orientation.Horizontal;
        brand.Margin = new Thickness(4, 0, 0, 18);
        TextBlock logo = Ui.Icon("", 18, Theme.Accent); // storage/database glyph
        logo.Margin = new Thickness(0, 0, 8, 0);
        TextBlock name = Ui.Text("SQL Express Backup", 13, Theme.Ink, FontWeights.SemiBold);
        name.VerticalAlignment = VerticalAlignment.Center; name.TextWrapping = TextWrapping.Wrap;
        brand.Children.Add(logo); brand.Children.Add(name);
        sp.Children.Add(brand);

        sp.Children.Add(Ui.NavItem("", "Overview", true, null));
        sp.Children.Add(Ui.NavItem("", "Databases", false, ShowDatabases));
        sp.Children.Add(Ui.NavItem("", "Restore", false, openRestore));
        sp.Children.Add(Ui.NavItem("", "Schedule", false, ShowSchedule));
        sp.Children.Add(Ui.NavItem("", "Activity", false, ShowFullLog));

        b.Child = sp;
        return b;
    }

    FrameworkElement Main()
    {
        Grid g = new Grid();
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // heading
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // tiles
        g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // db list
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // actions
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // progress
        g.Margin = new Thickness(22, 20, 22, 18);

        TextBlock h = Ui.Text("Protection overview", 19, Theme.Ink, FontWeights.SemiBold);
        g.Children.Add(h);

        UniformGrid tiles = new UniformGrid();
        tiles.Columns = 4; tiles.Margin = new Thickness(0, 14, 0, 0);
        Border t1 = Ui.Tile("—", "last run", Theme.Ink); lastRunVal = TileValue(t1);
        Border t2 = Ui.Tile("—", "schedule", Theme.Ink); schedVal = TileValue(t2);
        Border t3 = Ui.Tile("—", "databases", Theme.Ink); dbCountVal = TileValue(t3);
        Border t4 = Ui.Tile("—", "instance", Theme.Ink); instVal = TileValue(t4);
        foreach (Border t in new Border[] { t1, t2, t3, t4 }) { t.Margin = new Thickness(0, 0, 10, 0); }
        tiles.Children.Add(t1); tiles.Children.Add(t2); tiles.Children.Add(t3); tiles.Children.Add(t4);
        Grid.SetRow(tiles, 1); g.Children.Add(tiles);

        Border listCard = Ui.Card();
        listCard.Margin = new Thickness(0, 16, 0, 0);
        listCard.Padding = new Thickness(0);
        Grid lg = new Grid();
        lg.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        lg.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        TextBlock lh = Ui.Eyebrow("Databases");
        lh.Margin = new Thickness(16, 13, 0, 8);
        lg.Children.Add(lh);
        ScrollViewer sv = new ScrollViewer();
        sv.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        dbList = new StackPanel(); dbList.Margin = new Thickness(6, 0, 6, 8);
        sv.Content = dbList; Grid.SetRow(sv, 1); lg.Children.Add(sv);
        listCard.Child = lg;
        Grid.SetRow(listCard, 2); g.Children.Add(listCard);

        StackPanel actions = new StackPanel();
        actions.Orientation = Orientation.Horizontal;
        actions.Margin = new Thickness(0, 16, 0, 0);
        Border run = Ui.PrimaryButton("Run backup now", RunBackup);
        run.Margin = new Thickness(0, 0, 9, 0);
        Border self = Ui.GhostButton("Self test", SelfTest);
        self.Margin = new Thickness(0, 0, 9, 0);
        Border rest = Ui.GhostButton("Restore…", delegate { if (openRestore != null) openRestore(); });
        rest.Margin = new Thickness(0, 0, 9, 0);
        Border setup = Ui.GhostButton("Set up…", OpenSetup);
        setup.Margin = new Thickness(0, 0, 9, 0);
        Border refresh = Ui.GhostButton("Refresh", delegate { Refresh(); });
        actions.Children.Add(run); actions.Children.Add(self); actions.Children.Add(rest); actions.Children.Add(setup); actions.Children.Add(refresh);
        Grid.SetRow(actions, 3); g.Children.Add(actions);

        activityArea = ActivityArea();
        activityArea.Visibility = Visibility.Collapsed;
        Grid.SetRow(activityArea, 4); g.Children.Add(activityArea);

        return g;
    }

    static TextBlock TileValue(Border tile)
    {
        StackPanel sp = tile.Child as StackPanel;
        return sp.Children[0] as TextBlock;
    }

    // The activity area holds the glowing progress bar over a live/one-click log pane.
    // The glow shows only during a run; the log serves both the live stream and the
    // one-click set/database log.
    Border ActivityArea()
    {
        StackPanel sp = new StackPanel();
        glow = new GlowBar();
        glow.Margin = new Thickness(0, 0, 0, 10);
        sp.Children.Add(glow);
        log = new LogPane("Activity log", true, CloseActivity, true);
        log.MaxHeight = 200;
        sp.Children.Add(log);
        Border wrap = new Border();
        wrap.Margin = new Thickness(0, 14, 0, 0);
        wrap.Child = sp;
        return wrap;
    }

    void CloseActivity() { activityArea.Visibility = Visibility.Collapsed; }

    // One click on a database row: show that database's recent backup log.
    void ShowDbLog(string db)
    {
        activityArea.Visibility = Visibility.Visible;
        glow.Visibility = Visibility.Collapsed;
        log.SetTitle(db + " — backup log");
        log.SetLines(new string[] { "Reading " + db + " log…" });
        Thread t = new Thread(delegate ()
        {
            List<string> ls = Engine.ReadLog(db, 400);
            Dispatch(delegate
            {
                log.SetLines(ls);
                log.SetTitle(db + " — backup log (" + ls.Count + " lines)");
            });
        });
        t.IsBackground = true; t.Start();
    }

    // The Activity nav item: the whole recent log, unfiltered.
    void ShowFullLog()
    {
        activityArea.Visibility = Visibility.Visible;
        glow.Visibility = Visibility.Collapsed;
        log.SetTitle("Recent activity log");
        log.SetLines(new string[] { "Reading log…" });
        Thread t = new Thread(delegate ()
        {
            List<string> ls = Engine.ReadLog(null, 500);
            Dispatch(delegate { log.SetLines(ls); });
        });
        t.IsBackground = true; t.Start();
    }

    // The Schedule nav item: a small window with the backup schedule, read from the
    // engine's published status (interval, last run, the estimated next run, pending
    // copies, instance, share). No elevation and no SQL round-trip.
    void ShowSchedule()
    {
        Window w = new Window();
        w.Title = "Backup schedule";
        w.Width = 480; w.Height = 400; w.MinWidth = 380; w.MinHeight = 280;
        w.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        w.Background = Theme.Bg; w.FontFamily = Ui.Face;
        ScrollViewer sv = new ScrollViewer(); sv.Padding = new Thickness(20, 18, 20, 18);
        StackPanel sp = new StackPanel();
        sp.Children.Add(Ui.Text("Reading schedule…", 13, Theme.Ink3));
        sv.Content = sp; w.Content = sv;
        w.Show(); w.Activate();
        Thread t = new Thread(delegate ()
        {
            BackupStatus st = Engine.ReadStatus();
            Dispatch(delegate { FillSchedule(sp, st); });
        });
        t.IsBackground = true; t.Start();
    }

    void FillSchedule(StackPanel sp, BackupStatus st)
    {
        sp.Children.Clear();
        sp.Children.Add(Ui.Text("Backup schedule", 18, Theme.Ink, FontWeights.SemiBold));
        sp.Children.Add(Gap(12));

        if (!st.Found)
        {
            TextBlock none = Ui.Text("No schedule is configured yet. Run setup, then install the scheduled task:", 12.5, Theme.Ink2);
            none.TextWrapping = TextWrapping.Wrap; sp.Children.Add(none);
            sp.Children.Add(Gap(6));
            TextBlock cmd = Ui.Text("Invoke-SqlExpressBackup.ps1 -Setup   →   -Install -As Task", 12, Theme.Ink3);
            cmd.FontFamily = new FontFamily("Cascadia Mono, Consolas"); cmd.TextWrapping = TextWrapping.Wrap;
            sp.Children.Add(cmd);
            return;
        }

        ScheduleRow(sp, "Interval", "every " + st.IntervalHours + " hour" + (st.IntervalHours == 1 ? "" : "s"));
        ScheduleRow(sp, "Last run", st.LastRunUtc == "" ? "—" : (LocalTime(st.LastRunUtc) + (st.LastResult == "" ? "" : "   (" + st.LastResult + ")")));
        ScheduleRow(sp, "Next run (est.)", NextRun(st));
        ScheduleRow(sp, "Pending copies", st.PendingCount.ToString());
        ScheduleRow(sp, "Instance", st.Instance == "" ? "—" : st.Instance);
        ScheduleRow(sp, "Share", st.SharePath == "" ? "—" : st.SharePath);

        sp.Children.Add(Gap(16));
        sp.Children.Add(Ui.Text("Change schedule", 13, Theme.Ink, FontWeights.SemiBold));
        TextBlock hint = Ui.Text("Applies to the SYSTEM scheduled task. Needs administrator.", 11.5, Theme.Ink3);
        hint.Margin = new Thickness(0, 2, 0, 8); sp.Children.Add(hint);

        sp.Children.Add(ScheduleEditRow("Interval", BuildInterval(st)));
        sp.Children.Add(ScheduleEditRow("Keep hourly", BuildRetention(out schedHourlyBox)));
        sp.Children.Add(ScheduleEditRow("Keep daily (days)", BuildRetention(out schedDailyBox)));

        schedApplyBtn = Ui.PrimaryButton("Apply", ApplyReschedule);
        schedApplyBtn.Margin = new Thickness(0, 12, 0, 0); schedApplyBtn.HorizontalAlignment = HorizontalAlignment.Left;
        sp.Children.Add(schedApplyBtn);
        schedStatus = Ui.Text("", 12, Theme.Ink3); schedStatus.TextWrapping = TextWrapping.Wrap; schedStatus.Margin = new Thickness(0, 8, 0, 0);
        sp.Children.Add(schedStatus);
    }

    FrameworkElement BuildInterval(BackupStatus st)
    {
        schedIntervalBox = new ComboBox(); schedIntervalBox.Width = 150; schedIntervalBox.FontSize = 12.5;
        schedIntervalBox.HorizontalAlignment = HorizontalAlignment.Left;
        int sel = 4;
        for (int k = 0; k < schedHrs.Length; k++)
        {
            schedIntervalBox.Items.Add("every " + schedHrs[k] + "h");
            if (schedHrs[k] == st.IntervalHours) { sel = k; }
        }
        schedIntervalBox.SelectedIndex = sel;
        return schedIntervalBox;
    }
    FrameworkElement BuildRetention(out TextBox box)
    {
        box = new TextBox(); box.Width = 100; box.FontSize = 12.5; box.FontFamily = Ui.Face;
        box.HorizontalAlignment = HorizontalAlignment.Left;
        box.ToolTip = "Leave blank to keep the current value.";
        return box;
    }
    Grid ScheduleEditRow(string label, FrameworkElement input)
    {
        Grid g = new Grid(); g.Margin = new Thickness(0, 4, 0, 0);
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(135) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        TextBlock l = Ui.Text(label, 12.5, Theme.Ink2); l.VerticalAlignment = VerticalAlignment.Center; g.Children.Add(l);
        Grid.SetColumn(input, 1); g.Children.Add(input);
        return g;
    }

    void ApplyReschedule()
    {
        int interval = schedHrs[schedIntervalBox.SelectedIndex < 0 ? 4 : schedIntervalBox.SelectedIndex];
        System.Collections.Generic.Dictionary<string, object> d = new System.Collections.Generic.Dictionary<string, object>();
        d["IntervalHours"] = interval;
        int hv; if (int.TryParse(schedHourlyBox.Text.Trim(), out hv) && hv > 0) { d["HourlyKeep"] = hv; }
        int dv; if (int.TryParse(schedDailyBox.Text.Trim(), out dv) && dv > 0) { d["DailyKeepDays"] = dv; }
        string json = new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(d);
        string tmp = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "seb-resched-" + Guid.NewGuid().ToString("N") + ".json");
        try { System.IO.File.WriteAllText(tmp, json); }
        catch (Exception ex) { schedStatus.Foreground = Theme.Bad; schedStatus.Text = "Could not write: " + ex.Message; return; }

        schedApplyBtn.IsHitTestVisible = false; schedApplyBtn.Opacity = 0.5;
        schedStatus.Foreground = Theme.Ink3;
        schedStatus.Text = "Approve the elevation prompt to apply…";
        Elevate.Run("--reschedule \"" + tmp + "\"", 90,
            delegate(string line) { if (line.Trim().Length > 0 && !line.StartsWith("{")) { schedStatus.Text = line; } },
            delegate(bool ok, string output)
            {
                try { System.IO.File.Delete(tmp); } catch { }
                schedApplyBtn.IsHitTestVisible = true; schedApplyBtn.Opacity = 1.0;
                schedStatus.Foreground = ok ? Theme.Ok : Theme.Bad;
                schedStatus.Text = ok ? ("Schedule updated — every " + interval + " hours.") : ("Failed: " + FirstLine(output));
                if (ok) { Refresh(); }
            });
    }

    static string FirstLine(string s)
    {
        if (s == null) { return ""; }
        s = s.Replace("\r\n", "\n"); int i = s.IndexOf('\n');
        return i >= 0 ? s.Substring(0, i) : s;
    }

    void ScheduleRow(StackPanel sp, string label, string value)
    {
        Grid g = new Grid(); g.Margin = new Thickness(0, 5, 0, 5);
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(135) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.Children.Add(Ui.Text(label, 12.5, Theme.Ink3));
        TextBlock v = Ui.Text(value, 12.5, Theme.Ink); v.TextWrapping = TextWrapping.Wrap; Grid.SetColumn(v, 1);
        g.Children.Add(v);
        sp.Children.Add(g);
    }

    static Border Gap(double h) { Border b = new Border(); b.Height = h; return b; }

    static string NextRun(BackupStatus st)
    {
        try
        {
            DateTime last;
            if (DateTime.TryParse(st.LastRunUtc, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out last))
            {
                DateTime next = last.ToUniversalTime().AddHours(st.IntervalHours).ToLocalTime();
                string when = next.ToString("d MMM HH:mm", CultureInfo.CurrentCulture);
                if (next < DateTime.Now) { when += "   (overdue)"; }
                return when;
            }
        }
        catch { }
        return "—";
    }

    static string LocalTime(string utc)
    {
        DateTime d;
        if (DateTime.TryParse(utc, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out d))
        {
            return d.ToLocalTime().ToString("d MMM HH:mm", CultureInfo.CurrentCulture);
        }
        return utc;
    }

    // The Databases nav item: a window listing each protected database with its recovery
    // points, latest backup and total size. Reads the same catalogue the Overview list uses.
    void ShowDatabases()
    {
        Window w = new Window();
        w.Title = "Databases";
        w.Width = 560; w.Height = 520; w.MinWidth = 420; w.MinHeight = 300;
        w.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        w.Background = Theme.Bg; w.FontFamily = Ui.Face;
        ScrollViewer sv = new ScrollViewer(); sv.Padding = new Thickness(20, 18, 20, 18);
        StackPanel sp = new StackPanel();
        sp.Children.Add(Ui.Text("Reading databases…", 13, Theme.Ink3));
        sv.Content = sp; w.Content = sv;
        w.Show(); w.Activate();
        Thread t = new Thread(delegate ()
        {
            List<RestoreSet> sets = Engine.RestoreList();
            Dispatch(delegate { FillDatabases(sp, sets); });
        });
        t.IsBackground = true; t.Start();
    }

    void FillDatabases(StackPanel sp, List<RestoreSet> sets)
    {
        sp.Children.Clear();
        sp.Children.Add(Ui.Text("Databases", 18, Theme.Ink, FontWeights.SemiBold));
        sp.Children.Add(Gap(10));

        Dictionary<string, List<RestoreSet>> byDb = new Dictionary<string, List<RestoreSet>>();
        List<string> order = new List<string>();
        foreach (RestoreSet r in sets)
        {
            if (!byDb.ContainsKey(r.Database)) { byDb[r.Database] = new List<RestoreSet>(); order.Add(r.Database); }
            byDb[r.Database].Add(r);
        }
        if (order.Count == 0)
        {
            TextBlock none = Ui.Text("No databases visible. Run a backup, or start elevated to read a locked share.", 12.5, Theme.Ink3);
            none.TextWrapping = TextWrapping.Wrap; sp.Children.Add(none);
            return;
        }
        sp.Children.Add(Ui.Text(order.Count + " database" + (order.Count == 1 ? "" : "s") + " protected", 12, Theme.Ink3));
        sp.Children.Add(Gap(8));
        foreach (string db in order)
        {
            List<RestoreSet> ss = byDb[db];
            string latest = ""; long total = 0;
            foreach (RestoreSet r in ss)
            {
                total += r.Bytes;
                if (string.Compare(r.TakenUtc, latest, StringComparison.Ordinal) > 0) { latest = r.TakenUtc; }
            }
            Border card = Ui.Card(); card.Margin = new Thickness(0, 0, 0, 8); card.Padding = new Thickness(14, 11, 14, 11);
            StackPanel cs = new StackPanel();
            cs.Children.Add(Ui.Text(db, 14, Theme.Ink, FontWeights.SemiBold));
            TextBlock meta = Ui.Text(ss.Count + " recovery point" + (ss.Count == 1 ? "" : "s")
                + "   ·   latest " + LocalTime(latest) + "   ·   " + (total / 1048576) + " MB total", 12, Theme.Ink3);
            meta.Margin = new Thickness(0, 3, 0, 0); meta.TextWrapping = TextWrapping.Wrap;
            cs.Children.Add(meta);
            card.Child = cs; sp.Children.Add(card);
        }
    }

    // ---- data ---------------------------------------------------------------------

    public void Refresh()
    {
        Thread t = new Thread(delegate ()
        {
            BackupStatus st = Engine.ReadStatus();
            List<RestoreSet> sets = Engine.RestoreList();
            Dispatch(delegate { ApplyStatus(st, sets); });
        });
        t.IsBackground = true; t.Start();
    }

    void ApplyStatus(BackupStatus st, List<RestoreSet> sets)
    {
        if (st.Found)
        {
            lastRunVal.Text = st.LastResult == "" ? "unknown" : st.LastResult;
            lastRunVal.Foreground = st.LastResult == "ok" ? Theme.Ok : (st.LastResult == "" ? Theme.Ink3 : Theme.Warn);
            schedVal.Text = "every " + st.IntervalHours + "h";
            instVal.Text = st.Instance == "" ? "—" : st.Instance;
            instVal.FontSize = 15;
        }
        else
        {
            lastRunVal.Text = "not set up"; lastRunVal.Foreground = Theme.Ink3;
        }

        // group sets by database
        Dictionary<string, int> byDb = new Dictionary<string, int>();
        List<string> order = new List<string>();
        foreach (RestoreSet r in sets)
        {
            if (!byDb.ContainsKey(r.Database)) { byDb[r.Database] = 0; order.Add(r.Database); }
            byDb[r.Database] = byDb[r.Database] + 1;
        }
        dbCountVal.Text = order.Count.ToString();

        dbList.Children.Clear();
        if (order.Count == 0)
        {
            TextBlock empty = Ui.Text("No backup sets visible. Run a backup, or start elevated to read a locked share.", 12.5, Theme.Ink3);
            empty.Margin = new Thickness(12, 8, 12, 8); empty.TextWrapping = TextWrapping.Wrap;
            dbList.Children.Add(empty);
        }
        foreach (string db in order)
        {
            dbList.Children.Add(DbRow(db, byDb[db]));
        }
    }

    Border DbRow(string db, int count)
    {
        Border b = new Border();
        b.Padding = new Thickness(12, 9, 12, 9);
        b.BorderBrush = Theme.Line; b.BorderThickness = new Thickness(0, 0, 0, 1);
        b.Cursor = System.Windows.Input.Cursors.Hand;
        b.ToolTip = "Click to view the backup log for " + db;
        Grid g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        TextBlock ic = Ui.Icon("", 15, Theme.Ink3); ic.Margin = new Thickness(0, 0, 10, 0);
        TextBlock nm = Ui.Text(db, 13, Theme.Ink); nm.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(nm, 1);
        Border pill = Ui.Pill(count + " point" + (count == 1 ? "" : "s"), Theme.Ok, Theme.OkBg);
        pill.VerticalAlignment = VerticalAlignment.Center;
        Grid.SetColumn(pill, 2);
        TextBlock logHint = Ui.Text("log ›", 11.5, Theme.Ink3);
        logHint.VerticalAlignment = VerticalAlignment.Center;
        logHint.Margin = new Thickness(12, 0, 2, 0);
        Grid.SetColumn(logHint, 3);
        g.Children.Add(ic); g.Children.Add(nm); g.Children.Add(pill); g.Children.Add(logHint);
        b.Child = g;
        b.MouseEnter += delegate { b.Background = Theme.Sunken; logHint.Foreground = Theme.Accent; };
        b.MouseLeave += delegate { b.Background = Brushes.Transparent; logHint.Foreground = Theme.Ink3; };
        b.MouseLeftButtonUp += delegate { ShowDbLog(db); };
        return b;
    }

    // ---- actions ------------------------------------------------------------------

    public void StartSelfTest() { RunMode("-SelfTest", "Self test"); }
    void SelfTest() { RunMode("-SelfTest", "Self test"); }

    void RunBackup()
    {
        // A backup pass reads the SYSTEM-only sealed credential, so the engine requires
        // administrator. When already elevated, stream it live; otherwise run it as an
        // elevated job and show its output when it returns.
        if (Install.IsElevated()) { RunMode("-Run", "Backup"); return; }
        if (busy) { return; }
        busy = true;
        activityArea.Visibility = Visibility.Visible;
        glow.Visibility = Visibility.Visible;
        glow.Begin("Backup (elevated)");
        log.SetTitle("Backup — elevated");
        log.Clear();
        log.Append("Approve the Windows elevation prompt to run the backup as SYSTEM…");
        int total = 1, index = 0; string stage = "starting"; int pct = -1;
        Elevate.Run("--backup-now", 600,
            delegate(string line)
            {
                bool marker = false;
                if (line.StartsWith("[JOB]")) { index = FieldInt(line, "index", index); total = FieldInt(line, "total", total); marker = true; }
                else if (line.StartsWith("[STAGE]")) { stage = FieldRest(line, "stage"); marker = true; }
                else if (line.StartsWith("[PROGRESS]")) { pct = FieldInt(line, "pct", pct); marker = true; }
                double overall = Overall(index, total, stage, pct);
                if (marker) { glow.Update(overall, "Backup  ·  " + stage + (total > 1 ? ("  " + index + "/" + total) : "")); }
                if (!line.StartsWith("[PROGRESS]")) { log.Append(line); }
            },
            delegate(bool ok, string output)
            {
                glow.Finish(ok, ok ? "Backup finished" : "Backup failed (or elevation declined)");
                busy = false; Refresh();
            });
    }

    void OpenSetup()
    {
        SetupWizard w = new SetupWizard();
        w.Show(Application.Current != null ? Application.Current.MainWindow : null, delegate { Refresh(); });
    }

    static string[] SplitLines(string s) { return (s == null ? "" : s).Replace("\r\n", "\n").Split('\n'); }

    void RunMode(string args, string label)
    {
        if (busy) { return; }
        busy = true;
        activityArea.Visibility = Visibility.Visible;
        glow.Visibility = Visibility.Visible;
        glow.Begin(label);
        log.SetTitle(label + " — activity");
        log.Clear();
        Thread t = new Thread(delegate ()
        {
            int total = 1, index = 0; string stage = "starting"; int pct = -1;
            Engine.Run(args, delegate(string line)
            {
                bool marker = false;
                if (line.StartsWith("[JOB]")) { index = FieldInt(line, "index", index); total = FieldInt(line, "total", total); marker = true; }
                else if (line.StartsWith("[STAGE]")) { stage = FieldRest(line, "stage"); marker = true; }
                else if (line.StartsWith("[PROGRESS]")) { pct = FieldInt(line, "pct", pct); marker = true; }
                double overall = Overall(index, total, stage, pct);
                string label2 = label + "  ·  " + stage + (total > 1 ? ("  " + index + "/" + total) : "");
                Dispatch(delegate
                {
                    if (marker) { glow.Update(overall, label2); }
                    // The percent lives on the glow bar; keep those markers out of the
                    // log so it stays a readable record of stages, results and errors.
                    if (!line.StartsWith("[PROGRESS]")) { log.Append(line); }
                });
            });
            Dispatch(delegate { glow.Finish(true, label + " — finished"); busy = false; Refresh(); });
        });
        t.IsBackground = true; t.Start();
    }

    static double Overall(int index, int total, string stage, int pct)
    {
        if (stage.StartsWith("finished") || stage == "done") { return 1.0; }
        if (total <= 0) { return 0; }
        int done = index - 1; if (done < 0) done = 0;
        double frac;
        if (stage == "backup") { int p = pct < 0 ? 0 : (pct > 100 ? 100 : pct); frac = (p / 100.0) * 0.75; }
        else if (stage == "verify") { frac = 0.85; }
        else if (stage == "copy" || stage == "prune") { frac = 0.95; }
        else { frac = 0.0; }
        double v = (done + frac) / total;
        return v > 1 ? 1 : v;
    }

    static int FieldInt(string line, string key, int dflt)
    {
        int i = line.IndexOf(key + "=", StringComparison.Ordinal);
        if (i < 0) return dflt;
        int start = i + key.Length + 1, end = line.IndexOf(' ', start);
        if (end < 0) end = line.Length;
        int val; if (int.TryParse(line.Substring(start, end - start), out val)) return val;
        return dflt;
    }
    static string FieldRest(string line, string key)
    {
        int i = line.IndexOf(key + "=", StringComparison.Ordinal);
        if (i < 0) return "";
        return line.Substring(i + key.Length + 1).TrimEnd();
    }

    static void Dispatch(Action a)
    {
        Application app = Application.Current;
        if (app != null) { app.Dispatcher.BeginInvoke(DispatcherPriority.Normal, a); }
    }
}
