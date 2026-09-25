// The Encryption window - backups on the share become unreadable to anyone without the key.
// It drives the engine's key jobs, each as one elevated step:
//   set up (or rotate) a key   -SetupEncryption   passphrase in, recovery key out ONCE
//   turn on/off for new backups -Reschedule -EncryptBackups On|Off
//   import a key                -ImportEncryptionKey   (a rebuilt server: passphrase or recovery key)
//
// The passphrase / recovery key typed here go to the elevated job in a DPAPI-CurrentUser file
// (the same hand-off as the alert secrets) and are never on a command line or in a log. The
// recovery key comes back once, is shown in its own panel rather than the scrolling log, and
// the window will not close until the operator confirms it has been stored - it is the one
// thing that makes a lost server's backups readable if the passphrase is also gone.

using System;
using System.Collections.Generic;
using System.IO;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Controls;
using System.Web.Script.Serialization;

class EncryptionWindow
{
    static readonly Regex RecoveryKeyLine = new Regex("^\\s*([0-9A-F]{8}-){7}[0-9A-F]{8}\\s*$");

    Window win;
    BackupStatus cur;
    PasswordBox pass1, pass2, importBox;
    Border setupBtn, toggleBtn, importBtn;
    Border revealCard;
    TextBlock revealText;
    CheckBox storedBox;
    LogPane log;
    Action onDone;
    bool busy;
    bool keyShownUnconfirmed;

    public void Show(Window owner, Action onDone)
    {
        this.onDone = onDone;
        win = new Window();
        win.Title = "Encryption";
        win.Width = 680; win.Height = 760; win.MinWidth = 540; win.MinHeight = 520;
        win.Owner = owner;
        win.WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen;
        win.Background = Theme.Bg; win.FontFamily = Ui.Face;
        win.Content = BuildRoot();
        win.Closing += delegate(object s, System.ComponentModel.CancelEventArgs e)
        {
            if (keyShownUnconfirmed)
            {
                MessageBox.Show(win, "Store the recovery key first, then tick the box to confirm.\n\nIt is shown this once. If this server is lost and the passphrase is forgotten, it is the only way to read these backups.",
                    "Recovery key not confirmed", MessageBoxButton.OK, MessageBoxImage.Warning);
                e.Cancel = true;
            }
        };
        if (owner != null) { win.Closed += delegate { try { owner.Activate(); } catch { } }; }
        win.Show();
    }

