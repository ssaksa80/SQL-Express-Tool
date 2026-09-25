// The Offsite window - the immutable copy. Every backup on the share is also copied to
// S3-compatible storage with Object Lock, which refuses to delete it until its lock date -
// even for someone holding this server's credentials. That is the copy left standing when
// ransomware has the server and the share.
//
// Each action is one elevated engine job, like the other windows:
//   Save & test   -ConfigureOffsite   proves a locked upload before switching anything on
//   Sync now      -SyncOffsite
//   Turn off      -DisableOffsite     (copies already offsite stay locked until their date)
//
// The access key id and secret are write-only here: the app only knows whether they are
// stored. New values go to the elevated job in the DPAPI-CurrentUser hand-off file.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Web.Script.Serialization;

class OffsiteWindow
{
    Window win;
    BackupStatus cur;
    TextBox endpointBox, regionBox, bucketBox, prefixBox, daysBox, keyIdBox;
    PasswordBox secretBox;
    ComboBox modeBox;
    Border saveBtn, syncBtn, offBtn;
    LogPane log;
    Action onDone;
    bool busy;

    public void Show(Window owner, Action onDone)
    {
        this.onDone = onDone;
        win = new Window();
        win.Title = "Offsite copy";
        win.Width = 700; win.Height = 780; win.MinWidth = 560; win.MinHeight = 520;
        win.Owner = owner;
        win.WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen;
        win.Background = Theme.Bg; win.FontFamily = Ui.Face;
        win.Content = BuildRoot();
        if (owner != null) { win.Closed += delegate { try { owner.Activate(); } catch { } }; }
        win.Show();
    }

    public FrameworkElement BuildRoot()
    {
        cur = Engine.ReadStatus();
        ScrollViewer sv = new ScrollViewer(); sv.Padding = new Thickness(22, 20, 22, 18);
        StackPanel sp = new StackPanel();

        sp.Children.Add(Ui.Text("Immutable offsite copy", 19, Theme.Ink, FontWeights.SemiBold));
        sp.Children.Add(Wrap(Ui.Text("A Windows share cannot be write-once: whatever writes the backups can delete them, and so can ransomware that gets this server. So every backup is also copied to S3-compatible storage with Object Lock (AWS S3, Wasabi, Backblaze B2, ...). The storage itself refuses to delete a copy until its lock date - even with this server's own credentials. Needs administrator.", 12.5, Theme.Ink3), 6, 12));

        sp.Children.Add(StatusCard());

        sp.Children.Add(Section("Storage"));
        endpointBox = Field(sp, "Endpoint", cur.OffsiteEndpoint, "https:// only - e.g. https://s3.eu-west-1.amazonaws.com, https://s3.wasabisys.com, https://s3.us-west-004.backblazeb2.com");
        regionBox = Field(sp, "Region", cur.OffsiteRegion, "e.g. eu-west-1 (for Wasabi/B2, the region in the endpoint)");
        bucketBox = Field(sp, "Bucket", cur.OffsiteBucket, "Must be created WITH Object Lock enabled - it cannot be added to an existing bucket on most stores");
        prefixBox = Field(sp, "Folder prefix", cur.OffsitePrefix, "Copies are stored under <prefix>/<server>/<instance>/...");

        sp.Children.Add(Section("Lock"));
        sp.Children.Add(Label("Mode"));
        modeBox = new ComboBox(); modeBox.Width = 170; modeBox.HorizontalAlignment = HorizontalAlignment.Left; modeBox.FontSize = 12.5;
        modeBox.Items.Add("Compliance"); modeBox.Items.Add("Governance");
        modeBox.SelectedIndex = string.Equals(cur.OffsiteLockMode, "Governance", StringComparison.OrdinalIgnoreCase) ? 1 : 0;
        modeBox.Margin = new Thickness(0, 4, 0, 2);
        sp.Children.Add(modeBox);
        sp.Children.Add(Hint("Compliance: nobody can shorten or remove the lock - not even the bucket owner. Governance: an account with the special bypass right can. For ransomware protection, Compliance."));
        daysBox = Field(sp, "Lock each copy for (days)", cur.OffsiteLockDays.ToString(CultureInfo.InvariantCulture), "Longer than the share keeps anything (7 days by default), so there is a clean copy from before an attack that was noticed late. Storage is billed for the whole period.");

        sp.Children.Add(Section("Access key"));
        sp.Children.Add(Hint("A key that can PUT objects and set retention - and cannot delete. With such a key a fully compromised server can add copies but never remove one. The README has the exact policy."));
        keyIdBox = Field(sp, "Access key id", "", cur.OffsiteHasCredentials ? "Stored (sealed on this server). Leave both blank to keep it." : "Not stored yet.");
        sp.Children.Add(Label("Secret access key"));
        secretBox = new PasswordBox(); secretBox.FontSize = 12.5; secretBox.Width = 440; secretBox.HorizontalAlignment = HorizontalAlignment.Left; secretBox.Margin = new Thickness(0, 4, 0, 10);
        sp.Children.Add(secretBox);

        StackPanel act = new StackPanel(); act.Orientation = Orientation.Horizontal; act.Margin = new Thickness(0, 14, 0, 0);
        saveBtn = Ui.PrimaryButton(cur.OffsiteEnabled ? "Save & test" : "Test & turn on", Save); saveBtn.Margin = new Thickness(0, 0, 8, 0); act.Children.Add(saveBtn);
        if (cur.OffsiteEnabled)
        {
            syncBtn = Ui.GhostButton("Sync now", Sync); syncBtn.Margin = new Thickness(0, 0, 8, 0); act.Children.Add(syncBtn);
            offBtn = Ui.DangerButton("Turn off", TurnOff); offBtn.Margin = new Thickness(0, 0, 8, 0); act.Children.Add(offBtn);
        }
        act.Children.Add(Ui.GhostButton("Close", delegate { if (win != null) { win.Close(); } }));
        sp.Children.Add(act);

        log = new LogPane("Output", false, null, false);
        log.Height = 190; log.Margin = new Thickness(0, 14, 0, 0);
        log.Visibility = Visibility.Collapsed;
        sp.Children.Add(log);

        sv.Content = sp;
        return sv;
    }

