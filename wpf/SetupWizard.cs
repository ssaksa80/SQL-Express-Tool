// The "Set up backups" wizard - the flagship gap the app was missing. It configures the
// instance/share/staging/retention and registers the SYSTEM scheduled task, all from the
// app instead of the command line. It drives engine -Setup (Windows authentication, so
// the app never touches a SQL password) then -Reschedule to register the task, both run
// as one elevated job. -Reschedule creates the task if none exists and re-registers it if
// one does, so this same window serves a first setup and a later reconfigure.
//
// On a host that is already set up, every field starts from what is configured (read
// from public.json, no elevation), so a reconfigure changes only what the operator
// touches. It used to open on defaults, and an unchanged "Set up" quietly reset the
// retention - and, before the engine carried them over, turned point-in-time off.

using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;

class SetupWizard
{
    static readonly int[] Hrs = new int[] { 1, 2, 3, 4, 6, 8, 12, 24 };
    static readonly int[] LogMins = new int[] { 5, 10, 15, 30, 60 };
    static readonly int[] FullHrs = new int[] { 12, 24, 48, 72, 168 };

    Window win;
    TextBox shareBox, stagingBox, hourlyBox, dailyBox;
    ComboBox intervalBox, instanceBox, logIntervalBox, fullEveryBox;
    CheckBox pitrBox, compressBox, restoreTestBox;
    TextBox restoreTimeBox;
    StackPanel pitrOptions;
    Border applyBtn;
    LogPane log;
    Action onDone;

