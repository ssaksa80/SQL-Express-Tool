// A console-style log pane, used two ways:
//   * as a LIVE activity log - the engine's output streamed line by line while a backup
//     or restore runs (append as lines arrive);
//   * as a ONE-CLICK log viewer - click a backup set or database and its recent log
//     lines (from %ProgramData%\SqlExpressBackup\logs) load in one shot.
//
// Lines are tinted by level so an [ERROR]/[FAIL] jumps out and the noisy [PROGRESS]/
// [STAGE]/[JOB] markers recede. Copy puts the whole buffer on the clipboard for a ticket.

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

    public LogPane(string heading, bool showClose, Action onClose)
    {
        Background = Theme.Sunken;
        BorderBrush = Theme.Line;
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(10);

        Grid g = new Grid();
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });

        // header: title + copy / clear / (close)
        Grid head = new Grid();
        head.Margin = new Thickness(12, 9, 10, 8);
        title = Ui.Eyebrow(heading);
        title.VerticalAlignment = VerticalAlignment.Center;
        head.Children.Add(title);

        StackPanel tools = new StackPanel();
        tools.Orientation = Orientation.Horizontal;
        tools.HorizontalAlignment = HorizontalAlignment.Right;
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

    public void SetTitle(string t) { title.Text = t.ToUpperInvariant(); }

    public void Clear() { lines.Children.Clear(); }

    // Replace the buffer (one-click log view).
    public void SetLines(IEnumerable<string> ls)
    {
        Clear();
        if (ls != null) { foreach (string l in ls) { AddLine(l); } }
        if (lines.Children.Count == 0) { AddLine("(no log entries yet)"); }
        sv.ScrollToEnd();
    }

    // Append one line (live streaming).
    public void Append(string line)
    {
        AddLine(line);
        sv.ScrollToBottom();
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

    void CopyAll()
    {
        StringBuilder sb = new StringBuilder();
        foreach (object o in lines.Children)
        {
            TextBlock t = o as TextBlock;
            if (t != null) { sb.AppendLine(t.Text); }
        }
        try { Clipboard.SetText(sb.ToString()); } catch { }
    }
}