    Border StatusCard()
    {
        Border card = Ui.Card(); card.Margin = new Thickness(0, 0, 0, 12);
        StackPanel st = new StackPanel();
        if (!cur.OffsiteEnabled)
        {
            st.Children.Add(Wrap(Ui.Text("Off - the only copies are on the share.", 13, Theme.Warn, FontWeights.SemiBold), 0, 0));
        }
        else
        {
            bool behind = cur.OffsiteBacklog > 0 && cur.OffsiteOldestPendingUtc.Length > 0 && HoursSince(cur.OffsiteOldestPendingUtc) >= 24;
            bool failed = cur.OffsiteLastResult == "failed";
            string head = !cur.OffsiteSynced ? "On - waiting for the first sync"
                : (behind ? "BEHIND - backups are waiting to go offsite" : (failed ? "On - the last sync had a problem" : "On - backups are offsite and locked"));
            st.Children.Add(Wrap(Ui.Text(head, 13, behind ? Theme.Bad : (failed ? Theme.Warn : Theme.Ok), FontWeights.SemiBold), 0, 4));
            st.Children.Add(Wrap(Ui.Text(cur.OffsiteBucket + " at " + cur.OffsiteEndpoint + " - " + cur.OffsiteLockMode + " lock, " + cur.OffsiteLockDays + " days", 12, Theme.Ink2), 0, 2));
            if (cur.OffsiteSynced)
            {
                st.Children.Add(Wrap(Ui.Text("Last sync " + When(cur.OffsiteLastRunUtc) + ": " + cur.OffsiteObjects + " cop" + (cur.OffsiteObjects == 1 ? "y" : "ies") + " offsite, " + cur.OffsiteBacklog + " waiting"
                    + (cur.OffsiteBacklog > 0 && cur.OffsiteOldestPendingUtc.Length > 0 ? " (oldest " + (int)HoursSince(cur.OffsiteOldestPendingUtc) + "h)" : ""), 12, Theme.Ink2), 0, 2));
                if (cur.OffsiteLastError.Length > 0) { st.Children.Add(Wrap(Ui.Text(cur.OffsiteLastError, 12, Theme.Bad), 2, 0)); }
            }
        }
        card.Child = st;
        return card;
    }

    // ---- actions ----------------------------------------------------------------------

