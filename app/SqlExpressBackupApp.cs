// SQL Express Backup - portable operator console.
//
// Compiled by deploy/build-backup-app.ps1 with csc.exe, the C# compiler that ships
// with the .NET Framework on every Windows install. No SDK, no package restore, no
// network: the whole point is that this builds and runs on a server that has
// nothing installed on it. Keep this file to C# 4 - csc v4.0.30319 is the floor.
//
// WHY A RAW TcpListener AND NOT HttpListener
// HttpListener needs a URL reservation (netsh http add urlacl) or an elevated
// process to register its prefix. This app deliberately starts UNELEVATED so the
// self test and the dashboard work without an administrator, so HttpListener would
// have forced a UAC prompt just to open a window. A few dozen lines of HTTP/1.1 is
// the cheaper price.
//
// WHAT KEEPS THIS FROM BEING A HOLE
// It serves a page that can launch elevated PowerShell, so it is treated as such:
//   * binds 127.0.0.1 only - never any routable address
//   * OS-assigned port, so it is not a fixed target
//   * every request must carry a per-launch 256-bit token; without it, 401. That is
//     what stops any other local process, or a stray page in the same browser, from
//     driving it
//   * no external origin is reachable from the page (see the CSP in index.html) and
//     nothing is fetched at runtime - GSAP is embedded in this exe
//   * it exits on Quit, and on an idle timeout, so a forgotten tab does not leave a
//     listener running for weeks
//
// The token is NOT a password. It is a per-process capability that dies with the
// process; anyone who is already administrator on this box does not need it.

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Security.AccessControl;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Threading;

static class SebApp
{
    const string TaskName = "SqlExpressBackup";
    const int IdleMinutes = 20;

    static string Token;
    static TcpListener Listener;
    static volatile bool Running = true;
    static DateTime LastTouch = DateTime.UtcNow;

    static readonly object LogLock = new object();
    static readonly List<string> LogLines = new List<string>();
    static volatile bool Busy;

    static string StateDir;
    static string UserDir;
    static string EnginePath;

    static int Main(string[] args)
    {
        bool openBrowser = true;
        string endpointFile = null;
        int forcedPort = 0;

        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            if (a == "--no-browser") { openBrowser = false; }
            else if (a == "--endpoint" && i + 1 < args.Length) { endpointFile = args[++i]; }
            else if (a == "--port" && i + 1 < args.Length) { int.TryParse(args[++i], out forcedPort); }
        }

        try
        {
            StateDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SqlExpressBackup");
            // Best effort: once -Setup has run this is locked to SYSTEM and
            // Administrators, and an unelevated console must still start.
            try { Directory.CreateDirectory(StateDir); } catch { }

            // The console URL is NOT a secret and must stay readable by whoever
            // launched this - who is deliberately not an administrator. StateDir is
            // the opposite: -Setup locks it to SYSTEM and Administrators because it
            // sits beside a sealed credential, and that is correct. Writing the URL
            // there made it unreadable, and unwritable, to the one person who needs
            // it - defeating the entire reason the file exists.
            UserDir = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SqlExpressBackup");
            Directory.CreateDirectory(UserDir);

            EnginePath = ExtractEngine();
        }
        catch (Exception ex)
        {
            // Nowhere to report to yet - no console, no window. Leave a file and stop.
            TryWriteAll(Path.Combine(Path.GetTempPath(), "SqlExpressBackupApp-error.txt"), ex.ToString());
            return 2;
        }

        Token = NewToken();
        int port = forcedPort;
        if (port == 0) { port = FreePort(); }

        try
        {
            Listener = new TcpListener(IPAddress.Loopback, port);
            Listener.Start();
            port = ((IPEndPoint)Listener.LocalEndpoint).Port;
        }
        catch (Exception ex)
        {
            TryWriteAll(Path.Combine(Path.GetTempPath(), "SqlExpressBackupApp-error.txt"), ex.ToString());
            return 2;
        }

        string url = "http://127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture) + "/?t=" + Token;

        // Always leave the address somewhere findable: if the browser fails to open,
        // or the operator closed the tab, there is otherwise no way back in.
        WriteEndpointFile(Path.Combine(UserDir, "console-url.txt"), url);
        if (endpointFile != null) { WriteEndpointFile(endpointFile, url); }

        Say("console listening on 127.0.0.1:" + port.ToString(CultureInfo.InvariantCulture));
        Say("engine: " + EnginePath);

        if (openBrowser)
        {
            try
            {
                ProcessStartInfo psi = new ProcessStartInfo(url);
                psi.UseShellExecute = true;
                Process.Start(psi);
            }
            catch (Exception ex) { Say("could not open a browser: " + ex.Message); }
        }

