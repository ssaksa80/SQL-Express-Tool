// SQL Express Backup - native Windows console.
//
// Compiled by build-app.ps1 with csc.exe, the C# compiler that ships with the .NET
// Framework on every Windows install. No SDK, no package restore, no network, and
// no runtime to install: WinForms is in the box. Keep this file to C# 4 - csc
// v4.0.30319 is the floor, so no string interpolation, no expression-bodied
// members, no async.
//
// WHY THERE IS NO WEB SERVER HERE ANY MORE
// The first version of this console served an HTML page from a loopback TcpListener
// and opened a browser. It worked, and it cost three security defects in a single
// session: the engine was extracted somewhere a non-admin could rewrite it while a
// SYSTEM task ran it, the capability token was written to a file that inherited a
// permissive profile ACL, and the whole surface had to be defended with a token
// compared in constant time on every route. A native window needs none of that.
// There is no listener, no token, no token file, and no page to lock down.
//
// WHAT THIS STILL HAS TO GET RIGHT
//   * The engine copy this runs is per-user. The copy the SCHEDULED task runs is
//     placed by the elevated install somewhere only SYSTEM and Administrators can
//     write - a task running as SYSTEM must never execute a file a standard user
//     can rewrite. See Copy-SebEngineForService in the engine.
//   * Elevated actions cannot have their stdout redirected across the UAC boundary,
//     so the child tees to a file and this tails it. The child's window is left
//     visible on purpose: -Setup with a SQL login prompts for a password, and that
//     prompt belongs in a real console.
//   * Glow marks STATE, never text anyone has to read. The pip and the card borders
//     glow; the log pane and every path never do. Same rule the stylesheet had, and
//     the same reason: this gets read during a change window.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;
using System.Windows.Forms;

// ---------------------------------------------------------------- theme

static class Theme
{
    public static bool Dark = false;

    public static Color Bg { get { return Dark ? Color.FromArgb(14, 20, 24) : Color.FromArgb(244, 246, 248); } }
    public static Color Panel { get { return Dark ? Color.FromArgb(21, 29, 35) : Color.White; } }
    public static Color Ink { get { return Dark ? Color.FromArgb(230, 237, 242) : Color.FromArgb(22, 35, 43); } }
    public static Color Ink2 { get { return Dark ? Color.FromArgb(169, 188, 200) : Color.FromArgb(64, 82, 96); } }
    public static Color Ink3 { get { return Dark ? Color.FromArgb(125, 145, 158) : Color.FromArgb(107, 127, 141); } }
    public static Color Line { get { return Dark ? Color.FromArgb(36, 49, 58) : Color.FromArgb(216, 224, 230); } }
    public static Color Steel { get { return Dark ? Color.FromArgb(143, 196, 224) : Color.FromArgb(44, 74, 92); } }
    public static Color Ok { get { return Dark ? Color.FromArgb(79, 209, 160) : Color.FromArgb(28, 122, 82); } }
    public static Color Warn { get { return Dark ? Color.FromArgb(232, 180, 79) : Color.FromArgb(154, 98, 18); } }
    public static Color Bad { get { return Dark ? Color.FromArgb(255, 128, 128) : Color.FromArgb(163, 42, 42); } }

    public static Color ToneColor(string tone)
    {
        if (tone == "ok") { return Ok; }
        if (tone == "partial") { return Warn; }
        if (tone == "failed") { return Bad; }
        return Ink3;
    }

    public static void Load()
    {
        try
        {
            string p = Path.Combine(SebApp.UserDir, "ui.txt");
            if (File.Exists(p)) { Dark = File.ReadAllText(p).Trim().ToLowerInvariant() == "dark"; }
            else { Dark = SystemPrefersDark(); }
        }
        catch { Dark = false; }
    }

    public static void Save()
    {
        try { File.WriteAllText(Path.Combine(SebApp.UserDir, "ui.txt"), Dark ? "dark" : "light"); } catch { }
    }

