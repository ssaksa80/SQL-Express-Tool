// The Alerts window - who hears about a problem, and how. It edits the engine's alert
// settings (-ConfigureAlerts), sends a test through every channel (-TestAlert), and turns
// alerting off (-ClearAlerts), each as one elevated job like the setup wizard.
//
// Secrets - the SMTP password and the webhook / heartbeat URLs, which carry their own
// tokens - are never shown and never read back: the app cannot read alert.dat, by design.
// It only knows whether each one is stored. A new value is typed into a password box and
// handed to the elevated job in a file protected with DPAPI CurrentUser (the elevated job
// is the same user, nobody else can open it); the engine seals it and deletes the file.
// The settings themselves travel in a plain JSON file, as the other jobs' do.

using System;
using System.Collections.Generic;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Web.Script.Serialization;

class AlertsWindow
{
    static readonly string[] Kinds = new string[] { "None", "Teams", "Slack", "Generic" };

    Window win;
    TextBox toBox, fromBox, hostBox, portBox, userBox, remindBox, staleBox, pendingBox;
    CheckBox tlsBox, removePwBox, removeHookBox, removeBeatBox;
    PasswordBox pwBox, hookBox, beatBox;
    ComboBox kindBox;
    Border saveBtn, testBtn, offBtn;
    LogPane log;
    Action onDone;
    BackupStatus cur;
    bool busy;

    public void Show(Window owner, Action onDone)
    {
        this.onDone = onDone;
        win = new Window();
        win.Title = "Alerts";
        win.Width = 680; win.Height = 760; win.MinWidth = 540; win.MinHeight = 520;
        win.Owner = owner;
        win.WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen;
        win.Background = Theme.Bg; win.FontFamily = Ui.Face;
        win.Content = BuildRoot();
        if (owner != null) { win.Closed += delegate { try { owner.Activate(); } catch { } }; }
        win.Show();
    }

