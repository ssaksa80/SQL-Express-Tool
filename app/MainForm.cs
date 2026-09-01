// SQL Express Backup - the window, and the process plumbing behind it.
// C# 4 only; see the header of SqlExpressBackupApp.cs.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

static class SebApp
{
    // A windowed exe has no console of its own, but it usually HAS a parent one when
    // somebody runs it by hand or a test launches it. Attaching to that parent turns
    // a silent "exited 2" into the actual reason. dev-ba lost real time to this exact
    // silence: the diagnostic existed, it just went only to a temp file nobody knew
    // to look in.
    [System.Runtime.InteropServices.DllImport("kernel32.dll")]
    static extern bool AttachConsole(int processId);

    static int CheckProgress(string path)
    {
        StringBuilder sb = new StringBuilder();
        int bad = 0;
        // local assertion helper
        List<string> fails = new List<string>();

        Check(sb, fails, "starting is zero", JobProgress.Overall(1, 8, "starting", -1) == 0.0);
        Check(sb, fails, "finished is one", JobProgress.Overall(8, 8, "finished", -1) == 1.0);
        // The bug this fixes: a finished job must not render as an empty bar.
        Check(sb, fails, "finished is one even mid-job", JobProgress.Overall(3, 8, "finished", -1) == 1.0);
        Check(sb, fails, "backup at 100 pct does not fill the whole database",
              Math.Abs(JobProgress.Fraction("backup", 100) - 0.75) < 1e-9);
        Check(sb, fails, "verify is past backup", JobProgress.Fraction("verify", -1) > JobProgress.Fraction("backup", 100));
        Check(sb, fails, "copy is past verify", JobProgress.Fraction("copy", -1) > JobProgress.Fraction("verify", -1));
        Check(sb, fails, "first of eight backing up is under an eighth",
              JobProgress.Overall(1, 8, "backup", 50) < 0.125);
        Check(sb, fails, "eighth of eight copying is nearly whole",
              JobProgress.Overall(8, 8, "copy", -1) > 0.99);
        Check(sb, fails, "zero total does not divide by zero", JobProgress.Overall(1, 0, "backup", 50) == 0.0);
        Check(sb, fails, "percent above 100 is clamped", JobProgress.Fraction("backup", 300) <= 0.75);
        Check(sb, fails, "unknown stage contributes nothing", JobProgress.Fraction("banana", 50) == 0.0);

        // Monotonic. The regression is NOT across a database boundary - at database 4
        // of 8, three really are finished. It happens INSIDE one database: the engine
        // emits [JOB] before [STAGE], so database 4 is briefly reported still in the
        // previous database's 'copy' stage before its own 'backup' stage arrives.
        double a = JobProgress.Overall(4, 8, "copy", -1);
        double b = JobProgress.Overall(4, 8, "backup", 0);
        Check(sb, fails, "the raw value really can go backwards within a database", b < a);
        Check(sb, fails, "and the monotonic clamp stops it", JobProgress.Monotonic(a, b) == a);
        Check(sb, fails, "crossing to the next database still moves forward",
              JobProgress.Overall(4, 8, "starting", -1) > JobProgress.Overall(3, 8, "copy", -1));
        Check(sb, fails, "while genuine forward movement passes through",
              JobProgress.Monotonic(0.5, 0.6) == 0.6);

        Check(sb, fails, "no throughput for six seconds during backup is a stall",
              JobProgress.Stalled("backup", 0.0, 6.0));
        Check(sb, fails, "no throughput for two seconds is not yet a stall",
              !JobProgress.Stalled("backup", 0.0, 2.0));
        Check(sb, fails, "throughput means no stall", !JobProgress.Stalled("backup", 1.5, 60.0));
        Check(sb, fails, "verify reports no throughput and must not count as stalled",
              !JobProgress.Stalled("verify", 0.0, 600.0));

        bad = fails.Count;
        sb.AppendLine(bad == 0 ? "PROGRESS-OK" : ("PROGRESS-FAIL " + bad));
        TryWrite(path, sb.ToString());
        return bad == 0 ? 0 : 1;
    }

    static void Check(StringBuilder sb, List<string> fails, string what, bool ok)
    {
        sb.AppendLine((ok ? "PASS " : "FAIL ") + what);
        if (!ok) { fails.Add(what); }
    }

    static void Complain(string text)
    {
        try
        {
            if (AttachConsole(-1))   // -1 = ATTACH_PARENT_PROCESS
            {
                Console.Error.WriteLine(text);
                Console.Error.Flush();
            }
        }
        catch { }
    }

    internal const string TaskName = "SqlExpressBackup";
    internal static string StateDir;
    internal static string UserDir;
    internal static string EnginePath;