    // Follow the OS the first time, then remember what the operator chose.
    static bool SystemPrefersDark()
    {
        try
        {
            object v = Microsoft.Win32.Registry.GetValue(
                @"HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize",
                "AppsUseLightTheme", 1);
            if (v != null) { return Convert.ToInt32(v, CultureInfo.InvariantCulture) == 0; }
        }
        catch { }
        return false;
    }
}

// ---------------------------------------------------------------- painted bits

// A state light. This is the only element that is purely a signal, so it carries
// the strongest glow - and it is the one thing on screen you can read from across
// a room while something else has your attention.
class Pip : Control
{
    string tone = "unknown";
    float pulse = 0f;
    System.Windows.Forms.Timer timer;

    public Pip()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        Size = new Size(18, 18);
        timer = new System.Windows.Forms.Timer();
        timer.Interval = 33;
        timer.Tick += new EventHandler(OnTick);
    }

    public void SetTone(string value)
    {
        if (tone == value) { return; }
        tone = value;
        pulse = 1f;                 // only on CHANGE - a light that pulses forever is wallpaper
        if (!timer.Enabled) { timer.Start(); }
        Invalidate();
    }

    void OnTick(object sender, EventArgs e)
    {
        pulse -= 0.05f;
        if (pulse <= 0f) { pulse = 0f; timer.Stop(); }
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Color c = Theme.ToneColor(tone);
        int cx = Width / 2, cy = Height / 2;
        int r = 5;
        if (tone != "unknown")
        {
            int rings = 3;
            for (int i = rings; i >= 1; i--)
            {
                int spread = (int)(i * 3 + pulse * 6);
                int alpha = (int)((40 - i * 8) + pulse * 60);
                if (alpha < 0) { alpha = 0; }
                if (alpha > 255) { alpha = 255; }
                using (SolidBrush b = new SolidBrush(Color.FromArgb(alpha, c)))
                {
                    g.FillEllipse(b, cx - r - spread, cy - r - spread, (r + spread) * 2, (r + spread) * 2);
                }
            }
        }
        using (SolidBrush b = new SolidBrush(c)) { g.FillEllipse(b, cx - r, cy - r, r * 2, r * 2); }
    }
}

// A status card. The border and its halo carry the tone; the text never does.
class Card : Panel
{
    public string Eyebrow = "";
    public string Big = "";
    public string Sub = "";
    string tone = "unknown";
    float glow = 0f;
    System.Windows.Forms.Timer timer;

