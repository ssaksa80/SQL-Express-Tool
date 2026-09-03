// Runs a headless elevated app job through UAC and streams its output back on the UI
// thread, live.
//
// Config and scheduling need administrator (they rewrite the locked config and register a
// SYSTEM task). Rather than elevate the whole app, the UI spawns a second, elevated app
// instance for the one job (--backup-now / --reschedule / --apply-setup); that instance
// runs the engine and appends each output line to a shared "live" file, ending with an
// "[EXIT] N" sentinel. We tail that file here with a dispatcher timer and hand each new
// line to onLine as it arrives, then the final outcome to onResult - so the non-elevated
// UI shows a backup's progress live, exactly as an in-process run would.

using System;
using System.IO;
using System.Text;
using System.Windows.Threading;

static class Elevate
{
    // flagArgs is the app flag plus any value, e.g. "--backup-now" or
    // "--reschedule \"C:\\path\\settings.json\"". onLine (may be null) receives each new
    // output line; onResult(ok, allOutput) fires once when the job finishes, times out, or
    // the UAC prompt is declined.
    public static void Run(string flagArgs, int timeoutSeconds, Action<string> onLine, Action<bool, string> onResult)
    {
        string live = Path.Combine(Path.GetTempPath(), "seb-job-" + Guid.NewGuid().ToString("N") + ".log");
        try { if (File.Exists(live)) { File.Delete(live); } } catch { }

        bool started = Install.Relaunch(flagArgs + " --live \"" + live + "\"", true);
        if (!started)
        {
            onResult(false, "The Windows elevation prompt was declined, so nothing was changed.");
            return;
        }

        DateTime deadline = DateTime.Now.AddSeconds(timeoutSeconds);
        int delivered = 0;
        StringBuilder acc = new StringBuilder();
        DispatcherTimer timer = new DispatcherTimer();
        timer.Interval = TimeSpan.FromMilliseconds(300);
        timer.Tick += delegate
        {
            string text = null;
            if (File.Exists(live)) { try { text = ReadAll(live); } catch { } }
            if (text != null)
            {
                string[] parts = text.Replace("\r\n", "\n").Split('\n');
                // The last segment has no terminating newline yet, so it may be a line
                // still being written - deliver only the complete (newline-terminated) ones.
                int complete = parts.Length - 1;
                for (int i = delivered; i < complete; i++)
                {
                    string line = parts[i];
                    if (line.StartsWith("[EXIT] "))
                    {
                        timer.Stop();
                        int code; int.TryParse(line.Substring(7).Trim(), out code);
                        try { File.Delete(live); } catch { }
                        onResult(code == 0, acc.ToString());
                        return;
                    }
                    acc.AppendLine(line);
                    if (onLine != null) { onLine(line); }
                }
                delivered = complete;
            }
            if (DateTime.Now > deadline)
            {
                timer.Stop();
                try { File.Delete(live); } catch { }
                onResult(false, "Timed out waiting for the elevated job to finish. It may still be running.");
            }
        };
        timer.Start();
    }

    static string ReadAll(string path)
    {
        using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
        using (StreamReader sr = new StreamReader(fs))
        {
            return sr.ReadToEnd();
        }
    }
}