    [STAThread]
    static int Main(string[] args)
    {
        string checkFile = null;
        string progressFile = null;
        for (int i = 0; i < args.Length; i++)
        {
            if (args[i] == "--check" && i + 1 < args.Length) { checkFile = args[++i]; }
            if (args[i] == "--check-progress" && i + 1 < args.Length) { progressFile = args[++i]; }
        }

        // The progress arithmetic is pure, so it can be checked without a window, a
        // database or a backup. It runs the REAL compiled JobProgress - not a
        // reimplementation of it in the test - and writes findings to a file, because
        // a windowed exe has no console to report to.
        if (progressFile != null) { return CheckProgress(progressFile); }

        try
        {
            StateDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SqlExpressBackup");
            // Best effort: once -Setup has run this is locked to SYSTEM and
            // Administrators, and an unelevated console must still start.
            try { Directory.CreateDirectory(StateDir); } catch { }

            UserDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SqlExpressBackup");
            Directory.CreateDirectory(UserDir);

            EnginePath = ExtractEngine();
        }
        catch (Exception ex)
        {
            string where = Path.Combine(Path.GetTempPath(), "SqlExpressBackupApp-error.txt");
            TryWrite(where, ex.ToString());
            string summary = "SQL Express Backup could not start: " + ex.Message +
                Environment.NewLine + "Full detail: " + where;
            Complain(summary);
            if (checkFile != null) { TryWrite(checkFile, "CHECK-FAIL " + ex.Message); return 2; }
            MessageBox.Show(summary, "SQL Express Backup", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 2;
        }

        // A windowed exe has no console to report to, so the smoke test writes its
        // findings to a file. It exercises everything except the message pump:
        // extraction, the state paths, and reading status off disk.
        if (checkFile != null)
        {
            StringBuilder sb = new StringBuilder();
            try
            {
                Status s = Status.Read();
                sb.AppendLine("engine: " + EnginePath);
                sb.AppendLine("engine-exists: " + File.Exists(EnginePath).ToString().ToLowerInvariant());
                sb.AppendLine("state-dir: " + StateDir);
                sb.AppendLine("user-dir: " + UserDir);
                sb.AppendLine("host: " + s.HostName);
                sb.AppendLine("configured: " + s.Configured.ToString().ToLowerInvariant());
                sb.AppendLine("schedule: " + s.ScheduleState);
                sb.AppendLine("databases: " + s.Databases.Count.ToString(CultureInfo.InvariantCulture));
                using (MainForm f = new MainForm()) { sb.AppendLine("form-built: " + (f.Controls.Count > 0).ToString().ToLowerInvariant()); }
                // The restore window is constructed too. Layout code that has never
                // executed is the code most likely to throw on first use, and this one
                // opens in front of an operator who is already having a bad day. It is
                // built and disposed WITHOUT being shown, so nothing runs a restore.
                using (RestoreForm r = new RestoreForm()) { sb.AppendLine("restore-form-built: " + (r.Controls.Count > 0).ToString().ToLowerInvariant()); }
                sb.AppendLine("CHECK-OK");
                TryWrite(checkFile, sb.ToString());
                return 0;
            }
            catch (Exception ex)
            {
                sb.AppendLine("CHECK-FAIL " + ex.GetType().Name + ": " + ex.Message);
                TryWrite(checkFile, sb.ToString());
                return 2;
            }
        }

        Theme.Load();
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new MainForm());
        return 0;
    }

    static void TryWrite(string path, string text)
    {
        try { File.WriteAllText(path, text, new UTF8Encoding(false)); } catch { }
    }

    // Extracted PER USER, never into the machine-wide state directory. This process
    // runs unelevated, and ProgramData's default ACL lets a user rewrite what they
    // create there - so extracting here and then pointing a SYSTEM task at it would
    // hand any non-admin a script SYSTEM runs every six hours. The copy the
    // scheduled task uses is placed by the elevated install instead.
    internal static string ExtractEngine()
    {
        string dir = Path.Combine(UserDir, "engine");
        Directory.CreateDirectory(dir);
        string target = Path.Combine(dir, "Invoke-SqlExpressBackup.ps1");
        byte[] embedded = Resource("Invoke-SqlExpressBackup.ps1");
        if (embedded == null) { throw new InvalidOperationException("this exe was built without the backup engine embedded"); }
        bool write = true;
        if (File.Exists(target))
        {
            try
            {
                byte[] onDisk = File.ReadAllBytes(target);
                write = onDisk.Length != embedded.Length;
                if (!write)
                {
                    for (int i = 0; i < onDisk.Length; i++) { if (onDisk[i] != embedded[i]) { write = true; break; } }
                }
            }
            catch { write = true; }
        }
        if (write) { File.WriteAllBytes(target, embedded); }
        return target;
    }

