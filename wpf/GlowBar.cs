// An animated progress bar with a moving sheen - the "glow" that sweeps the filled
// portion while a job runs. It is a liveness signal, not decoration: the sheen only
// moves while progress is actually advancing, and a stall turns the fill amber and
// freezes the glow, so a stuck job reads as stuck rather than falsely progressing.
//
// Code-first WPF: a Canvas holds the track, the fill, and the sheen; a DispatcherTimer
// advances the sheen and the elapsed/ETA readout. No XAML, no storyboards.

using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;
using System.Windows.Threading;

class GlowBar : Border
{
    Grid canvas;
    Border track;
    Border fill;
    Rectangle sheen;
    TextBlock caption;
    TextBlock stat;

    DispatcherTimer timer;
    double overall = 0;          // 0..1, clamped monotonic
    double sheenPhase = 0;
    bool active = false;
    bool stalled = false;
    DateTime started = DateTime.MinValue;
    DateTime lastAdvance = DateTime.MinValue;
    string stageText = "";

    public GlowBar()
    {
        Background = Theme.Surface;
        BorderBrush = Theme.Line;
        BorderThickness = new Thickness(1);
        CornerRadius = new CornerRadius(10);
        Padding = new Thickness(14, 12, 14, 12);

        StackPanel sp = new StackPanel();

        Grid head = new Grid();
        caption = Ui.Text("Idle", 12.5, Theme.Ink2, FontWeights.SemiBold);
        stat = Ui.Text("", 11.5, Theme.Ink3);
        stat.HorizontalAlignment = HorizontalAlignment.Right;
        head.Children.Add(caption);
        head.Children.Add(stat);
        head.Margin = new Thickness(0, 0, 0, 8);
        sp.Children.Add(head);

        track = new Border();
        track.Height = 10; track.CornerRadius = new CornerRadius(5);
        track.Background = Theme.Sunken; track.BorderBrush = Theme.Line; track.BorderThickness = new Thickness(1);
        track.ClipToBounds = true;

        canvas = new Grid();
        canvas.HorizontalAlignment = HorizontalAlignment.Left;
        fill = new Border();
        fill.Height = 10; fill.CornerRadius = new CornerRadius(5);
        fill.Background = Theme.Ok; fill.Width = 0;
        fill.ClipToBounds = true;
        // the sheen lives inside the fill so it never leaks onto the empty track
        sheen = new Rectangle();
        sheen.Width = 60; sheen.Height = 10;
        sheen.HorizontalAlignment = HorizontalAlignment.Left;
        sheen.Fill = SheenBrush();
        sheen.RenderTransform = new TranslateTransform(-60, 0);
        Grid fillGrid = new Grid(); fillGrid.ClipToBounds = true;
        fillGrid.Children.Add(sheen);
        fill.Child = fillGrid;
        canvas.Children.Add(fill);
        track.Child = canvas;
        sp.Children.Add(track);

        Child = sp;

        timer = new DispatcherTimer();
        timer.Interval = TimeSpan.FromMilliseconds(60);
        timer.Tick += new EventHandler(OnTick);

        SizeChanged += delegate { Relayout(); };
    }

    static LinearGradientBrush SheenBrush()
    {
        LinearGradientBrush b = new LinearGradientBrush();
        b.StartPoint = new Point(0, 0); b.EndPoint = new Point(1, 0);
        b.GradientStops.Add(new GradientStop(Color.FromArgb(0, 255, 255, 255), 0));
        b.GradientStops.Add(new GradientStop(Color.FromArgb(150, 255, 255, 255), 0.5));
        b.GradientStops.Add(new GradientStop(Color.FromArgb(0, 255, 255, 255), 1));
        b.Freeze();
        return b;
    }

    public void Begin(string caption0)
    {
        active = true; stalled = false;
        overall = 0; sheenPhase = 0;
        started = DateTime.Now; lastAdvance = DateTime.Now;
        stageText = "";
        caption.Text = caption0 + " starting…";
        stat.Text = "";
        fill.Background = Theme.Ok; fill.Width = 0;
        timer.Start();
        Relayout();
    }

    public void Finish(bool ok, string message)
    {
        active = false; stalled = false;
        overall = ok ? 1.0 : overall;
        timer.Stop();
        sheen.RenderTransform = new TranslateTransform(-60, 0);
        caption.Text = message;
        Relayout();
    }

    // Set the caption while idle (not during a run) - used as a status line.
    public void Status(string s) { if (!active) { caption.Text = s; stat.Text = ""; } }

    // Progress update from the engine markers. `label` is the current stage/job text.
    public void Update(double fraction, string label)
    {
        if (fraction < 0) fraction = 0; if (fraction > 1) fraction = 1;
        if (fraction > overall) { overall = fraction; lastAdvance = DateTime.Now; }
        stageText = label;
        Relayout();
    }

    void OnTick(object sender, EventArgs e)
    {
        // Stall: no forward movement for 5s while active means the sheen freezes and
        // the fill goes amber. Recovery clears it.
        double sinceAdvance = (DateTime.Now - lastAdvance).TotalSeconds;
        bool nowStalled = active && overall < 1.0 && sinceAdvance >= 5.0;
        if (nowStalled != stalled)
        {
            stalled = nowStalled;
            fill.Background = stalled ? Theme.Warn : Theme.Ok;
        }

        if (active && !stalled && overall < 1.0)
        {
            sheenPhase += 0.02;
            if (sheenPhase > 1.3) { sheenPhase = -0.15; }
        }
        Relayout();
    }

    void Relayout()
    {
        double trackW = track.ActualWidth - 2;
        if (trackW < 0) trackW = 0;
        double w = trackW * overall;
        fill.Width = w;

        // sheen position within the fill
        double sx = (w + 60) * sheenPhase - 60;
        ((TranslateTransform)sheen.RenderTransform).X = sx;

        // stat line: percent, elapsed, ETA
        string s = ((int)Math.Round(overall * 100)) + "%";
        if (stalled) { s += "   stalled"; }
        if (active)
        {
            TimeSpan el = DateTime.Now - started;
            s += "   " + Span(el) + " elapsed";
            if (!stalled && overall > 0.03 && overall < 1.0)
            {
                double total = el.TotalSeconds / overall;
                s += "   ~" + Span(TimeSpan.FromSeconds(Math.Max(0, total - el.TotalSeconds))) + " left";
            }
        }
        stat.Text = s;
        if (stageText.Length > 0 && active) { caption.Text = stageText; }
    }

    static string Span(TimeSpan t)
    {
        if (t.TotalHours >= 1) { return ((int)t.TotalHours) + "h " + t.Minutes.ToString("00") + "m"; }
        if (t.TotalMinutes >= 1) { return t.Minutes + "m " + t.Seconds.ToString("00") + "s"; }
        return ((int)t.TotalSeconds) + "s";
    }
}