    public void Show(Window owner, Action onDone)
    {
        this.onDone = onDone;
        win = new Window();
        win.Title = "Set up backups";
        win.Width = 640; win.Height = 660; win.MinWidth = 520; win.MinHeight = 520;
        win.Owner = owner;
        win.WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen;
        win.Background = Theme.Bg; win.FontFamily = Ui.Face;

        ScrollViewer sv = new ScrollViewer(); sv.Padding = new Thickness(22, 20, 22, 18);
        StackPanel sp = new StackPanel();

        sp.Children.Add(Ui.Text("Set up backups", 19, Theme.Ink, FontWeights.SemiBold));
        TextBlock intro = Ui.Text("Configure the instance, share and schedule, then register the backup as a Windows scheduled task that runs as SYSTEM. Uses Windows authentication (the SQL service account), so no SQL password is entered here. Needs administrator.", 12.5, Theme.Ink3);
        intro.TextWrapping = TextWrapping.Wrap; intro.Margin = new Thickness(0, 6, 0, 16);
        sp.Children.Add(intro);

        BackupStatus cur = Engine.ReadStatus();
        bool configured = cur.Found && cur.SharePath.Length > 0;
        if (configured)
        {
            TextBlock note = Ui.Text("Already set up on this host - the fields show the current settings. Change what you need and apply.", 12, Theme.Ink2);
            note.TextWrapping = TextWrapping.Wrap; note.Margin = new Thickness(0, -6, 0, 14);
            sp.Children.Add(note);
            if (!cur.UseWindowsAuth)
            {
                // The app only ever configures Windows authentication (it never handles a SQL
                // password), so applying here changes how this host signs in. Say so first.
                TextBlock auth = Ui.Text("This host signs in to SQL Server with a SQL login. Applying setup here switches it to Windows authentication (the SQL service account's own identity) and the stored SQL credential stops being used. To keep the SQL login, re-run -Setup from PowerShell instead.", 12, Theme.Bad);
                auth.TextWrapping = TextWrapping.Wrap; auth.Margin = new Thickness(0, -6, 0, 14);
                sp.Children.Add(auth);
            }
        }

        instanceBox = InstanceField(sp);
        if (configured && cur.Instance.Length > 0) { instanceBox.Text = cur.Instance; }
        shareBox = Field(sp, "Backup share (UNC)", configured ? cur.SharePath : "","Where backups are written, e.g. \\\\fileserver\\sqlbackups");
        stagingBox = Field(sp, "Staging folder", (configured && cur.StagingPath.Length > 0) ? cur.StagingPath : "C:\\SqlBackupStaging","Local scratch folder SQL writes to before copying to the share");

        sp.Children.Add(Label("Interval"));
        intervalBox = Combo(Hrs, "every {0} hour", "every {0} hours", configured ? cur.IntervalHours : 6, 4);
        sp.Children.Add(intervalBox);

        hourlyBox = Field(sp, "Keep hourly (copies)", configured ? cur.HourlyKeep.ToString() : "3", "How many hourly backups to keep");
        dailyBox = Field(sp, "Keep daily (days)", configured ? cur.DailyKeepDays.ToString() : "7", "How many days of daily backups to keep");

        sp.Children.Add(Section("Protection"));
        pitrBox = Check("Point-in-time recovery",
            "Puts user databases in FULL recovery and backs their transaction log up on its own schedule, so a restore can land on any minute - not only on the last backup. master and msdb stay full-only.");
        pitrBox.IsChecked = configured && cur.RecoveryMode == "Full";
        sp.Children.Add(pitrBox);
        pitrOptions = new StackPanel(); pitrOptions.Margin = new Thickness(26, 0, 0, 4);
        pitrOptions.Children.Add(Label("Back up the log"));
        logIntervalBox = Combo(LogMins, "every {0} minute", "every {0} minutes", configured ? cur.LogIntervalMinutes : 15, 2);
        pitrOptions.Children.Add(logIntervalBox);
        pitrOptions.Children.Add(Label("Take a full backup"));
        fullEveryBox = Combo(FullHrs, "every {0} hour", "every {0} hours", configured ? cur.FullEveryHours : 24, 1);
        pitrOptions.Children.Add(fullEveryBox);
        TextBlock ph = Ui.Text("Between fulls, each backup pass takes a differential. At most one log interval of work can be lost.", 11, Theme.Ink3);
        ph.TextWrapping = TextWrapping.Wrap; ph.Margin = new Thickness(0, 0, 0, 8);
        pitrOptions.Children.Add(ph);
        sp.Children.Add(pitrOptions);
        pitrBox.Checked += delegate { pitrOptions.Visibility = Visibility.Visible; };
        pitrBox.Unchecked += delegate { pitrOptions.Visibility = Visibility.Collapsed; };
        pitrOptions.Visibility = pitrBox.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;

        compressBox = Check("Compress backups",
            "Zips every backup on the share (SQL Express has no built-in backup compression). Restores unzip automatically. Usually much smaller on disk, at some CPU cost during the backup.");
        compressBox.IsChecked = configured && cur.CompressBackups;
        sp.Children.Add(compressBox);

        restoreTestBox = Check("Test restores daily",
            "Each day, restores the newest backup of one database (the one tested longest ago) to a scratch copy, runs DBCC CHECKDB on it, and drops it. A failure is an alert. Needs free space on the staging drive about the size of your largest database.");
        // Ticked for a first setup - a backup nobody has restored is a hope - and as
        // configured for a reconfigure.
        restoreTestBox.IsChecked = configured ? cur.RestoreTesting : true;
        sp.Children.Add(restoreTestBox);
        StackPanel rtRow = new StackPanel(); rtRow.Orientation = Orientation.Horizontal; rtRow.Margin = new Thickness(26, 0, 0, 8);
        rtRow.Children.Add(Ui.Text("at", 12, Theme.Ink2));
        restoreTimeBox = new TextBox(); restoreTimeBox.Width = 60; restoreTimeBox.FontSize = 12.5; restoreTimeBox.Margin = new Thickness(8, 0, 8, 0);
        restoreTimeBox.Text = configured ? cur.RestoreTestTime : "03:30";
        rtRow.Children.Add(restoreTimeBox);
        rtRow.Children.Add(Ui.Text("(24-hour, a quiet time)", 11, Theme.Ink3));
        sp.Children.Add(rtRow);

        StackPanel act = new StackPanel(); act.Orientation = Orientation.Horizontal; act.Margin = new Thickness(0, 12, 0, 0);
        applyBtn = Ui.PrimaryButton("Set up & schedule", Apply);
        applyBtn.Margin = new Thickness(0, 0, 8, 0);
        act.Children.Add(applyBtn);
        act.Children.Add(Ui.GhostButton("Cancel", delegate { win.Close(); }));
        sp.Children.Add(act);

        log = new LogPane("Output", false, null, false);
        log.Height = 200; log.Margin = new Thickness(0, 16, 0, 0);
        log.Visibility = Visibility.Collapsed;
        sp.Children.Add(log);

        sv.Content = sp; win.Content = sv;
        // When this window closes, hand focus back to the owner so the app stays in front
        // instead of dropping behind whatever is next in the Z-order.
        if (owner != null) { win.Closed += delegate { try { owner.Activate(); } catch { } }; }
        win.Show();
    }

