// Drives the proven PowerShell engine and reads its published status. The WPF shell
// owns none of the backup/restore logic - it invokes the same modes the WinForms
// console does, so there is one implementation of the work, not two.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Text;
using System.Web.Script.Serialization;

class BackupStatus
{
    public bool Found = false;
    public string Host = "";
    public string Instance = "";
    public string DataSource = "";
    public string SharePath = "";
    public int IntervalHours = 6;
    public string LastResult = "";
    public string LastRunUtc = "";
    public int PendingCount = 0;
    // The configured settings, from public.json's allow-list, so a reconfigure starts from
    // what is set rather than from defaults that would quietly overwrite it.
    public string StagingPath = "";
    public int HourlyKeep = 3;
    public int DailyKeepDays = 7;
    public string RecoveryMode = "Simple";
    public int LogIntervalMinutes = 15;
    public int FullEveryHours = 24;
    public bool CompressBackups = false;
    public bool UseWindowsAuth = true;
    // Alerting: the settings, whether each secret is stored (never the secret itself -
    // the app cannot read alert.dat, by design), and what is open right now.
    public string AlertEmailTo = "", AlertEmailFrom = "", AlertSmtpHost = "", AlertSmtpUser = "", AlertWebhookKind = "";
    public int AlertSmtpPort = 587, AlertRemindHours = 24, AlertStaleHours = 0, AlertPendingMinutes = 60;
    public bool AlertSmtpTls = true, AlertHasSmtpPassword = false, AlertHasWebhook = false, AlertHasHeartbeat = false;
    public List<OpenAlert> OpenAlerts = new List<OpenAlert>();
    // Restore testing: whether the daily test is on, when, and each database's last result.
    public bool RestoreTesting = false;
    public string RestoreTestTime = "03:30";
    public List<RestoreTestResult> RestoreTests = new List<RestoreTestResult>();
    // Encryption: on for new backups, and the key they use (an id, never key material).
    public bool EncryptBackups = false;
    public string ActiveKeyId = "";
}

class RestoreTestResult
{
    public string Database = "";
    public string Result = "";
    public string Message = "";
    public string LastUtc = "";
    public string RecoveredToUtc = "";
    public int DurationSeconds = 0;
}

class OpenAlert
{
    public string Key = "";
    public string Severity = "";
    public string Message = "";
    public string SinceUtc = "";
}

class RestoreSet
{
    public string Database = "";
    public string Kind = "";
    public string Path = "";
    public long Bytes = 0;
    public string TakenUtc = "";
}

