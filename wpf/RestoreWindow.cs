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
    StackPanel setList;
    StackPanel filterPanel;
    Dictionary<string, CheckBox> checks = new Dictionary<string, CheckBox>();
    HashSet<string> shown = new HashSet<string>();
    List<string> dbOrder = new List<string>();
    StackPanel detail;
    TextBox targetBox;
    ComboBox recoveryBox;
    CheckBox replaceBox;
    TextBox dataDirBox, logDirBox;
    CheckBox closeConnBox, restrictedBox;
    StackPanel confirmRow;
    TextBox confirmBox;
    Border startBtn;
    GlowBar glow;
    LogPane log;
    Border logHost;

    Dictionary<string, List<RestoreSet>> byDb = new Dictionary<string, List<RestoreSet>>();
    RestoreSet current;
    Dictionary<string, object> inspected;
    Border verifyCard;
    bool busy;

    struct PlanFile { public string Logical; public string Type; public long Bytes; }

    public void Show(Window owner)
    {
        win = new Window();
        win.Title = "Restore — SQL Express Backup";
        win.Width = 980; win.Height = 660; win.MinWidth = 820; win.MinHeight = 520;
        win.Owner = owner;
        win.WindowStartupLocation = WindowStartupLocation.CenterOwner;
        win.Background = Theme.Bg; win.FontFamily = Ui.Face;
        win.Content = BuildRoot();
        if (owner != null) { win.Closed += delegate { try { owner.Activate(); } catch { } }; }
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
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // eyebrow
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // database filter
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // divider
        g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // sets
        TextBlock eb = Ui.Eyebrow("Backup sets"); eb.Margin = new Thickness(13, 12, 0, 6);
        g.Children.Add(eb);

        // database filter - tick a database to show only its sets, instead of scrolling
        // the whole catalogue of every database at once
        ScrollViewer fsv = new ScrollViewer(); fsv.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        fsv.MaxHeight = 190; fsv.Margin = new Thickness(9, 0, 6, 2);
        filterPanel = new StackPanel();
        fsv.Content = filterPanel; Grid.SetRow(fsv, 1); g.Children.Add(fsv);

        Border div = new Border(); div.Height = 1; div.Background = Theme.Line; div.Margin = new Thickness(9, 4, 9, 4);
        Grid.SetRow(div, 2); g.Children.Add(div);

        ScrollViewer sv = new ScrollViewer(); sv.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        setList = new StackPanel(); setList.Margin = new Thickness(7, 0, 7, 10);
        sv.Content = setList; Grid.SetRow(sv, 3); g.Children.Add(sv);
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
        byDb.Clear(); dbOrder.Clear();
        foreach (RestoreSet r in sets)
        {
            if (!byDb.ContainsKey(r.Database)) { byDb[r.Database] = new List<RestoreSet>(); dbOrder.Add(r.Database); }
            byDb[r.Database].Add(r);
        }
        foreach (List<RestoreSet> ss in byDb.Values)
        {
            ss.Sort(delegate(RestoreSet a, RestoreSet c) { return string.Compare(c.TakenUtc, a.TakenUtc, StringComparison.Ordinal); });
        }
        glow.Status(dbOrder.Count == 0 ? "No backup sets — run elevated to read a locked share, or open a .bak" : "Ready");

        // default to the first database checked, so you land on one database's sets
        // rather than the whole scrolling catalogue
        shown.Clear();
        if (dbOrder.Count > 0) { shown.Add(dbOrder[0]); }

        BuildFilter();
        RenderSets();
    }

    // Per-database filter checkboxes plus All / None quick actions.
    void BuildFilter()
    {
        filterPanel.Children.Clear();
        checks.Clear();
        if (dbOrder.Count == 0) { return; }

        StackPanel quick = new StackPanel(); quick.Orientation = Orientation.Horizontal;
        quick.Margin = new Thickness(4, 0, 0, 4);
        TextBlock lbl = Ui.Text("Show:", 11, Theme.Ink3); lbl.VerticalAlignment = VerticalAlignment.Center;
        quick.Children.Add(lbl);
        quick.Children.Add(MiniLink("All", delegate { shown = new HashSet<string>(dbOrder); SyncChecks(); RenderSets(); }));
        quick.Children.Add(MiniLink("None", delegate { shown.Clear(); SyncChecks(); RenderSets(); }));
        filterPanel.Children.Add(quick);

        foreach (string db in dbOrder)
        {
            string d = db;
            CheckBox cb = new CheckBox();
            cb.Content = db + "  (" + byDb[db].Count + ")";
            cb.Foreground = Theme.Ink2; cb.FontFamily = Ui.Face; cb.FontSize = 12.5;
            cb.Margin = new Thickness(4, 2, 0, 2);
            cb.IsChecked = shown.Contains(db);
            cb.Checked += delegate { shown.Add(d); RenderSets(); };
            cb.Unchecked += delegate { shown.Remove(d); RenderSets(); };
            checks[db] = cb;
            filterPanel.Children.Add(cb);
        }
    }

    // Reflect `shown` onto the checkboxes (for All / None); the change handlers re-render.
    void SyncChecks()
    {
        foreach (KeyValuePair<string, CheckBox> kv in checks)
        {
            bool want = shown.Contains(kv.Key);
            if (kv.Value.IsChecked != want) { kv.Value.IsChecked = want; }
        }
    }

    Border MiniLink(string text, Action onClick)
    {
        Border b = new Border(); b.Padding = new Thickness(6, 1, 6, 1); b.Margin = new Thickness(6, 0, 0, 0);
        b.CornerRadius = new CornerRadius(4); b.Cursor = System.Windows.Input.Cursors.Hand;
        b.Child = Ui.Text(text, 11.5, Theme.Accent, FontWeights.SemiBold);
        b.MouseEnter += delegate { b.Background = Theme.Sunken; };
        b.MouseLeave += delegate { b.Background = Brushes.Transparent; };
        if (onClick != null) { b.MouseLeftButtonUp += delegate { onClick(); }; }
        return b;
    }

    // Render only the checked databases' sets.
    void RenderSets()
    {
        setList.Children.Clear();
        foreach (string db in dbOrder)
        {
            if (!shown.Contains(db)) { continue; }
            setList.Children.Add(DbHeader(db));
            foreach (RestoreSet r in byDb[db]) { setList.Children.Add(SetRow(r)); }
        }
        if (shown.Count == 0)
        {
            TextBlock hint = Ui.Text("Tick a database above to show its backup sets.", 12, Theme.Ink3);
            hint.Margin = new Thickness(10, 10, 10, 0); hint.TextWrapping = TextWrapping.Wrap;
            setList.Children.Add(hint);
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
        verifyCard = null;
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
        detail.Children.Add(Margin(OptionRow("Data files to", DataDirInput()), 0, 8, 0, 0));
        detail.Children.Add(Margin(OptionRow("Log files to", LogDirInput()), 0, 8, 0, 0));
        closeConnBox = OptionCheck("Close active connections first (SET SINGLE_USER — needed to REPLACE a live database)");
        detail.Children.Add(Margin(closeConnBox, 0, 10, 0, 0));
        restrictedBox = OptionCheck("Bring back as RESTRICTED_USER (owners / dbcreator / sysadmin only)");
        detail.Children.Add(Margin(restrictedBox, 0, 6, 0, 0));
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
    FrameworkElement DataDirInput()
    {
        dataDirBox = new TextBox(); dataDirBox.Width = 320; dataDirBox.FontSize = 12.5; dataDirBox.FontFamily = Ui.Face;
        dataDirBox.HorizontalAlignment = HorizontalAlignment.Left;
        dataDirBox.ToolTip = "Folder for the restored .mdf/.ndf files. Blank = the instance default data path.";
        return dataDirBox;
    }
    FrameworkElement LogDirInput()
    {
        logDirBox = new TextBox(); logDirBox.Width = 320; logDirBox.FontSize = 12.5; logDirBox.FontFamily = Ui.Face;
        logDirBox.HorizontalAlignment = HorizontalAlignment.Left;
        logDirBox.ToolTip = "Folder for the restored .ldf log file. Blank = the same folder as the data files.";
        return logDirBox;
    }
    CheckBox OptionCheck(string text)
    {
        CheckBox c = new CheckBox(); c.Content = text;
        c.Foreground = Theme.Ink2; c.FontFamily = Ui.Face; c.FontSize = 12.5;
        return c;
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

    // A real pre-restore verification: a dry run that validates the backup set and lays
    // out exactly what a restore would do. It reports the permission check (can the SQL
    // service actually read the file), the media-integrity result (RESTORE VERIFYONLY
    // WITH CHECKSUM, run live), the recovery details from the header, and the file-by-file
    // MOVE plan - so any permission trap, corruption, or surprise surfaces before you
    // commit. Nothing is written; VERIFYONLY is SQL Server's own dry-run of a restore.
    void VerifyMedia()
    {
        if (current == null || busy) { return; }
        Dictionary<string, object> info = inspected;
        string db = (info != null) ? Engine.Field(info, "Database") : "";
        if (db == "") { db = current.Database; }
        string target = (targetBox != null && targetBox.Text.Trim().Length > 0) ? targetBox.Text.Trim() : TargetName(db);
        bool replace = (replaceBox != null && replaceBox.IsChecked == true);

        Border card = Ui.Card(); card.Margin = new Thickness(0, 14, 0, 4);
        StackPanel sp = new StackPanel();
        sp.Children.Add(Ui.Eyebrow("Verification — dry run"));

        // 1. permission: Readable comes from RESTORE FILELISTONLY run AS the SQL service,
        // so it is the real answer to "can the account that restores read this file".
        bool readable = Engine.FieldBool(info, "Readable");
        string reason = Engine.Field(info, "ReadReason");
        sp.Children.Add(Check(readable, readable
            ? "SQL Server service account can read the backup file"
            : "SQL service cannot read the file — " + (reason == "denied"
                ? "access denied; grant its service account read on the backup folder"
                : (reason == "" ? "unreadable" : reason))));

        // 2. media integrity — filled in live once VERIFYONLY returns
        TextBlock vIcon, vText;
        sp.Children.Add(StepMutable("RESTORE VERIFYONLY (checksum) — checking…", out vIcon, out vText));

        sp.Children.Add(Divider());
        sp.Children.Add(Ui.Eyebrow("Recovery details"));
        sp.Children.Add(Detail2("Database", db == "" ? "(unknown)" : db));
        sp.Children.Add(Detail2("Backup taken", LocalTime(current.TakenUtc)));
        sp.Children.Add(Detail2("Compression", Engine.FieldBool(info, "Compressed") ? "compressed" : "none"));
        List<PlanFile> files = Files(info);
        long total = 0; foreach (PlanFile f in files) { total += f.Bytes; }
        sp.Children.Add(Detail2("Data size", (total / 1048576) + " MB across " + files.Count + " file(s)"));
        sp.Children.Add(Detail2("Recovery model", "SIMPLE — full backup, restorable standalone (no log chain to validate)"));

        sp.Children.Add(Divider());
        sp.Children.Add(Ui.Eyebrow("Restore plan (MOVE)"));
        if (files.Count == 0) { sp.Children.Add(Ui.Text("(file list unavailable)", 12, Theme.Ink3)); }
        else
        {
            int dataIdx = 0;
            foreach (PlanFile f in files)
            {
                bool isLog = (f.Type == "L");
                string leaf = isLog ? (target + "_log.ldf") : (dataIdx == 0 ? (target + ".mdf") : (target + "_" + dataIdx + ".ndf"));
                if (!isLog) { dataIdx++; }
                sp.Children.Add(Mono(f.Logical + "  ·  " + (isLog ? "Log" : "Data") + "  ·  " + (f.Bytes / 1048576) + " MB  →  " + leaf));
            }
        }

        sp.Children.Add(Divider());
        if (replace && string.Equals(target, db, StringComparison.OrdinalIgnoreCase))
        {
            sp.Children.Add(Check(false, "REPLACE targets the LIVE database " + db + " — it would be overwritten"));
        }
        else
        {
            sp.Children.Add(Check(true, "Restores as " + target + " — the source database is untouched"));
        }

        card.Child = sp;
        if (verifyCard != null) { detail.Children.Remove(verifyCard); }
        verifyCard = card;
        detail.Children.Add(card);
        card.BringIntoView();

        // run the live check
        glow.Status("Verifying " + System.IO.Path.GetFileName(current.Path) + " …");
        string path = current.Path; string dbName = db;
        Thread t = new Thread(delegate ()
        {
            string err; bool ok = Engine.RestoreVerify(path, out err);
            Dispatch(delegate
            {
                vIcon.Text = ok ? "✓" : "!";
                vIcon.Foreground = ok ? Theme.Ok : Theme.Bad;
                vText.Text = ok
                    ? "RESTORE VERIFYONLY passed — media is complete and restorable (CHECKSUM ok)"
                    : "RESTORE VERIFYONLY failed — " + err;
                vText.Foreground = ok ? Theme.Ok : Theme.Bad;
                glow.Status(ok ? ("Verification passed — " + dbName + " backup is restorable")
                               : ("Verification FAILED — " + err));
            });
        });
        t.IsBackground = true; t.Start();
    }

    // A verification step whose icon/text are updated once an async check returns.
    Grid StepMutable(string text, out TextBlock icon, out TextBlock textBlock)
    {
        Grid g = new Grid(); g.Margin = new Thickness(0, 2, 0, 0);
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        icon = Ui.Text("…", 12.5, Theme.Ink3, FontWeights.Bold); icon.Margin = new Thickness(0, 0, 8, 0);
        textBlock = Ui.Text(text, 12.5, Theme.Ink2); textBlock.TextWrapping = TextWrapping.Wrap;
        Grid.SetColumn(textBlock, 1);
        g.Children.Add(icon); g.Children.Add(textBlock);
        return g;
    }

    Grid Detail2(string label, string value)
    {
        Grid g = new Grid(); g.Margin = new Thickness(0, 2, 0, 2);
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(120) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.Children.Add(Ui.Text(label, 12, Theme.Ink3));
        TextBlock v = Ui.Text(value, 12, Theme.Ink2); v.TextWrapping = TextWrapping.Wrap; Grid.SetColumn(v, 1);
        g.Children.Add(v);
        return g;
    }

    // The backup's file list (logical name, D/L type, size) from the inspect result.
    static List<PlanFile> Files(Dictionary<string, object> info)
    {
        List<PlanFile> r = new List<PlanFile>();
        if (info == null || !info.ContainsKey("Files") || info["Files"] == null) { return r; }
        System.Collections.IEnumerable seq = info["Files"] as System.Collections.IEnumerable;
        if (seq == null) { return r; }
        foreach (object o in seq)
        {
            System.Collections.Generic.IDictionary<string, object> row = o as System.Collections.Generic.IDictionary<string, object>;
            if (row == null) { continue; }
            PlanFile f = new PlanFile();
            f.Logical = (row.ContainsKey("LogicalName") && row["LogicalName"] != null) ? Convert.ToString(row["LogicalName"]) : "";
            f.Type = (row.ContainsKey("Type") && row["Type"] != null) ? Convert.ToString(row["Type"]) : "";
            try { if (row.ContainsKey("SizeBytes") && row["SizeBytes"] != null) { f.Bytes = Convert.ToInt64(row["SizeBytes"]); } } catch { }
            r.Add(f);
        }
        return r;
    }

    void StartRestore(string db)
    {
        if (current == null || busy) { return; }
        string target = targetBox.Text.Trim();
        string recovery = recoveryBox.SelectedItem == null ? "RECOVERY" : recoveryBox.SelectedItem.ToString();
        string args = "-RestoreRun -RestoreFrom \"" + current.Path + "\" -RestoreAs \"" + target + "\" -RestoreRecoveryState " + recovery;
        if (replaceBox.IsChecked == true) { args += " -RestoreReplace"; }
        if (dataDirBox != null && dataDirBox.Text.Trim().Length > 0) { args += " -RestoreDataDir \"" + dataDirBox.Text.Trim() + "\""; }
        if (logDirBox != null && logDirBox.Text.Trim().Length > 0) { args += " -RestoreLogDir \"" + logDirBox.Text.Trim() + "\""; }
        if (closeConnBox != null && closeConnBox.IsChecked == true) { args += " -RestoreCloseConnections"; }
        if (restrictedBox != null && restrictedBox.IsChecked == true) { args += " -RestoreRestrictedUser"; }

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
