// The two panels the restore window is built from.
//
// Kept separate from the window itself because they are the parts with real logic in
// them - what the sequence says, and what the options mean - and the window is mostly
// plumbing between the engine and these.

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Text;
using System.Windows.Forms;

// The restore sequence, rendered as the SQL it will actually run plus the checks made
// before offering it. Showing the statement rather than a prose summary is deliberate:
// the operator can compare it against SSMS, paste it into a change ticket, or satisfy
// themselves it does what they think, before anything executes.
class SequencePanel : Panel
{
    string message = "Select a backup set on the left.";
    string[] lines = new string[0];
    string[] checks = new string[0];
    bool[] checkOk = new bool[0];
    bool danger;

    public SequencePanel()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }

    public void SetMessage(string text)
    {
        message = text;
        lines = new string[0];
        checks = new string[0];
        checkOk = new bool[0];
        danger = false;
        Invalidate();
    }

    public string PlainText()
    {
        StringBuilder sb = new StringBuilder();
        foreach (string l in lines) { sb.AppendLine("  " + l); }
        return sb.ToString().TrimEnd();
    }

    public void Configure(BackupSet set, Dictionary<string, object> info, OptionsPanel opt, bool readable)
    {
        message = null;
        List<string> l = new List<string>();
        List<string> c = new List<string>();
        List<bool> ok = new List<bool>();

        string source = Get(info, "Database");
        danger = opt.Replace && string.Equals(opt.TargetName, source, StringComparison.OrdinalIgnoreCase);

        l.Add("RESTORE DATABASE [" + opt.TargetName + "]");
        l.Add("  FROM DISK = " + Path.GetFileName(set.Path));
        string with = "  WITH MOVE x" + opt.FileCount + ", " + opt.RecoveryState;
        if (opt.Replace) { with += ", REPLACE"; }
        if (opt.RestrictedUser) { with += ", RESTRICTED_USER"; }
        l.Add(with + ", CHECKSUM");

        if (danger)
        {
            l.Add("");
            l.Add("then, to put it in place of the live database:");
            l.Add("  ALTER DATABASE [" + source + "] SET SINGLE_USER WITH ROLLBACK IMMEDIATE");
            l.Add("  ALTER DATABASE [" + source + "] MODIFY NAME = [" + source + "_Old]");
            l.Add("  ALTER DATABASE [" + opt.TargetName + "] MODIFY NAME = [" + source + "]");
        }

        if (!readable)
        {
            string reason = Get(info, "ReadReason");
            c.Add(reason == "denied"
                ? "SQL Server cannot READ this file - grant its service account read on the folder"
                : ("SQL Server cannot read this file: " + reason));
            ok.Add(false);
        }
        else
        {
            c.Add("Media readable by the SQL Server service account");
            ok.Add(true);
        }

        if (danger)
        {
            c.Add("REPLACES the live database - everything after this recovery point is lost");
            ok.Add(false);
            c.Add("The live database is RENAMED, not dropped, so a wrong restore is reversible");
            ok.Add(true);
        }
        else
        {
            c.Add("Restores to a NEW database - the source is not touched");
            ok.Add(true);
        }

        lines = l.ToArray();
        checks = c.ToArray();
        checkOk = ok.ToArray();
        Invalidate();
    }

    static string Get(Dictionary<string, object> d, string key)
    {
        if (d == null || !d.ContainsKey(key) || d[key] == null) { return ""; }
        return Convert.ToString(d[key], CultureInfo.InvariantCulture);
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = new Rectangle(0, 0, Width - 1, Height - 1);
        Color edge = danger ? Theme.Bad : Theme.Line;

        using (GraphicsPath path = Card.Rounded(r, 6))
        {
            using (SolidBrush b = new SolidBrush(Theme.Panel)) { g.FillPath(b, path); }
            using (Pen p = new Pen(edge, 1f)) { g.DrawPath(p, path); }
        }

        using (SolidBrush ink3 = new SolidBrush(Theme.Ink3))
        using (Font small = Theme.UI(7.5f, FontStyle.Bold))
        {
            g.DrawString("RESTORE SEQUENCE", small, ink3, 12, 9);
        }

        if (message != null)
        {
            using (SolidBrush b = new SolidBrush(Theme.Ink3))
            using (Font f = Theme.UI(9f))
            {
                g.DrawString(message, f, b, new RectangleF(12, 28, Width - 24, Height - 34));
            }
            return;
        }

        float y = 28;
        using (Font mono = Theme.Mono(8.5f))
        using (SolidBrush ink = new SolidBrush(Theme.Ink))
        using (SolidBrush ink2 = new SolidBrush(Theme.Ink2))
        {
            foreach (string line in lines)
            {
                if (y > Height - 40) { break; }
                g.DrawString(line, mono, line.StartsWith("  ") ? ink2 : ink, 12, y);
                y += 15;
            }
        }

        y += 4;
        using (Font f = Theme.UI(8.5f))
        using (Font fb = Theme.UI(8.5f, FontStyle.Bold))
        {
            for (int i = 0; i < checks.Length; i++)
            {
                if (y > Height - 18) { break; }
                using (SolidBrush b = new SolidBrush(checkOk[i] ? Theme.Ok : Theme.Bad))
                {
                    g.DrawString(checkOk[i] ? "OK" : "!!", fb, b, 12, y);
                    g.DrawString(checks[i], f, b, 36, y);
                }
                y += 15;
            }
        }
    }
}

