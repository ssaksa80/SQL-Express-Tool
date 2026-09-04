// A console-style log pane, used two ways:
//   * as a LIVE activity log - the engine's output streamed line by line while a backup
//     or restore runs (append as lines arrive);
//   * as a ONE-CLICK log viewer - click a backup set or database and its recent log
//     lines (from %ProgramData%\SqlExpressBackup\logs) load in one shot.
//
// Lines are tinted by level so an [ERROR]/[FAIL] jumps out and the noisy [PROGRESS]/
// [STAGE]/[JOB] markers recede. Copy puts the whole buffer on the clipboard for a ticket.
//
// "Pop out" opens the log in its own standalone window - a real top-level Window with
// minimize / maximize / resize, for reading a long log full-screen. A popped-out window
// takes a snapshot of the current lines and then LIVE-MIRRORS any further streamed lines,
// so popping out mid-backup keeps updating.

using System;
using System.Collections.Generic;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

class LogPane : Border
{
    ScrollViewer sv;
    StackPanel lines;
    TextBlock title;
    readonly int max = 800;
    readonly bool allowPopOut;
    string lastTitle;
    List<LogPane> mirrors = new List<LogPane>();

    public LogPane(string heading, bool showClose, Action onClose, bool allowPopOut)
    {
        this.allowPopOut = allowPopOut;
        lastTitle = heading;

        Background = Theme.Sunken;
        BorderBrush = Theme.Line;
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(10);

        Grid g = new Grid();
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // header: title + pop-out / copy / clear / (close)
        Grid head = new Grid();
        head.Margin = new Thickness(12, 9, 10, 8);
        title = Ui.Eyebrow(heading);
        title.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(title);

        StackPanel tools = new StackPanel();
        tools.Orientation = Orientation.Horizontal;
        tools.HorizontalAlignment = HorizontalAlignment.Right;
        if (allowPopOut) { tools.Children.Add(MiniButton("Pop out", delegate { PopOut(); })); }
        tools.Children.Add(MiniButton("Copy", delegate { CopyAll(); }));
        tools.Children.Add(MiniButton("Clear", delegate { Clear(); }));
        if (showClose) { tools.Children.Add(MiniButton("Close", onClose)); }
        head.Children.Add(tools);
        g.Children.Add(head);

        sv = new ScrollViewer();
        sv.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
        sv.HorizontalScrollBarVisibility = ScrollBarVisibility.Auto;
        sv.Margin = new Thickness(12, 0, 6, 10);
        lines = new StackPanel();
        sv.Content = lines;
        Grid.SetRow(sv, 1);
        g.Children.Add(sv);

        Child = g;
    }

    Border MiniButton(string text, Action onClick)
    {
        Border b = new Border();
        b.CornerRadius = new CornerRadius(5);
        b.Padding = new Thickness(9, 3, 9, 3);
        b.Margin = new Thickness(6, 0, 0, 0);
        b.Background = Theme.Surface;
        b.BorderBrush = Theme.Line; b.BorderThickness = new Thickness(1);
        b.Cursor = System.Windows.Input.Cursors.Hand;
        b.Child = Ui.Text(text, 11, Theme.Ink2, FontWeights.SemiBold);
        b.MouseEnter += delegate { b.Background = Theme.Bg; };
        b.MouseLeave += delegate { b.Background = Theme.Surface; };
        if (onClick != null) { b.MouseLeftButtonUp += delegate { onClick(); }; }
        return b;
    }

    public void SetTitle(string t) { lastTitle = t; title.Text = t.ToUpperInvariant(); }

    public void Clear() { lines.Children.Clear(); }

    // Replace the buffer (one-click log view).
    public void SetLines(IEnumerable<string> ls)
    {
        Clear();
        if (ls != null) { foreach (string l in ls) { AddLine(l); } }
        if (lines.Children.Count == 0) { AddLine("(no log entries yet)"); }
        sv.ScrollToEnd();
    }

    // Append one line (live streaming). Forwarded to any popped-out mirror windows so
    // they keep updating after being popped out mid-run.
    public void Append(string line)
    {
        AddLine(line);
        sv.ScrollToBottom();
        for (int i = 0; i < mirrors.Count; i++) { mirrors[i].Append(line); }
    }

    void AddLine(string line)
    {
        if (line == null) { line = ""; }
        SolidColorBrush c = Theme.Ink2;
        if (Has(line, "[ERROR]") || Has(line, "[FAIL]")) { c = Theme.Bad; }
        else if (Has(line, "[WARN]")) { c = Theme.Warn; }
        else if (Has(line, "[ OK ]") || Has(line, "[OK]")) { c = Theme.Ok; }
        else if (line.StartsWith("[PROGRESS]") || line.StartsWith("[STAGE]") || line.StartsWith("[JOB]")) { c = Theme.Ink3; }

        TextBlock t = new TextBlock();
        t.Text = line;
        t.FontFamily = new FontFamily("Cascadia Mono, Consolas, Courier New");
        t.FontSize = 11.5;
        t.Foreground = c;
        t.TextWrapping = TextWrapping.NoWrap;
        t.Margin = new Thickness(0, 0.5, 0, 0.5);
        lines.Children.Add(t);
        while (lines.Children.Count > max) { lines.Children.RemoveAt(0); }
    }

    static bool Has(string s, string sub) { return s.IndexOf(sub, StringComparison.OrdinalIgnoreCase) >= 0; }

    List<string> Snapshot()
    {
        List<string> r = new List<string>();
        foreach (object o in lines.Children)
        {
            TextBlock t = o as TextBlock;
            if (t != null) { r.Add(t.Text); }
        }
        return r;
    }

    void CopyAll()
    {
        StringBuilder sb = new StringBuilder();
        foreach (string s in Snapshot()) { sb.AppendLine(s); }
        try { Clipboard.SetText(sb.ToString()); } catch { }
    }

    // Open the log in its own resizable/maximizable/minimizable window. The new window
    // starts from a snapshot of the current lines and is registered as a live mirror, so
    // a job still running keeps streaming into it.
    void PopOut()
    {
        List<string> snap = Snapshot();
        Window w = new Window();
        w.Title = lastTitle;
        w.Width = 940; w.Height = 620; w.MinWidth = 480; w.MinHeight = 260;
        Window owner = Window.GetWindow(this);
        if (owner == null && Application.Current != null) { owner = Application.Current.MainWindow; }
        w.Owner = owner;
        w.WindowStartupLocation = owner != null ? WindowStartupLocation.CenterOwner : WindowStartupLocation.CenterScreen;
        if (owner != null) { w.Closed += delegate { try { owner.Activate(); } catch { } }; }
        w.Background = Theme.Bg; w.FontFamily = Ui.Face;
        // default WindowStyle already gives minimize / maximize / resize + a taskbar entry
        LogPane child = new LogPane(lastTitle, true, delegate { w.Close(); }, false);
        child.Margin = new Thickness(12);
        w.Content = child;
        child.SetLines(snap);
        mirrors.Add(child);
        w.Closed += delegate { mirrors.Remove(child); };
        w.Show();
        w.Activate();
    }
}