    public FrameworkElement BuildRoot()
    {
        cur = Engine.ReadStatus();
        bool hasKey = cur.ActiveKeyId.Length > 0;
        ScrollViewer sv = new ScrollViewer(); sv.Padding = new Thickness(22, 20, 22, 18);
        StackPanel sp = new StackPanel();

        sp.Children.Add(Ui.Text("Encryption", 19, Theme.Ink, FontWeights.SemiBold));
        sp.Children.Add(Wrap(Ui.Text("SQL Server Express cannot encrypt a backup, so the tool does: every new backup is encrypted (AES-256, tamper-checked) before it goes to the share. Anyone who can read the share sees only ciphertext. Needs administrator.", 12.5, Theme.Ink3), 6, 12));

        Border status = Ui.Card(); status.Margin = new Thickness(0, 0, 0, 12);
        StackPanel st = new StackPanel();
        string line;
        System.Windows.Media.SolidColorBrush color;
        if (cur.EncryptBackups && hasKey) { line = "On - new backups are encrypted with key " + cur.ActiveKeyId + "."; color = Theme.Ok; }
        else if (hasKey) { line = "Off for new backups. Key " + cur.ActiveKeyId + " is kept, so encrypted backups still restore."; color = Theme.Warn; }
        else { line = "Off - backups on the share are readable by anyone who can open them."; color = Theme.Ink2; }
        st.Children.Add(Wrap(Ui.Text(line, 13, color, FontWeights.SemiBold), 0, 0));
        status.Child = st; sp.Children.Add(status);

        // The one-time recovery key, hidden until a setup returns it.
        revealCard = Ui.Card(); revealCard.Margin = new Thickness(0, 0, 0, 14);
        revealCard.BorderBrush = Theme.Bad; revealCard.BorderThickness = new Thickness(2);
        StackPanel rp = new StackPanel();
        rp.Children.Add(Ui.Text("Your recovery key - store it now", 15, Theme.Bad, FontWeights.SemiBold));
        rp.Children.Add(Wrap(Ui.Text("Shown this once and stored nowhere. With it - or the passphrase - a rebuilt server can read these backups. Without either, nobody can. Put it in a password manager or print it and lock it away; not on this server.", 12, Theme.Ink2), 4, 10));
        revealText = Ui.Text("", 17, Theme.Ink, FontWeights.SemiBold);
        revealText.FontFamily = new System.Windows.Media.FontFamily("Consolas");
        revealText.TextWrapping = TextWrapping.Wrap;
        rp.Children.Add(revealText);
        StackPanel rrow = new StackPanel(); rrow.Orientation = Orientation.Horizontal; rrow.Margin = new Thickness(0, 10, 0, 0);
        Border copy = Ui.GhostButton("Copy", delegate { try { Clipboard.SetText(revealText.Text); } catch { } });
        copy.Margin = new Thickness(0, 0, 12, 0); rrow.Children.Add(copy);
        storedBox = new CheckBox(); storedBox.Content = "I have stored the recovery key somewhere safe, away from this server";
        storedBox.Foreground = Theme.Ink; storedBox.FontFamily = Ui.Face; storedBox.FontSize = 12.5; storedBox.VerticalAlignment = VerticalAlignment.Center;
        storedBox.Checked += delegate { keyShownUnconfirmed = false; };
        storedBox.Unchecked += delegate { if (revealText.Text.Length > 0) { keyShownUnconfirmed = true; } };
        rrow.Children.Add(storedBox);
        rp.Children.Add(rrow);
        revealCard.Child = rp;
        revealCard.Visibility = Visibility.Collapsed;
        sp.Children.Add(revealCard);

        sp.Children.Add(Section(hasKey ? "Make a new key" : "Set up encryption"));
        sp.Children.Add(Hint(hasKey
            ? "Rotating makes a new key for new backups; the current one stays so older backups still restore. Choose a passphrase for the new key."
            : "Choose a passphrase (12 or more characters). It protects the copy of the key kept on the share, so a rebuilt server can get the backups back. You will also get a one-time recovery key."));
        sp.Children.Add(Label("Passphrase"));
        pass1 = Pw(sp);
        sp.Children.Add(Label("Passphrase again"));
        pass2 = Pw(sp);
        setupBtn = Ui.PrimaryButton(hasKey ? "Make a new key" : "Set up encryption", SetUp);
        setupBtn.HorizontalAlignment = HorizontalAlignment.Left; setupBtn.Margin = new Thickness(0, 8, 0, 4);
        sp.Children.Add(setupBtn);

        if (hasKey)
        {
            sp.Children.Add(Section(cur.EncryptBackups ? "Turn off" : "Turn back on"));
            sp.Children.Add(Hint(cur.EncryptBackups
                ? "New backups go to the share unencrypted again. Keys are kept, so everything already encrypted still restores."
                : "New backups are encrypted again with key " + cur.ActiveKeyId + "."));
            toggleBtn = cur.EncryptBackups ? Ui.DangerButton("Stop encrypting new backups", Toggle) : Ui.PrimaryButton("Encrypt new backups", Toggle);
            toggleBtn.HorizontalAlignment = HorizontalAlignment.Left; toggleBtn.Margin = new Thickness(0, 4, 0, 4);
            sp.Children.Add(toggleBtn);
        }

        sp.Children.Add(Section("Import a key (a rebuilt server)"));
        sp.Children.Add(Hint("On a server rebuilt after a loss: set up backups to the same share first, then enter the passphrase or the recovery key. The key copy is read from the share, and this server can restore the old backups."));
        sp.Children.Add(Label("Passphrase or recovery key"));
        importBox = Pw(sp);
        importBtn = Ui.GhostButton("Import", Import);
        importBtn.HorizontalAlignment = HorizontalAlignment.Left; importBtn.Margin = new Thickness(0, 4, 0, 4);
        sp.Children.Add(importBtn);

        StackPanel act = new StackPanel(); act.Orientation = Orientation.Horizontal; act.Margin = new Thickness(0, 16, 0, 0);
        act.Children.Add(Ui.GhostButton("Close", delegate { if (win != null) { win.Close(); } }));
        sp.Children.Add(act);

        log = new LogPane("Output", false, null, false);
        log.Height = 170; log.Margin = new Thickness(0, 14, 0, 0);
        log.Visibility = Visibility.Collapsed;
        sp.Children.Add(log);

        sv.Content = sp;
        return sv;
    }

    // ---- actions ----------------------------------------------------------------------

    void SetUp()
    {
        if (busy) { return; }
        if (pass1.Password.Length < 12) { Flash("The passphrase must be at least 12 characters - it is all that protects the key copy on the share."); return; }
        if (pass1.Password != pass2.Password) { Flash("The two passphrases differ."); return; }
        bool rotate = cur.ActiveKeyId.Length > 0;
        if (rotate)
        {
            MessageBoxResult r = MessageBox.Show(win, "Make a new encryption key?\n\nNew backups will use it. The current key is kept, so older backups still restore. You will get a new recovery key to store.",
                "Make a new key", MessageBoxButton.YesNo, MessageBoxImage.Question, MessageBoxResult.No);
            if (r != MessageBoxResult.Yes) { return; }
        }
        Dictionary<string, string> secrets = new Dictionary<string, string>();
        secrets["Passphrase"] = pass1.Password;
        string file;
        try { file = AlertsWindow.WriteSecretsFile(secrets); }
        catch (Exception ex) { Flash("Could not prepare the passphrase for hand-off: " + ex.Message); return; }
        string lastJson = null;
        RunJob("--setup-encryption \"" + file + "\"" + (rotate ? " --rotate" : ""), rotate ? "Making a new key" : "Setting up encryption",
            delegate(string json) { lastJson = json; },
            delegate(bool ok)
            {
                AlertsWindow.DeleteQuietly(file);
                pass1.Clear(); pass2.Clear();
                string key = Engine.JsonField(lastJson, "RecoveryKey");
                if (ok && key.Length > 0)
                {
                    revealText.Text = key;
                    revealCard.Visibility = Visibility.Visible;
                    keyShownUnconfirmed = true;
                    storedBox.IsChecked = false;
                    revealCard.BringIntoView();
                    log.SetTitle("Encryption is on - store the recovery key above");
                }
                if (ok && onDone != null) { onDone(); }
            });
    }