    // The whole layout without a window - the --check smoke builds it headless.
    public FrameworkElement BuildRoot()
    {
        cur = Engine.ReadStatus();
        ScrollViewer sv = new ScrollViewer(); sv.Padding = new Thickness(22, 20, 22, 18);
        StackPanel sp = new StackPanel();

        sp.Children.Add(Ui.Text("Alerts", 19, Theme.Ink, FontWeights.SemiBold));
        sp.Children.Add(Wrap(Ui.Text("Who hears about it when backups stop protecting the data: once when a problem starts, a reminder while it lasts, and once when it clears. The Windows event log always gets them (events 9100 / 9101 / 9102); add email or a chat webhook so a person does too. Needs administrator.", 12.5, Theme.Ink3), 6, 12));

        if (cur.OpenAlerts.Count > 0)
        {
            Border open = Ui.Card(); open.Margin = new Thickness(0, 0, 0, 14);
            StackPanel op = new StackPanel();
            op.Children.Add(Ui.Eyebrow("Open now"));
            foreach (OpenAlert a in cur.OpenAlerts) { op.Children.Add(Wrap(Ui.Text(AlertLine(a), 12, a.Severity == "critical" ? Theme.Bad : Theme.Warn), 4, 0)); }
            open.Child = op; sp.Children.Add(open);
        }

        sp.Children.Add(Section("Email"));
        toBox = Field(sp, "Send to", cur.AlertEmailTo, "One or more addresses, separated by commas");
        fromBox = Field(sp, "From", cur.AlertEmailFrom, "The sender address your mail server accepts, e.g. sqlbackup@yourdomain");
        hostBox = Field(sp, "SMTP server", cur.AlertSmtpHost, "e.g. smtp.office365.com, or your internal relay");
        portBox = Field(sp, "Port", cur.AlertSmtpPort.ToString(), "587 for STARTTLS (the usual). Port 465 (implicit TLS) is not supported.");
        tlsBox = new CheckBox(); tlsBox.Content = "Use TLS (STARTTLS) - turn off only for an internal relay on port 25";
        Style(tlsBox); tlsBox.IsChecked = cur.AlertSmtpTls; tlsBox.Margin = new Thickness(0, 0, 0, 10);
        sp.Children.Add(tlsBox);
        userBox = Field(sp, "SMTP user", cur.AlertSmtpUser, "Blank for a relay that needs no sign-in");
        pwBox = Secret(sp, "SMTP password", cur.AlertHasSmtpPassword, out removePwBox);

        sp.Children.Add(Section("Chat webhook"));
        sp.Children.Add(Label("Kind"));
        kindBox = new ComboBox(); kindBox.Width = 170; kindBox.HorizontalAlignment = HorizontalAlignment.Left; kindBox.FontSize = 12.5;
        foreach (string k in Kinds) { kindBox.Items.Add(k); }
        int ki = 0;
        for (int i = 0; i < Kinds.Length; i++) { if (string.Equals(Kinds[i], cur.AlertWebhookKind, StringComparison.OrdinalIgnoreCase)) { ki = i; } }
        kindBox.SelectedIndex = ki; kindBox.Margin = new Thickness(0, 4, 0, 2);
        sp.Children.Add(kindBox);
        sp.Children.Add(Hint("Teams: a Power Automate \"Workflows\" webhook (Office 365 connectors are retired). Slack: an incoming webhook. Generic: JSON to any HTTPS endpoint."));
        hookBox = Secret(sp, "Webhook URL", cur.AlertHasWebhook, out removeHookBox);

        sp.Children.Add(Section("Heartbeat"));
        sp.Children.Add(Hint("Optional. A ping after every good backup to healthchecks.io, Uptime Kuma or similar - it alerts you when the pings STOP, which is the only way to hear about a server that is switched off."));
        beatBox = Secret(sp, "Ping URL", cur.AlertHasHeartbeat, out removeBeatBox);

        sp.Children.Add(Section("When"));
        remindBox = Field(sp, "Remind every (hours)", cur.AlertRemindHours.ToString(), "While a problem lasts, how often to say so again");
        staleBox = Field(sp, "Backups overdue after (hours)", cur.AlertStaleHours.ToString(), "0 = work it out from the schedule (two missed passes plus an hour)");
        PendingField(sp);

        StackPanel act = new StackPanel(); act.Orientation = Orientation.Horizontal; act.Margin = new Thickness(0, 14, 0, 0);
        saveBtn = Ui.PrimaryButton("Save", Save); saveBtn.Margin = new Thickness(0, 0, 8, 0); act.Children.Add(saveBtn);
        testBtn = Ui.GhostButton("Send test alert", Test); testBtn.Margin = new Thickness(0, 0, 8, 0); act.Children.Add(testBtn);
        offBtn = Ui.DangerButton("Turn alerts off", TurnOff); offBtn.Margin = new Thickness(0, 0, 8, 0); act.Children.Add(offBtn);
        act.Children.Add(Ui.GhostButton("Close", delegate { if (win != null) { win.Close(); } }));
        sp.Children.Add(act);

        log = new LogPane("Output", false, null, false);
        log.Height = 190; log.Margin = new Thickness(0, 16, 0, 0);
        log.Visibility = Visibility.Collapsed;
        sp.Children.Add(log);

        sv.Content = sp;
        return sv;
    }

    void PendingField(StackPanel sp)
    {
        pendingBox = Field(sp, "Copies waiting on the share for (minutes)", cur.AlertPendingMinutes.ToString(), "How long a backup may sit in local staging, share unreachable, before it is a problem");
    }

    static string AlertLine(OpenAlert a)
    {
        return (a.Severity == "critical" ? "CRITICAL  " : "WARNING  ") + a.Message;
    }

    // ---- actions ----------------------------------------------------------------------