    // Auto-discovered SQL instance picker: an editable combo pre-filled from the registry.
    ComboBox InstanceField(StackPanel sp)
    {
        sp.Children.Add(Label("SQL instance"));
        ComboBox c = new ComboBox(); c.IsEditable = true; c.FontSize = 12.5; c.FontFamily = Ui.Face;
        c.Width = 440; c.HorizontalAlignment = HorizontalAlignment.Left;
        System.Collections.Generic.List<string> inst = Engine.DiscoverInstances();
        foreach (string i in inst) { c.Items.Add(i); }
        string hint;
        if (inst.Count == 1) { c.Text = inst[0]; hint = "Discovered: " + inst[0] + " (auto-filled). Blank = the only instance on this host."; }
        else if (inst.Count > 1) { hint = "Discovered " + inst.Count + ": " + string.Join(", ", inst.ToArray()) + " - pick one from the list."; }
        else { hint = "No instance auto-discovered - type it, e.g. SQLEXPRESS. Blank = the only instance on this host."; }
        sp.Children.Add(c);
        TextBlock h = Ui.Text(hint, 11, Theme.Ink3); h.TextWrapping = TextWrapping.Wrap; h.Margin = new Thickness(0, 2, 0, 10);
        sp.Children.Add(h);
        return c;
    }

    void Apply()
    {
        string share = shareBox.Text.Trim();
        if (share.Length == 0) { Flash("A backup share (UNC path) is required."); return; }
        int interval = ValueOf(intervalBox, 6);

        System.Collections.Generic.Dictionary<string, object> d = new System.Collections.Generic.Dictionary<string, object>();
        d["Instance"] = instanceBox.Text.Trim();
        d["SharePath"] = share;
        d["StagingPath"] = stagingBox.Text.Trim();
        d["IntervalHours"] = interval;
        d["HourlyKeep"] = ParseInt(hourlyBox.Text, 3);
        d["DailyKeepDays"] = ParseInt(dailyBox.Text, 7);
        bool pitr = pitrBox.IsChecked == true;
        d["RecoveryMode"] = pitr ? "Full" : "Simple";
        if (pitr)
        {
            d["LogIntervalMinutes"] = ValueOf(logIntervalBox, 15);
            d["FullEveryHours"] = ValueOf(fullEveryBox, 24);
        }
        d["CompressBackups"] = compressBox.IsChecked == true;
        d["RestoreTesting"] = restoreTestBox.IsChecked == true;
        string rt = restoreTimeBox.Text.Trim();
        if (rt.Length == 4 && rt[1] == ':') { rt = "0" + rt; }   // 3:30 -> 03:30
        if (restoreTestBox.IsChecked == true && !System.Text.RegularExpressions.Regex.IsMatch(rt, "^([01][0-9]|2[0-3]):[0-5][0-9]$"))
        {
            Flash("The restore-test time must be HH:mm on a 24-hour clock, e.g. 03:30.");
            return;
        }
        d["RestoreTestTime"] = rt;
        string json = new System.Web.Script.Serialization.JavaScriptSerializer().Serialize(d);
        string tmp = Path.Combine(Path.GetTempPath(), "seb-setup-" + Guid.NewGuid().ToString("N") + ".json");
        try { File.WriteAllText(tmp, json); }
        catch (Exception ex) { Flash("Could not write settings: " + ex.Message); return; }

        applyBtn.IsHitTestVisible = false; applyBtn.Opacity = 0.5;
        log.Visibility = Visibility.Visible;
        log.SetTitle("Working");
        log.Clear();
        log.Append("Approve the Windows elevation prompt to configure and schedule…");

        Elevate.Run("--apply-setup \"" + tmp + "\"", 180,
            delegate(string line) { log.Append(line); },
            delegate(bool ok, string output)
            {
                try { File.Delete(tmp); } catch { }
                log.SetTitle(ok ? "Setup complete" : "Setup failed");
                applyBtn.IsHitTestVisible = true; applyBtn.Opacity = 1.0;
                if (ok && onDone != null) { onDone(); }
            });
    }

