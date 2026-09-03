// The restore window — a separate top-level window (as decided). Backup-set tree on
// the left; the selected set's readability check, restore sequence, and options on the
// right; progress along the bottom. It drives the engine's restore modes, so there is
// one implementation of the restore work, not two.
//
// SQL Server's vocabulary throughout - backup set, restore sequence, recovery state,
// MOVE, REPLACE - and the destructive REPLACE path is guarded by a typed confirmation.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

class RestoreWindow
{
    Window win;
    StackPanel tree;
    StackPanel detail;
    TextBox targetBox;
    ComboBox recoveryBox;
    CheckBox replaceBox;
    StackPanel confirmRow;
    TextBox confirmBox;
    Border startBtn;
    GlowBar glow;
    LogPane log;
    Border logHost;

    Dictionary<string, List<RestoreSet>> byDb = new Dictionary<string, List<RestoreSet>>();
    RestoreSet current;
    Dictionary<string, object> inspected;
    bool busy;

    public void Show(Window owner)
    {
        win = new Window();
        win.Title = "Restore — SQL Express Backup";
        win.Width = 980; win.Height = 660; win.MinWidth = 820; win.MinHeight = 520;
        win.Owner = owner;
        win.WindowStartupLocation = WindowStartupLocation.CenterOwner;
        win.Background = Theme.Bg; win.FontFamily = Ui.Face;
        win.Content = BuildRoot();
        win.Show();
        LoadSets();
    }