    void Save()
    {
        if (busy) { return; }
        string to = toBox.Text.Trim(), from = fromBox.Text.Trim(), host = hostBox.Text.Trim();
        bool anyEmail = to.Length > 0 || from.Length > 0 || host.Length > 0;
        if (anyEmail && (to.Length == 0 || from.Length == 0 || host.Length == 0)) { Flash("For email, fill in Send to, From and SMTP server - or clear all three."); return; }
        int port = ParseInt(portBox.Text, -1);
        if (port < 1 || port > 65535) { Flash("The port must be a number from 1 to 65535."); return; }
        string kind = Kinds[kindBox.SelectedIndex < 0 ? 0 : kindBox.SelectedIndex];
        if (hookBox.Password.Length > 0 && !hookBox.Password.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) { Flash("The webhook URL must start with https:// - it carries its own access token."); return; }
        if (beatBox.Password.Length > 0 && !beatBox.Password.StartsWith("https://", StringComparison.OrdinalIgnoreCase) && !beatBox.Password.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) { Flash("The ping URL must be an http(s) address."); return; }
        if (kind != "None" && !cur.AlertHasWebhook && hookBox.Password.Length == 0) { Flash("Paste the webhook URL for " + kind + ", or set Kind to None."); return; }

        Dictionary<string, object> d = new Dictionary<string, object>();
        d["AlertEmailTo"] = to; d["AlertEmailFrom"] = from; d["AlertSmtpHost"] = host; d["AlertSmtpUser"] = userBox.Text.Trim();
        d["AlertSmtpPort"] = port;
        d["AlertSmtpTls"] = tlsBox.IsChecked == true;
        d["AlertWebhookKind"] = kind;
        d["AlertRemindHours"] = ParseInt(remindBox.Text, 24);
        d["AlertStaleHours"] = Math.Max(0, ParseInt(staleBox.Text, 0));
        d["AlertPendingMinutes"] = Math.Max(0, ParseInt(pendingBox.Text, 60));

        // Secrets: set what was typed, remove what was ticked, leave the rest alone.
        Dictionary<string, string> secrets = new Dictionary<string, string>();
        SecretChange(secrets, "SmtpPassword", pwBox, removePwBox);
        SecretChange(secrets, "WebhookUrl", hookBox, removeHookBox);
        SecretChange(secrets, "HeartbeatUrl", beatBox, removeBeatBox);
        string secretsFile = null;
        if (secrets.Count > 0)
        {
            try { secretsFile = WriteSecretsFile(secrets); }
            catch (Exception ex) { Flash("Could not prepare the secrets for hand-off: " + ex.Message); return; }
            d["SecretsFile"] = secretsFile;
        }

        string json = Path.Combine(Path.GetTempPath(), "seb-alerts-" + Guid.NewGuid().ToString("N") + ".json");
        try { File.WriteAllText(json, new JavaScriptSerializer().Serialize(d)); }
        catch (Exception ex) { DeleteQuietly(secretsFile); Flash("Could not write the settings: " + ex.Message); return; }

        RunJob("--configure-alerts \"" + json + "\"", "Saving", "Saved", "Save failed", delegate (bool ok)
        {
            DeleteQuietly(json); DeleteQuietly(secretsFile);   // the engine deletes it on read; this covers a job that never ran
            pwBox.Clear(); hookBox.Clear(); beatBox.Clear();
            if (ok && onDone != null) { onDone(); }
        });
    }

    void Test()
    {
        if (busy) { return; }
        RunJob("--test-alert", "Sending a test", "Test sent - check each channel below", "Test: a channel failed (see below)", null);
    }