    public Card()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        timer = new System.Windows.Forms.Timer();
        timer.Interval = 33;
        timer.Tick += new EventHandler(OnTick);
    }

    public void SetTone(string value)
    {
        if (tone == value) { return; }
        tone = value;
        glow = 1f;
        if (!timer.Enabled) { timer.Start(); }
        Invalidate();
    }

    void OnTick(object sender, EventArgs e)
    {
        glow -= 0.04f;
        if (glow <= 0f) { glow = 0f; timer.Stop(); }
        Invalidate();
    }

    public void Update(string big, string sub) { Big = big; Sub = sub; Invalidate(); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = new Rectangle(1, 1, Width - 3, Height - 3);
        bool toned = tone != "unknown";
        Color edge = toned ? Theme.ToneColor(tone) : Theme.Line;

        using (GraphicsPath path = Rounded(r, 8))
        {
            using (SolidBrush b = new SolidBrush(Theme.Panel)) { g.FillPath(b, path); }
            if (toned)
            {
                for (int i = 3; i >= 1; i--)
                {
                    int a = (int)((14 - i * 3) + glow * 40);
                    if (a < 0) { a = 0; }
                    if (a > 255) { a = 255; }
                    using (Pen p = new Pen(Color.FromArgb(a, edge), i * 2))
                    using (GraphicsPath gp = Rounded(Rectangle.Inflate(r, i, i), 8 + i)) { g.DrawPath(p, gp); }
                }
            }
            using (Pen p = new Pen(edge, 1f)) { g.DrawPath(p, path); }
        }

        using (SolidBrush b = new SolidBrush(Theme.Ink3))
        using (Font f = new Font("Segoe UI", 7.5f, FontStyle.Bold))
        {
            g.DrawString(Eyebrow.ToUpperInvariant(), f, b, 13, 11);
        }
        using (SolidBrush b = new SolidBrush(Theme.Ink))
        using (Font f = new Font("Segoe UI", Big.Length > 18 ? 10f : 17f, FontStyle.Bold))
        {
            g.DrawString(Big, f, b, new RectangleF(12, 26, Width - 22, 30));
        }
        using (SolidBrush b = new SolidBrush(Theme.Ink3))
        using (Font f = new Font("Segoe UI", 8f))
        {
            g.DrawString(Sub, f, b, new RectangleF(13, Height - 24, Width - 22, 20));
        }
    }

    internal static GraphicsPath Rounded(Rectangle r, int radius)
    {
        GraphicsPath p = new GraphicsPath();
        int d = radius * 2;
        if (d > r.Width) { d = r.Width; }
        if (d > r.Height) { d = r.Height; }
        p.AddArc(r.X, r.Y, d, d, 180, 90);
        p.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        p.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        p.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        p.CloseFigure();
        return p;
    }
}

// An action button. Hover lifts the border; nothing here pulses on its own.
class ActionButton : Button
{
    public string Why = "";
    public bool Danger = false;
    bool hot = false;

    public ActionButton()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        Height = 62;
    }

    protected override void OnMouseEnter(EventArgs e) { hot = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hot = false; Invalidate(); base.OnMouseLeave(e); }

    protected override void OnPaint(PaintEventArgs e)
    {
        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        Rectangle r = new Rectangle(1, 1, Width - 3, Height - 3);
        Color edge = Theme.Line;
        if (hot && Enabled) { edge = Danger ? Theme.Bad : Theme.Steel; }

        using (GraphicsPath path = Card.Rounded(r, 7))
        {
            using (SolidBrush b = new SolidBrush(Theme.Bg)) { g.FillPath(b, path); }
            if (hot && Enabled)
            {
                for (int i = 3; i >= 1; i--)
                {
                    using (Pen p = new Pen(Color.FromArgb(16 - i * 3, edge), i * 2))
                    using (GraphicsPath gp = Card.Rounded(Rectangle.Inflate(r, i, i), 7 + i)) { g.DrawPath(p, gp); }
                }
            }
            using (Pen p = new Pen(edge, 1f)) { g.DrawPath(p, path); }
        }

        Color ink = Enabled ? Theme.Ink : Theme.Ink3;
        using (SolidBrush b = new SolidBrush(ink))
        using (Font f = new Font("Segoe UI", 9.5f, FontStyle.Bold)) { g.DrawString(Text, f, b, 12, 9); }
        using (SolidBrush b = new SolidBrush(Theme.Ink3))
        using (Font f = new Font("Segoe UI", 8f))
        {
            g.DrawString(Why, f, b, new RectangleF(12, 27, Width - 22, Height - 30));
        }
    }
}

// ---------------------------------------------------------------- status

class DbRow
{
    public string Name = "";
    public int Hourly = 0;
    public int Daily = 0;
    public DateTime Newest = DateTime.MinValue;
}

class Status
{
    public string HostName = "";
    public string Instance = "";
    public string SharePath = "";
    public string StagingPath = "";
    public int IntervalHours = 6;
    public int HourlyKeep = 3;
    public int DailyKeepDays = 7;
    public bool UseWindowsAuth = true;
    public string LastResult = "";
    public DateTime LastRunUtc = DateTime.MinValue;
    public int PendingCount = 0;
    public bool Configured = false;
    public string ScheduleState = "absent";
    public string ScheduleNext = "";
    public string ScheduleSub = "";
    public string ShareNote = "";
    public List<DbRow> Databases = new List<DbRow>();

