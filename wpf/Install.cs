// Portable / installed modes and the self-registering installer.
//
// The executable carries the PowerShell engine as an embedded resource, so it is
// self-contained: whichever mode it runs in, it extracts the engine beside itself.
// There is no MSI and no MSIX on the target estate, so the exe installs itself -
// copies into Program Files, writes its own Add/Remove Programs entry, drops a Start
// menu shortcut - and uninstalls the same way.

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;

public enum AppMode { Fresh, Portable, Installed }

static class Install
{
    public const string ProductName = "SQL Express Backup";
    public const string Version = "2.0.0";
    const string UninstallKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\SqlExpressBackup";
    const string EngineResource = "SqlExpressBackup.engine.ps1";
    const string PortableMarker = "portable.marker";
    const string InstalledMarker = "installed.marker";

    public static string ExeDir()
    {
        return Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location);
    }
    public static string ExePath()
    {
        return Assembly.GetExecutingAssembly().Location;
    }
    public static string InstallDir()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), ProductName);
    }

    // Where the app is running from tells us the mode: a copy under Program Files with
    // its marker is installed; a copy with a portable marker beside it is portable;
    // anything else is a fresh download that has not chosen yet.
    public static AppMode DetectMode()
    {
        try
        {
            string dir = ExeDir();
            if (File.Exists(Path.Combine(dir, InstalledMarker))) { return AppMode.Installed; }
            if (File.Exists(Path.Combine(dir, PortableMarker))) { return AppMode.Portable; }
            // running from the canonical install dir counts as installed even without
            // the marker, so a manual copy there still behaves.
            if (string.Equals(dir.TrimEnd('\\'), InstallDir().TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            { return AppMode.Installed; }
        }
        catch { }
        return AppMode.Fresh;
    }

    // UI settings live per-user for an installed app; beside the executable for a
    // portable one, so a portable copy carries its own preferences on a USB stick.
    public static string SettingsDir(AppMode mode)
    {
        if (mode == AppMode.Portable) { return ExeDir(); }
        string d = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SqlExpressBackup");
        Directory.CreateDirectory(d);
        return d;
    }

    // Extract the embedded engine to <dir>\engine, unless a copy is already there.
    public static string ExtractEngine(string dir)
    {
        string engineDir = Path.Combine(dir, "engine");
        Directory.CreateDirectory(engineDir);
        string target = Path.Combine(engineDir, "Invoke-SqlExpressBackup.ps1");
        try
        {
            Assembly asm = Assembly.GetExecutingAssembly();
            using (Stream s = asm.GetManifestResourceStream(EngineResource))
            {
                if (s == null) { return File.Exists(target) ? target : null; }
                using (StreamReader r = new StreamReader(s))
                {
                    string content = r.ReadToEnd();
                    // Only rewrite if changed, so a running scheduled copy is not churned.
                    if (!File.Exists(target) || File.ReadAllText(target) != content)
                    {
                        File.WriteAllText(target, content);
                    }
                }
            }
        }
        catch { }
        return File.Exists(target) ? target : null;
    }

    // The engine path for the current mode, extracting the embedded copy if needed.
    public static string EnsureEngine(AppMode mode)
    {
        string baseDir = (mode == AppMode.Portable || mode == AppMode.Installed)
            ? ExeDir()
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SqlExpressBackup");
        return ExtractEngine(baseDir);
    }

    // ---- elevation ---------------------------------------------------------------

    public static bool IsElevated()
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

    public static bool Relaunch(string args, bool elevated) { return Relaunch(args, elevated, ExePath()); }

    public static bool Relaunch(string args, bool elevated, string exe)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo(exe);
            psi.Arguments = args;
            psi.WorkingDirectory = Path.GetDirectoryName(exe);
            psi.UseShellExecute = true;
            if (elevated) { psi.Verb = "runas"; }
            Process.Start(psi);
            return true;
        }
        catch (System.ComponentModel.Win32Exception) { return false; } // UAC declined
        catch { return false; }
    }

    // ---- install -----------------------------------------------------------------

    // Copy into Program Files, extract the engine, register uninstall, drop a shortcut.
    // Must run elevated (Program Files and HKLM). Returns the installed exe path.
    public static string DoInstall()
    {
        string dir = InstallDir();
        Directory.CreateDirectory(dir);
        string destExe = Path.Combine(dir, "SqlExpressBackup.exe");

        // Copy the running exe in (skip if we are already it).
        string src = ExePath();
        if (!string.Equals(src.TrimEnd('\\'), destExe, StringComparison.OrdinalIgnoreCase))
        {
            File.Copy(src, destExe, true);
        }
        File.WriteAllText(Path.Combine(dir, InstalledMarker), Version);
        ExtractEngine(dir);

        WriteUninstallEntry(dir, destExe);
        CreateShortcut(AllUsersStartMenu(), destExe);
        return destExe;
    }

    static void WriteUninstallEntry(string dir, string exe)
    {
        try
        {
            Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.LocalMachine.CreateSubKey(UninstallKey);
            if (k == null) { return; }
            k.SetValue("DisplayName", ProductName);
            k.SetValue("DisplayVersion", Version);
            k.SetValue("Publisher", ProductName);
            k.SetValue("InstallLocation", dir);
            k.SetValue("DisplayIcon", exe);
            k.SetValue("UninstallString", "\"" + exe + "\" --uninstall");
            k.SetValue("QuietUninstallString", "\"" + exe + "\" --uninstall --quiet");
            k.SetValue("NoModify", 1, Microsoft.Win32.RegistryValueKind.DWord);
            k.SetValue("NoRepair", 1, Microsoft.Win32.RegistryValueKind.DWord);
            try { k.SetValue("EstimatedSize", (int)(new FileInfo(exe).Length / 1024), Microsoft.Win32.RegistryValueKind.DWord); } catch { }
            k.Close();
        }
        catch { }
    }

    static string AllUsersStartMenu()
    {
        return Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.CommonStartMenu),
            "Programs\\" + ProductName + ".lnk");
    }

    // Create a .lnk via WScript.Shell through late-bound COM - no assembly reference,
    // works under the in-box compiler.
    static void CreateShortcut(string lnkPath, string target)
    {
        try
        {
            Type t = Type.GetTypeFromProgID("WScript.Shell");
            if (t == null) { return; }
            object shell = Activator.CreateInstance(t);
            object lnk = t.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { lnkPath });
            Type lt = lnk.GetType();
            lt.InvokeMember("TargetPath", BindingFlags.SetProperty, null, lnk, new object[] { target });
            lt.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, lnk, new object[] { Path.GetDirectoryName(target) });
            lt.InvokeMember("Description", BindingFlags.SetProperty, null, lnk, new object[] { ProductName });
            lt.InvokeMember("Save", BindingFlags.InvokeMethod, null, lnk, null);
        }
        catch { }
    }

    // ---- uninstall ---------------------------------------------------------------

    // Remove the registry entry, the shortcut, and the install directory. Backups on
    // the share are never touched. Runs elevated. The exe cannot delete itself while
    // running, so it schedules the directory removal via a detached command.
    public static void DoUninstall()
    {
        try { Microsoft.Win32.Registry.LocalMachine.DeleteSubKeyTree(UninstallKey, false); } catch { }
        try { string lnk = AllUsersStartMenu(); if (File.Exists(lnk)) { File.Delete(lnk); } } catch { }

        string dir = InstallDir();
        try
        {
            // A detached cmd waits for this process to exit, then removes the folder -
            // with RETRIES. The first rmdir can clear the contents yet fail to drop the
            // now-empty directory when a handle to it is briefly still open (the exiting
            // exe, antivirus, an open Explorer window), leaving an empty shell behind.
            // Three attempts spaced ~2s apart clear that race. `rmdir /S /Q` on an
            // already-empty or already-gone dir is harmless, so the extra passes cost
            // nothing when the first one succeeds.
            string q = "\"" + dir + "\"";
            string wait = "ping 127.0.0.1 -n 3 >nul";
            string rm = "rmdir /S /Q " + q + " 2>nul";
            string cmd = "/C " + wait + " & " + rm + " & " + wait + " & " + rm + " & " + wait + " & " + rm;
            ProcessStartInfo psi = new ProcessStartInfo("cmd.exe", cmd);
            psi.UseShellExecute = false; psi.CreateNoWindow = true;
            Process.Start(psi);
        }
        catch { }
    }

    // ---- portable ----------------------------------------------------------------

    // Set up a portable copy at the chosen folder: copy the exe in, extract the engine,
    // drop the portable marker, and return the new exe path to launch.
    public static string DoPortable(string folder)
    {
        Directory.CreateDirectory(folder);
        string destExe = Path.Combine(folder, "SqlExpressBackup.exe");
        string src = ExePath();
        if (!string.Equals(src.TrimEnd('\\'), destExe, StringComparison.OrdinalIgnoreCase))
        {
            File.Copy(src, destExe, true);
        }
        File.WriteAllText(Path.Combine(folder, PortableMarker), Version);
        ExtractEngine(folder);
        return destExe;
    }
}
