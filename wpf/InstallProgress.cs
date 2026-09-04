// A real installer/uninstaller progress window - what a full Windows install shows and
// this app was missing. The elevated --install / --uninstall process opens this instead
// of doing the work silently: a header, the glowing progress bar, a live step log, and a
// Launch / Close finish. The operations (Install.DoInstall / DoUninstallSteps) report each
// step to it, so the user sees "Copying to Program Files", "Registering with Add/Remove
// Programs", "Removing the scheduled task" rather than a frozen cursor. --quiet skips the
// window for scripted installs.

using System;
using System.Threading;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Threading;

class InstallProgress : Window
{
    readonly bool uninstall;
    GlowBar glow;
    LogPane log;
    Border primaryBtn, closeBtn;
    string installedExe;
    public int ExitCode = 0;

    public InstallProgress(bool uninstall)
    {
        this.uninstall = uninstall;
        Title = (uninstall ? "Uninstall" : "Install") + " - SQL Express Backup";
        Width = 560; Height = 470; MinWidth = 460; MinHeight = 380;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        Background = Theme.Bg; FontFamily = Ui.Face;

        Grid g = new Grid(); g.Margin = new Thickness(22, 20, 22, 18);
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });   // header
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });   // glow
        g.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) }); // log
        g.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });   // buttons

        StackPanel head = new StackPanel(); head.Margin = new Thickness(0, 0, 0, 14);
        head.Children.Add(Ui.Text((uninstall ? "Uninstalling" : "Installing") + " SQL Express Backup", 18, Theme.Ink, FontWeights.SemiBold));
        head.Children.Add(Ui.Text("Version " + Install.Version, 12, Theme.Ink3));
        g.Children.Add(head);

        glow = new GlowBar(); Grid.SetRow(glow, 1); g.Children.Add(glow);

        log = new LogPane("Steps", false, null, false); log.Margin = new Thickness(0, 12, 0, 0);
        Grid.SetRow(log, 2); g.Children.Add(log);

        StackPanel btns = new StackPanel(); btns.Orientation = Orientation.Horizontal;
        btns.HorizontalAlignment = HorizontalAlignment.Right; btns.Margin = new Thickness(0, 14, 0, 0);
        if (!uninstall)
        {
            primaryBtn = Ui.PrimaryButton("Launch", delegate { LaunchAndClose(); });
            primaryBtn.Margin = new Thickness(0, 0, 8, 0);
            btns.Children.Add(primaryBtn);
        }
        closeBtn = Ui.GhostButton("Close", delegate { Close(); });
        btns.Children.Add(closeBtn);
        SetEnabled(primaryBtn, false); SetEnabled(closeBtn, false);
        Grid.SetRow(btns, 3); g.Children.Add(btns);

        Content = g;
        Loaded += delegate { Start(); };
    }

    void Start()
    {
        glow.Begin(uninstall ? "Uninstalling" : "Installing");
        Thread t = new Thread(delegate ()
        {
            bool ok = true; string err = null;
            Action<double, string> step = delegate(double f, string s)
            {
                Dispatch(delegate { glow.Update(f, s); log.Append(s); });
            };
            try
            {
                if (uninstall) { Install.DoUninstallSteps(step); }
                else { installedExe = Install.DoInstall(step); }
            }
            catch (Exception ex) { ok = false; err = ex.Message; }
            bool okF = ok; string errF = err;
            Dispatch(delegate { Finish(okF, errF); });
        });
        t.IsBackground = true; t.Start();
    }

    void Finish(bool ok, string err)
    {
        if (ok) { glow.Finish(true, uninstall ? "Uninstalled." : "Installed successfully."); }
        else
        {
            glow.Finish(false, (uninstall ? "Uninstall" : "Install") + " failed");
            log.Append("[ERROR] " + (err == null ? "unknown error" : err));
            ExitCode = 1;
        }
        SetEnabled(primaryBtn, ok && !uninstall);
        SetEnabled(closeBtn, true);
    }

    void LaunchAndClose()
    {
        if (installedExe != null) { try { Install.Relaunch("", false, installedExe); } catch { } }
        Close();
    }

    static void SetEnabled(Border b, bool on)
    {
        if (b == null) { return; }
        b.Opacity = on ? 1.0 : 0.45; b.IsHitTestVisible = on;
    }

    static void Dispatch(Action a)
    {
        Application app = Application.Current;
        if (app != null) { app.Dispatcher.BeginInvoke(DispatcherPriority.Normal, a); }
    }
}