    static byte[] Resource(string name)
    {
        using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream(name))
        {
            if (s == null) { return null; }
            using (MemoryStream ms = new MemoryStream())
            {
                byte[] buf = new byte[8192];
                int n;
                while ((n = s.Read(buf, 0, buf.Length)) > 0) { ms.Write(buf, 0, n); }
                return ms.ToArray();
            }
        }
    }
}

class MainForm : Form
{
    Pip pip;
    Label titleLabel, hostLabel;
    Card cardRun, cardSchedule, cardPending, cardInstance;
    ListView dbList;
    TextBox txtShare, txtStaging, txtInterval, txtHourly, txtDaily;
    ComboBox cboAuth;
    Button btnSave, btnTheme, btnQuit;
    ActionButton btnRestore;
    ActionButton btnSelfTest, btnRunNow, btnInstall, btnUninstall, btnFull;
    TextBox log;
    Label noteLabel;
    ProgressPanel progress;
    bool amElevated;
    System.Windows.Forms.Timer statusTimer;
    volatile bool busy;

    public MainForm()
    {
        amElevated = IsElevated();
        Text = "SQL Express Backup" + (amElevated ? " (administrator)" : "");
        MinimumSize = new Size(900, 680);
        Size = new Size(1020, 780);
        StartPosition = FormStartPosition.CenterScreen;
        Font = Theme.UI(9f);
        DoubleBuffered = true;

        TableLayoutPanel root = new TableLayoutPanel();
        root.Dock = DockStyle.Fill;
        root.ColumnCount = 1;
        root.RowCount = 7;
        root.Padding = new Padding(16, 10, 16, 14);
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 46));   // header
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 104));  // cards
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 168));  // databases
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 100));  // settings
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 86));   // actions
        root.RowStyles.Add(new RowStyle(SizeType.Absolute, 74));   // progress
        root.RowStyles.Add(new RowStyle(SizeType.Percent, 100f));  // log
        Controls.Add(root);

        root.Controls.Add(BuildHeader(), 0, 0);
        root.Controls.Add(BuildCards(), 0, 1);
        root.Controls.Add(BuildDatabases(), 0, 2);
        root.Controls.Add(BuildSettings(), 0, 3);
        root.Controls.Add(BuildActions(), 0, 4);
        progress = new ProgressPanel();
        progress.Dock = DockStyle.Fill;
        root.Controls.Add(progress, 0, 5);
        root.Controls.Add(BuildLog(), 0, 6);

        ApplyTheme();

        statusTimer = new System.Windows.Forms.Timer();
        statusTimer.Interval = 5000;
        statusTimer.Tick += delegate { RefreshStatus(); };
        statusTimer.Start();
        Shown += delegate { RefreshStatus(); };
    }

    static bool IsElevated()
    {
        try
        {
            using (System.Security.Principal.WindowsIdentity id = System.Security.Principal.WindowsIdentity.GetCurrent())
            {
                return new System.Security.Principal.WindowsPrincipal(id)
                    .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);
            }
        }
        catch { return false; }
    }

    Control BuildHeader()
    {
        Panel p = new Panel();
        p.Dock = DockStyle.Fill;
        pip = new Pip();
        pip.Location = new Point(2, 13);
        titleLabel = new Label();
        titleLabel.Text = "SQL Express Backup";
        titleLabel.Font = Theme.UI(12f, FontStyle.Bold);
        titleLabel.AutoSize = true;
        titleLabel.Location = new Point(26, 10);
        hostLabel = new Label();
        hostLabel.AutoSize = true;
        hostLabel.Location = new Point(210, 15);
        btnQuit = SmallButton("Quit", 0);
        btnQuit.Click += delegate { Close(); };
        btnTheme = SmallButton("Theme", 1);
        btnTheme.Click += delegate { Theme.Toggle(); Theme.Save(); ApplyTheme(); };
        p.Controls.AddRange(new Control[] { pip, titleLabel, hostLabel, btnQuit, btnTheme });
        p.Resize += delegate
        {
            btnQuit.Location = new Point(p.Width - 78, 10);
            btnTheme.Location = new Point(p.Width - 158, 10);
        };
        return p;
    }

    Button SmallButton(string text, int slot)
    {
        Button b = new Button();
        b.Text = text;
        b.Size = new Size(72, 26);
        b.FlatStyle = FlatStyle.Flat;
        return b;
    }

    Control BuildCards()
    {
        TableLayoutPanel t = new TableLayoutPanel();
        t.Dock = DockStyle.Fill;
        t.ColumnCount = 4;
        t.RowCount = 1;
        for (int i = 0; i < 4; i++) { t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 25f)); }
        cardRun = NewCard("Last run", t, 0);
        cardSchedule = NewCard("Schedule", t, 1);
        cardPending = NewCard("Waiting for share", t, 2);
        cardInstance = NewCard("Instance", t, 3);
        return t;
    }

    Card NewCard(string eyebrow, TableLayoutPanel host, int col)
    {
        Card c = new Card();
        c.Eyebrow = eyebrow;
        c.Big = "-";
        c.Sub = "";
        c.Dock = DockStyle.Fill;
        c.Margin = new Padding(col == 0 ? 0 : 5, 0, col == 3 ? 0 : 5, 0);
        host.Controls.Add(c, col, 0);
        return c;
    }

    Control BuildDatabases()
    {
        Panel wrap = new Panel();
        wrap.Dock = DockStyle.Fill;
        wrap.Padding = new Padding(0, 6, 0, 0);
        dbList = new ListView();
        dbList.Dock = DockStyle.Fill;
        dbList.View = View.Details;
        dbList.FullRowSelect = true;
        dbList.GridLines = false;
        dbList.BorderStyle = BorderStyle.FixedSingle;
        dbList.HeaderStyle = ColumnHeaderStyle.Nonclickable;
        dbList.Columns.Add("Database", 240);
        dbList.Columns.Add("Hourly", 70, HorizontalAlignment.Right);
        dbList.Columns.Add("Daily", 70, HorizontalAlignment.Right);
        dbList.Columns.Add("Newest backup", 170);
        dbList.Columns.Add("Age", 120);
        wrap.Controls.Add(dbList);
        noteLabel = new Label();
        noteLabel.AutoSize = false;
        noteLabel.Dock = DockStyle.Bottom;
        noteLabel.Height = 34;
        noteLabel.Padding = new Padding(2, 6, 2, 0);
        wrap.Controls.Add(noteLabel);
        return wrap;
    }

    // Six columns, four rows, and NO overlapping spans. The first attempt put the
    // Save button at column 4 of row 1 while the two path fields each spanned three
    // columns across that same row - TableLayoutPanel then reflowed everything and
    // the labels scattered. Rows alternate label, field.
    Control BuildSettings()
    {
        TableLayoutPanel t = new TableLayoutPanel();
        t.Dock = DockStyle.Fill;
        t.ColumnCount = 6;
        t.RowCount = 4;
        for (int i = 0; i < 6; i++) { t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f / 6f)); }
        t.RowStyles.Add(new RowStyle(SizeType.Absolute, 18));
        t.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));
        t.RowStyles.Add(new RowStyle(SizeType.Absolute, 18));
        t.RowStyles.Add(new RowStyle(SizeType.Absolute, 28));

        Label lShare = FieldLabel("Share path");
        t.Controls.Add(lShare, 0, 0); t.SetColumnSpan(lShare, 3);
        Label lStaging = FieldLabel("Staging folder");
        t.Controls.Add(lStaging, 3, 0); t.SetColumnSpan(lStaging, 3);

        txtShare = Field();
        t.Controls.Add(txtShare, 0, 1); t.SetColumnSpan(txtShare, 3);
        txtStaging = Field();
        t.Controls.Add(txtStaging, 3, 1); t.SetColumnSpan(txtStaging, 3);

        t.Controls.Add(FieldLabel("Every (hours)"), 0, 2);
        t.Controls.Add(FieldLabel("Keep hourly"), 1, 2);
        t.Controls.Add(FieldLabel("Keep daily"), 2, 2);
        Label lAuth = FieldLabel("Authentication");
        t.Controls.Add(lAuth, 3, 2); t.SetColumnSpan(lAuth, 2);

        txtInterval = Field(); txtInterval.Text = "6"; t.Controls.Add(txtInterval, 0, 3);
        txtHourly = Field(); txtHourly.Text = "3"; t.Controls.Add(txtHourly, 1, 3);
        txtDaily = Field(); txtDaily.Text = "7"; t.Controls.Add(txtDaily, 2, 3);

        cboAuth = new ComboBox();
        cboAuth.Dock = DockStyle.Fill;
        cboAuth.DropDownStyle = ComboBoxStyle.DropDownList;
        cboAuth.Items.Add("Windows - task runs as SYSTEM, no password stored");
        cboAuth.Items.Add("SQL login - sealed to this machine");
        cboAuth.SelectedIndex = 0;
        cboAuth.Margin = new Padding(3, 2, 3, 4);
        t.Controls.Add(cboAuth, 3, 3); t.SetColumnSpan(cboAuth, 2);

        btnSave = new Button();
        btnSave.Text = "Save settings";
        btnSave.Dock = DockStyle.Fill;
        btnSave.FlatStyle = FlatStyle.Flat;
        btnSave.Margin = new Padding(3, 2, 0, 4);
        btnSave.Click += delegate { SaveSettings(); };
        t.Controls.Add(btnSave, 5, 3);

        return t;
    }

    Label FieldLabel(string text)
    {
        Label l = new Label();
        l.Text = text.ToUpperInvariant();
        l.Font = Theme.UI(7.5f, FontStyle.Bold);
        l.Dock = DockStyle.Fill;
        l.TextAlign = ContentAlignment.BottomLeft;
        l.Margin = new Padding(3, 0, 3, 0);
        return l;
    }

    TextBox Field()
    {
        TextBox t = new TextBox();
        t.Dock = DockStyle.Fill;
        t.BorderStyle = BorderStyle.FixedSingle;
        t.Margin = new Padding(3, 2, 3, 4);
        return t;
    }

    Control BuildActions()
    {
        TableLayoutPanel t = new TableLayoutPanel();
        t.Dock = DockStyle.Fill;
        t.ColumnCount = 6;
        t.RowCount = 1;
        for (int i = 0; i < 6; i++) { t.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100f / 6f)); }

        btnSelfTest = Act("Self test", "Scratch database, backed up, restored, dropped. No prompt.", false);
        btnSelfTest.Click += delegate { RunEngine("-SelfTest", false, "self test"); };
        btnRunNow = Act("Run backup now", "One pass, immediately. Needs an administrator.", false);
        // The one thing this application exists to do, so it carries the accent.
        btnRunNow.Primary = true;
        btnRunNow.Click += delegate { RunEngine("-Run", true, "run"); };
        btnRestore = Act("Restore", "Browse backup sets and restore a database.", false);
        btnRestore.Click += delegate { OpenRestore(); };
        btnInstall = Act("Install schedule", "Every database, on the interval above, as SYSTEM.", false);
        btnInstall.Click += delegate { RunEngine("-Install -As Task", true, "install"); };
        btnUninstall = Act("Uninstall schedule", "Stops the schedule. Backups are not touched.", true);
        btnUninstall.Click += delegate { RunEngine("-Uninstall", true, "uninstall"); };
        btnFull = Act("Full install", "Make a local share, set up, schedule, back up now.", true);
        btnFull.Click += delegate { FullInstall(); };

        ActionButton[] all = new ActionButton[] { btnSelfTest, btnRunNow, btnRestore, btnInstall, btnUninstall, btnFull };
        for (int i = 0; i < all.Length; i++)
        {
            all[i].Dock = DockStyle.Fill;
            all[i].Margin = new Padding(i == 0 ? 0 : 4, 4, i == all.Length - 1 ? 0 : 4, 4);
            t.Controls.Add(all[i], i, 0);
        }
        return t;
    }

    // Non-modal on purpose: a restore is long, and the operator needs to keep reading
    // the log and the status behind it while one runs.
    RestoreForm restoreWindow;
    void OpenRestore()
    {
        if (restoreWindow != null && !restoreWindow.IsDisposed)
        {
            if (restoreWindow.WindowState == FormWindowState.Minimized) { restoreWindow.WindowState = FormWindowState.Normal; }
            restoreWindow.Activate();
            return;
        }
        restoreWindow = new RestoreForm();
        restoreWindow.Show(this);
    }

    ActionButton Act(string text, string why, bool danger)
    {
        ActionButton b = new ActionButton();
        b.Text = text;
        b.Why = why;
        b.Danger = danger;
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
        log.Font = Theme.Mono(8.5f);
        log.Text = "Ready." + Environment.NewLine;
        return log;
    }

    void ApplyTheme()
    {
        BackColor = Theme.Bg;
        ForeColor = Theme.Ink;
        Paint2(this);
        Invalidate(true);
    }

    void Paint2(Control parent)
    {
        foreach (Control c in parent.Controls)
        {
            if (c is TextBox || c is ListView || c is ComboBox)
            {
                c.BackColor = Theme.Panel;
                c.ForeColor = Theme.Ink;
            }
            else if (c is Button && !(c is ActionButton))
            {
                Button b = (Button)c;
                b.BackColor = Theme.Panel;
                b.ForeColor = Theme.Ink2;
                b.FlatAppearance.BorderColor = Theme.Line;
            }
            else if (c is Label)
            {
                c.ForeColor = (c == hostLabel || c == noteLabel) ? Theme.Ink3 : Theme.Ink2;
            }
            if (c.Controls.Count > 0) { Paint2(c); }
        }
    }

    // ------------------------------------------------------------ status

    void RefreshStatus()
    {
        Status s;
        try { s = Status.Read(); } catch { return; }

        hostLabel.Text = s.HostName;
        string tone = s.LastResult == "ok" ? "ok" : (s.LastResult == "partial" ? "partial" : (s.LastResult == "failed" ? "failed" : "unknown"));
        pip.SetTone(tone);
        cardRun.SetTone(tone);
        cardRun.Update(string.IsNullOrEmpty(s.LastResult) ? "never" : s.LastResult, Ago(s.LastRunUtc));
        cardSchedule.SetTone(s.ScheduleState == "Ready" || s.ScheduleState == "Running" ? "ok" : "unknown");
        string schedSub = s.ScheduleSub;
        if (string.IsNullOrEmpty(schedSub)) { schedSub = string.IsNullOrEmpty(s.ScheduleNext) ? "not installed" : ("next " + s.ScheduleNext); }
        cardSchedule.Update(s.ScheduleState, schedSub);
        cardPending.SetTone(s.PendingCount > 0 ? "partial" : (s.Configured ? "ok" : "unknown"));
        cardPending.Update(s.PendingCount.ToString(CultureInfo.InvariantCulture), "copies still to go up");
        cardInstance.Update(string.IsNullOrEmpty(s.Instance) ? "not configured" : s.Instance,
            string.IsNullOrEmpty(s.SharePath) ? "no share configured" : s.SharePath);

        dbList.BeginUpdate();
        dbList.Items.Clear();
        foreach (DbRow r in s.Databases)
        {
            ListViewItem it = new ListViewItem(r.Name);
            it.SubItems.Add(r.Hourly.ToString(CultureInfo.InvariantCulture));
            it.SubItems.Add(r.Daily.ToString(CultureInfo.InvariantCulture));
            it.SubItems.Add(r.Newest == DateTime.MinValue ? "-" : r.Newest.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture));
            string age = r.Newest == DateTime.MinValue ? "-" : Ago(r.Newest.ToUniversalTime());
            it.SubItems.Add(age);
            if (r.Newest != DateTime.MinValue && (DateTime.Now - r.Newest).TotalHours > s.IntervalHours * 2)
            { it.ForeColor = Theme.Bad; }
            dbList.Items.Add(it);
        }
        dbList.EndUpdate();
        noteLabel.Text = s.ShareNote;

        progress.SetStagingPath(s.StagingPath);
        if (!txtShare.Focused && !string.IsNullOrEmpty(s.SharePath)) { txtShare.Text = s.SharePath; }
        if (!txtStaging.Focused && !string.IsNullOrEmpty(s.StagingPath)) { txtStaging.Text = s.StagingPath; }
        if (!txtInterval.Focused) { txtInterval.Text = s.IntervalHours.ToString(CultureInfo.InvariantCulture); }
        if (!txtHourly.Focused) { txtHourly.Text = s.HourlyKeep.ToString(CultureInfo.InvariantCulture); }
        if (!txtDaily.Focused) { txtDaily.Text = s.DailyKeepDays.ToString(CultureInfo.InvariantCulture); }
        if (s.Configured) { cboAuth.SelectedIndex = s.UseWindowsAuth ? 0 : 1; }
    }

    static string Ago(DateTime utc)
    {
        if (utc == DateTime.MinValue) { return "never run"; }
        double mins = (DateTime.UtcNow - utc).TotalMinutes;
        if (mins < 1) { return "just now"; }
        if (mins < 60) { return ((int)mins).ToString(CultureInfo.InvariantCulture) + " min ago"; }
        double hrs = mins / 60.0;
        if (hrs < 48) { return ((int)hrs).ToString(CultureInfo.InvariantCulture) + " h ago"; }
        return ((int)(hrs / 24)).ToString(CultureInfo.InvariantCulture) + " days ago";
    }

    // ------------------------------------------------------------ actions

    void SaveSettings()
    {
        string share = txtShare.Text.Trim();
        if (share.Length == 0)
        {
            MessageBox.Show("A share path is required before setup can run.", "SQL Express Backup",
                MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        StringBuilder a = new StringBuilder();
        a.Append("-Setup -SharePath ").Append(PsQuote(share));
        string staging = txtStaging.Text.Trim();
        if (staging.Length > 0) { a.Append(" -StagingPath ").Append(PsQuote(staging)); }
        a.Append(" -IntervalHours ").Append(SafeInt(txtInterval.Text, 6, 1, 168));
        a.Append(" -HourlyKeep ").Append(SafeInt(txtHourly.Text, 3, 1, 99));
        a.Append(" -DailyKeepDays ").Append(SafeInt(txtDaily.Text, 7, 1, 365));
        if (cboAuth.SelectedIndex == 0) { a.Append(" -UseWindowsAuth"); }
        RunEngine(a.ToString(), true, "setup");
    }

    // There is no server to bypass any more, so this dialog IS the boundary rather
    // than a convenience in front of one. It stays a typed phrase because this is
    // the action that creates a share, schedules a permanent job, and starts backing
    // up every database on the instance.
    void FullInstall()
    {
        using (FullInstallDialog d = new FullInstallDialog())
        {
            if (d.ShowDialog(this) != DialogResult.OK) { return; }
            StringBuilder a = new StringBuilder();
            a.Append("-FullInstall -ShareName ").Append(PsQuote(d.ShareName));
            a.Append(" -ShareFolder ").Append(PsQuote(d.ShareFolder));
            a.Append(" -IntervalHours ").Append(SafeInt(txtInterval.Text, 6, 1, 168));
            a.Append(" -HourlyKeep ").Append(SafeInt(txtHourly.Text, 3, 1, 99));
            a.Append(" -DailyKeepDays ").Append(SafeInt(txtDaily.Text, 7, 1, 365));
            RunEngine(a.ToString(), true, "full install");
        }
    }

    static string PsQuote(string s) { return "'" + s.Replace("'", "''") + "'"; }

    static string SafeInt(string s, int fallback, int min, int max)
    {
        int v;
        if (s == null || !int.TryParse(s.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) { v = fallback; }
        if (v < min) { v = min; }
        if (v > max) { v = max; }
        return v.ToString(CultureInfo.InvariantCulture);
    }

    void Say(string line)
    {
        if (InvokeRequired) { BeginInvoke(new Action<string>(Say), new object[] { line }); return; }
        // Progress markers drive the panel and stay OUT of the log. They are machine
        // lines; a log full of them is a log nobody reads.
        if (line != null && line.Length > 0 && line[0] == '[' && progress.Consume(line)) { return; }
        log.AppendText(DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + "  " + line + Environment.NewLine);
    }


    void SetBusy(bool value)
    {
        if (InvokeRequired) { BeginInvoke(new Action<bool>(SetBusy), new object[] { value }); return; }
        busy = value;
        if (!value) { progress.Finish("finished"); }
        btnSelfTest.Enabled = !value;
        btnRunNow.Enabled = !value;
        btnInstall.Enabled = !value;
        btnUninstall.Enabled = !value;
        btnFull.Enabled = !value;
        btnSave.Enabled = !value;
        Cursor = value ? Cursors.AppStarting : Cursors.Default;
        if (!value) { RefreshStatus(); }
    }

    void RunEngine(string engineArgs, bool needsAdmin, string label)
    {
        if (busy) { return; }

        // No PowerShell window, ever - but that is only possible when this process is
        // already elevated. Redirecting a child's output requires UseShellExecute
        // false, and launching it elevated requires UseShellExecute true, so the two
        // are mutually exclusive across a UAC boundary. Elevate the CONSOLE once and
        // every action after it runs hidden with its output streamed in here.
        if (needsAdmin && !amElevated)
        {
            DialogResult answer = MessageBox.Show(this,
                "This action needs administrator rights." + Environment.NewLine + Environment.NewLine +
                "Restart the console as administrator? Everything then runs inside this " +
                "window with no further prompts and no PowerShell windows." + Environment.NewLine + Environment.NewLine +
                "Backups already scheduled keep running either way.",
                "SQL Express Backup", MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
            if (answer == DialogResult.OK) { RelaunchElevated(); }
            return;
        }

        SetBusy(true);
        progress.Begin(label);
        Say("--- " + label + " ---");
        Thread t = new Thread(delegate () { EngineWorker(engineArgs); });
        t.IsBackground = true;
        t.Start();
    }

    void RelaunchElevated()
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(Application.ExecutablePath);
            psi.UseShellExecute = true;
            psi.Verb = "runas";
            Process.Start(psi);
            Close();
        }
        catch (System.ComponentModel.Win32Exception)
        {
            Say("the administrator prompt was dismissed - nothing was changed");
        }
    }

    void EngineWorker(string engineArgs)
    {
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell\\v1.0\\powershell.exe");
        try
        {
            // CreateNoWindow with redirected output - the reason this console had to
            // become elevated itself. Across a UAC boundary the two are mutually
            // exclusive, which is where the PowerShell windows came from.
            ProcessStartInfo psi = new ProcessStartInfo(ps,
                "-NoProfile -ExecutionPolicy Bypass -File \"" + SebApp.EnginePath + "\" " + engineArgs);
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;
            using (Process pr = Process.Start(psi))
            {
                pr.OutputDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) { Say(e.Data); } };
                pr.ErrorDataReceived += delegate (object s, DataReceivedEventArgs e) { if (e.Data != null) { Say(e.Data); } };
                pr.BeginOutputReadLine();
                pr.BeginErrorReadLine();
                pr.WaitForExit();
                Say("--- finished, exit code " + pr.ExitCode.ToString(CultureInfo.InvariantCulture) + " ---");
            }
        }
        catch (Exception ex) { Say("could not run the engine: " + ex.Message); }
        finally { SetBusy(false); }
    }

    // Read the whole file each pass and emit only what is new. Tracking a byte
    // offset looks tidier and is how the first version did it - it also disposed the
    // stream before reading Length, so the offset never advanced and every tick
    // reprinted the entire log.
    void TailInto(string path, Process child)
    {
        int emitted = 0;
        while (true)
        {
            try
            {
                if (File.Exists(path))
                {
                    string all;
                    using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    using (StreamReader sr = new StreamReader(fs)) { all = sr.ReadToEnd(); }
                    string[] lines = all.Replace("\r\n", "\n").Split('\n');
                    for (int i = emitted; i < lines.Length; i++)
                    {
                        if (i == lines.Length - 1 && lines[i].Length == 0) { break; }
                        Say(lines[i]);
                    }
                    if (lines.Length > 0) { emitted = lines.Length - (lines[lines.Length - 1].Length == 0 ? 1 : 0); }
                }
            }
            catch { }
            if (child.HasExited && emitted > 0) { break; }
            if (child.HasExited && !File.Exists(path)) { break; }
            Thread.Sleep(400);
        }
        try { File.Delete(path); } catch { }
    }
}