    TextBox Field(StackPanel sp, string label, string value, string hint)
    {
        sp.Children.Add(Label(label));
        TextBox t = new TextBox(); t.Text = value; t.FontSize = 12.5; t.FontFamily = Ui.Face;
        t.Width = 440; t.HorizontalAlignment = HorizontalAlignment.Left;
        sp.Children.Add(t);
        TextBlock h = Ui.Text(hint, 11, Theme.Ink3); h.TextWrapping = TextWrapping.Wrap; h.Margin = new Thickness(0, 2, 0, 10);
        sp.Children.Add(h);
        return t;
    }
    // A fixed-choice picker preselected on the configured value. A value from the command
    // line that is not one of the choices is added, so an unchanged apply keeps it instead
    // of snapping it to a default. The chosen value is read back through ValueOf.
    static ComboBox Combo(int[] values, string one, string many, int current, int dfltIndex)
    {
        ComboBox c = new ComboBox(); c.Width = 170; c.HorizontalAlignment = HorizontalAlignment.Left; c.FontSize = 12.5;
        c.Margin = new Thickness(0, 4, 0, 12);
        foreach (int v in values) { c.Items.Add(new ComboBoxItem { Content = string.Format(v == 1 ? one : many, v), Tag = v }); }
        int sel = Array.IndexOf(values, current);
        if (sel < 0 && current > 0) { c.Items.Add(new ComboBoxItem { Content = string.Format(current == 1 ? one : many, current) + " (current)", Tag = current }); sel = c.Items.Count - 1; }
        c.SelectedIndex = sel >= 0 ? sel : dfltIndex;
        return c;
    }
    static int ValueOf(ComboBox c, int dflt)
    {
        ComboBoxItem it = c.SelectedItem as ComboBoxItem;
        return (it != null && it.Tag is int) ? (int)it.Tag : dflt;
    }
    CheckBox Check(string label, string hint)
    {
        CheckBox cb = new CheckBox(); cb.Margin = new Thickness(0, 6, 0, 8);
        cb.VerticalContentAlignment = VerticalAlignment.Top;
        StackPanel p = new StackPanel();
        p.Children.Add(Ui.Text(label, 12.5, Theme.Ink, FontWeights.SemiBold));
        TextBlock h = Ui.Text(hint, 11, Theme.Ink3); h.TextWrapping = TextWrapping.Wrap; h.MaxWidth = 470; h.Margin = new Thickness(0, 2, 0, 0);
        p.Children.Add(h);
        cb.Content = p;
        return cb;
    }
    TextBlock Section(string s) { TextBlock t = Ui.Text(s, 14, Theme.Ink, FontWeights.SemiBold); t.Margin = new Thickness(0, 10, 0, 2); return t; }
    TextBlock Label(string s) { TextBlock t = Ui.Text(s, 12, Theme.Ink2, FontWeights.SemiBold); t.Margin = new Thickness(0, 4, 0, 0); return t; }
    void Flash(string msg) { log.Visibility = Visibility.Visible; log.SetTitle("Check the form"); log.SetLines(new string[] { msg }); }
    static int ParseInt(string s, int dflt) { int v; return (int.TryParse((s == null ? "" : s).Trim(), out v) && v > 0) ? v : dflt; }
    static string[] SplitLines(string s) { return (s == null ? "" : s).Replace("\r\n", "\n").Split('\n'); }
}
