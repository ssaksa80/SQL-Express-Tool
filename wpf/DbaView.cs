// The DBA view — the SSMS-native look. An object-explorer tree of the instance and its
// databases on the left; the selected database's recovery points as a grid on the
// right. Same data as the Modern view, presented the way someone who lives in SQL
// Server Management Studio expects.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Threading;

class DbaView
{
    readonly Action openRestore;
    Grid root;
    StackPanel tree;
    StackPanel grid;
    TextBlock gridHeading;
    Dictionary<string, List<RestoreSet>> byDb = new Dictionary<string, List<RestoreSet>>();
    string selected;
    LogPane log;
    Border logHost;

    public DbaView(Action openRestore) { this.openRestore = openRestore; }

    public FrameworkElement Build()
    {
        root = new Grid();
        root.Background = Theme.Bg;
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(232) });
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });

        // left: object explorer
        Border left = new Border();
        left.Background = Theme.Surface;
        left.BorderBrush = Theme.Line; left.BorderThickness = new Thickness(0, 0, 1, 0);
        Grid lg = new Grid();
        lg.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        lg.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        TextBlock eb = Ui.Eyebrow("Object Explorer");
        eb.Margin = new Thickness(13, 12, 0, 6); lg.Children.Add(eb);
        ScrollViewer sv = new ScrollViewer(); sv.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        tree = new StackPanel(); tree.Margin = new Thickness(8, 0, 8, 10);
        sv.Content = tree; Grid.SetRow(sv, 1); lg.Children.Add(sv);
        left.Child = lg;
        root.Children.Add(left);

        // right: recovery points
        Grid rg = new Grid();
        rg.Margin = new Thickness(16, 14, 16, 14);
        rg.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // heading
        rg.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // grid
        rg.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // actions
        rg.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto }); // log pane
        gridHeading = Ui.Text("Select a database", 15, Theme.Ink, FontWeights.SemiBold);
        rg.Children.Add(gridHeading);
        ScrollViewer gsv = new ScrollViewer(); gsv.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        gsv.Margin = new Thickness(0, 10, 0, 0);
        grid = new StackPanel(); gsv.Content = grid; Grid.SetRow(gsv, 1); rg.Children.Add(gsv);
        StackPanel actions = new StackPanel(); actions.Orientation = Orientation.Horizontal;
        actions.Margin = new Thickness(0, 12, 0, 0);
        Border rest = Ui.PrimaryButton("Restore…", delegate { if (openRestore != null) openRestore(); });
        rest.Margin = new Thickness(0, 0, 8, 0);
        actions.Children.Add(rest);
        Border verify = Ui.GhostButton("Verify", null);
        verify.Margin = new Thickness(0, 0, 8, 0);
        actions.Children.Add(verify);
        actions.Children.Add(Ui.GhostButton("View log", delegate { ShowLog(selected); }));
        Grid.SetRow(actions, 2); rg.Children.Add(actions);

        log = new LogPane("Backup log", true, delegate { logHost.Visibility = Visibility.Collapsed; });
        log.Height = 150;
        logHost = new Border();
        logHost.Margin = new Thickness(0, 12, 0, 0);
        logHost.Visibility = Visibility.Collapsed;
        logHost.Child = log;
        Grid.SetRow(logHost, 3); rg.Children.Add(logHost);

        Grid.SetColumn(rg, 1); root.Children.Add(rg);

        Load();
        return root;
    }

    void Load()
    {
        Thread t = new Thread(delegate ()
        {
            List<RestoreSet> sets = Engine.RestoreList();
            Dispatch(delegate { Apply(sets); });
        });
        t.IsBackground = true; t.Start();
    }

    void Apply(List<RestoreSet> sets)
    {
        byDb.Clear();
        List<string> order = new List<string>();
        foreach (RestoreSet r in sets)
        {
            if (!byDb.ContainsKey(r.Database)) { byDb[r.Database] = new List<RestoreSet>(); order.Add(r.Database); }
            byDb[r.Database].Add(r);
        }

        tree.Children.Add(TreeRow("", "APPSRV1\\SQLEXPRESS", 0, Theme.Accent, null));
        tree.Children.Add(TreeRow("", "Databases", 1, Theme.Ink2, null));
        foreach (string db in order)
        {
            string d = db;
            tree.Children.Add(TreeRow("", db, 2, Theme.Ink, delegate { Select(d); }));
        }
        if (order.Count == 0)
        {
            TextBlock empty = Ui.Text("(no databases visible)", 12, Theme.Ink3);
            empty.Margin = new Thickness(24, 4, 0, 0); tree.Children.Add(empty);
        }
        else { Select(order[0]); }
    }

    Border TreeRow(string glyph, string text, int depth, SolidColorBrush ink, Action onClick)
    {
        Border b = new Border();
        b.Padding = new Thickness(6 + depth * 15, 4, 6, 4);
        b.CornerRadius = new CornerRadius(5);
        b.Cursor = onClick != null ? System.Windows.Input.Cursors.Hand : System.Windows.Input.Cursors.Arrow;
        StackPanel row = new StackPanel(); row.Orientation = Orientation.Horizontal;
        TextBlock ic = Ui.Icon(glyph, 13, depth == 0 ? Theme.Accent : (depth == 1 ? Theme.Warn : Theme.Ink3));
        ic.Margin = new Thickness(0, 0, 7, 0);
        TextBlock tx = Ui.Text(text, 12.5, ink); tx.VerticalAlignment = VerticalAlignment.Center;
        row.Children.Add(ic); row.Children.Add(tx); b.Child = row;
        if (onClick != null)
        {
            b.MouseEnter += delegate { b.Background = Theme.Sunken; };
            b.MouseLeave += delegate { if (tx.Text != selected) b.Background = Brushes.Transparent; };
            b.MouseLeftButtonUp += delegate { onClick(); };
        }
        return b;
    }

    void Select(string db)
    {
        selected = db;
        gridHeading.Text = db + " — recovery points";
        grid.Children.Clear();
        grid.Children.Add(GridHeader());
        List<RestoreSet> sets = byDb.ContainsKey(db) ? byDb[db] : new List<RestoreSet>();
        // newest first
        sets.Sort(delegate(RestoreSet a, RestoreSet c) { return string.Compare(c.TakenUtc, a.TakenUtc, StringComparison.Ordinal); });
        foreach (RestoreSet r in sets) { grid.Children.Add(GridRow(r)); }
    }

    Grid GridHeader()
    {
        Grid g = Cols();
        g.Children.Add(Cell(Ui.Eyebrow("Taken"), 0));
        g.Children.Add(Cell(Ui.Eyebrow("Kind"), 1));
        g.Children.Add(Cell(Ui.Eyebrow("Size"), 2));
        g.Children.Add(Cell(Ui.Eyebrow("Verified"), 3));
        Border wrap = new Border(); wrap.BorderBrush = Theme.Line; wrap.BorderThickness = new Thickness(0, 0, 0, 1);
        wrap.Padding = new Thickness(4, 0, 4, 6); wrap.Child = g;
        Grid outer = new Grid(); outer.Children.Add(wrap); return outer;
    }

    Border GridRow(RestoreSet r)
    {
        Grid g = Cols();
        g.Margin = new Thickness(4, 6, 4, 6);
        g.Children.Add(Cell(Ui.Text(LocalTime(r.TakenUtc), 12.5, Theme.Ink), 0));
        g.Children.Add(Cell(Ui.Text(r.Kind, 12.5, Theme.Ink2), 1));
        g.Children.Add(Cell(Ui.Text((r.Bytes / 1048576) + " MB", 12.5, Theme.Ink2), 2));
        g.Children.Add(Cell(Ui.Text("✓", 12.5, Theme.Ok, FontWeights.SemiBold), 3));
        Border b = new Border();
        b.CornerRadius = new CornerRadius(5); b.Padding = new Thickness(2, 0, 2, 0);
        b.Cursor = System.Windows.Input.Cursors.Hand;
        b.ToolTip = "Click to view this database's backup log";
        b.Child = g;
        b.MouseEnter += delegate { b.Background = Theme.Sunken; };
        b.MouseLeave += delegate { b.Background = Brushes.Transparent; };
        b.MouseLeftButtonUp += delegate { ShowLog(selected); };
        return b;
    }

    // One click on a recovery-point row: show the selected database's backup log.
    void ShowLog(string db)
    {
        if (db == null || db.Length == 0) { return; }
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

    static Grid Cols()
    {
        Grid g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(2, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        return g;
    }
    static FrameworkElement Cell(FrameworkElement e, int col) { Grid.SetColumn(e, col); return e; }

    static string LocalTime(string utc)
    {
        DateTime d;
        if (DateTime.TryParse(utc, CultureInfo.InvariantCulture,
            DateTimeStyles.RoundtripKind, out d))
        {
            return d.ToLocalTime().ToString("d MMM HH:mm", CultureInfo.CurrentCulture);
        }
        return utc;
    }

    static void Dispatch(Action a)
    {
        Application app = Application.Current;
        if (app != null) { app.Dispatcher.BeginInvoke(DispatcherPriority.Normal, a); }
    }
}