static class Engine
{
    // The engine script, found in the locations it can live: beside the exe (portable
    // or installed), the per-user extraction the console uses, or the ProgramData copy
    // the scheduled task runs.
    static string enginePath;
    // Pin the engine this process runs (an elevated job's admin-only copy), bypassing the
    // per-mode lookup below entirely.
    public static void UseEngine(string path) { enginePath = path; }
    public static string FindEngine()
    {
        if (enginePath != null) { return enginePath; }
        // The exe carries the engine embedded; extract it for the current mode. Fall
        // back to any copy already on disk (e.g. the console's per-user extraction).
        try { enginePath = Install.EnsureEngine(AppSettings.Mode); } catch { }
        if (enginePath != null && File.Exists(enginePath)) { return enginePath; }
        try
        {
            string exeDir = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
            string[] fallbacks = new string[] {
                Path.Combine(exeDir, "Invoke-SqlExpressBackup.ps1"),
                Path.Combine(Path.Combine(exeDir, "engine"), "Invoke-SqlExpressBackup.ps1"),
                Path.Combine(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                    "SqlExpressBackup"), Path.Combine("engine", "Invoke-SqlExpressBackup.ps1"))
            };
            foreach (string c in fallbacks) { if (File.Exists(c)) { enginePath = c; return c; } }
        }
        catch { }
        return enginePath;
    }

    static string PublicJsonPath()
    {
        return Path.Combine(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "SqlExpressBackup"), "public.json");
    }

    // Status is read from the published summary rather than by running the engine -
    // it needs no elevation and no SQL round-trip, which is what the console does too.
    public static BackupStatus ReadStatus()
    {
        BackupStatus s = new BackupStatus();
        try
        {
            string p = PublicJsonPath();
            if (!File.Exists(p)) { return s; }
            JavaScriptSerializer js = new JavaScriptSerializer();
            Dictionary<string, object> d = js.Deserialize<Dictionary<string, object>>(File.ReadAllText(p));
            if (d == null) { return s; }
            s.Found = true;
            s.Host = Str(d, "HostName");
            s.Instance = Str(d, "InstanceName");
            s.DataSource = Str(d, "DataSource");
            s.SharePath = Str(d, "SharePath");
            s.LastResult = Str(d, "LastResult");
            s.LastRunUtc = Str(d, "LastRunUtc");
            s.IntervalHours = Int(d, "IntervalHours", 6);
            s.PendingCount = Int(d, "PendingCount", 0);
            s.StagingPath = Str(d, "StagingPath");
            s.HourlyKeep = Int(d, "HourlyKeep", 3);
            s.DailyKeepDays = Int(d, "DailyKeepDays", 7);
            string rm = Str(d, "RecoveryMode");
            s.RecoveryMode = string.Equals(rm, "Full", StringComparison.OrdinalIgnoreCase) ? "Full" : "Simple";
            s.LogIntervalMinutes = Int(d, "LogIntervalMinutes", 15);
            s.FullEveryHours = Int(d, "FullEveryHours", 24);
            s.CompressBackups = Bool(d, "CompressBackups");
            s.UseWindowsAuth = !d.ContainsKey("UseWindowsAuth") || Bool(d, "UseWindowsAuth");
            s.AlertEmailTo = Str(d, "AlertEmailTo"); s.AlertEmailFrom = Str(d, "AlertEmailFrom");
            s.AlertSmtpHost = Str(d, "AlertSmtpHost"); s.AlertSmtpUser = Str(d, "AlertSmtpUser");
            s.AlertWebhookKind = Str(d, "AlertWebhookKind");
            s.AlertSmtpPort = Int(d, "AlertSmtpPort", 587); s.AlertRemindHours = Int(d, "AlertRemindHours", 24);
            s.AlertStaleHours = Int(d, "AlertStaleHours", 0); s.AlertPendingMinutes = Int(d, "AlertPendingMinutes", 60);
            s.AlertSmtpTls = !d.ContainsKey("AlertSmtpTls") || Bool(d, "AlertSmtpTls");
            s.AlertHasSmtpPassword = Bool(d, "AlertHasSmtpPassword");
            s.AlertHasWebhook = Bool(d, "AlertHasWebhook");
            s.AlertHasHeartbeat = Bool(d, "AlertHasHeartbeat");
            s.EncryptBackups = Bool(d, "EncryptBackups");
            s.ActiveKeyId = Str(d, "ActiveKeyId");
            s.RestoreTesting = Bool(d, "RestoreTesting");
            string rtt = Str(d, "RestoreTestTime");
            if (rtt.Length == 5) { s.RestoreTestTime = rtt; }
            foreach (IDictionary<string, object> t in Rows(d, "RestoreTests"))
            {
                RestoreTestResult r = new RestoreTestResult();
                r.Database = DStr(t, "Database"); r.Result = DStr(t, "Result"); r.Message = DStr(t, "Message");
                r.LastUtc = DStr(t, "LastUtc"); r.RecoveredToUtc = DStr(t, "RecoveredToUtc");
                try { if (t.ContainsKey("DurationSeconds") && t["DurationSeconds"] != null) { r.DurationSeconds = Convert.ToInt32(t["DurationSeconds"]); } } catch { }
                s.RestoreTests.Add(r);
            }
            // PowerShell can write a one-element array as the bare object; take either shape.
            object rawAlerts = d.ContainsKey("Alerts") ? d["Alerts"] : null;
            if (rawAlerts is IDictionary<string, object>) { rawAlerts = new object[] { rawAlerts }; }
            System.Collections.IEnumerable alerts = rawAlerts as System.Collections.IEnumerable;
            if (alerts != null && !(alerts is string))
            {
                foreach (object o in alerts)
                {
                    IDictionary<string, object> a = o as IDictionary<string, object>;
                    if (a == null) { continue; }
                    OpenAlert oa = new OpenAlert();
                    oa.Key = DStr(a, "Key"); oa.Severity = DStr(a, "Severity"); oa.Message = DStr(a, "Message"); oa.SinceUtc = DStr(a, "SinceUtc");
                    s.OpenAlerts.Add(oa);
                }
            }
        }
        catch { }
        return s;
    }

    // Run an engine mode hidden and hand each output line to a callback (for live
    // progress markers). Blocks until exit; callers run it on a worker thread.
    public static int Run(string args, Action<string> onLine)
    {
        string eng = FindEngine();
        if (eng == null) { if (onLine != null) { onLine("[ERROR] backup engine not found"); } return 9; }

        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell\\v1.0\\powershell.exe");
        ProcessStartInfo psi = new ProcessStartInfo(ps);
        psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File \"" + eng + "\" " + args;
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        // the engine writes UTF-8 when redirected; the default (ANSI) mangled any non-ASCII database name
        psi.StandardOutputEncoding = System.Text.Encoding.UTF8; psi.StandardErrorEncoding = System.Text.Encoding.UTF8;
        psi.CreateNoWindow = true;

        using (Process p = Process.Start(psi))
        {
            p.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null && onLine != null) { onLine(e.Data); } };
            p.ErrorDataReceived += delegate(object sender, DataReceivedEventArgs e) { if (e.Data != null && onLine != null) { onLine(e.Data); } };
            p.BeginOutputReadLine();
            p.BeginErrorReadLine();
            p.WaitForExit();
            return p.ExitCode;
        }
    }

    // One command-line argument, quoted by the rules powershell.exe -File parses with
    // (CommandLineToArgvW): a quote is escaped as \", and backslashes are doubled only
    // where they precede a quote. A bare "\"" + value + "\"" broke on the ordinary case of
    // a folder typed with a trailing backslash - D:\SQLData\ escaped its own closing quote
    // and swallowed every flag after it - and dropped any quote inside a database name.
    public static string QuoteArg(string s)
    {
        if (s == null) { s = ""; }
        StringBuilder b = new StringBuilder("\"");
        int slashes = 0;
        foreach (char c in s)
        {
            if (c == '\\') { slashes++; continue; }
            if (c == '"') { b.Append('\\', slashes * 2 + 1); }
            else { b.Append('\\', slashes); }
            slashes = 0;
            b.Append(c);
        }
        b.Append('\\', slashes * 2);
        b.Append('"');
        return b.ToString();
    }

    // Enumerate backup sets. Returns an empty list on any failure rather than throwing.
    public static List<RestoreSet> RestoreList()
    {
        List<RestoreSet> result = new List<RestoreSet>();
        StringBuilder all = new StringBuilder();
        Run("-RestoreList", delegate(string line) { all.AppendLine(line); });
        string json = LastJsonLine(all.ToString());
        if (json == null) { return result; }
        try
        {
            JavaScriptSerializer js = new JavaScriptSerializer();
            js.MaxJsonLength = 64 * 1024 * 1024;
            Dictionary<string, object> d = js.Deserialize<Dictionary<string, object>>(json);
            object raw = d != null && d.ContainsKey("Sets") ? d["Sets"] : null;
            // JavaScriptSerializer hands a JSON array back as an ArrayList, not object[]
            // - checking for object[] specifically was why this silently returned
            // nothing. Iterate anything enumerable and read each row through IDictionary.
            System.Collections.IEnumerable seq = raw as System.Collections.IEnumerable;
            if (seq != null)
            {
                foreach (object o in seq)
                {
                    System.Collections.Generic.IDictionary<string, object> row = o as System.Collections.Generic.IDictionary<string, object>;
                    if (row == null) { continue; }
                    RestoreSet r = new RestoreSet();
                    r.Database = DStr(row, "Database"); r.Kind = DStr(row, "Kind");
                    r.Path = DStr(row, "Path"); r.TakenUtc = DStr(row, "TakenUtc");
                    try { if (row.ContainsKey("Bytes")) { r.Bytes = Convert.ToInt64(row["Bytes"]); } } catch { }
                    result.Add(r);
                }
            }
        }
        catch { }
        return result;
    }

    // Inspect a backup file: readability pre-check, header, file list. Returns the
    // parsed dictionary (Readable, Database, Compressed, Files, ...) or null.
    public static Dictionary<string, object> RestoreInspect(string path)
    {
        StringBuilder all = new StringBuilder();
        Run("-RestoreInspect " + QuoteArg(path), delegate(string line) { all.AppendLine(line); });
        string json = LastJsonLine(all.ToString());
        if (json == null) { return null; }
        try
        {
            JavaScriptSerializer js = new JavaScriptSerializer();
            js.MaxJsonLength = 64 * 1024 * 1024;
            return js.Deserialize<Dictionary<string, object>>(json);
        }
        catch { return null; }
    }

    // Verify media (RESTORE VERIFYONLY WITH CHECKSUM). Returns true on Ok.
    public static bool RestoreVerify(string path, out string error)
    {
        error = "";
        StringBuilder all = new StringBuilder();
        Run("-RestoreVerify " + QuoteArg(path), delegate(string line) { all.AppendLine(line); });
        string json = LastJsonLine(all.ToString());
        if (json == null) { error = "no response from engine"; return false; }
        try
        {
            JavaScriptSerializer js = new JavaScriptSerializer();
            Dictionary<string, object> d = js.Deserialize<Dictionary<string, object>>(json);
            bool ok = d != null && d.ContainsKey("Ok") && Convert.ToBoolean(d["Ok"]);
            if (!ok && d != null && d.ContainsKey("Error")) { error = Convert.ToString(d["Error"]); }
            return ok;
        }
        catch (Exception ex) { error = ex.Message; return false; }
    }

    // Point-in-time restore: <src> -> a new database <asName>, replayed up to the local
    // wall-clock moment <stopAt>. Unelevated - same restore context as RestoreRun/RestoreList
    // (reads public.json, no UAC) - so this calls Run() directly exactly like they do.
    // Streams every line to onLine as it arrives (the [STAGE]/[PROGRESS] markers, and on
    // failure the engine's own [ERROR] line naming the reason - a bounded/gap target, a
    // missing backup, etc). -RestoreToPoint prints a final {"Ok":true,...} line ONLY on
    // success; a validation failure throws inside the engine before that line is ever
    // written, so success here is never assumed from the process just having run - it is
    // read back off that final JSON line, the same way RestoreVerify reads "Ok" above.
    public static bool RestoreToPoint(string src, string asName, DateTime stopAt, bool replace, Action<string> onLine)
    {
        string args = "-RestoreToPoint -Database " + QuoteArg(src) + " -RestoreAs " + QuoteArg(asName) +
            " -StopAt " + QuoteArg(stopAt.ToString("yyyy-MM-ddTHH:mm:ss", System.Globalization.CultureInfo.InvariantCulture));
        if (replace) { args += " -RestoreReplace"; }

        StringBuilder all = new StringBuilder();
        Run(args, delegate(string line)
        {
            all.AppendLine(line);
            if (onLine != null) { onLine(line); }
        });
        string json = LastJsonLine(all.ToString());
        if (json == null) { return false; }
        try
        {
            JavaScriptSerializer js = new JavaScriptSerializer();
            Dictionary<string, object> d = js.Deserialize<Dictionary<string, object>>(json);
            return d != null && d.ContainsKey("Ok") && Convert.ToBoolean(d["Ok"]);
        }
        catch { return false; }
    }

    // Discover the SQL Server instances on this host by reading the registry - the same
    // source SQL Server Browser and the engine use. Value names under Instance Names\SQL
    // are the instance names: "MSSQLSERVER" is the default instance, anything else (e.g.
    // "SQLEXPRESS") is a named instance. Registry-only, so it needs no elevation and no
    // SQL round-trip - safe to call while building the setup form.
    public static List<string> DiscoverInstances()
    {
        List<string> names = new List<string>();
        string[] keys = new string[] {
            @"SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL",
            @"SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server\Instance Names\SQL"
        };
        foreach (string k in keys)
        {
            try
            {
                using (Microsoft.Win32.RegistryKey rk = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(k))
                {
                    if (rk == null) { continue; }
                    foreach (string vn in rk.GetValueNames())
                    {
                        if (!string.IsNullOrEmpty(vn) && !names.Contains(vn)) { names.Add(vn); }
                    }
                }
            }
            catch { }
        }
        return names;
    }

    // The engine's log directory: %ProgramData%\SqlExpressBackup\logs, holding one
    // backup-YYYYMM.log per month (line format: "yyyy-MM-dd HH:mm:ss [LEVEL] message").
    public static string LogDir()
    {
        return Path.Combine(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            "SqlExpressBackup"), "logs");
    }

    // Recent engine log lines, newest last. When dbFilter is set, only lines mentioning
    // that database are returned - but if that yields nothing, the recent tail is
    // returned instead, so a click on a set always shows something rather than a blank
    // pane. Reads the two newest monthly files so a set from last month is still covered,
    // and shares the file with the writer (the scheduled task may hold it open).
    public static List<string> ReadLog(string dbFilter, int maxLines)
    {
        List<string> lines = new List<string>();
        try
        {
            string dir = LogDir();
            if (!Directory.Exists(dir)) { return lines; }
            string[] files = Directory.GetFiles(dir, "backup-*.log");
            Array.Sort(files, StringComparer.Ordinal); // yyyyMM names sort oldest->newest
            int take = files.Length > 2 ? 2 : files.Length;
            List<string> all = new List<string>();
            for (int i = files.Length - take; i < files.Length; i++)
            {
                foreach (string ln in ReadLinesShared(files[i])) { all.Add(ln); }
            }
            List<string> filtered = all;
            if (!string.IsNullOrEmpty(dbFilter))
            {
                // Word-boundary match, not a raw substring: filtering "APPDB" must not also
                // pull in "APPDB_Restore" lines. \b treats the underscore as a word character,
                // so the boundary falls only at real edges (space, backslash, end).
                System.Text.RegularExpressions.Regex rx = new System.Text.RegularExpressions.Regex(
                    "\\b" + System.Text.RegularExpressions.Regex.Escape(dbFilter) + "\\b",
                    System.Text.RegularExpressions.RegexOptions.IgnoreCase);
                List<string> hit = new List<string>();
                foreach (string ln in all)
                {
                    if (rx.IsMatch(ln)) { hit.Add(ln); }
                }
                if (hit.Count > 0) { filtered = hit; }
            }
            int start = filtered.Count - maxLines; if (start < 0) { start = 0; }
            for (int i = start; i < filtered.Count; i++) { lines.Add(filtered[i]); }
        }
        catch { }
        return lines;
    }

    static string[] ReadLinesShared(string path)
    {
        List<string> ls = new List<string>();
        try
        {
            using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
            using (StreamReader sr = new StreamReader(fs))
            {
                string line;
                while ((line = sr.ReadLine()) != null) { ls.Add(line); }
            }
        }
        catch { }
        return ls.ToArray();
    }

    // Read one string field from a parsed dictionary (helper for callers).
    public static string Field(Dictionary<string, object> d, string k) { return Str(d, k); }
    public static bool FieldBool(Dictionary<string, object> d, string k)
    {
        try { if (d != null && d.ContainsKey(k) && d[k] != null) { return Convert.ToBoolean(d[k]); } } catch { }
        return false;
    }

    // Whether an engine result line reads {"Ok":true,...}. A missing or unparseable line is
    // a failure, never a success - the engine prints it last, only when it got that far.
    public static bool JsonOk(string json)
    {
        if (json == null) { return false; }
        try
        {
            Dictionary<string, object> d = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json);
            return d != null && d.ContainsKey("Ok") && d["Ok"] != null && Convert.ToBoolean(d["Ok"]);
        }
        catch { return false; }
    }
    public static string JsonField(string json, string key)
    {
        if (json == null) { return ""; }
        try { return Str(new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json), key); }
        catch { return ""; }
    }

    static string LastJsonLine(string output)
    {
        string found = null;
        foreach (string line in output.Split('\n'))
        {
            string t = line.Trim();
            if (t.StartsWith("{") && t.EndsWith("}")) { found = t; }
        }
        return found;
    }

    static string Str(Dictionary<string, object> d, string k)
    {
        if (d == null || !d.ContainsKey(k) || d[k] == null) { return ""; }
        return Convert.ToString(d[k], System.Globalization.CultureInfo.InvariantCulture);
    }
    static string DStr(System.Collections.Generic.IDictionary<string, object> d, string k)
    {
        if (d == null || !d.ContainsKey(k) || d[k] == null) { return ""; }
        return Convert.ToString(d[k], System.Globalization.CultureInfo.InvariantCulture);
    }
    // The rows of a JSON array of objects - or of a lone object, which is how PowerShell
    // can write a one-element array.
    static List<IDictionary<string, object>> Rows(Dictionary<string, object> d, string k)
    {
        List<IDictionary<string, object>> rows = new List<IDictionary<string, object>>();
        object raw = (d != null && d.ContainsKey(k)) ? d[k] : null;
        IDictionary<string, object> single = raw as IDictionary<string, object>;
        if (single != null) { rows.Add(single); return rows; }
        System.Collections.IEnumerable seq = raw as System.Collections.IEnumerable;
        if (seq == null || raw is string) { return rows; }
        foreach (object o in seq)
        {
            IDictionary<string, object> r = o as IDictionary<string, object>;
            if (r != null) { rows.Add(r); }
        }
        return rows;
    }

    static bool Bool(Dictionary<string, object> d, string k)
    {
        try { if (d != null && d.ContainsKey(k) && d[k] != null) { return Convert.ToBoolean(d[k]); } } catch { }
        return false;
    }
    static int Int(Dictionary<string, object> d, string k, int dflt)
    {
        try { if (d != null && d.ContainsKey(k) && d[k] != null) { return Convert.ToInt32(d[k]); } } catch { }
        return dflt;
    }
}