    public static Status Read()
    {
        Status s = new Status();
        Dictionary<string, string> p = ReadPublic();
        s.HostName = Pick(p, "HostName");
        if (string.IsNullOrEmpty(s.HostName)) { s.HostName = Environment.MachineName; }
        s.Instance = Pick(p, "DataSource");
        s.SharePath = Pick(p, "SharePath");
        s.StagingPath = Pick(p, "StagingPath");
        s.IntervalHours = Num(Pick(p, "IntervalHours"), 6);
        s.HourlyKeep = Num(Pick(p, "HourlyKeep"), 3);
        s.DailyKeepDays = Num(Pick(p, "DailyKeepDays"), 7);
        string wa = Pick(p, "UseWindowsAuth");
        s.UseWindowsAuth = string.IsNullOrEmpty(wa) || wa.ToLowerInvariant() == "true";
        s.LastResult = Pick(p, "LastResult");
        s.PendingCount = Num(Pick(p, "PendingCount"), 0);
        s.Configured = !string.IsNullOrEmpty(s.SharePath);
        DateTime parsed;
        if (DateTime.TryParse(Pick(p, "LastRunUtc"), CultureInfo.InvariantCulture,
                DateTimeStyles.AdjustToUniversal | DateTimeStyles.AssumeUniversal, out parsed)) { s.LastRunUtc = parsed; }

        ReadSchedule(s);
        ReadShare(s, Pick(p, "InstanceName"));
        return s;
    }

    static string Pick(Dictionary<string, string> d, string k) { string v; return d.TryGetValue(k, out v) ? v : null; }

    static int Num(string s, int fallback)
    {
        int v;
        if (s != null && int.TryParse(s.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) { return v; }
        return fallback;
    }

    // config.json is locked to SYSTEM and Administrators because it sits beside a
    // sealed credential. public.json holds only the non-secret keys and is written
    // for exactly this: a dashboard that must work without elevation.
    static Dictionary<string, string> ReadPublic()
    {
        Dictionary<string, string> d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string path = Path.Combine(SebApp.StateDir, "public.json");
        string text;
        try { if (!File.Exists(path)) { return d; } text = File.ReadAllText(path); }
        catch { return d; }

        int i = 0;
        while (i < text.Length)
        {
            int ks = text.IndexOf('"', i);
            if (ks < 0) { break; }
            int ke = text.IndexOf('"', ks + 1);
            if (ke < 0) { break; }
            string key = text.Substring(ks + 1, ke - ks - 1);
            int colon = text.IndexOf(':', ke);
            if (colon < 0) { break; }
            int p = colon + 1;
            while (p < text.Length && char.IsWhiteSpace(text[p])) { p++; }
            if (p >= text.Length) { break; }
            string val;
            if (text[p] == '"')
            {
                StringBuilder sb = new StringBuilder();
                int ve = p + 1;
                while (ve < text.Length && text[ve] != '"')
                {
                    if (text[ve] == '\\' && ve + 1 < text.Length) { ve++; sb.Append(text[ve] == 'n' ? '\n' : text[ve]); }
                    else { sb.Append(text[ve]); }
                    ve++;
                }
                val = sb.ToString();
                i = ve + 1;
            }
            else
            {
                int ve = p;
                while (ve < text.Length && text[ve] != ',' && text[ve] != '}' && text[ve] != '\r' && text[ve] != '\n') { ve++; }
                val = text.Substring(p, ve - p).Trim();
                i = ve;
            }
            d[key] = val;
        }
        return d;
    }

    // A task registered to run as SYSTEM is not readable by a standard user, so
    // schtasks failing does NOT mean the task is missing. Saying "absent" there
    // would tell an operator their backups are not scheduled while they run fine.
    static void ReadSchedule(Status s)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo("schtasks.exe", "/query /tn \"" + SebApp.TaskName + "\" /fo LIST");
            psi.UseShellExecute = false;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.CreateNoWindow = true;
            using (Process pr = Process.Start(psi))
            {
                string outText = pr.StandardOutput.ReadToEnd();
                string errText = pr.StandardError.ReadToEnd();
                pr.WaitForExit(8000);
                if (pr.ExitCode != 0)
                {
                    if (errText != null && errText.IndexOf("Access is denied", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        s.ScheduleState = "installed?";
                        s.ScheduleSub = "needs an administrator to read";
                    }
                    else { s.ScheduleState = "absent"; s.ScheduleSub = "not installed"; }
                    return;
                }
                foreach (string line in outText.Split('\n'))
                {
                    int c = line.IndexOf(':');
                    if (c <= 0) { continue; }
                    string k = line.Substring(0, c).Trim();
                    string v = line.Substring(c + 1).Trim();
                    if (k.Equals("Status", StringComparison.OrdinalIgnoreCase)) { s.ScheduleState = v; }
                    else if (k.Equals("Next Run Time", StringComparison.OrdinalIgnoreCase)) { s.ScheduleNext = v; }
                }
            }
        }
        catch { s.ScheduleState = "unknown"; }
    }