    void Save()
    {
        if (busy) { return; }
        string endpoint = endpointBox.Text.Trim(), bucket = bucketBox.Text.Trim();
        if (!endpoint.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) { Flash("The endpoint must be an https:// address."); return; }
        if (bucket.Length == 0) { Flash("Enter the bucket - one created with Object Lock enabled."); return; }
        int days;
        if (!int.TryParse(daysBox.Text.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out days) || days < 1 || days > 3650) { Flash("Lock days must be a number from 1 to 3650."); return; }
        string keyId = keyIdBox.Text.Trim(), secret = secretBox.Password;
        bool newKey = keyId.Length > 0 || secret.Length > 0;
        if (newKey && (keyId.Length == 0 || secret.Length == 0)) { Flash("Enter both the access key id and the secret - or neither, to keep the stored ones."); return; }
        if (!newKey && !cur.OffsiteHasCredentials) { Flash("Enter the access key id and secret access key."); return; }
        if (modeBox.SelectedIndex == 1)
        {
            MessageBoxResult g = MessageBox.Show(win, "Governance mode can be bypassed by an account with the bypass-retention right. Against ransomware that steals an admin's cloud credentials, Compliance is the one that holds.\n\nUse Governance anyway?",
                "Governance lock", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
            if (g != MessageBoxResult.Yes) { return; }
        }

        Dictionary<string, object> d = new Dictionary<string, object>();
        d["OffsiteEndpoint"] = endpoint; d["OffsiteRegion"] = regionBox.Text.Trim(); d["OffsiteBucket"] = bucket;
        d["OffsitePrefix"] = prefixBox.Text.Trim(); d["OffsiteLockDays"] = days;
        d["OffsiteLockMode"] = modeBox.SelectedIndex == 1 ? "Governance" : "Compliance";
        string secretsFile = null;
        if (newKey)
        {
            Dictionary<string, string> s = new Dictionary<string, string>();
            s["AccessKeyId"] = keyId; s["SecretAccessKey"] = secret;
            try { secretsFile = AlertsWindow.WriteSecretsFile(s); }
            catch (Exception ex) { Flash("Could not prepare the key for hand-off: " + ex.Message); return; }
            d["SecretsFile"] = secretsFile;
        }
        string json = Path.Combine(Path.GetTempPath(), "seb-offsite-" + Guid.NewGuid().ToString("N") + ".json");
        try { File.WriteAllText(json, new JavaScriptSerializer().Serialize(d)); }
        catch (Exception ex) { AlertsWindow.DeleteQuietly(secretsFile); Flash("Could not write the settings: " + ex.Message); return; }
        RunJob("--configure-offsite \"" + json + "\"", "Testing a locked upload, then saving", "Offsite copy is on - a locked test upload succeeded", "Not switched on - see below",
            delegate(bool ok) { AlertsWindow.DeleteQuietly(json); AlertsWindow.DeleteQuietly(secretsFile); secretBox.Clear(); if (ok) { keyIdBox.Clear(); } if (ok && onDone != null) { onDone(); } });
    }

    void Sync()
    {
        if (busy) { return; }
        // A first sync of a whole share can take a while; the job prints a line per upload.
        RunJob("--sync-offsite", "Syncing", "Sync finished", "Sync had problems - see below", delegate(bool ok) { if (onDone != null) { onDone(); } });
    }

    void TurnOff()
    {
        if (busy) { return; }
        MessageBoxResult r = MessageBox.Show(win,
            "Stop copying backups offsite?\n\nCopies already offsite stay locked until their dates - nothing is deleted. New backups will exist only on the share.",
            "Turn off the offsite copy", MessageBoxButton.YesNo, MessageBoxImage.Warning, MessageBoxResult.No);
        if (r != MessageBoxResult.Yes) { return; }
        RunJob("--disable-offsite", "Turning off", "Offsite copy is off", "Could not turn it off", delegate(bool ok) { if (ok && onDone != null) { onDone(); } });
    }

    void RunJob(string flag, string working, string okTitle, string failTitle, Action<bool> after)
    {
        busy = true; Enable(false);
        log.Visibility = Visibility.Visible;
        log.SetTitle(working);
        log.Clear();
        log.Append("Approve the Windows elevation prompt…");
        // Uploads print a line each; half an hour of silence means something is stuck.
        Elevate.Run(flag, 1800,
            delegate(string line) { log.Append(line); },
            delegate(bool ok, string output)
            {
                log.SetTitle(ok ? okTitle : failTitle);
                busy = false; Enable(true);
                if (after != null) { after(ok); }
            });
    }

    // ---- widgets ----------------------------------------------------------------------

    static double HoursSince(string utc)
    {
        DateTime d;
        if (!DateTime.TryParse(utc, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out d)) { return 0; }
        return (DateTime.UtcNow - d.ToUniversalTime()).TotalHours;
    }
    static string When(string utc)
    {
        DateTime d;
        if (!DateTime.TryParse(utc, CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out d)) { return "never"; }
        return d.ToLocalTime().ToString("d MMM HH:mm", CultureInfo.CurrentCulture);
    }

    void Enable(bool on)
    {
        foreach (Border b in new Border[] { saveBtn, syncBtn, offBtn })
        {
            if (b == null) { continue; }
            b.IsHitTestVisible = on; b.Opacity = on ? 1.0 : 0.5;
        }
    }

    TextBox Field(StackPanel sp, string label, string value, string hint)
    {
        sp.Children.Add(Label(label));
        TextBox t = new TextBox(); t.Text = value ?? ""; t.FontSize = 12.5; t.FontFamily = Ui.Face;
        t.Width = 440; t.HorizontalAlignment = HorizontalAlignment.Left; t.Margin = new Thickness(0, 4, 0, 0);
        sp.Children.Add(t);
        sp.Children.Add(Hint(hint));
        return t;
    }
    static TextBlock Wrap(TextBlock t, double top, double bottom) { t.TextWrapping = TextWrapping.Wrap; t.Margin = new Thickness(0, top, 0, bottom); return t; }
    TextBlock Hint(string s) { return Wrap(Ui.Text(s, 11.5, Theme.Ink3), 2, 8); }
    TextBlock Label(string s) { TextBlock t = Ui.Text(s, 12, Theme.Ink2, FontWeights.SemiBold); t.Margin = new Thickness(0, 4, 0, 0); return t; }
    TextBlock Section(string s) { TextBlock t = Ui.Text(s, 14, Theme.Ink, FontWeights.SemiBold); t.Margin = new Thickness(0, 14, 0, 2); return t; }
    void Flash(string msg) { log.Visibility = Visibility.Visible; log.SetTitle("Check the form"); log.SetLines(new string[] { msg }); }
}
