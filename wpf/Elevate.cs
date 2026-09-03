// Runs a headless elevated app job through UAC and reports its result on the UI thread.
//
// Config and scheduling need administrator (they rewrite the locked config and register a
// SYSTEM task). Rather than elevate the whole app, the UI spawns a second, elevated app
// instance for the one job (--backup-now / --reschedule / --apply-setup); that instance
// runs the engine and writes "exit=N\n<output>" to a result file. We poll that file here
// and hand the outcome back, so the non-elevated UI stays responsive across the UAC line.

using System;
using System.IO;
using System.Windows.Threading;

static class Elevate
{
    // flagArgs is the app flag plus any value, e.g. "--backup-now" or
    // "--reschedule \"C:\\path\\settings.json\"". onResult(ok, output) fires once, on the
    // UI thread, when the job finishes, times out, or the UAC prompt is declined.
    public static void Run(string flagArgs, int timeoutSeconds, Action<bool, string> onResult)
    {
        string result = Path.Combine(Path.GetTempPath(), "seb-job-" + Guid.NewGuid().ToString("N") + ".txt");
        try { if (File.Exists(result)) { File.Delete(result); } } catch { }

        bool started = Install.Relaunch(flagArgs + " --result \"" + result + "\"", true);
        if (!started)
        {
            onResult(false, "The Windows elevation prompt was declined, so nothing was changed.");
            return;
        }

        DateTime deadline = DateTime.Now.AddSeconds(timeoutSeconds);
        DispatcherTimer timer = new DispatcherTimer();
        timer.Interval = TimeSpan.FromMilliseconds(400);
        timer.Tick += delegate
        {
            bool done = false, ok = false; string output = "";
            if (File.Exists(result))
            {
                try
                {
                    string text = ReadAll(result);
                    if (text.Length > 0)
                    {
                        done = true;
                        int code = ParseExit(text, out output);
                        ok = (code == 0);
                    }
                }
                catch { }
            }
            if (!done && DateTime.Now > deadline)
            {
                done = true; ok = false;
                output = "Timed out waiting for the elevated job to finish. It may still be running.";
            }
            if (done)
            {
                timer.Stop();
                try { File.Delete(result); } catch { }
                onResult(ok, output);
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

    // The result file is "exit=N" then a newline then the job's output.
    static int ParseExit(string text, out string output)
    {
        int nl = text.IndexOf('\n');
        string first = nl >= 0 ? text.Substring(0, nl) : text;
        output = nl >= 0 ? text.Substring(nl + 1) : "";
        first = first.Trim();
        if (first.StartsWith("exit="))
        {
            int code;
            if (int.TryParse(first.Substring(5).Trim(), out code)) { return code; }
        }
        return 9;
    }
}
