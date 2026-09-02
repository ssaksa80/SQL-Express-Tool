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
    public static string FindEngine()
    {
        if (enginePath != null) { return enginePath; }
        List<string> candidates = new List<string>();
        try
        {
            string exeDir = Path.GetDirectoryName(System.Reflection.Assembly.GetExecutingAssembly().Location);
            candidates.Add(Path.Combine(exeDir, "Invoke-SqlExpressBackup.ps1"));
            candidates.Add(Path.Combine(Path.Combine(exeDir, "engine"), "Invoke-SqlExpressBackup.ps1"));
        }
        catch { }
        candidates.Add(Path.Combine(Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "SqlExpressBackup"), Path.Combine("engine", "Invoke-SqlExpressBackup.ps1")));
        foreach (string c in candidates)
        {
            try { if (File.Exists(c)) { enginePath = c; return c; } } catch { }
        }
        return null;
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
    static int Int(Dictionary<string, object> d, string k, int dflt)
    {
        try { if (d != null && d.ContainsKey(k) && d[k] != null) { return Convert.ToInt32(d[k]); } } catch { }
        return dflt;
    }
}
