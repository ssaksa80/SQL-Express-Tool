// The Modern view — the default look. A sidebar over a spacious content area: status
// tiles, the protected databases, and the primary actions. Data comes from the same
// engine the console uses; a backup run streams the same progress markers.

using System;
using System.Collections.Generic;
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
        sp.Children.Add(Ui.NavItem("", "Databases", false, null));
        sp.Children.Add(Ui.NavItem("", "Restore", false, openRestore));
        sp.Children.Add(Ui.NavItem("", "Schedule", false, null));
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
        Border refresh = Ui.GhostButton("Refresh", delegate { Refresh(); });
        actions.Children.Add(run); actions.Children.Add(self); actions.Children.Add(rest); actions.Children.Add(refresh);
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
        log = new LogPane("Activity log", true, CloseActivity);
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
    void RunBackup() { RunMode("-Run", "Backup"); }

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
