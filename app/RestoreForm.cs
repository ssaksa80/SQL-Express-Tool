// The restore window.
//
// Layout: backup sets on the left, the restore sequence and its options on the
// right, progress across the bottom. Browsing and configuring happen freely; the
// destructive step is gated behind a sequence the operator reads first.
//
// It speaks SQL Server's vocabulary rather than invented product language - backup
// set, restore sequence, recovery state, MOVE, REPLACE. The operator's other tools
// and every article they will find under pressure use these words, and a window that
// renames them forces a translation step at the worst possible moment.
//
// No restore logic lives here. Every operation is an engine mode, because the engine
// already performs HEADERONLY, FILELISTONLY and RESTORE ... WITH MOVE inside its self
// test and that code runs on every self test. A second implementation in C# would be
// two things that must agree forever about relocation and recovery state.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Text;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

class BackupSet
{
    public string Database = "";
    public string Kind = "";
    public string Path = "";
    public long Bytes = 0;
    public string TakenUtc = "";

    public DateTime TakenLocal()
    {
        DateTime d;
        if (DateTime.TryParse(TakenUtc, CultureInfo.InvariantCulture,
                DateTimeStyles.RoundtripKind | DateTimeStyles.AdjustToUniversal, out d))
        {
            return d.ToLocalTime();
        }
        return DateTime.MinValue;
    }

    public string Label()
    {
        DateTime d = TakenLocal();
        string when = d == DateTime.MinValue ? "unknown time" : d.ToString("d MMM HH:mm:ss", CultureInfo.CurrentCulture);
        return when + "   " + (Bytes / 1048576) + " MB   " + Kind;
    }
}

class RestoreForm : Form
{
    TreeView tree;
    Label headline;
    SequencePanel sequence;
    OptionsPanel options;
    ProgressPanel progress;
    TextBox log;
    Button btnVerify, btnStart, btnOptions;
    Panel confirmBar;
    TextBox confirmBox;
    Label confirmLabel;

    List<BackupSet> sets = new List<BackupSet>();
    BackupSet current;
    Dictionary<string, object> inspected;
    bool busy;