// Restore options: the applicable subset of the SSMS restore dialog, plus the ones
// that are impossible here shown GREYED WITH THE REASON rather than hidden. A disabled
// control that explains itself teaches the operator why their situation is what it is.
// A missing one teaches nothing, and leaves them looking for a feature that cannot
// exist on a SIMPLE-recovery instance.
class OptionsPanel : Panel
{
    public event EventHandler Changed;

    TextBox target, dataDir, logDir;
    ComboBox recovery;
    CheckBox replace, restricted, closeConns;
    string sourceDb = "";
    int fileCount = 2;

    public string TargetName { get { return target.Text.Trim(); } }
    public string RecoveryState { get { return recovery.SelectedItem == null ? "RECOVERY" : recovery.SelectedItem.ToString(); } }
    public bool Replace { get { return replace.Checked; } }
    public bool RestrictedUser { get { return restricted.Checked; } }
    public bool CloseConnections { get { return closeConns.Checked; } }
    public int FileCount { get { return fileCount; } }

    public OptionsPanel()
    {
        BackColor = Theme.Bg;
        AutoScroll = true;

        int y = 4;
        AddEyebrow("RESTORE OPTIONS", y); y += 22;

        target = AddText("Restore as", ref y);
        recovery = AddCombo("Recovery state", new string[] { "RECOVERY", "NORECOVERY", "STANDBY" }, ref y);
        dataDir = AddText("Data files (MOVE)", ref y);
        logDir = AddText("Log file (MOVE)", ref y);

        y += 2;
        replace = AddCheck("Overwrite the existing database  (REPLACE)", ref y);
        restricted = AddCheck("Restrict access after restore  (RESTRICTED_USER)", ref y);
        closeConns = AddCheck("Close existing connections to the target", ref y);

        y += 8;
        AddDisabled("Recovery point  (STOPAT)", "no log chain - SIMPLE recovery", ref y);
        AddDisabled("Tail-log backup before restore", "impossible under SIMPLE recovery", ref y);
        AddDisabled("Preserve replication  (KEEP_REPLICATION)", "the database is not published", ref y);

        target.TextChanged += delegate { Fire(); };
        recovery.SelectedIndexChanged += delegate { Fire(); };
        dataDir.TextChanged += delegate { Fire(); };
        logDir.TextChanged += delegate { Fire(); };
        replace.CheckedChanged += delegate { Fire(); };
        restricted.CheckedChanged += delegate { Fire(); };
        closeConns.CheckedChanged += delegate { Fire(); };
    }

    void Fire() { if (Changed != null) { Changed(this, EventArgs.Empty); } }

    public void SetSourceDatabase(string db) { sourceDb = db; }
    public void SetFileCount(int n) { fileCount = n; }

    public void SuggestTarget(string name)
    {
        if (target.Text.Trim().Length == 0) { target.Text = name; }
    }

