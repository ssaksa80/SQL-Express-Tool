// Persisted application state. Every parameter change and the window's own geometry
// are written here on change / on close, and read on launch - so the app always opens
// the way it was left. C# 5, in-box serializer, no external packages.
//
// Location in Phase 0 is a fixed per-user path. Phase 2 makes it mode-aware: beside
// the executable for a portable run, under ProgramData for an installed one.

using System;
using System.IO;
using System.Web.Script.Serialization;

public class AppSettings
{
    // Window geometry. NaN left/top means "never positioned yet" -> centre on screen.
    public double WinLeft = double.NaN;
    public double WinTop = double.NaN;
    public double WinWidth = 1160;
    public double WinHeight = 760;
    public bool Maximized = false;

    // Look. The single toggle writes View; the theme toggle writes Theme.
    public string View = "modern";    // modern | dba
    public string Theme = "system";   // system | light | dark

    // Backup parameters — carried here so a change is saved immediately. Wired to the
    // engine in Phase 1; present now so the store shape is settled from the start.
    public string SharePath = "";
    public string StagingPath = "";
    public int IntervalHours = 6;
    public int KeepHourly = 3;
    public int KeepDaily = 7;

    // Set by the bootstrapper once the run mode is known, so a portable copy keeps its
    // settings beside the executable and an installed one keeps them per-user.
    public static AppMode Mode = AppMode.Fresh;

    static string FilePath()
    {
        return Path.Combine(Install.SettingsDir(Mode), "wpf-settings.json");
    }

    public static AppSettings Load()
    {
        try
        {
            string p = FilePath();
            if (File.Exists(p))
            {
                JavaScriptSerializer js = new JavaScriptSerializer();
                AppSettings s = js.Deserialize<AppSettings>(File.ReadAllText(p));
                if (s != null) { return s; }
            }
        }
        catch { }
        return new AppSettings();
    }

    // Best-effort and atomic-ish: write a temp file then move over, so a crash mid-write
    // cannot leave a truncated settings file that fails to parse next launch.
    public void Save()
    {
        try
        {
            JavaScriptSerializer js = new JavaScriptSerializer();
            string json = js.Serialize(this);
            string p = FilePath();
            string tmp = p + ".tmp";
            File.WriteAllText(tmp, json);
            if (File.Exists(p)) { File.Delete(p); }
            File.Move(tmp, p);
        }
        catch { }
    }
}