    public RestoreForm()
    {
        Text = "Restore - SQL Express Backup";
        StartPosition = FormStartPosition.CenterParent;
        MinimumSize = new Size(880, 620);
        Size = new Size(1000, 700);
        BackColor = Theme.Bg;
        Font = Theme.UI(9f);

        TableLayoutPanel root = new TableLayoutPanel();
        root.Dock = DockStyle.Fill;
        root.ColumnCount = 1;
        root.RowCount = 3;
        root.Padding = new Padding(14, 12, 14, 12);
        root.BackColor = Theme.Bg;
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 74));
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 132));

        root.Controls.Add(BuildBody(), 0, 0);
        progress = new ProgressPanel();
        progress.Dock = DockStyle.Fill;
        root.Controls.Add(progress, 0, 1);
        root.Controls.Add(BuildLog(), 0, 2);
        Controls.Add(root);

        Shown += delegate { LoadSets(); };
    }

    Control BuildBody()
    {
        TableLayoutPanel t = new TableLayoutPanel();
        t.Dock = DockStyle.Fill;
        t.ColumnCount = 2;
        t.RowCount = 1;
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Absolute, 268));
        t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f));
        t.BackColor = Theme.Bg;

        // ---- left: the catalogue -------------------------------------------------
        Panel left = new Panel();
        left.Dock = DockStyle.Fill;
        left.BackColor = Theme.Panel;
        left.Padding = new Padding(1);
        left.Margin = new Padding(0, 0, 8, 0);

        tree = new TreeView();
        tree.Dock = DockStyle.Fill;
        tree.BorderStyle = BorderStyle.None;
        tree.BackColor = Theme.Panel;
        tree.ForeColor = Theme.Ink;
        tree.LineColor = Theme.Line;
        tree.HideSelection = false;
        tree.ItemHeight = 22;
        tree.Font = Theme.UI(9f);
        tree.AfterSelect += new TreeViewEventHandler(OnSetSelected);

        Panel treeHead = new Panel();
        treeHead.Dock = DockStyle.Top;
        treeHead.Height = 30;
        treeHead.BackColor = Theme.Panel;
        Label th = new Label();
        th.Text = "BACKUP SETS";
        th.ForeColor = Theme.Ink3;
        th.Font = Theme.UI(7.5f, FontStyle.Bold);
        th.Location = new Point(11, 10);
        th.AutoSize = true;
        treeHead.Controls.Add(th);

        LinkLabel open = new LinkLabel();
        open.Text = "Open backup media...";
        open.Dock = DockStyle.Bottom;
        open.Height = 30;
        open.Padding = new Padding(11, 8, 0, 0);
        open.LinkColor = Theme.Accent;
        open.ActiveLinkColor = Theme.Accent;
        open.BackColor = Theme.Panel;
        open.Font = Theme.UI(8.5f);
        open.LinkBehavior = LinkBehavior.NeverUnderline;
        open.Click += delegate { OpenMedia(); };

        left.Controls.Add(tree);
        left.Controls.Add(open);
        left.Controls.Add(treeHead);
        t.Controls.Add(left, 0, 0);

        // ---- right: sequence, options, actions -----------------------------------
        TableLayoutPanel right = new TableLayoutPanel();
        right.Dock = DockStyle.Fill;
        right.ColumnCount = 1;
        right.RowCount = 4;
        right.BackColor = Theme.Bg;
        right.RowStyles.Add(new RowStyle(SizeType.Absolute, 26));
        right.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
        right.RowStyles.Add(new RowStyle(SizeType.Absolute, 44));
        right.RowStyles.Add(new RowStyle(SizeType.Absolute, 40));

        headline = new Label();
        headline.Text = "Select a backup set";
        headline.Dock = DockStyle.Fill;
        headline.ForeColor = Theme.Ink;
        headline.Font = Theme.UI(11f, FontStyle.Bold);
        right.Controls.Add(headline, 0, 0);

        TableLayoutPanel mid = new TableLayoutPanel();
        mid.Dock = DockStyle.Fill;
        mid.ColumnCount = 1;
        mid.RowCount = 2;
        mid.BackColor = Theme.Bg;
        mid.RowStyles.Add(new RowStyle(SizeType.Absolute, 150));
        mid.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));
        sequence = new SequencePanel();
        sequence.Dock = DockStyle.Fill;
        sequence.Margin = new Padding(0, 0, 0, 8);
        options = new OptionsPanel();
        options.Dock = DockStyle.Fill;
        options.Changed += delegate { Rebuild(); };
        mid.Controls.Add(sequence, 0, 0);
        mid.Controls.Add(options, 0, 1);
        right.Controls.Add(mid, 0, 1);

        confirmBar = new Panel();
        confirmBar.Dock = DockStyle.Fill;
        confirmBar.BackColor = Theme.Bg;
        confirmBar.Visible = false;
        confirmLabel = new Label();
        confirmLabel.AutoSize = true;
        confirmLabel.ForeColor = Theme.Bad;
        confirmLabel.Font = Theme.UI(9f);
        confirmLabel.Location = new Point(0, 12);
        confirmBox = new TextBox();
        confirmBox.Width = 190;
        confirmBox.Font = Theme.UI(9f);
        confirmBox.TextChanged += delegate { UpdateStartEnabled(); };
        confirmBar.Controls.Add(confirmLabel);
        confirmBar.Controls.Add(confirmBox);
        confirmBar.Resize += delegate { LayoutConfirm(); };
        right.Controls.Add(confirmBar, 0, 2);

        FlowLayoutPanel actions = new FlowLayoutPanel();
        actions.Dock = DockStyle.Fill;
        actions.FlowDirection = FlowDirection.RightToLeft;
        actions.BackColor = Theme.Bg;
        btnStart = MakeButton("Start restore", true);
        btnStart.Click += delegate { StartRestore(); };
        btnVerify = MakeButton("Verify media", false);
        btnVerify.Click += delegate { VerifyMedia(); };
        btnOptions = MakeButton("Reset options", false);
        btnOptions.Click += delegate { options.Reset(); Rebuild(); };
        actions.Controls.Add(btnStart);
        actions.Controls.Add(btnVerify);
        actions.Controls.Add(btnOptions);
        right.Controls.Add(actions, 0, 3);

        t.Controls.Add(right, 1, 0);
        return t;
    }

    void LayoutConfirm()
    {
        confirmBox.Left = confirmLabel.Right + 10;
        confirmBox.Top = 9;
    }

    Button MakeButton(string text, bool primary)
    {
        Button b = new Button();
        b.Text = text;
        b.AutoSize = false;
        b.Size = new Size(126, 32);
        b.FlatStyle = FlatStyle.Flat;
        b.Font = Theme.UI(9f);
        b.Margin = new Padding(8, 4, 0, 4);
        b.FlatAppearance.BorderColor = primary ? Theme.Accent : Theme.Line;
        b.BackColor = primary ? Theme.Accent : Theme.Panel;
        b.ForeColor = primary ? Theme.OnAccent : Theme.Ink;
        b.UseVisualStyleBackColor = false;
        return b;
    }

    Control BuildLog()
    {
        log = new TextBox();
        log.Multiline = true;
        log.ReadOnly = true;
        log.ScrollBars = ScrollBars.Vertical;
        log.Dock = DockStyle.Fill;
        log.BorderStyle = BorderStyle.FixedSingle;
        log.BackColor = Theme.Panel;
        log.ForeColor = Theme.Ink2;
        log.Font = Theme.Mono(8.5f);
        log.Text = "Ready." + Environment.NewLine;
        return log;
    }

    // ---- engine plumbing ----------------------------------------------------------

    void Say(string line)
    {
        if (InvokeRequired) { BeginInvoke(new Action<string>(Say), new object[] { line }); return; }
        if (progress.Consume(line)) { return; }
        log.AppendText(line + Environment.NewLine);
    }

    // Runs an engine mode hidden and returns everything it wrote. Restore needs
    // sysadmin on the INSTANCE, which is a SQL right - it does not need local
    // administrator, so nothing here elevates.
    string RunMode(string args)
    {
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell\\v1.0\\powershell.exe");
        ProcessStartInfo psi = new ProcessStartInfo(ps);
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + SebApp.EnginePath + "\" " + args;
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.CreateNoWindow = true;
        StringBuilder all = new StringBuilder();
        using (Process p = Process.Start(psi))
        {
            p.OutputDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data == null) { return; }
                all.AppendLine(e.Data);
                Say(e.Data);
            };
            p.ErrorDataReceived += delegate(object s, DataReceivedEventArgs e)
            {
                if (e.Data == null) { return; }
                all.AppendLine(e.Data);
                Say(e.Data);
            };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            p.WaitForExit();
        }
        return all.ToString();
    }

    // The engine answers in JSON on one line. Take the LAST such line: the log may
    // legitimately contain braces, and the answer is always written last.
    static Dictionary<string, object> LastJson(string output)
    {
        string found = null;
        foreach (string line in output.Split('\n'))
        {
            string t = line.Trim();
            if (t.StartsWith("{") && t.EndsWith("}")) { found = t; }
        }
        if (found == null) { return null; }
        try
        {
            JavaScriptSerializer js = new JavaScriptSerializer();
            js.MaxJsonLength = 64 * 1024 * 1024;
            return js.Deserialize<Dictionary<string, object>>(found);
        }
        catch { return null; }
    }

    static string Str(Dictionary<string, object> d, string key)
    {
        if (d == null || !d.ContainsKey(key) || d[key] == null) { return ""; }
        return Convert.ToString(d[key], CultureInfo.InvariantCulture);
    }

    static bool Bool(Dictionary<string, object> d, string key)
    {
        if (d == null || !d.ContainsKey(key) || d[key] == null) { return false; }
        try { return Convert.ToBoolean(d[key]); } catch { return false; }
    }

    // ---- catalogue ----------------------------------------------------------------

    void LoadSets()
    {
        Say("--- reading backup sets ---");
        SetBusy(true);
        Thread t = new Thread(delegate ()
        {
            string outp = RunMode("-RestoreList");
            Dictionary<string, object> d = LastJson(outp);
            BeginInvoke(new Action(delegate { ApplySets(d); }));
        });
        t.IsBackground = true;
        t.Start();
    }

    void ApplySets(Dictionary<string, object> d)
    {
        sets.Clear();
        tree.Nodes.Clear();
        string reason = Str(d, "Reason");
        object rawSets = d != null && d.ContainsKey("Sets") ? d["Sets"] : null;
        if (rawSets is object[])
        {
            foreach (object o in (object[])rawSets)
            {
                Dictionary<string, object> row = o as Dictionary<string, object>;
                if (row == null) { continue; }
                BackupSet b = new BackupSet();
                b.Database = Str(row, "Database");
                b.Kind = Str(row, "Kind");
                b.Path = Str(row, "Path");
                b.TakenUtc = Str(row, "TakenUtc");
                try { b.Bytes = Convert.ToInt64(row["Bytes"]); } catch { }
                sets.Add(b);
            }
        }

        Dictionary<string, TreeNode> byDb = new Dictionary<string, TreeNode>();
        foreach (BackupSet b in sets)
        {
            if (!byDb.ContainsKey(b.Database))
            {
                TreeNode n = new TreeNode(b.Database);
                n.ForeColor = Theme.Ink;
                byDb[b.Database] = n;
                tree.Nodes.Add(n);
            }
            TreeNode leaf = new TreeNode(b.Label());
            leaf.Tag = b;
            leaf.ForeColor = Theme.Ink2;
            byDb[b.Database].Nodes.Add(leaf);
        }
        foreach (TreeNode n in tree.Nodes) { n.Expand(); }

        SetBusy(false);
        if (sets.Count == 0)
        {
            headline.Text = "No backup sets found";
            string why = reason == "" ? Str(d, "Root") : reason;
            sequence.SetMessage("Nothing to restore from." + Environment.NewLine + Environment.NewLine +
                (reason == ""
                    ? ("Looked in " + Str(d, "Root") + " and found no .bak files.")
                    : ("Could not read the backup location: " + reason)) + Environment.NewLine + Environment.NewLine +
                "Use Open backup media to point at a .bak file directly - including one produced by another server.");
            Say("no backup sets found" + (reason == "" ? "" : " - " + reason));
        }
        else
        {
            Say("found " + sets.Count + " backup sets");
        }
    }

    void OpenMedia()
    {
        OpenFileDialog f = new OpenFileDialog();
        f.Title = "Open backup media";
        f.Filter = "SQL Server backup (*.bak)|*.bak|All files (*.*)|*.*";
        if (f.ShowDialog(this) != DialogResult.OK) { return; }
        BackupSet b = new BackupSet();
        b.Path = f.FileName;
        b.Database = Path.GetFileNameWithoutExtension(f.FileName);
        b.Kind = "opened";
        try { b.Bytes = new FileInfo(f.FileName).Length; } catch { }
        Select(b);
    }

    void OnSetSelected(object sender, TreeViewEventArgs e)
    {
        BackupSet b = e.Node == null ? null : e.Node.Tag as BackupSet;
        if (b == null) { return; }
        Select(b);
    }

    void Select(BackupSet b)
    {
        if (busy) { return; }
        current = b;
        inspected = null;
        headline.Text = "Reading " + Path.GetFileName(b.Path);
        sequence.SetMessage("Reading the backup header...");
        SetBusy(true);
        Thread t = new Thread(delegate ()
        {
            string outp = RunMode("-RestoreInspect \"" + b.Path + "\"");
            Dictionary<string, object> d = LastJson(outp);
            BeginInvoke(new Action(delegate { ApplyInspect(d); }));
        });
        t.IsBackground = true;
        t.Start();
    }

    void ApplyInspect(Dictionary<string, object> d)
    {
        inspected = d;
        SetBusy(false);
        if (d == null) { sequence.SetMessage("The engine returned nothing readable."); return; }
        string db = Str(d, "Database");
        if (db != "") { headline.Text = db; }
        options.SuggestTarget(db == "" ? "Restored" : db + "_Restore");
        options.SetSourceDatabase(db);
        Rebuild();
    }

    // ---- the restore sequence ------------------------------------------------------

    void Rebuild()
    {
        if (current == null || inspected == null) { return; }
        bool readable = Bool(inspected, "Readable");
        string db = Str(inspected, "Database");
        string target = options.TargetName;

        sequence.Configure(current, inspected, options, readable);

        bool overwrite = options.Replace && string.Equals(target, db, StringComparison.OrdinalIgnoreCase);
        confirmBar.Visible = overwrite;
        if (overwrite)
        {
            confirmLabel.Text = "This replaces the live database. Type " + db + " to confirm:";
            LayoutConfirm();
        }
        UpdateStartEnabled();
    }

    void UpdateStartEnabled()
    {
        bool readable = inspected != null && Bool(inspected, "Readable");
        bool ok = !busy && current != null && readable && options.TargetName.Length > 0;
        if (confirmBar.Visible)
        {
            ok = ok && string.Equals(confirmBox.Text.Trim(), Str(inspected, "Database"), StringComparison.Ordinal);
        }
        btnStart.Enabled = ok;
        btnStart.BackColor = ok ? Theme.Accent : Theme.Sunken;
        btnStart.ForeColor = ok ? Theme.OnAccent : Theme.Ink3;
        btnVerify.Enabled = !busy && current != null;
    }

    void VerifyMedia()
    {
        if (current == null || busy) { return; }
        Say("--- verify media ---");
        SetBusy(true);
        progress.Begin("verify");
        Thread t = new Thread(delegate ()
        {
            string outp = RunMode("-RestoreVerify \"" + current.Path + "\"");
            Dictionary<string, object> d = LastJson(outp);
            BeginInvoke(new Action(delegate
            {
                SetBusy(false);
                progress.Finish("finished");
                if (Bool(d, "Ok")) { Say("[ OK ] the media verified - RESTORE VERIFYONLY passed WITH CHECKSUM"); }
                else { Say("[FAIL] " + Str(d, "Error")); }
            }));
        });
        t.IsBackground = true;
        t.Start();
    }

    void StartRestore()
    {
        if (current == null || busy) { return; }
        string args = options.BuildArguments(current.Path);
        Say("--- restore ---");
        Say(sequence.PlainText());
        SetBusy(true);
        progress.Begin("restore");
        Thread t = new Thread(delegate ()
        {
            string outp = RunMode(args);
            Dictionary<string, object> d = LastJson(outp);
            BeginInvoke(new Action(delegate
            {
                SetBusy(false);
                progress.Finish("finished");
                if (d != null && Bool(d, "Ok"))
                {
                    Say("[ OK ] restored " + Str(d, "Database"));
                    string check = Str(d, "Check");
                    if (check != "") { Say("       " + check); }
                    Say("       the source database was not touched");
                }
                else
                {
                    Say("[FAIL] the restore did not complete. The log above says why.");
                    // A failed RESTORE leaves the database in RESTORING, which reliably
                    // confuses people who have not met it before.
                    Say("       if a database is left in RESTORING, finish it with:");
                    Say("         RESTORE DATABASE [" + options.TargetName + "] WITH RECOVERY");
                }
            }));
        });
        t.IsBackground = true;
        t.Start();
    }

    void SetBusy(bool value)
    {
        if (InvokeRequired) { BeginInvoke(new Action<bool>(SetBusy), new object[] { value }); return; }
        busy = value;
        tree.Enabled = !value;
        options.Enabled = !value;
        btnOptions.Enabled = !value;
        Cursor = value ? Cursors.AppStarting : Cursors.Default;
        UpdateStartEnabled();
    }
}