class FullInstallDialog : Form
{
    public string ShareName = "SqlBackups";
    public string ShareFolder = "C:\\SqlBackups";
    TextBox txtFolder, txtShare, txtConfirm;
    Button ok;

    public FullInstallDialog()
    {
        Text = "Full install";
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        StartPosition = FormStartPosition.CenterParent;
        Size = new Size(620, 400);
        BackColor = Theme.Bg;
        ForeColor = Theme.Ink;
        Font = Theme.UI(9f);

        Label head = new Label();
        head.Text = "This will, on " + Environment.MachineName + ":";
        head.Font = Theme.UI(10f, FontStyle.Bold);
        head.SetBounds(16, 14, 560, 22);

        Label steps = new Label();
        steps.Text =
            "1.  Create the folder below and share it from THIS host." + Environment.NewLine +
            "2.  Set up against that share using Windows authentication." + Environment.NewLine +
            "3.  Schedule EVERY database on the instance, as SYSTEM." + Environment.NewLine +
            "4.  Run one backup immediately, as SYSTEM, and report the result.";
        steps.SetBounds(20, 40, 570, 76);
        steps.ForeColor = Theme.Ink2;

        Label warn = new Label();
        warn.Text = "Every database is included, production ones too. A share on this host is NOT an " +
                    "offsite copy - if this disk dies the backups die with it.";
        warn.SetBounds(16, 118, 572, 38);
        warn.ForeColor = Theme.Warn;

        Label l1 = new Label(); l1.Text = "Folder to create and share"; l1.SetBounds(16, 164, 260, 18); l1.ForeColor = Theme.Ink3;
        txtFolder = new TextBox(); txtFolder.Text = ShareFolder; txtFolder.SetBounds(16, 184, 270, 24);
        Label l2 = new Label(); l2.Text = "Share name"; l2.SetBounds(300, 164, 260, 18); l2.ForeColor = Theme.Ink3;
        txtShare = new TextBox(); txtShare.Text = ShareName; txtShare.SetBounds(300, 184, 270, 24);

        Label l3 = new Label(); l3.Text = "Type FULL INSTALL to confirm"; l3.SetBounds(16, 220, 300, 18); l3.ForeColor = Theme.Ink3;
        txtConfirm = new TextBox(); txtConfirm.SetBounds(16, 240, 270, 24);
        txtConfirm.TextChanged += delegate { ok.Enabled = txtConfirm.Text.Trim() == "FULL INSTALL"; };

        ok = new Button();
        ok.Text = "Run full install";
        ok.SetBounds(300, 240, 140, 26);
        ok.Enabled = false;
        ok.FlatStyle = FlatStyle.Flat;
        ok.Click += delegate
        {
            ShareFolder = txtFolder.Text.Trim();
            ShareName = txtShare.Text.Trim();
            DialogResult = DialogResult.OK;
            Close();
        };

        Button cancel = new Button();
        cancel.Text = "Cancel";
        cancel.SetBounds(450, 240, 120, 26);
        cancel.FlatStyle = FlatStyle.Flat;
        cancel.Click += delegate { DialogResult = DialogResult.Cancel; Close(); };

        Label tail = new Label();
        tail.Text = "Windows will ask for an administrator after this.";
        tail.SetBounds(16, 288, 560, 20);
        tail.ForeColor = Theme.Ink3;

        Controls.AddRange(new Control[] { head, steps, warn, l1, txtFolder, l2, txtShare, l3, txtConfirm, ok, cancel, tail });
        AcceptButton = null;
        CancelButton = cancel;
    }
}