    public void Reset()
    {
        target.Text = sourceDb == "" ? "" : sourceDb + "_Restore";
        recovery.SelectedIndex = 0;
        dataDir.Text = "";
        logDir.Text = "";
        replace.Checked = false;
        restricted.Checked = false;
        closeConns.Checked = false;
    }

    // Every value is quoted, because a database name or a path may contain spaces and
    // the engine is reached through a command line.
    public string BuildArguments(string mediaPath)
    {
        StringBuilder sb = new StringBuilder();
        sb.Append("-RestoreRun -RestoreFrom \"").Append(mediaPath).Append("\"");
        sb.Append(" -RestoreAs \"").Append(TargetName).Append("\"");
        sb.Append(" -RestoreRecoveryState ").Append(RecoveryState);
        if (dataDir.Text.Trim().Length > 0) { sb.Append(" -RestoreDataDir \"").Append(dataDir.Text.Trim()).Append("\""); }
        if (logDir.Text.Trim().Length > 0) { sb.Append(" -RestoreLogDir \"").Append(logDir.Text.Trim()).Append("\""); }
        if (Replace) { sb.Append(" -RestoreReplace"); }
        if (RestrictedUser) { sb.Append(" -RestoreRestrictedUser"); }
        if (CloseConnections) { sb.Append(" -RestoreCloseConnections"); }
        return sb.ToString();
    }

    void AddEyebrow(string text, int y)
    {
        Label l = new Label();
        l.Text = text;
        l.AutoSize = true;
        l.Location = new Point(0, y);
        l.ForeColor = Theme.Ink3;
        l.Font = Theme.UI(7.5f, FontStyle.Bold);
        Controls.Add(l);
    }

    Label Caption(string text, int y)
    {
        Label l = new Label();
        l.Text = text;
        l.AutoSize = true;
        l.Location = new Point(0, y);
        l.ForeColor = Theme.Ink2;
        l.Font = Theme.UI(8.5f);
        Controls.Add(l);
        return l;
    }

    TextBox AddText(string caption, ref int y)
    {
        Caption(caption, y + 5);
        TextBox t = new TextBox();
        t.Location = new Point(200, y);
        t.Width = 330;
        t.Font = Theme.UI(9f);
        t.BackColor = Theme.Panel;
        t.ForeColor = Theme.Ink;
        t.BorderStyle = BorderStyle.FixedSingle;
        Controls.Add(t);
        y += 29;
        return t;
    }

    ComboBox AddCombo(string caption, string[] items, ref int y)
    {
        Caption(caption, y + 5);
        ComboBox c = new ComboBox();
        c.Location = new Point(200, y);
        c.Width = 170;
        c.DropDownStyle = ComboBoxStyle.DropDownList;
        c.Font = Theme.UI(9f);
        c.FlatStyle = FlatStyle.Flat;
        c.BackColor = Theme.Panel;
        c.ForeColor = Theme.Ink;
        foreach (string i in items) { c.Items.Add(i); }
        c.SelectedIndex = 0;
        Controls.Add(c);
        y += 29;
        return c;
    }

    CheckBox AddCheck(string caption, ref int y)
    {
        CheckBox c = new CheckBox();
        c.Text = caption;
        c.AutoSize = true;
        c.Location = new Point(0, y);
        c.ForeColor = Theme.Ink2;
        c.Font = Theme.UI(8.5f);
        c.FlatStyle = FlatStyle.Flat;
        Controls.Add(c);
        y += 24;
        return c;
    }

    void AddDisabled(string caption, string why, ref int y)
    {
        Label l = new Label();
        l.Text = caption;
        l.AutoSize = true;
        l.Location = new Point(0, y);
        l.ForeColor = Theme.Ink3;
        l.Font = Theme.UI(8.5f);
        Controls.Add(l);

        Label w = new Label();
        w.Text = "unavailable - " + why;
        w.AutoSize = true;
        w.Location = new Point(285, y);
        w.ForeColor = Theme.Ink3;
        w.Font = Theme.UI(8.5f, FontStyle.Italic);
        Controls.Add(w);
        y += 21;
    }
}
