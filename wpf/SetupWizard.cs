// The "Set up backups" wizard - the flagship gap the app was missing. It configures the
// instance/share/staging/retention and registers the SYSTEM scheduled task, all from the
// app instead of the command line. It drives engine -Setup (Windows authentication, so
// the app never touches a SQL password) then -Reschedule to register the task, both run
// as one elevated job. -Reschedule creates the task if none exists and re-registers it if
// one does, so this same window serves a first setup and a later reconfigure.

using System;
using System.IO;
using System.Windows;
using System.Windows.Controls;

class SetupWizard
{
    static readonly int[] Hrs = new int[] { 1, 2, 3, 4, 6, 8, 12, 24 };

    Window win;
    TextBox instanceBox, shareBox, stagingBox, hourlyBox, dailyBox;
    ComboBox intervalBox;
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

        instanceBox = Field(sp, "SQL instance", "", "Blank = the only instance on this host; otherwise e.g. SQLEXPRESS");
        shareBox = Field(sp, "Backup share (UNC)", "", "Where backups are written, e.g. \\\\fileserver\\sqlbackups");
        stagingBox = Field(sp, "Staging folder", "C:\\SqlBackupStaging", "Local scratch folder SQL writes to before copying to the share");

        sp.Children.Add(Label("Interval"));
        intervalBox = new ComboBox(); intervalBox.Width = 170; intervalBox.HorizontalAlignment = HorizontalAlignment.Left; intervalBox.FontSize = 12.5;
        foreach (int h in Hrs) { intervalBox.Items.Add("every " + h + " hour" + (h == 1 ? "" : "s")); }
        intervalBox.SelectedIndex = 4; // 6h
        intervalBox.Margin = new Thickness(0, 4, 0, 12);
        sp.Children.Add(intervalBox);

        hourlyBox = Field(sp, "Keep hourly (copies)", "3", "How many hourly backups to keep");
        dailyBox = Field(sp, "Keep daily (days)", "7", "How many days of daily backups to keep");

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
        win.Show();
    }

    void Apply()
    {
        string share = shareBox.Text.Trim();
        if (share.Length == 0) { Flash("A backup share (UNC path) is required."); return; }
        int interval = Hrs[intervalBox.SelectedIndex < 0 ? 4 : intervalBox.SelectedIndex];

        System.Collections.Generic.Dictionary<string, object> d = new System.Collections.Generic.Dictionary<string, object>();
        d["Instance"] = instanceBox.Text.Trim();
        d["SharePath"] = share;
        d["StagingPath"] = stagingBox.Text.Trim();
        d["IntervalHours"] = interval;
        d["HourlyKeep"] = ParseInt(hourlyBox.Text, 3);
        d["DailyKeepDays"] = ParseInt(dailyBox.Text, 7);
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
    TextBlock Label(string s) { TextBlock t = Ui.Text(s, 12, Theme.Ink2, FontWeights.SemiBold); t.Margin = new Thickness(0, 4, 0, 0); return t; }
    void Flash(string msg) { log.Visibility = Visibility.Visible; log.SetTitle("Check the form"); log.SetLines(new string[] { msg }); }
    static int ParseInt(string s, int dflt) { int v; return (int.TryParse((s == null ? "" : s).Trim(), out v) && v > 0) ? v : dflt; }
    static string[] SplitLines(string s) { return (s == null ? "" : s).Replace("\r\n", "\n").Split('\n'); }
}