    static void ReadShare(Status s, string instanceName)
    {
        if (string.IsNullOrEmpty(s.SharePath)) { s.ShareNote = "No share configured yet."; return; }
        string root = Path.Combine(Path.Combine(s.SharePath, s.HostName), instanceName == null ? "" : instanceName);
        try
        {
            string[] dbs = Directory.GetDirectories(root);
            Array.Sort(dbs);
            foreach (string dbDir in dbs)
            {
                DbRow r = new DbRow();
                r.Name = Path.GetFileName(dbDir);
                r.Hourly = CountBaks(Path.Combine(dbDir, "hourly"));
                r.Daily = CountBaks(Path.Combine(dbDir, "daily"));
                r.Newest = NewestStamp(Path.Combine(dbDir, "hourly"));
                s.Databases.Add(r);
            }
            if (s.Databases.Count == 0) { s.ShareNote = "Nothing backed up to the share for this instance yet."; }
        }
        catch (UnauthorizedAccessException)
        {
            // Not the same fact as "empty", and a status page must not confuse them.
            // Short enough to fit the strip. The long version ran off the edge and the
            // operator lost the half that said what to do about it.
            s.ShareNote = "Backups exist; this account cannot read them. Run as administrator for the per-database detail.";
        }
        catch (DirectoryNotFoundException) { s.ShareNote = "Nothing on the share for this host and instance yet: " + root; }
        catch (IOException ex) { s.ShareNote = "The share is not reachable right now: " + ex.Message; }
    }

    static int CountBaks(string dir)
    {
        try { return Directory.Exists(dir) ? Directory.GetFiles(dir, "*.bak").Length : 0; }
        catch { return 0; }
    }

    // The stamp comes out of the NAME, exactly as the engine's retention does:
    // copying to a share can rewrite LastWriteTime, and then "newest" is a lie.
    static DateTime NewestStamp(string dir)
    {
        DateTime best = DateTime.MinValue;
        try
        {
            if (!Directory.Exists(dir)) { return best; }
            foreach (string f in Directory.GetFiles(dir, "*.bak"))
            {
                string n = Path.GetFileNameWithoutExtension(f);
                int u = n.LastIndexOf('_');
                if (u < 0 || n.Length - u - 1 != 15) { continue; }
                DateTime parsed;
                if (DateTime.TryParseExact(n.Substring(u + 1), "yyyyMMdd-HHmmss",
                        CultureInfo.InvariantCulture, DateTimeStyles.None, out parsed))
                {
                    if (parsed > best) { best = parsed; }
                }
            }
        }
        catch { }
        return best;
    }
}