    void Toggle()
    {
        if (busy) { return; }
        bool turnOn = !cur.EncryptBackups;
        Dictionary<string, object> d = new Dictionary<string, object>();
        d["EncryptBackups"] = turnOn;
        string json = Path.Combine(Path.GetTempPath(), "seb-resched-" + Guid.NewGuid().ToString("N") + ".json");
        try { File.WriteAllText(json, new JavaScriptSerializer().Serialize(d)); }
        catch (Exception ex) { Flash("Could not write the setting: " + ex.Message); return; }
        RunJob("--reschedule \"" + json + "\"", turnOn ? "Turning encryption on" : "Turning encryption off", null,
            delegate(bool ok) { AlertsWindow.DeleteQuietly(json); if (ok && onDone != null) { onDone(); } });
    }

    void Import()
    {
        if (busy) { return; }
        string typed = importBox.Password.Trim();
        if (typed.Length == 0) { Flash("Enter the passphrase or the recovery key."); return; }
        Dictionary<string, string> secrets = new Dictionary<string, string>();
        // A recovery key has a shape a passphrase almost never has.
        if (Regex.IsMatch(typed.Replace("-", "").Replace(" ", ""), "^[0-9A-Fa-f]{64}$")) { secrets["RecoveryKey"] = typed; }
        else { secrets["Passphrase"] = typed; }
        string file;
        try { file = AlertsWindow.WriteSecretsFile(secrets); }
        catch (Exception ex) { Flash("Could not prepare the key for hand-off: " + ex.Message); return; }
        RunJob("--import-encryption-key \"" + file + "\"", "Importing the key", null,
            delegate(bool ok) { AlertsWindow.DeleteQuietly(file); importBox.Clear(); if (ok && onDone != null) { onDone(); } });
    }

    // One elevated job. Lines carrying the recovery key never reach the log pane - the key
    // is shown in its own panel, once, and a scrolling log is where it would be forgotten.
    void RunJob(string flag, string working, Action<string> onJson, Action<bool> after)
    {
        busy = true; Enable(false);
        log.Visibility = Visibility.Visible;
        log.SetTitle(working);
        log.Clear();
        log.Append("Approve the Windows elevation prompt…");
        Elevate.Run(flag, 180,
            delegate(string line)
            {
                string t = line.Trim();
                if (t.StartsWith("{") && t.EndsWith("}"))
                {
                    if (onJson != null) { onJson(t); }
                    if (t.Contains("\"RecoveryKey\"")) { return; }
                }
                if (RecoveryKeyLine.IsMatch(line)) { log.Append("   (recovery key - shown above)"); return; }
                log.Append(line);
            },
            delegate(bool ok, string output)
            {
                log.SetTitle(ok ? "Done" : "Failed - see below");
                busy = false; Enable(true);
                if (after != null) { after(ok); }
            });
    }

    // ---- widgets ----------------------------------------------------------------------

    void Enable(bool on)
    {
        foreach (Border b in new Border[] { setupBtn, toggleBtn, importBtn })
        {
            if (b == null) { continue; }
            b.IsHitTestVisible = on; b.Opacity = on ? 1.0 : 0.5;
        }
    }

    PasswordBox Pw(StackPanel sp)
    {
        PasswordBox p = new PasswordBox(); p.FontSize = 12.5; p.Width = 440; p.HorizontalAlignment = HorizontalAlignment.Left;
        p.Margin = new Thickness(0, 4, 0, 8);
        sp.Children.Add(p);
        return p;
    }
    static TextBlock Wrap(TextBlock t, double top, double bottom) { t.TextWrapping = TextWrapping.Wrap; t.Margin = new Thickness(0, top, 0, bottom); return t; }
    TextBlock Hint(string s) { return Wrap(Ui.Text(s, 11.5, Theme.Ink3), 2, 8); }
    TextBlock Label(string s) { TextBlock t = Ui.Text(s, 12, Theme.Ink2, FontWeights.SemiBold); t.Margin = new Thickness(0, 4, 0, 0); return t; }
    TextBlock Section(string s) { TextBlock t = Ui.Text(s, 14, Theme.Ink, FontWeights.SemiBold); t.Margin = new Thickness(0, 14, 0, 2); return t; }
    void Flash(string msg) { log.Visibility = Visibility.Visible; log.SetTitle("Check the form"); log.SetLines(new string[] { msg }); }
}