        Thread idle = new Thread(IdleWatch);
        idle.IsBackground = true;
        idle.Start();

        while (Running)
        {
            TcpClient client = null;
            try { client = Listener.AcceptTcpClient(); }
            catch { break; }
            Thread t = new Thread(HandleClient);
            t.IsBackground = true;
            t.Start(client);
        }

        try { Listener.Stop(); } catch { }
        return 0;
    }

    // ---------------------------------------------------------------- plumbing

    static string NewToken()
    {
        byte[] b = new byte[32];
        using (RNGCryptoServiceProvider rng = new RNGCryptoServiceProvider()) { rng.GetBytes(b); }
        StringBuilder sb = new StringBuilder(64);
        for (int i = 0; i < b.Length; i++) { sb.Append(b[i].ToString("x2", CultureInfo.InvariantCulture)); }
        return sb.ToString();
    }

    static int FreePort()
    {
        TcpListener probe = new TcpListener(IPAddress.Loopback, 0);
        probe.Start();
        int p = ((IPEndPoint)probe.LocalEndpoint).Port;
        probe.Stop();
        return p;
    }

    static void IdleWatch()
    {
        while (Running)
        {
            Thread.Sleep(5000);
            if (Busy) { LastTouch = DateTime.UtcNow; continue; }
            if ((DateTime.UtcNow - LastTouch).TotalMinutes >= IdleMinutes)
            {
                Say("no console activity for " + IdleMinutes + " minutes - shutting down");
                Shutdown();
            }
        }
    }

    static void Shutdown()
    {
        Running = false;
        try { Listener.Stop(); } catch { }
    }

    static void TryWriteAll(string path, string text)
    {
        try { File.WriteAllText(path, text, new UTF8Encoding(false)); } catch { }
    }

    // The URL carries the token, and the token drives this console - which, when this
    // console is elevated, means driving an elevated process. So the file it is
    // written to must not inherit.
    //
    // That is not theoretical here. On a tiered-admin site the admin account's profile
    // can grant the matching standard account FullControl - it does on this host - so
    // an inherited ACL under LOCALAPPDATA hands the standard user the elevated
    // console's token. The gate refuses a missing or wrong token exactly as intended
    // and is beside the point when the real one is readable.
    //
    // If the lock cannot be applied, the token is NOT written at all: a recovery file
    // is worth having, but not at the price of leaking the capability it exists to
    // restore. Fail closed.
    static void WriteEndpointFile(string path, string url)
    {
        try
        {
            File.WriteAllText(path, url + Environment.NewLine, new UTF8Encoding(false));

            FileSecurity fs = new FileSecurity();
            fs.SetAccessRuleProtection(true, false);
            fs.AddAccessRule(new FileSystemAccessRule(
                WindowsIdentity.GetCurrent().User, FileSystemRights.FullControl, AccessControlType.Allow));
            fs.AddAccessRule(new FileSystemAccessRule(
                new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
                FileSystemRights.FullControl, AccessControlType.Allow));
            File.SetAccessControl(path, fs);
        }
        catch (Exception ex)
        {
            try
            {
                File.WriteAllText(path,
                    "This console is listening, but its address was not written here because the file" + Environment.NewLine +
                    "could not be restricted to you alone (" + ex.Message + ")." + Environment.NewLine +
                    "The address contains a token that controls this process, so it is withheld rather" + Environment.NewLine +
                    "than left readable. Close this console and start it again to get a fresh one." + Environment.NewLine,
                    new UTF8Encoding(false));
            }
            catch { }
            Say("the address file could not be restricted to you, so the token was withheld from it");
        }
    }

    static void Say(string line)
    {
        lock (LogLock)
        {
            LogLines.Add(DateTime.Now.ToString("HH:mm:ss", CultureInfo.InvariantCulture) + "  " + line);
            if (LogLines.Count > 4000) { LogLines.RemoveRange(0, 1000); }
        }
    }

    static byte[] Resource(string name)
    {
        Assembly asm = Assembly.GetExecutingAssembly();
        using (Stream s = asm.GetManifestResourceStream(name))
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

    // The engine is written to ProgramData rather than run from beside the exe, so
    // the scheduled task points at a path that survives the exe being unplugged.
    // Rewritten whenever the embedded copy differs, so carrying a newer exe to a
    // server upgrades the engine it installs.
    // Extracted PER USER, never into the machine-wide state directory.
    //
    // This process runs unelevated on purpose. ProgramData's default ACL lets a user
    // own and rewrite what they create there, so extracting the engine to
    // ProgramData\SqlExpressBackup\engine and then registering a task that runs it as
    // SYSTEM would hand any non-admin a script SYSTEM executes every six hours. The
    // copy the SCHEDULED task uses is placed by the elevated install instead, into a
    // directory only SYSTEM and Administrators can write - see Install-SebTask.
    //
    // This copy is only ever run as the caller: the self test, and the elevated
    // actions the operator themselves approved through UAC.
    static string ExtractEngine()
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

    // ---------------------------------------------------------------- http

    static void HandleClient(object state)
    {
        TcpClient client = (TcpClient)state;
        try
        {
            client.ReceiveTimeout = 15000;
            client.SendTimeout = 15000;
            using (NetworkStream ns = client.GetStream())
            {
                MemoryStream head = new MemoryStream();
                byte[] one = new byte[1];
                int matched = 0;
                while (matched < 4 && head.Length < 32768)
                {
                    int r = ns.Read(one, 0, 1);
                    if (r <= 0) { return; }
                    head.WriteByte(one[0]);
                    char c = (char)one[0];
                    if ((matched == 0 || matched == 2) && c == '\r') { matched++; }
                    else if ((matched == 1 || matched == 3) && c == '\n') { matched++; }
                    else { matched = 0; }
                }

                string headText = Encoding.ASCII.GetString(head.ToArray());
                string[] lines = headText.Split(new string[] { "\r\n" }, StringSplitOptions.None);
                if (lines.Length == 0) { return; }
                string[] parts = lines[0].Split(' ');
                if (parts.Length < 2) { return; }
                string method = parts[0];
                string target = parts[1];

                int contentLength = 0;
                for (int i = 1; i < lines.Length; i++)
                {
                    int colon = lines[i].IndexOf(':');
                    if (colon <= 0) { continue; }
                    string key = lines[i].Substring(0, colon).Trim().ToLowerInvariant();
                    if (key == "content-length")
                    {
                        int.TryParse(lines[i].Substring(colon + 1).Trim(), NumberStyles.Integer,
                            CultureInfo.InvariantCulture, out contentLength);
                    }
                }

                string body = "";
                if (contentLength > 0 && contentLength < 1048576)
                {
                    byte[] buf = new byte[contentLength];
                    int got = 0;
                    while (got < contentLength)
                    {
                        int r = ns.Read(buf, got, contentLength - got);
                        if (r <= 0) { break; }
                        got += r;
                    }
                    body = Encoding.UTF8.GetString(buf, 0, got);
                }

                Route(ns, method, target, body);
            }
        }
        catch { /* a dropped console connection is not an event */ }
        finally { try { client.Close(); } catch { } }
    }

    static void Route(Stream ns, string method, string target, string body)
    {
        string path = target;
        string query = "";
        int q = target.IndexOf('?');
        if (q >= 0) { path = target.Substring(0, q); query = target.Substring(q + 1); }

        Dictionary<string, string> qs = ParseForm(query);

        // Token first, on EVERY route including assets. A page in another tab must not
        // be able to read this app's status, let alone drive it.
        string given;
        if (!qs.TryGetValue("t", out given) || !FixedEquals(given, Token))
        {
            Send(ns, 401, "text/plain; charset=utf-8",
                Encoding.UTF8.GetBytes("401 - this console needs the token it was started with.\r\n" +
                                       "Open the URL in " + Path.Combine(UserDir, "console-url.txt") + "\r\n"));
            return;
        }

        LastTouch = DateTime.UtcNow;

        if (method == "GET" && (path == "/" || path == "/index.html"))
        {
            byte[] page = Resource("index.html");
            string html = Encoding.UTF8.GetString(page).Replace("__TOKEN__", Token);
            Send(ns, 200, "text/html; charset=utf-8", Encoding.UTF8.GetBytes(html));
            return;
        }

        if (method == "GET" && path.StartsWith("/assets/", StringComparison.Ordinal))
        {
            string name = path.Substring("/assets/".Length);
            if (name.IndexOf('/') >= 0 || name.IndexOf('\\') >= 0 || name.IndexOf("..", StringComparison.Ordinal) >= 0)
            {
                Send(ns, 400, "text/plain", Encoding.UTF8.GetBytes("bad asset name"));
                return;
            }
            byte[] bytes = Resource(name);
            if (bytes == null) { Send(ns, 404, "text/plain", Encoding.UTF8.GetBytes("no such asset")); return; }
            Send(ns, 200, ContentType(name), bytes);
            return;
        }

        if (method == "GET" && path == "/api/status") { Send(ns, 200, "application/json", Encoding.UTF8.GetBytes(StatusJson())); return; }

        if (method == "GET" && path == "/api/log")
        {
            int since = 0;
            string s;
            if (qs.TryGetValue("since", out s)) { int.TryParse(s, NumberStyles.Integer, CultureInfo.InvariantCulture, out since); }
            Send(ns, 200, "application/json", Encoding.UTF8.GetBytes(LogJson(since)));
            return;
        }

        if (method == "POST" && path == "/api/action")
        {
            Dictionary<string, string> form = ParseForm(body);
            string action;
            if (!form.TryGetValue("action", out action)) { action = ""; }
            // The form goes through. It used to be dropped here, which was harmless
            // while no action under /api/action needed one - and then silently made
            // the full install impossible, refusing every request as "needs its
            // settings" long before it reached the guard that was supposed to refuse it.
            string err = StartAction(action, form);
            Send(ns, err == null ? 200 : 400, "application/json",
                Encoding.UTF8.GetBytes(err == null ? "{\"ok\":true}" : "{\"ok\":false,\"error\":" + JsonStr(err) + "}"));
            return;
        }

        if (method == "POST" && path == "/api/settings")
        {
            string err = StartAction("setup", ParseForm(body));
            Send(ns, err == null ? 200 : 400, "application/json",
                Encoding.UTF8.GetBytes(err == null ? "{\"ok\":true}" : "{\"ok\":false,\"error\":" + JsonStr(err) + "}"));
            return;
        }

        if (method == "POST" && path == "/api/quit")
        {
            Send(ns, 200, "application/json", Encoding.UTF8.GetBytes("{\"ok\":true}"));
            Thread t = new Thread(delegate () { Thread.Sleep(250); Shutdown(); });
            t.IsBackground = true;
            t.Start();
            return;
        }

        Send(ns, 404, "text/plain", Encoding.UTF8.GetBytes("404"));
    }

    static bool FixedEquals(string a, string b)
    {
        if (a == null || b == null || a.Length != b.Length) { return false; }
        int diff = 0;
        for (int i = 0; i < a.Length; i++) { diff |= a[i] ^ b[i]; }
        return diff == 0;
    }

    static string ContentType(string name)
    {
        if (name.EndsWith(".css", StringComparison.OrdinalIgnoreCase)) { return "text/css; charset=utf-8"; }
        if (name.EndsWith(".js", StringComparison.OrdinalIgnoreCase)) { return "application/javascript; charset=utf-8"; }
        if (name.EndsWith(".html", StringComparison.OrdinalIgnoreCase)) { return "text/html; charset=utf-8"; }
        return "application/octet-stream";
    }

    static void Send(Stream ns, int code, string contentType, byte[] payload)
    {
        string reason = code == 200 ? "OK" : (code == 401 ? "Unauthorized" : (code == 404 ? "Not Found" : (code == 400 ? "Bad Request" : "Error")));
        StringBuilder h = new StringBuilder();
        h.Append("HTTP/1.1 ").Append(code.ToString(CultureInfo.InvariantCulture)).Append(' ').Append(reason).Append("\r\n");
        h.Append("Content-Type: ").Append(contentType).Append("\r\n");
        h.Append("Content-Length: ").Append(payload.Length.ToString(CultureInfo.InvariantCulture)).Append("\r\n");
        h.Append("Cache-Control: no-store\r\n");
        h.Append("X-Content-Type-Options: nosniff\r\n");
        h.Append("Referrer-Policy: no-referrer\r\n");
        h.Append("Connection: close\r\n\r\n");
        byte[] head = Encoding.ASCII.GetBytes(h.ToString());
        ns.Write(head, 0, head.Length);
        ns.Write(payload, 0, payload.Length);
        ns.Flush();
    }

    static Dictionary<string, string> ParseForm(string s)
    {
        Dictionary<string, string> d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        if (string.IsNullOrEmpty(s)) { return d; }
        string[] pairs = s.Split('&');
        for (int i = 0; i < pairs.Length; i++)
        {
            if (pairs[i].Length == 0) { continue; }
            int eq = pairs[i].IndexOf('=');
            string k = eq < 0 ? pairs[i] : pairs[i].Substring(0, eq);
            string v = eq < 0 ? "" : pairs[i].Substring(eq + 1);
            d[Uri.UnescapeDataString(k.Replace('+', ' '))] = Uri.UnescapeDataString(v.Replace('+', ' '));
        }
        return d;
    }

    // ---------------------------------------------------------------- json

    static string JsonStr(string s)
    {
        if (s == null) { return "null"; }
        StringBuilder sb = new StringBuilder(s.Length + 8);
        sb.Append('"');
        for (int i = 0; i < s.Length; i++)
        {
            char c = s[i];
            if (c == '"' || c == '\\') { sb.Append('\\').Append(c); }
            else if (c == '\n') { sb.Append("\\n"); }
            else if (c == '\r') { sb.Append("\\r"); }
            else if (c == '\t') { sb.Append("\\t"); }
            else if (c < ' ') { sb.Append("\\u").Append(((int)c).ToString("x4", CultureInfo.InvariantCulture)); }
            else { sb.Append(c); }
        }
        sb.Append('"');
        return sb.ToString();
    }

    static string LogJson(int since)
    {
        StringBuilder sb = new StringBuilder();
        sb.Append("{\"lines\":[");
        int next;
        lock (LogLock)
        {
            if (since < 0 || since > LogLines.Count) { since = 0; }
            for (int i = since; i < LogLines.Count; i++)
            {
                if (i > since) { sb.Append(','); }
                sb.Append(JsonStr(LogLines[i]));
            }
            next = LogLines.Count;
        }
        sb.Append("],\"next\":").Append(next.ToString(CultureInfo.InvariantCulture));
        sb.Append(",\"idle\":").Append(Busy ? "false" : "true").Append('}');
        return sb.ToString();
    }

    // ---------------------------------------------------------------- status

    // Read from public.json, which -Setup and every pass write. config.json itself is
    // locked to SYSTEM and Administrators, so an unelevated console cannot read it -
    // and loosening that to feed a dashboard would be the wrong trade.
    static Dictionary<string, string> ReadPublic()
    {
        Dictionary<string, string> d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        string path = Path.Combine(StateDir, "public.json");
        if (!File.Exists(path)) { return d; }
        string text;
        try { text = File.ReadAllText(path); } catch { return d; }
        // A flat object of scalars written by ConvertTo-Json. Parsed narrowly on
        // purpose: this is convenience data, never authority for an action.
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
            while (p < text.Length && (text[p] == ' ' || text[p] == '\r' || text[p] == '\n' || text[p] == '\t')) { p++; }
            if (p >= text.Length) { break; }
            string val;
            if (text[p] == '"')
            {
                int ve = p + 1;
                StringBuilder sb = new StringBuilder();
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

    static string Pick(Dictionary<string, string> d, string key)
    {
        string v;
        return d.TryGetValue(key, out v) ? v : null;
    }

    static string StatusJson()
    {
        Dictionary<string, string> p = ReadPublic();
        string share = Pick(p, "SharePath");
        string instanceName = Pick(p, "InstanceName");
        string hostName = Pick(p, "HostName");
        if (string.IsNullOrEmpty(hostName)) { hostName = Environment.MachineName; }

        StringBuilder sb = new StringBuilder();
        sb.Append('{');
        sb.Append("\"hostName\":").Append(JsonStr(hostName));
        sb.Append(",\"instance\":").Append(JsonStr(Pick(p, "DataSource")));
        sb.Append(",\"sharePath\":").Append(JsonStr(share));
        sb.Append(",\"stagingPath\":").Append(JsonStr(Pick(p, "StagingPath")));
        sb.Append(",\"sqlUser\":").Append(JsonStr(Pick(p, "SqlUser")));
        sb.Append(",\"useWindowsAuth\":").Append(string.Equals(Pick(p, "UseWindowsAuth"), "true", StringComparison.OrdinalIgnoreCase) ? "true" : "false");
        sb.Append(",\"intervalHours\":").Append(NumOr(Pick(p, "IntervalHours"), 6));
        sb.Append(",\"hourlyKeep\":").Append(NumOr(Pick(p, "HourlyKeep"), 3));
        sb.Append(",\"dailyKeepDays\":").Append(NumOr(Pick(p, "DailyKeepDays"), 7));
        sb.Append(",\"lastResult\":").Append(JsonStr(Pick(p, "LastResult")));
        sb.Append(",\"lastRunUtc\":").Append(JsonStr(Pick(p, "LastRunUtc")));
        sb.Append(",\"pendingCount\":").Append(NumOr(Pick(p, "PendingCount"), 0));
        sb.Append(",\"configured\":").Append(string.IsNullOrEmpty(share) ? "false" : "true");

        string schedState = "absent";
        string schedNext = "";
        ReadSchedule(ref schedState, ref schedNext);
        sb.Append(",\"scheduleState\":").Append(JsonStr(schedState));
        sb.Append(",\"scheduleNext\":").Append(JsonStr(schedNext));

        string note = "";
        sb.Append(",\"databases\":[");
        bool readable = false;
        if (!string.IsNullOrEmpty(share))
        {
            string root = Path.Combine(Path.Combine(share, hostName), instanceName == null ? "" : instanceName);
            // Enumerate first and let it throw, rather than branching on
            // Directory.Exists: that returns false for "denied" exactly as it does for
            // "not there", so an unreadable share was being reported as an empty one.
            // "Nothing backed up yet" and "you are not allowed to look" are opposite
            // facts and a status page must not confuse them.
            try
            {
                string[] dbs = Directory.GetDirectories(root);
                readable = true;
                Array.Sort(dbs);
                for (int i = 0; i < dbs.Length; i++)
                {
                    if (i > 0) { sb.Append(','); }
                    AppendDb(sb, dbs[i]);
                }
                if (dbs.Length == 0) { note = "Nothing backed up to the share for this instance yet."; }
            }
            catch (UnauthorizedAccessException)
            {
                note = "The backups exist but this account cannot read them. The share grants Administrators " +
                       "and the machine account only, which is deliberate - run this console as an administrator " +
                       "to see the per-database detail.";
            }
            catch (DirectoryNotFoundException)
            {
                note = "Nothing on the share for this host and instance yet: " + root;
            }
            catch (IOException ex)
            {
                note = "The share is not reachable right now: " + ex.Message;
            }
        }
        else { note = "No share configured yet."; }
        sb.Append(']');
        sb.Append(",\"shareReadable\":").Append(readable ? "true" : "false");
        sb.Append(",\"shareNote\":").Append(JsonStr(note));
        sb.Append('}');
        return sb.ToString();
    }

    static string NumOr(string s, int fallback)
    {
        int v;
        if (s != null && int.TryParse(s.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) { return v.ToString(CultureInfo.InvariantCulture); }
        return fallback.ToString(CultureInfo.InvariantCulture);
    }

    static void AppendDb(StringBuilder sb, string dbDir)
    {
        string name = Path.GetFileName(dbDir);
        int hourly = CountBaks(Path.Combine(dbDir, "hourly"));
        int daily = CountBaks(Path.Combine(dbDir, "daily"));
        DateTime newest = NewestStamp(Path.Combine(dbDir, "hourly"));
        sb.Append('{');
        sb.Append("\"name\":").Append(JsonStr(name));
        sb.Append(",\"hourly\":").Append(hourly.ToString(CultureInfo.InvariantCulture));
        sb.Append(",\"daily\":").Append(daily.ToString(CultureInfo.InvariantCulture));
        if (newest == DateTime.MinValue)
        {
            sb.Append(",\"newestUtc\":null,\"newestLocal\":null,\"ageHours\":null");
        }
        else
        {
            sb.Append(",\"newestUtc\":").Append(JsonStr(newest.ToUniversalTime().ToString("o", CultureInfo.InvariantCulture)));
            sb.Append(",\"newestLocal\":").Append(JsonStr(newest.ToString("yyyy-MM-dd HH:mm", CultureInfo.InvariantCulture)));
            sb.Append(",\"ageHours\":").Append(((int)(DateTime.Now - newest).TotalHours).ToString(CultureInfo.InvariantCulture));
        }
        sb.Append('}');
    }

    static int CountBaks(string dir)
    {
        try { return Directory.Exists(dir) ? Directory.GetFiles(dir, "*.bak").Length : 0; }
        catch { return 0; }
    }

    // The stamp comes out of the file NAME, exactly as the engine's retention does:
    // copying to a share can rewrite LastWriteTime, and then "newest" is a lie.
    static DateTime NewestStamp(string dir)
    {
        DateTime best = DateTime.MinValue;
        try
        {
            if (!Directory.Exists(dir)) { return best; }
            string[] files = Directory.GetFiles(dir, "*.bak");
            for (int i = 0; i < files.Length; i++)
            {
                string n = Path.GetFileNameWithoutExtension(files[i]);
                int u = n.LastIndexOf('_');
                if (u < 0 || n.Length - u - 1 != 15) { continue; }
                string stamp = n.Substring(u + 1);
                DateTime parsed;
                if (DateTime.TryParseExact(stamp, "yyyyMMdd-HHmmss", CultureInfo.InvariantCulture,
                        DateTimeStyles.None, out parsed))
                {
                    if (parsed > best) { best = parsed; }
                }
            }
        }
        catch { }
        return best;
    }

    static void ReadSchedule(ref string state, ref string next)
    {
        try
        {
            ProcessStartInfo psi = new ProcessStartInfo("schtasks.exe",
                "/query /tn \"" + TaskName + "\" /fo LIST");
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
                    // A task registered to run as SYSTEM is not readable by a standard
                    // user, so "schtasks failed" does NOT mean "not installed". Saying
                    // absent there tells the operator the schedule is missing when it is
                    // running perfectly - the one thing a status page must never do.
                    if (errText != null && errText.IndexOf("Access is denied", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        state = "installed? needs an administrator to read";
                    }
                    else { state = "absent"; }
                    return;
                }
                string[] lines = outText.Split('\n');
                for (int i = 0; i < lines.Length; i++)
                {
                    int c = lines[i].IndexOf(':');
                    if (c <= 0) { continue; }
                    string k = lines[i].Substring(0, c).Trim();
                    string v = lines[i].Substring(c + 1).Trim();
                    if (k.Equals("Status", StringComparison.OrdinalIgnoreCase)) { state = v; }
                    else if (k.Equals("Next Run Time", StringComparison.OrdinalIgnoreCase)) { next = v; }
                }
            }
        }
        catch { state = "unknown"; }
    }

    // ---------------------------------------------------------------- actions

    static string StartAction(string action, Dictionary<string, string> form)
    {
        if (Busy) { return "another action is already running"; }

        string args;
        bool elevated;
        switch (action)
        {
            case "selftest":
                args = "-SelfTest";
                elevated = false;
                break;
            case "run":
                args = "-Run";
                elevated = true;
                break;
            case "install":
                args = "-Install -As Task";
                elevated = true;
                break;
            case "uninstall":
                args = "-Uninstall";
                elevated = true;
                break;
            case "fullinstall":
                {
                    if (form == null) { return "full install needs its settings"; }
                    // The typed confirmation is enforced HERE, not in the page. A guard
                    // that lives only in the browser is not a guard: this endpoint is
                    // reachable by anything holding the token, and this is the one
                    // action that creates a share, schedules a permanent job, and
                    // starts backing up every database on the instance.
                    if (!string.Equals(Pick(form, "confirm"), "FULL INSTALL", StringComparison.Ordinal))
                    {
                        return "full install needs the typed confirmation";
                    }
                    string shareName = SafeShareName(Pick(form, "shareName"));
                    if (shareName == null) { return "that share name is not usable - letters, digits, dot, dash, underscore or $"; }
                    string shareFolder = SafeLocalPath(Pick(form, "shareFolder"));
                    if (shareFolder == null) { return "the shared folder must be a full local path, for example C:\\SqlBackups"; }

                    StringBuilder f = new StringBuilder();
                    f.Append("-FullInstall -ShareName ").Append(PsQuote(shareName));
                    f.Append(" -ShareFolder ").Append(PsQuote(shareFolder));
                    f.Append(" -IntervalHours ").Append(SafeInt(Pick(form, "interval"), 6, 1, 168));
                    f.Append(" -HourlyKeep ").Append(SafeInt(Pick(form, "hourly"), 3, 1, 99));
                    f.Append(" -DailyKeepDays ").Append(SafeInt(Pick(form, "daily"), 7, 1, 365));
                    args = f.ToString();
                    elevated = true;
                }
                break;
            case "setup":
                if (form == null) { return "setup needs settings"; }
                string share = Pick(form, "share");
                if (string.IsNullOrEmpty(share)) { return "a share path is required"; }
                StringBuilder a = new StringBuilder();
                a.Append("-Setup -SharePath ").Append(PsQuote(share));
                string staging = Pick(form, "staging");
                if (!string.IsNullOrEmpty(staging)) { a.Append(" -StagingPath ").Append(PsQuote(staging)); }
                a.Append(" -IntervalHours ").Append(SafeInt(Pick(form, "interval"), 6, 1, 168));
                a.Append(" -HourlyKeep ").Append(SafeInt(Pick(form, "hourly"), 3, 1, 99));
                a.Append(" -DailyKeepDays ").Append(SafeInt(Pick(form, "daily"), 7, 1, 365));
                if (!string.Equals(Pick(form, "auth"), "sql", StringComparison.OrdinalIgnoreCase)) { a.Append(" -UseWindowsAuth"); }
                args = a.ToString();
                elevated = true;
                break;
            default:
                return "unknown action";
        }

        Busy = true;
        Say("--- " + action + " ---");
        Thread t = new Thread(delegate () { RunEngine(args, elevated); });
        t.IsBackground = true;
        t.Start();
        return null;
    }

    static string PsQuote(string s)
    {
        return "'" + s.Replace("'", "''") + "'";
    }

    // These two reach an elevated command line. PsQuote already makes injection into
    // PowerShell impossible, so this is not the thing standing between us and a shell -
    // it is here so a typo or a hostile value becomes a clear refusal in the page
    // rather than a confusing failure inside an elevated console the operator then has
    // to interpret. Returns null when the value is not usable.
    static string SafeShareName(string v)
    {
        if (string.IsNullOrEmpty(v)) { return null; }
        v = v.Trim();
        if (v.Length == 0 || v.Length > 80) { return null; }
        for (int i = 0; i < v.Length; i++)
        {
            char c = v[i];
            bool okChar = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
                          || c == '.' || c == '-' || c == '_' || c == '$';
            if (!okChar) { return null; }
        }
        return v;
    }

    static string SafeLocalPath(string v)
    {
        if (string.IsNullOrEmpty(v)) { return null; }
        v = v.Trim().TrimEnd('\\');
        if (v.Length < 3) { return null; }
        // A UNC here would mean sharing something this host does not own, and a
        // relative path would resolve against whatever directory the elevated shell
        // happened to start in.
        if (v.StartsWith("\\\\", StringComparison.Ordinal)) { return null; }
        if (!(char.IsLetter(v[0]) && v[1] == ':' && v[2] == '\\')) { return null; }
        if (v.IndexOf("..", StringComparison.Ordinal) >= 0) { return null; }
        if (v.IndexOfAny(new char[] { '"', '<', '>', '|', '*', '?' }) >= 0) { return null; }
        return v;
    }

    static string SafeInt(string s, int fallback, int min, int max)
    {
        int v;
        if (s == null || !int.TryParse(s.Trim(), NumberStyles.Integer, CultureInfo.InvariantCulture, out v)) { v = fallback; }
        if (v < min) { v = min; }
        if (v > max) { v = max; }
        return v.ToString(CultureInfo.InvariantCulture);
    }

    static void RunEngine(string engineArgs, bool elevated)
    {
        string ps = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
            "WindowsPowerShell\\v1.0\\powershell.exe");
        try
        {
            if (!elevated)
            {
                ProcessStartInfo psi = new ProcessStartInfo(ps,
                    "-NoProfile -ExecutionPolicy Bypass -File \"" + EnginePath + "\" " + engineArgs);
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
                return;
            }

            // Elevated: stdout CANNOT be redirected across a UAC boundary - the handles
            // are not inherited - so the child tees itself to a file and we tail that.
            // The window is left VISIBLE on purpose: -Setup with a SQL login prompts for
            // a password, and that prompt must appear in a real console, never in the
            // page this app is serving.
            string logFile = Path.Combine(Path.GetTempPath(),
                "seb-console-" + Guid.NewGuid().ToString("N") + ".log");
            string inner = "& '" + EnginePath.Replace("'", "''") + "' " + engineArgs +
                           " *>&1 | Tee-Object -FilePath '" + logFile.Replace("'", "''") + "'";
            ProcessStartInfo pe = new ProcessStartInfo(ps,
                "-NoProfile -ExecutionPolicy Bypass -Command \"" + inner.Replace("\"", "\\\"") + "\"");
            pe.UseShellExecute = true;
            pe.Verb = "runas";
            pe.WindowStyle = ProcessWindowStyle.Normal;

            Process child;
            try { child = Process.Start(pe); }
            catch (System.ComponentModel.Win32Exception)
            {
                Say("the administrator prompt was dismissed - nothing was changed");
                return;
            }

            Thread tail = new Thread(delegate () { TailInto(logFile, child); });
            tail.IsBackground = true;
            tail.Start();
            child.WaitForExit();
            Thread.Sleep(600);
            Say("--- finished, exit code " + child.ExitCode.ToString(CultureInfo.InvariantCulture) + " ---");
        }
        catch (Exception ex) { Say("could not run the engine: " + ex.Message); }
        finally { Busy = false; }
    }

    static void TailInto(string path, Process child)
    {
        long at = 0;
        while (true)
        {
            try
            {
                if (File.Exists(path))
                {
                    using (FileStream fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite))
                    {
                        if (fs.Length > at)
                        {
                            fs.Seek(at, SeekOrigin.Begin);
                            using (StreamReader sr = new StreamReader(fs))
                            {
                                string line;
                                while ((line = sr.ReadLine()) != null) { Say(line); }
                            }
                            at = fs.Length;
                        }
                    }
                }
            }
            catch { }
            if (child.HasExited && at > 0) { break; }
            if (child.HasExited && !File.Exists(path)) { break; }
            Thread.Sleep(400);
        }
        try { File.Delete(path); } catch { }
    }
}