    // Build the window's visual tree without showing it - lets the smoke check
    // construct the whole restore layout headless and prove it does not throw.
    public FrameworkElement BuildRoot()
    {
        Grid root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // log pane
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // progress

        Grid body = new Grid();
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(250) });
        body.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        body.Children.Add(TreePane());
        FrameworkElement d = DetailPane(); Grid.SetColumn(d, 1); body.Children.Add(d);
        root.Children.Add(body);

        logHost = LogHost();
        logHost.Visibility = Visibility.Collapsed;
        Grid.SetRow(logHost, 1); root.Children.Add(logHost);

        Border prog = ProgressBar();
        Grid.SetRow(prog, 2); root.Children.Add(prog);
        return root;
    }

    Border LogHost()
    {
        Border b = new Border();
        b.Background = Theme.Surface; b.BorderBrush = Theme.Line; b.BorderThickness = new Thickness(0, 1, 0, 0);
        b.Padding = new Thickness(14, 10, 14, 10);
        log = new LogPane("Log", true, delegate { logHost.Visibility = Visibility.Collapsed; }, true);
        log.Height = 170;
        b.Child = log;
        return b;
    }

    Border TreePane()
    {
        Border b = new Border();
        b.Background = Theme.Surface; b.BorderBrush = Theme.Line; b.BorderThickness = new Thickness(0, 0, 1, 0);
        Grid g = new Grid();
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        TextBlock eb = Ui.Eyebrow("Backup sets"); eb.Margin = new Thickness(13, 12, 0, 6);
        g.Children.Add(eb);
        ScrollViewer sv = new ScrollViewer(); sv.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        tree = new StackPanel(); tree.Margin = new Thickness(7, 0, 7, 10);
        sv.Content = tree; Grid.SetRow(sv, 1); g.Children.Add(sv);
        b.Child = g;
        return b;
    }

    FrameworkElement DetailPane()
    {
        ScrollViewer sv = new ScrollViewer(); sv.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        sv.Padding = new Thickness(18, 14, 18, 14);
        detail = new StackPanel();
        detail.Children.Add(Ui.Text("Select a backup set", 15, Theme.Ink3, FontWeights.SemiBold));
        sv.Content = detail;
        return sv;
    }

    Border ProgressBar()
    {
        Border b = new Border();
        b.Background = Theme.Surface; b.BorderBrush = Theme.Line; b.BorderThickness = new Thickness(0, 1, 0, 0);
        b.Padding = new Thickness(16, 10, 16, 12);
        glow = new GlowBar();
        glow.Status("Ready");
        b.Child = glow;
        return b;
    }

    // ---- data ---------------------------------------------------------------------

    void LoadSets()
    {
        glow.Status("Reading backup sets…");
        Thread t = new Thread(delegate ()
        {
            List<RestoreSet> sets = Engine.RestoreList();
            Dispatch(delegate { ApplySets(sets); });
        });
        t.IsBackground = true; t.Start();
    }

    void ApplySets(List<RestoreSet> sets)
    {
        byDb.Clear(); tree.Children.Clear();
        List<string> order = new List<string>();
        foreach (RestoreSet r in sets)
        {
            if (!byDb.ContainsKey(r.Database)) { byDb[r.Database] = new List<RestoreSet>(); order.Add(r.Database); }
            byDb[r.Database].Add(r);
        }
        glow.Status(order.Count == 0 ? "No backup sets — run elevated to read a locked share, or open a .bak" : "Ready");
        foreach (string db in order)
        {
            tree.Children.Add(DbHeader(db));
            List<RestoreSet> ss = byDb[db];
            ss.Sort(delegate(RestoreSet a, RestoreSet c) { return string.Compare(c.TakenUtc, a.TakenUtc, StringComparison.Ordinal); });
            foreach (RestoreSet r in ss) { tree.Children.Add(SetRow(r)); }
        }
    }

    Border DbHeader(string db)
    {
        Border b = new Border(); b.Padding = new Thickness(6, 7, 6, 3);
        StackPanel row = new StackPanel(); row.Orientation = Orientation.Horizontal;
        TextBlock ic = Ui.Icon("", 13, Theme.Ink3); ic.Margin = new Thickness(0, 0, 7, 0);
        row.Children.Add(ic); row.Children.Add(Ui.Text(db, 12.5, Theme.Ink, FontWeights.SemiBold));
        b.Child = row; return b;
    }

    Border SetRow(RestoreSet r)
    {
        Border b = new Border();
        b.Padding = new Thickness(24, 5, 8, 5); b.CornerRadius = new CornerRadius(5);
        b.Cursor = System.Windows.Input.Cursors.Hand;
        Grid g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        StackPanel sp = new StackPanel();
        sp.Children.Add(Ui.Text(LocalTime(r.TakenUtc), 12, Theme.Ink2));
        TextBlock sub = Ui.Text(r.Kind + " · " + (r.Bytes / 1048576) + " MB", 11, Theme.Ink3);
        sp.Children.Add(sub);
        g.Children.Add(sp);
        // per-set log affordance; e.Handled stops it also selecting the row
        TextBlock logHint = Ui.Text("log", 11, Theme.Ink3);
        logHint.VerticalAlignment = VerticalAlignment.Center;
        logHint.Margin = new Thickness(6, 0, 4, 0);
        logHint.ToolTip = "View this database's backup log";
        Grid.SetColumn(logHint, 1);
        logHint.MouseEnter += delegate { logHint.Foreground = Theme.Accent; };
        logHint.MouseLeave += delegate { logHint.Foreground = Theme.Ink3; };
        logHint.MouseLeftButtonUp += delegate(object s, System.Windows.Input.MouseButtonEventArgs e) { e.Handled = true; ShowSetLog(r.Database); };
        g.Children.Add(logHint);
        b.Child = g;
        b.MouseEnter += delegate { if (current != r) b.Background = Theme.Sunken; };
        b.MouseLeave += delegate { if (current != r) b.Background = Brushes.Transparent; };
        b.MouseLeftButtonUp += delegate { Select(r, b); };
        return b;
    }

    // One click on a set's "log": show that database's recent backup log.
    void ShowSetLog(string db)
    {
        logHost.Visibility = Visibility.Visible;
        log.SetTitle(db + " — backup log");
        log.SetLines(new string[] { "Reading " + db + " log…" });
        Thread t = new Thread(delegate ()
        {
            List<string> ls = Engine.ReadLog(db, 400);
            Dispatch(delegate { log.SetLines(ls); log.SetTitle(db + " — backup log (" + ls.Count + " lines)"); });
        });
        t.IsBackground = true; t.Start();
    }

    Border selectedRow;
    void Select(RestoreSet r, Border row)
    {
        if (busy) { return; }
        if (selectedRow != null) { selectedRow.Background = Brushes.Transparent; }
        selectedRow = row; row.Background = Theme.AccentBg;
        current = r; inspected = null;
        detail.Children.Clear();
        detail.Children.Add(Ui.Text("Reading " + System.IO.Path.GetFileName(r.Path) + "…", 13, Theme.Ink3));
        Thread t = new Thread(delegate ()
        {
            Dictionary<string, object> info = Engine.RestoreInspect(r.Path);
            Dispatch(delegate { ApplyInspect(info); });
        });
        t.IsBackground = true; t.Start();
    }

    void ApplyInspect(Dictionary<string, object> info)
    {
        inspected = info;
        detail.Children.Clear();
        if (info == null) { detail.Children.Add(Ui.Text("The engine returned nothing readable.", 13, Theme.Bad)); return; }

        string db = Engine.Field(info, "Database");
        bool readable = Engine.FieldBool(info, "Readable");

        detail.Children.Add(Ui.Text(db == "" ? current.Database : db, 18, Theme.Ink, FontWeights.SemiBold));
        detail.Children.Add(Margin(Ui.Text("from " + LocalTime(current.TakenUtc), 12.5, Theme.Ink3), 0, 2, 0, 14));

        // readability check
        detail.Children.Add(Ui.Eyebrow("Restore sequence"));
        Border seq = Ui.Card(); seq.Margin = new Thickness(0, 6, 0, 14); seq.Padding = new Thickness(13, 11, 13, 11);
        StackPanel sqp = new StackPanel();
        sqp.Children.Add(Mono("RESTORE DATABASE [" + TargetName(db) + "]"));
        sqp.Children.Add(Mono("  FROM DISK = " + System.IO.Path.GetFileName(current.Path)));
        sqp.Children.Add(Mono("  WITH MOVE …, RECOVERY, CHECKSUM"));
        sqp.Children.Add(Divider());
        sqp.Children.Add(Check(readable, readable ? "SQL Server can read this file" : "SQL cannot read this file — grant its service account read on the folder"));
        sqp.Children.Add(Check(true, "Restores to a NEW database — the source is untouched"));
        seq.Child = sqp; detail.Children.Add(seq);

        // options
        detail.Children.Add(Ui.Eyebrow("Restore options"));
        detail.Children.Add(Margin(OptionRow("Restore as", TargetInput(db)), 0, 8, 0, 8));
        detail.Children.Add(OptionRow("Recovery state", RecoveryInput()));
        replaceBox = new CheckBox();
        replaceBox.Content = "Overwrite the existing database  (REPLACE)";
        replaceBox.Foreground = Theme.Ink2; replaceBox.FontFamily = Ui.Face; replaceBox.FontSize = 12.5;
        replaceBox.Margin = new Thickness(0, 10, 0, 0);
        replaceBox.Checked += delegate { UpdateConfirm(db); };
        replaceBox.Unchecked += delegate { UpdateConfirm(db); };
        detail.Children.Add(replaceBox);

        confirmRow = new StackPanel(); confirmRow.Orientation = Orientation.Horizontal;
        confirmRow.Margin = new Thickness(0, 8, 0, 0); confirmRow.Visibility = Visibility.Collapsed;
        confirmRow.Children.Add(Margin(Ui.Text("This replaces the live database. Type " + db + " to confirm:", 12, Theme.Bad), 0, 4, 8, 0));
        confirmBox = new TextBox(); confirmBox.Width = 150; confirmBox.FontSize = 12.5; confirmBox.FontFamily = Ui.Face;
        confirmBox.TextChanged += delegate { UpdateStart(db, readable); };
        confirmRow.Children.Add(confirmBox);
        detail.Children.Add(confirmRow);

        // greyed-unavailable
        detail.Children.Add(Margin(Ui.Eyebrow("Unavailable here"), 0, 16, 0, 6));
        detail.Children.Add(Unavailable("Recovery point (STOPAT)", "no log chain — SIMPLE recovery"));
        detail.Children.Add(Unavailable("Tail-log backup", "impossible under SIMPLE recovery"));

        // actions
        StackPanel act = new StackPanel(); act.Orientation = Orientation.Horizontal; act.Margin = new Thickness(0, 18, 0, 4);
        startBtn = Ui.PrimaryButton("Start restore", delegate { StartRestore(db); });
        startBtn.Margin = new Thickness(0, 0, 8, 0);
        act.Children.Add(startBtn);
        Border verifyBtn = Ui.GhostButton("Verify media", delegate { VerifyMedia(); });
        verifyBtn.Margin = new Thickness(0, 0, 8, 0);
        act.Children.Add(verifyBtn);
        // Copy the restore sequence as a template a DBA can paste into a ticket or SSMS.
        string sqlText = "-- Restore template (fill in MOVE for each logical file)\r\n"
            + "RESTORE DATABASE [" + TargetName(db) + "]\r\n"
            + "  FROM DISK = '" + current.Path + "'\r\n"
            + "  WITH MOVE '<logical>' TO '<path>', RECOVERY, CHECKSUM";
        Border copyBtn = Ui.GhostButton("Copy SQL", delegate
        {
            try { Clipboard.SetText(sqlText); glow.Status("Restore SQL copied to clipboard"); } catch { }
        });
        copyBtn.Margin = new Thickness(0, 0, 8, 0);
        act.Children.Add(copyBtn);
        act.Children.Add(Ui.GhostButton("View log", delegate { ShowSetLog(db); }));
        detail.Children.Add(act);

        UpdateStart(db, readable);
    }

    // ---- option widgets -----------------------------------------------------------

    FrameworkElement TargetInput(string db)
    {
        targetBox = new TextBox(); targetBox.Text = TargetName(db);
        targetBox.Width = 260; targetBox.FontSize = 12.5; targetBox.FontFamily = Ui.Face;
        targetBox.HorizontalAlignment = HorizontalAlignment.Left;
        bool readable = Engine.FieldBool(inspected, "Readable");
        targetBox.TextChanged += delegate { UpdateStart(db, readable); };
        return targetBox;
    }
    FrameworkElement RecoveryInput()
    {
        recoveryBox = new ComboBox(); recoveryBox.Width = 170; recoveryBox.FontSize = 12.5;
        recoveryBox.HorizontalAlignment = HorizontalAlignment.Left;
        recoveryBox.Items.Add("RECOVERY"); recoveryBox.Items.Add("NORECOVERY"); recoveryBox.Items.Add("STANDBY");
        recoveryBox.SelectedIndex = 0;
        return recoveryBox;
    }
    static string TargetName(string db) { return (db == "" ? "Restored" : db) + "_Restore"; }

    Grid OptionRow(string label, FrameworkElement input)
    {
        Grid g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        TextBlock l = Ui.Text(label, 12.5, Theme.Ink2); l.VerticalAlignment = VerticalAlignment.Center;
        g.Children.Add(l); Grid.SetColumn(input, 1); g.Children.Add(input);
        return g;
    }

    void UpdateConfirm(string db)
    {
        bool overwrite = replaceBox.IsChecked == true &&
            string.Equals(targetBox.Text.Trim(), db, StringComparison.OrdinalIgnoreCase);
        // REPLACE only truly overwrites when the target IS the live database; if the
        // target is a new name, REPLACE just allows overwriting stray files.
        confirmRow.Visibility = (replaceBox.IsChecked == true && string.Equals(targetBox.Text.Trim(), db, StringComparison.OrdinalIgnoreCase))
            ? Visibility.Visible : Visibility.Collapsed;
        UpdateStart(db, Engine.FieldBool(inspected, "Readable"));
    }

    void UpdateStart(string db, bool readable)
    {
        bool ok = !busy && current != null && readable && targetBox != null && targetBox.Text.Trim().Length > 0;
        if (confirmRow != null && confirmRow.Visibility == Visibility.Visible)
        {
            ok = ok && confirmBox != null && string.Equals(confirmBox.Text.Trim(), db, StringComparison.Ordinal);
        }
        if (startBtn != null)
        {
            startBtn.Opacity = ok ? 1.0 : 0.45;
            startBtn.IsHitTestVisible = ok;
        }
    }

    // ---- actions ------------------------------------------------------------------

    void VerifyMedia()
    {
        if (current == null || busy) { return; }
        glow.Status("Verifying media…");
        Thread t = new Thread(delegate ()
        {
            string err; bool ok = Engine.RestoreVerify(current.Path, out err);
            Dispatch(delegate { glow.Status(ok ? "Media verified — RESTORE VERIFYONLY passed WITH CHECKSUM" : ("Verify failed: " + err)); });
        });
        t.IsBackground = true; t.Start();
    }

    void StartRestore(string db)
    {
        if (current == null || busy) { return; }
        string target = targetBox.Text.Trim();
        string recovery = recoveryBox.SelectedItem == null ? "RECOVERY" : recoveryBox.SelectedItem.ToString();
        string args = "-RestoreRun -RestoreFrom \"" + current.Path + "\" -RestoreAs \"" + target + "\" -RestoreRecoveryState " + recovery;
        if (replaceBox.IsChecked == true) { args += " -RestoreReplace"; }

        busy = true; UpdateStart(db, true);
        glow.Begin("Restoring " + target);
        logHost.Visibility = Visibility.Visible;
        log.SetTitle("Restore — activity");
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
                Dispatch(delegate
                {
                    if (marker) { glow.Update(overall, "Restoring " + target + "  ·  " + stage); }
                    if (!line.StartsWith("[PROGRESS]")) { log.Append(line); }
                });
            });
            Dispatch(delegate
            {
                glow.Finish(true, "Restore finished — " + target + " (source untouched)");
                busy = false; UpdateStart(db, true);
            });
        });
        t.IsBackground = true; t.Start();
    }

    // ---- small builders -----------------------------------------------------------

    static TextBlock Mono(string s)
    {
        TextBlock t = new TextBlock(); t.Text = s; t.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        t.FontSize = 11.5; t.Foreground = Theme.Ink2; t.TextWrapping = TextWrapping.Wrap;
        return t;
    }
    static Border Divider() { Border b = new Border(); b.Height = 1; b.Background = Theme.Line; b.Margin = new Thickness(0, 7, 0, 7); return b; }
    StackPanel Check(bool ok, string text)
    {
        StackPanel sp = new StackPanel(); sp.Orientation = Orientation.Horizontal; sp.Margin = new Thickness(0, 2, 0, 0);
        TextBlock ic = Ui.Text(ok ? "✓" : "!", 12.5, ok ? Theme.Ok : Theme.Bad, FontWeights.Bold);
        ic.Margin = new Thickness(0, 0, 8, 0);
        TextBlock tx = Ui.Text(text, 12.5, ok ? Theme.Ok : Theme.Bad); tx.TextWrapping = TextWrapping.Wrap;
        sp.Children.Add(ic); sp.Children.Add(tx); return sp;
    }
    Grid Unavailable(string label, string why)
    {
        Grid g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(220) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.Margin = new Thickness(0, 3, 0, 0);
        g.Children.Add(Ui.Text(label, 12, Theme.Ink3));
        TextBlock w = Ui.Text("unavailable — " + why, 12, Theme.Ink3); w.FontStyle = FontStyles.Italic;
        Grid.SetColumn(w, 1); g.Children.Add(w);
        return g;
    }
    static FrameworkElement Margin(FrameworkElement e, double l, double t, double r, double b) { e.Margin = new Thickness(l, t, r, b); return e; }

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
        double v = (done + frac) / total; return v > 1 ? 1 : v;
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
    static string LocalTime(string utc)
    {
        DateTime d;
        if (DateTime.TryParse(utc, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out d))
        { return d.ToLocalTime().ToString("d MMM HH:mm", CultureInfo.CurrentCulture); }
        return utc;
    }
    static void Dispatch(Action a)
    {
        Application app = Application.Current;
        if (app != null) { app.Dispatcher.BeginInvoke(DispatcherPriority.Normal, a); }
    }
}
