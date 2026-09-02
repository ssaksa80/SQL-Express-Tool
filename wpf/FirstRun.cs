// First-run chooser. Shown once, when the exe is a fresh download that has not decided
// how it wants to live: run portable from a folder the operator picks, install into
// Program Files like a normal Windows application, or just run this once without
// committing to either.

using System;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;

class FirstRun
{
    readonly Application app;
    readonly Action runOnce;
    Window win;

    public FirstRun(Application app, Action runOnce)
    {
        this.app = app;
        this.runOnce = runOnce;
    }

    public Window Build()
    {
        win = new Window();
        win.Title = "SQL Express Backup — Setup";
        win.Width = 640; win.Height = 520; win.ResizeMode = ResizeMode.NoResize;
        win.WindowStartupLocation = WindowStartupLocation.CenterScreen;
        win.Background = Theme.Bg; win.FontFamily = Ui.Face;

        StackPanel sp = new StackPanel();
        sp.Margin = new Thickness(30, 26, 30, 26);

        sp.Children.Add(Ui.Text("Set up SQL Express Backup", 22, Theme.Ink, FontWeights.SemiBold));
        TextBlock sub = Ui.Text("Choose how to run it. You can change this later by re-running the app.", 13, Theme.Ink3);
        sub.Margin = new Thickness(0, 6, 0, 20); sub.TextWrapping = TextWrapping.Wrap;
        sp.Children.Add(sub);

        sp.Children.Add(Choice("", "Install",
            "Install into Program Files like a normal Windows app. Adds a Start-menu shortcut and an entry in Add or Remove Programs. Asks for administrator once.",
            true, DoInstall));
        sp.Children.Add(Choice("", "Portable",
            "Extract to a folder you choose and run from there. No system changes, nothing to uninstall — delete the folder and it is gone.",
            false, DoPortable));
        sp.Children.Add(Choice("", "Just run once",
            "Run now without installing. The engine is unpacked to your user folder; no shortcut, no registry entry.",
            false, DoRunOnce));

        win.Content = sp;
        return win;
    }

    Border Choice(string glyph, string title, string body, bool primary, Action onClick)
    {
        Border card = Ui.Card();
        card.Margin = new Thickness(0, 0, 0, 12);
        card.Cursor = System.Windows.Input.Cursors.Hand;
        card.BorderBrush = primary ? Theme.Accent : Theme.Line;
        card.BorderThickness = new Thickness(primary ? 1.5 : 1);

        Grid g = new Grid();
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
        g.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        TextBlock ic = Ui.Icon(glyph, 22, primary ? Theme.Accent : Theme.Ink3);
        ic.VerticalAlignment = VerticalAlignment.Top; ic.Margin = new Thickness(2, 2, 16, 0);
        g.Children.Add(ic);
        StackPanel txt = new StackPanel(); Grid.SetColumn(txt, 1);
        txt.Children.Add(Ui.Text(title, 15, Theme.Ink, FontWeights.SemiBold));
        TextBlock b = Ui.Text(body, 12.5, Theme.Ink3); b.TextWrapping = TextWrapping.Wrap; b.Margin = new Thickness(0, 4, 0, 0);
        txt.Children.Add(b);
        g.Children.Add(txt);
        card.Child = g;

        card.MouseEnter += delegate { card.Background = Theme.Sunken; };
        card.MouseLeave += delegate { card.Background = Theme.Surface; };
        card.MouseLeftButtonUp += delegate { onClick(); };
        return card;
    }

    void DoInstall()
    {
        // Install needs Program Files and HKLM; relaunch elevated to do the work.
        if (Install.Relaunch("--install", true))
        {
            app.Shutdown();
        }
        // if UAC was declined, leave the chooser up so they can pick another option
    }

    void DoPortable()
    {
        string folder = PickFolder();
        if (folder == null) { return; }
        try
        {
            string exe = Install.DoPortable(folder);
            Install.Relaunch("", false, exe);
            app.Shutdown();
        }
        catch (Exception ex)
        {
            MessageBox.Show(win, "Could not set up the portable copy:\n\n" + ex.Message,
                "SQL Express Backup", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    void DoRunOnce()
    {
        win.Hide();
        runOnce();
        win.Close();
    }

    static string PickFolder()
    {
        // WinForms folder browser - available in-box, no extra package.
        System.Windows.Forms.FolderBrowserDialog dlg = new System.Windows.Forms.FolderBrowserDialog();
        dlg.Description = "Choose a folder for the portable copy";
        dlg.ShowNewFolderButton = true;
        System.Windows.Forms.DialogResult r = dlg.ShowDialog();
        if (r == System.Windows.Forms.DialogResult.OK && dlg.SelectedPath.Length > 0)
        {
            return System.IO.Path.Combine(dlg.SelectedPath, "SQL Express Backup");
        }
        return null;
    }
}