    void TurnOff()
    {
        if (busy) { return; }
        MessageBoxResult r = MessageBox.Show(win,
            "Turn alerting off?\n\nThis removes the email and webhook settings, the stored password and URLs, and the watchdog task. Backups carry on; nobody is told when they fail. The event log still records problems.",
            "Turn alerts off", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
        if (r != MessageBoxResult.Yes) { return; }
        RunJob("--clear-alerts", "Turning alerts off", "Alerts are off", "Could not turn alerts off", delegate (bool ok) { if (ok && onDone != null) { onDone(); } });
    }

    void RunJob(string flag, string working, string okTitle, string failTitle, Action<bool> after)
    {
        busy = true; Enable(false);
        log.Visibility = Visibility.Visible;
        log.SetTitle(working);
        log.Clear();
        log.Append("Approve the Windows elevation prompt…");
        Elevate.Run(flag, 120,
            delegate (string line) { log.Append(line); },
            delegate (bool ok, string output)
            {
                log.SetTitle(ok ? okTitle : failTitle);
                busy = false; Enable(true);
                if (after != null) { after(ok); }
            });
    }

    // ---- secrets hand-off -------------------------------------------------------------

    static void SecretChange(Dictionary<string, string> secrets, string key, PasswordBox box, CheckBox remove)
    {
        if (remove != null && remove.IsChecked == true) { secrets[key] = ""; return; }
        if (box.Password.Length > 0) { secrets[key] = box.Password; }
    }

    // DPAPI CurrentUser, base64 - the format the engine's Read-SebAlertSecretsFile expects.
    public static string WriteSecretsFile(Dictionary<string, string> secrets)
    {
        byte[] plain = System.Text.Encoding.UTF8.GetBytes(new JavaScriptSerializer().Serialize(secrets));
        try
        {
            byte[] sealedBytes = System.Security.Cryptography.ProtectedData.Protect(plain, null, System.Security.Cryptography.DataProtectionScope.CurrentUser);
            string path = Path.Combine(Path.GetTempPath(), "seb-alert-secrets-" + Guid.NewGuid().ToString("N") + ".bin");
            File.WriteAllText(path, Convert.ToBase64String(sealedBytes));
            return path;
        }
        finally { Array.Clear(plain, 0, plain.Length); }
    }

    public static void DeleteQuietly(string path)
    {
        if (path == null) { return; }
        try { if (File.Exists(path)) { File.Delete(path); } } catch { }
    }

    // ---- widgets ----------------------------------------------------------------------

    void Enable(bool on)
    {
        foreach (Border b in new Border[] { saveBtn, testBtn, offBtn })
        {
            if (b == null) { continue; }
            b.IsHitTestVisible = on; b.Opacity = on ? 1.0 : 0.5;
        }
    }

    TextBox Field(StackPanel sp, string label, string value, string hint)
    {
        sp.Children.Add(Label(label));
        TextBox t = new TextBox(); t.Text = value ?? ""; t.FontSize = 12.5; t.FontFamily = Ui.Face;
        t.Width = 440; t.HorizontalAlignment = HorizontalAlignment.Left;
        sp.Children.Add(t);
        sp.Children.Add(Hint(hint));
        return t;
    }

    // A write-only secret: a password box that starts empty whatever is stored, a line
    // saying whether something is stored, and a tick-box to remove it.
    PasswordBox Secret(StackPanel sp, string label, bool stored, out CheckBox remove)
    {
        sp.Children.Add(Label(label));
        PasswordBox p = new PasswordBox(); p.FontSize = 12.5; p.Width = 440; p.HorizontalAlignment = HorizontalAlignment.Left;
        sp.Children.Add(p);
        StackPanel row = new StackPanel(); row.Orientation = Orientation.Horizontal; row.Margin = new Thickness(0, 2, 0, 10);
        row.Children.Add(Ui.Text(stored ? "Stored (sealed on this server). Leave blank to keep it, or type a new one." : "Not stored.", 11, stored ? Theme.Ok : Theme.Ink3));
        remove = null;
        if (stored)
        {
            remove = new CheckBox(); remove.Content = "Remove"; Style(remove); remove.FontSize = 11; remove.Margin = new Thickness(12, 0, 0, 0);
            row.Children.Add(remove);
        }
        sp.Children.Add(row);
        return p;
    }

    static void Style(CheckBox c) { c.Foreground = Theme.Ink2; c.FontFamily = Ui.Face; c.FontSize = 12.5; }
    static TextBlock Wrap(TextBlock t, double top, double bottom) { t.TextWrapping = TextWrapping.Wrap; t.Margin = new Thickness(0, top, 0, bottom); return t; }
    TextBlock Hint(string s) { return Wrap(Ui.Text(s, 11, Theme.Ink3), 2, 10); }
    TextBlock Label(string s) { TextBlock t = Ui.Text(s, 12, Theme.Ink2, FontWeights.SemiBold); t.Margin = new Thickness(0, 4, 0, 0); return t; }
    TextBlock Section(string s) { TextBlock t = Ui.Text(s, 14, Theme.Ink, FontWeights.SemiBold); t.Margin = new Thickness(0, 12, 0, 2); return t; }
    void Flash(string msg) { log.Visibility = Visibility.Visible; log.SetTitle("Check the form"); log.SetLines(new string[] { msg }); }
    static int ParseInt(string s, int dflt) { int v; return int.TryParse((s ?? "").Trim(), out v) ? v : dflt; }
}
