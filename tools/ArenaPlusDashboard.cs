// A small window explaining what the two scheduled tasks do, when they next
// run, and letting either be run on the spot.
//
// It exists because the pipeline is invisible. Two scheduled tasks fire hidden
// windows, write files, and say nothing -- and the only way to know whether the
// data was fresh was to read timestamps out of a .lua file by hand. Twice now a
// scheduled task has quietly not been running at all, and neither time was it
// noticed for hours.
//
// A real executable rather than the PowerShell script this began as: double
// clicking a .ps1 opens an editor rather than running it, running it properly
// meant a shortcut with -ExecutionPolicy Bypass, and every launch flashed a
// console window. Built with the csc.exe that ships with the .NET Framework,
// so there is nothing to install and nothing downloaded -- see Build.cmd.
//
// Scheduled tasks are read through the Schedule.Service COM object, which is
// what Get-ScheduledTask itself talks to. Shelling out to schtasks.exe and
// parsing its output would have meant parsing localised text.

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

static class Program
{
    // One window, ever.
    //
    // Two copies would each poll the same tasks and each offer to start them,
    // and a second tray icon for the same thing is just confusing. The mutex is
    // held for the life of the process, so it releases even on a hard kill.
    static Mutex only;

    // Broadcast by a second copy to say "you are already the window, show
    // yourself". Registered by name, so both processes agree on the number
    // without either knowing about the other.
    public static readonly uint ShowExisting =
        RegisterWindowMessage("ArenaPlusDashboard.Show");

    [DllImport("user32.dll")] static extern uint RegisterWindowMessage(string name);
    [DllImport("user32.dll")] static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);

    static readonly IntPtr Broadcast = (IntPtr)0xFFFF;

    [STAThread]
    static void Main()
    {
        bool mine;
        only = new Mutex(true, "ArenaPlusDashboardSingleInstance", out mine);

        if (!mine)
        {
            // Rather than a message box saying it is already running: ask the
            // copy that exists to come to the front. It may be sitting in the
            // notification area, which is exactly when somebody would launch it
            // again wondering where it went.
            PostMessage(Broadcast, ShowExisting, IntPtr.Zero, IntPtr.Zero);
            return;
        }

        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        Application.Run(new Dashboard());

        GC.KeepAlive(only);
    }
}

// What one scheduled task is doing, in the words the window shows.
class TaskLine
{
    public bool Missing;
    public string State = "";
    public string Last = "never";
    public string Next = "not scheduled";
    public string Result = "";
    public bool Running;
}

// What one task spent the last time it ran, and when that was.
class RunCost
{
    public Dictionary<string, int> ByRegion = new Dictionary<string, int>();
    public DateTime Latest = DateTime.MinValue;

    public int Total
    {
        get { int n = 0; foreach (int v in ByRegion.Values) n += v; return n; }
    }
}

// A run in flight, as reported by the run itself.
class RunProgress
{
    public string Kind = "";      // "specs" or "ladder"
    public string Region = "";
    public int Done;
    public int Total;
    public DateTime Started;
    public bool HasStarted;       // false for the older four-field format
    public string Unit = "";      // what is being counted, when the run says so
    public DateTime Written;      // when the run last wrote the file
}

// One job, in one region: the line in the window and the task behind it.
//
// The three jobs used to be three sets of fields, which worked while each was a
// single task. Splitting the regions apart doubled them, and six of everything
// named by hand is how a window ends up wiring the EU picker to the US task.
class TaskRow
{
    public string Task;        // the scheduled task's name
    public string Region;      // "US" or "EU"
    public string Kind;        // "ladder", "specs" or "inspect"
    public Label Status;
    public ComboBox Every;
    public Button Run;
    public Button Halt;        // "Stop": only ever enabled while this row is the one running
    public ProgressBar Bar;    // its own, so a run is shown against the job doing it
}

class Dashboard : Form
{
    // Blizzard's published ceiling per client. Shown because the honest answer
    // to "how many more runs can I do" is "about three thousand an hour", and
    // that is worth seeing once rather than worrying about repeatedly.
    const int HourlyCap = 36000;

    // One task per job per region, so either region can be run on its own and
    // given its own cadence -- Blizzard rebuilds the two ladders on different
    // clocks anyway, measured an hour apart.
    const string TaskDataUS  = "ArenaPlus Data US";
    const string TaskDataEU  = "ArenaPlus Data EU";

    // Its own task with its own trigger, like the other two.
    //
    // It used to have no trigger at all: the gear pass was a second action bolted
    // onto the class and spec task, throttled by a -MinHours argument, and this
    // task existed only so the button could run it by hand. That made its picker
    // a different kind of thing from the other four -- "at most every 12 hours"
    // beside "hourly" -- for an implementation reason nobody looking at the
    // window can see.
    const string TaskInspectUS = "ArenaPlus Inspect US";
    const string TaskInspectEU = "ArenaPlus Inspect EU";

    readonly string tools;
    readonly string root;

    Label summary, quota, footer;
    readonly List<TaskRow> rows = new List<TaskRow>();

    // One line per section: what that job spent last time, and what is left of
    // the hour. The budget is shared, so the remaining figure is the same on
    // each -- shown against each job anyway, because that is where the question
    // is asked.
    readonly Dictionary<string, Label> spend = new Dictionary<string, Label>();
    // Per section, the logs its task writes. Two for the ladder section since
    // the class and spec pass became the second half of that task, and a cost
    // line that named only one of them would understate every run.
    readonly Dictionary<string, string[]> spendLog = new Dictionary<string, string[]>();

    // Worked out on the same slow tick as the budget. The logs only gain a line
    // when a run ends, and reading three of them every second to redraw text
    // that cannot have changed is the stutter the summary already had once.
    readonly Dictionary<string, string> spendText = new Dictionary<string, string>();
    bool settingUp;   // true while the pickers are being filled in
    CheckBox trayOption;
    NotifyIcon tray;
    bool toldWhereItWent;   // the balloon is shown once, not every minimise

    // Re-read only when the files themselves change: see UpdateSummary.
    string summaryStamp = "";
    string summaryText = "";

    // The budget is counted from log files, which only gain a line when a run
    // ends. Once every ten ticks is far more often than they can change.
    int ticks;
    int quotaUsed;
    int ladderRunCost;   // measured, both regions; 0 until a run has been logged, then used by the budget
    double forecast;     // what the whole schedule costs an hour, from each job's last run

    // What each section's last run cost, kept from the last time the logs were
    // read. The logs are the slow part; the arithmetic over them is not, so
    // changing an interval can redo the sums at once and leave the reading to
    // the timer.
    readonly Dictionary<string, RunCost> lastCost = new Dictionary<string, RunCost>();

    object scheduler;

    public Dashboard()
    {
        tools = Path.GetDirectoryName(Application.ExecutablePath);

        // Where the ladder and the specs are read from for the summary at the
        // bottom. Not this addon: they moved out to ArenaPlus_Data, which is a
        // sibling of it rather than anything underneath. Pointing here at the
        // addon that holds the scripts is why the summary read nought places,
        // nought with a spec, for every region.
        root  = Path.Combine(Path.GetDirectoryName(Path.GetDirectoryName(tools)), "ArenaPlus_Data");

        Text = "ArenaPlus data";
        ClientSize = new Size(640, 690);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        Font = new Font("Segoe UI", 9F);
        BackColor = SystemColors.Window;

        BuildLayout();
        BuildTray();

        // Fully qualified: System.Threading is now in scope for the mutex, and
        // its Timer is not this one.
        var timer = new System.Windows.Forms.Timer();
        timer.Interval = 1000;
        // Wrapped, because an unhandled exception inside a tick does not go to
        // a log -- it throws a crash dialog over whatever you were doing.
        // Anything this reads can vanish mid-run: a task can be removed, and a
        // file can be being rewritten by the very run this is watching.
        timer.Tick += delegate
        {
            try { UpdateEverything(); }
            catch (Exception e) { footer.Text = "refresh failed: " + e.Message; }
        };
        timer.Start();

        try { UpdateEverything(); }
        catch (Exception e) { footer.Text = "refresh failed: " + e.Message; }
    }

    // ------------------------------------------------------------ layout

    Label AddLabel(string text, int x, int y, int w, int h, bool bold, bool grey)
    {
        var l = new Label();
        l.Text = text;
        l.Location = new Point(x, y);
        l.Size = new Size(w, h);
        if (bold) l.Font = new Font("Segoe UI", 10F, FontStyle.Bold);
        if (grey) l.ForeColor = Color.DimGray;
        Controls.Add(l);
        return l;
    }

    // One section per job, two rows in each.
    int AddSection(int y, string heading, string what, string kind,
                   string taskUS, string taskEU)
    {
        AddLabel(heading, 16, y, 300, 20, true, false);
        AddLabel(what, 16, y + 22, 596, 32, false, true);
        y += 58;

        foreach (string region in new[] { "US", "EU" })
        {
            bool us = (region == "US");
            var row = new TaskRow();
            row.Region = region;
            row.Kind = kind;
            row.Task = us ? taskUS : taskEU;

            AddLabel(region, 16, y + 2, 28, 20, false, true);
            row.Status = AddLabel("", 46, y + 2, 250, 20, false, false);
            row.Every = AddEvery(302, y, EveryName);
            row.Run = AddButton("Run now", 458, y, 92, row.Task);
            row.Halt = AddStop(556, y, 60, row);

            // Under its own row, so which job is working is never in question.
            // One shared bar was fine for three tasks and ambiguous for six.
            row.Bar = new ProgressBar();
            row.Bar.Location = new Point(46, y + 22);
            row.Bar.Size = new Size(570, 6);
            row.Bar.Visible = false;
            Controls.Add(row.Bar);

            rows.Add(row);
            y += 34;
        }

        Label spent = AddLabel("", 46, y, 570, 20, false, true);
        spend[kind] = spent;

        return y + 34;
    }

    void BuildLayout()
    {
        // Which log each job writes what it spent into.
        spendLog["ladder"]  = new[] { "UpdateFromBlizzard.log", "UpdateSpecs.log" };
        spendLog["inspect"] = new[] { "UpdateInspect.log" };

        int y = 14;

        y = AddSection(y, "Ladder, cutoffs, class and spec",
            "Seven requests for the ladder itself, then class and spec for any new name plus a slice of " +
            "the roster -- about eight -- so everybody comes round once a week. Each region rebuilds on " +
            "its own clock, so the two are scheduled separately.",
            "ladder", TaskDataUS, TaskDataEU);

        y = AddSection(y, "Gear, talents and glyphs",
            "Everything the inspect panel shows, for the best five of every spec in every bracket. " +
            "About 1,100 requests a region, and the only pass with no incremental mode: builds change, " +
            "so every run re-asks about everybody.",
            "inspect", TaskInspectUS, TaskInspectEU);

        // Filled in from the tasks themselves, then wired up. Wiring after
        // filling, so setting the initial selection does not read as the user
        // choosing it and rewrite the task with the value it already had.
        LoadSchedules();
        foreach (TaskRow row in rows)
        {
            TaskRow captured = row;
            captured.Every.SelectedIndexChanged += delegate { ApplyEvery(captured); };
        }

        AddLabel("On disk", 16, y, 300, 20, true, false);
        summary = AddLabel("", 16, y + 22, 600, 44, false, false);
        y += 76;

        AddLabel("Request budget", 16, y, 300, 20, true, false);
        quota = AddLabel("", 16, y + 22, 600, 60, false, true);
        y += 90;

        // Left of the footer rather than up with the tasks: it is a preference
        // about this window, not about the data.
        trayOption = new CheckBox();
        trayOption.Text = "Minimise to the notification area";
        trayOption.Location = new Point(16, y);
        trayOption.Size = new Size(280, 22);
        trayOption.ForeColor = Color.DimGray;
        trayOption.Checked = ReadSetting("minimizeToTray") == "true";
        trayOption.CheckedChanged += delegate
        {
            WriteSetting("minimizeToTray", trayOption.Checked ? "true" : "false");
            // Turning it off with the window already hidden would strand it.
            if (!trayOption.Checked) RestoreFromTray();
        };
        Controls.Add(trayOption);

        footer = AddLabel("", 16, y + 26, 600, 20, false, true);

        ClientSize = new Size(640, y + 56);
    }

    Button AddButton(string text, int x, int y, int w, string taskName)
    {
        var b = new Button();
        b.Text = text;
        b.Location = new Point(x, y);
        b.Size = new Size(w, 26);
        b.Click += delegate
        {
            try
            {
                RunTask(taskName);
                b.Enabled = false;
                UpdateEverything();
            }
            catch (Exception e)
            {
                MessageBox.Show("Could not start " + taskName + ":\r\n\r\n" + e.Message,
                                "ArenaPlus data", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        };
        Controls.Add(b);
        return b;
    }

    // ------------------------------------------------------------ tray

    void BuildTray()
    {
        var menu = new ContextMenuStrip();
        menu.Items.Add("Open", null, delegate { RestoreFromTray(); });
        menu.Items.Add(new ToolStripSeparator());
        // Both regions of each job, since they are separate tasks now.
        menu.Items.Add("Run ladder, cutoffs, class and spec -- US", null, delegate { TryRun(TaskDataUS); });
        menu.Items.Add("Run ladder, cutoffs, class and spec -- EU", null, delegate { TryRun(TaskDataEU); });
        menu.Items.Add("Run gear, talents and glyphs -- US", null, delegate { TryRun(TaskInspectUS); });
        menu.Items.Add("Run gear, talents and glyphs -- EU", null, delegate { TryRun(TaskInspectEU); });
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Exit", null, delegate { Close(); });

        tray = new NotifyIcon();
        // The window's own icon, so the tray entry and the taskbar entry match
        // without a second icon file to keep in step.
        try { tray.Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
        catch { tray.Icon = SystemIcons.Application; }
        tray.Text = "ArenaPlus data";
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += delegate { RestoreFromTray(); };
        tray.Visible = false;

        // Still handled, for a minimise that does not come through the caption
        // button -- the taskbar's own menu, or Win+D. Guarded on Visible so it
        // cannot fire a second time for a window WndProc has already hidden.
        Resize += delegate
        {
            if (WindowState == FormWindowState.Minimized && trayOption.Checked && Visible) HideToTray();
        };

        // Otherwise the icon outlives the window and sits there until something
        // hovers over it.
        FormClosing += delegate
        {
            tray.Visible = false;
            tray.Dispose();
        };
    }

    void HideToTray()
    {
        // Window first, icon second. Registering with the shell takes a moment
        // the first time, and doing it before hiding puts that moment between
        // the click and anything happening.
        Hide();

        try
        {
            tray.Visible = true;
        }
        catch
        {
            // A hidden window with no tray icon is unreachable, so give up on
            // the tray rather than on the window.
            RestoreFromTray();
            return;
        }

        if (!toldWhereItWent)
        {
            toldWhereItWent = true;
            tray.BalloonTipTitle = "ArenaPlus data";
            tray.BalloonTipText = "Still here. Double click to open it again.";
            tray.ShowBalloonTip(3000);
        }
    }

    void RestoreFromTray()
    {
        Show();
        WindowState = FormWindowState.Normal;
        Activate();
        if (tray != null) tray.Visible = false;
    }

    void TryRun(string taskName)
    {
        try { RunTask(taskName); }
        catch (Exception e)
        {
            tray.BalloonTipTitle = "ArenaPlus data";
            tray.BalloonTipText = "Could not start " + taskName + ": " + e.Message;
            tray.ShowBalloonTip(4000);
        }
    }

    // ------------------------------------------------------------ settings

    // One small file beside the exe. A registry key or an AppData folder would
    // both outlive an uninstall that is just deleting the addon folder.
    string SettingsPath { get { return Path.Combine(tools, "dashboard-settings.txt"); } }

    string ReadSetting(string name)
    {
        try
        {
            if (!File.Exists(SettingsPath)) return "";
            foreach (string line in File.ReadAllLines(SettingsPath))
            {
                int eq = line.IndexOf('=');
                if (eq > 0 && line.Substring(0, eq).Trim() == name) return line.Substring(eq + 1).Trim();
            }
        }
        catch { }
        return "";
    }

    void WriteSetting(string name, string value)
    {
        try
        {
            var kept = new List<string>();
            if (File.Exists(SettingsPath))
            {
                foreach (string line in File.ReadAllLines(SettingsPath))
                {
                    int eq = line.IndexOf('=');
                    if (eq > 0 && line.Substring(0, eq).Trim() == name) continue;
                    kept.Add(line);
                }
            }
            kept.Add(name + "=" + value);
            File.WriteAllLines(SettingsPath, kept.ToArray());
        }
        catch { }
    }

    // ------------------------------------------------------------ how often

    // What the pickers offer. The value is what Task Scheduler wants -- an
    // ISO 8601 duration -- and the name is what a person wants to read.
    //
    // Fifteen minutes is offered because it is nearly free and it is the whole
    // of what we control. Blizzard rebuilds the leaderboard on its own clock --
    // measured at two to three hours behind, and each region on a different one
    // -- so polling only decides how long we sit on a snapshot after it appears.
    // A run is seven requests: four an hour is 28 against a budget of 36,000.
    //
    // "never" is not an interval -- there is no such thing -- so it switches the
    // task off instead, and the interval it had is left alone underneath so
    // turning it back on restores the cadence rather than a default.
    const string NeverValue = "never";
    static readonly string[] EveryValue = { "PT15M", "PT30M", "PT1H", "PT2H", "PT4H", "PT6H", "PT12H", "PT24H", NeverValue };
    static readonly string[] EveryName  = { "every 15 minutes", "every 30 minutes", "hourly", "every 2 hours",
                                            "every 4 hours", "every 6 hours", "every 12 hours", "daily", "never" };

    // Runs an hour for each entry in EveryValue, in the same order. "never" is
    // zero, which is what makes a switched-off region contribute nothing to the
    // forecast rather than contributing its last run for ever.
    static readonly double[] EveryPerHour = { 4, 2, 1, 0.5, 0.25, 1.0 / 6, 1.0 / 12, 1.0 / 24, 0 };

    // What this row will spend in an hour, given what it last spent and how
    // often it is set to run. Zero for a row that is off, or has never run.
    double PerHour(TaskRow row, RunCost cost)
    {
        int choice = row.Every.SelectedIndex;
        if (choice < 0 || choice >= EveryPerHour.Length) return 0;

        int spent;
        if (!cost.ByRegion.TryGetValue(row.Region.ToUpper(), out spent)) return 0;

        return spent * EveryPerHour[choice];
    }

    // Whether this row is scheduled at all, which decides both its share of the
    // forecast and whether a section can honestly say "for both".
    bool IsScheduled(TaskRow row)
    {
        int choice = row.Every.SelectedIndex;
        return choice >= 0 && choice < EveryPerHour.Length && EveryPerHour[choice] > 0;
    }

    // An ISO 8601 duration in hours, or -1 if it is not one.
    //
    // Needed because the scheduler does not store back what it is given: write
    // PT24H and it returns P1D. The same duration, a different string, and
    // matching on the string put the gear rows' pickers blank and left them out
    // of the hourly forecast entirely.
    static double Hours(string iso)
    {
        if (string.IsNullOrEmpty(iso) || iso == NeverValue) return -1;

        Match m = Regex.Match(iso, @"^P(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?)?$");
        if (!m.Success) return -1;

        double hours = 0;
        if (m.Groups[1].Success) hours += int.Parse(m.Groups[1].Value) * 24;
        if (m.Groups[2].Success) hours += int.Parse(m.Groups[2].Value);
        if (m.Groups[3].Success) hours += int.Parse(m.Groups[3].Value) / 60.0;

        return hours > 0 ? hours : -1;
    }

    // Which entry in the picker an interval corresponds to, by duration.
    static int IndexOfInterval(string iso)
    {
        if (iso == NeverValue) return Array.IndexOf(EveryValue, NeverValue);

        double want = Hours(iso);
        if (want < 0) return -1;

        for (int i = 0; i < EveryValue.Length; i++)
        {
            double have = Hours(EveryValue[i]);
            if (have > 0 && Math.Abs(have - want) < 0.0001) return i;
        }
        return -1;
    }

    string ReadInterval(string taskName)
    {
        try
        {
            dynamic task = RootFolder().GetTask(taskName);

            // Switched off beats whatever interval it is not firing on.
            if (!(bool)task.Enabled) return NeverValue;

            dynamic triggers = task.Definition.Triggers;

            // Nothing to fire on is the same answer, arrived at differently: the
            // gear tasks start life this way, runnable by button and by nothing
            // else.
            if (triggers.Count == 0) return NeverValue;

            return (string)triggers.Item(1).Repetition.Interval;
        }
        catch { scheduler = null; }
        return "";
    }

    void WriteInterval(string taskName, string iso)
    {
        dynamic folder = RootFolder();

        if (iso == NeverValue)
        {
            folder.GetTask(taskName).Enabled = false;
            return;
        }

        // Anything else turns it back on, so choosing an interval after "never"
        // does what it plainly means.
        folder.GetTask(taskName).Enabled = true;

        dynamic definition = folder.GetTask(taskName).Definition;
        dynamic triggers = definition.Triggers;

        // A task with nothing to fire on needs one made for it before an
        // interval means anything. 1 is TASK_TRIGGER_TIME: a single start,
        // repeating for ever, which is what the other tasks use.
        if (triggers.Count == 0)
        {
            dynamic fresh = triggers.Create(1);
            fresh.StartBoundary = DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss");
            fresh.Repetition.Duration = "";
            fresh.Enabled = true;
        }

        // Every trigger, not only the first: a task given a second trigger later
        // would otherwise keep firing on the old cadence through it.
        for (int i = 1; i <= (int)triggers.Count; i++) triggers.Item(i).Repetition.Interval = iso;

        // 6 is TASK_CREATE_OR_UPDATE. The principal is passed back as it came so
        // the task keeps running as whoever owns it, rather than being quietly
        // re-registered as somebody else.
        folder.RegisterTaskDefinition(taskName, definition, 6, null, null,
                                      definition.Principal.LogonType, null);
    }

    void LoadSchedules()
    {
        settingUp = true;
        try
        {
            foreach (TaskRow row in rows)
            {
                row.Every.SelectedIndex = IndexOfInterval(ReadInterval(row.Task));

                // An interval nobody offers -- set by hand, or by an older
                // version of this window -- leaves the picker blank rather than
                // showing one of the choices and pretending that is what is set.
            }
        }
        finally { settingUp = false; }
    }

    void ApplyEvery(TaskRow row)
    {
        if (settingUp || row.Every.SelectedIndex < 0) return;

        try
        {
            WriteInterval(row.Task, EveryValue[row.Every.SelectedIndex]);
        }
        catch (Exception e) { Complain(row.Task, e); return; }

        // At once, rather than at the next refresh: the figure being changed is
        // the one on screen.
        Recalculate();
        UpdateEverything();
    }

    void Complain(string what, Exception e)
    {
        MessageBox.Show("Could not change how often " + what + " runs:" + Environment.NewLine +
                        Environment.NewLine + e.Message,
                        "ArenaPlus data", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        LoadSchedules();
    }

    // Stop, beside Run.
    //
    // Not a convenience. A run that hangs holds its scheduled task open, and
    // the scheduler will not start the next one while an instance is still
    // "running" -- so one stuck pass silently stops every later pass too.
    // Measured 2026-08-22: an EU run hung at 09:10 and EU had no fresh data for
    // the following twelve hours, because every hourly run after it was skipped.
    Button AddStop(int x, int y, int w, TaskRow row)
    {
        var b = new Button();
        b.Text = "Stop";
        b.Location = new Point(x, y);
        b.Size = new Size(w, 26);
        b.Enabled = false;
        b.Click += delegate
        {
            try
            {
                StopRow(row);
                UpdateEverything();
            }
            catch (Exception e)
            {
                MessageBox.Show("Could not stop " + row.Task + ":\r\n\r\n" + e.Message,
                                "ArenaPlus data", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            }
        };
        Controls.Add(b);
        return b;
    }

    ComboBox AddEvery(int x, int y, string[] names)
    {
        var box = new ComboBox();
        box.DropDownStyle = ComboBoxStyle.DropDownList;
        box.Location = new Point(x, y);
        box.Size = new Size(150, 24);
        foreach (string name in names) box.Items.Add(name);
        Controls.Add(box);
        return box;
    }

    // ------------------------------------------------------------ tasks

    // Late bound rather than referencing the Task Scheduler interop assembly,
    // which is not present on every machine. The connection is cached but
    // rebuilt on failure: it can go stale if the service restarts.
    dynamic RootFolder()
    {
        if (scheduler == null)
        {
            Type t = Type.GetTypeFromProgID("Schedule.Service");
            if (t == null) throw new Exception("Task Scheduler is not available.");
            dynamic svc = Activator.CreateInstance(t);
            svc.Connect();
            scheduler = svc;
        }
        return ((dynamic)scheduler).GetFolder("\\");
    }

    void RunTask(string name)
    {
        try { RootFolder().GetTask(name).Run(null); }
        catch { scheduler = null; RootFolder().GetTask(name).Run(null); }
    }

    // Every instance the scheduler is holding of this task, and the file the
    // run leaves behind when it dies without tidying up.
    //
    // Both halves matter. Stopping the task without clearing the file leaves the
    // window showing a bar for a run that no longer exists; clearing the file
    // without stopping the task leaves the task blocking its own schedule with
    // nothing on screen to say so.
    void StopRow(TaskRow row)
    {
        try
        {
            dynamic instances = RootFolder().GetTask(row.Task).GetInstances(0);
            for (int i = 1; i <= (int)instances.Count; i++)
            {
                try { instances.Item(i).Stop(); }
                catch { }
            }
        }
        catch { scheduler = null; }

        ClearProgress(row);
    }

    // The run's own progress file, gone, so the row reads idle rather than
    // stalled. Matched on what the file says rather than on its name, which is
    // the same test the window uses to decide whose bar it is.
    void ClearProgress(TaskRow row)
    {
        string[] files;
        try { files = Directory.GetFiles(tools, "*.progress"); }
        catch { return; }

        foreach (string path in files)
        {
            try
            {
                string[] bits = File.ReadAllText(path).Trim().Split('|');
                if (bits.Length < 4) continue;
                if (bits[0] != row.Kind) continue;
                if (!string.Equals(bits[1], row.Region, StringComparison.OrdinalIgnoreCase)) continue;
                File.Delete(path);
            }
            catch { }
        }
    }

    TaskLine GetTaskLine(string name)
    {
        dynamic task;
        try { task = RootFolder().GetTask(name); }
        catch
        {
            scheduler = null;
            return new TaskLine { Missing = true };
        }
        if (task == null) return new TaskLine { Missing = true };

        var line = new TaskLine();
        line.Missing = false;

        // 4 is running, 3 ready, 2 queued, 1 disabled.
        int state = 0;
        try { state = (int)task.State; } catch { }
        line.Running = (state == 4);
        line.State = state == 4 ? "Running"
                   : state == 3 ? "Ready"
                   : state == 2 ? "Queued"
                   : state == 1 ? "Disabled"
                   : "Unknown";

        // 267009 is "currently running", 267011 "has not run yet". Neither is a
        // failure, and showing the raw number invites a search that ends
        // nowhere.
        int result = 0;
        try { result = (int)task.LastTaskResult; } catch { }
        line.Result = result == 0      ? "succeeded"
                    : result == 267009 ? "running"
                    : result == 267011 ? "never run"
                    : "exit code " + result;

        try
        {
            DateTime last = (DateTime)task.LastRunTime;
            if (last.Year > 2000) line.Last = last.ToString("ddd HH:mm");
        }
        catch { }

        // Throws outright when nothing is scheduled, rather than returning a
        // sentinel, so the catch is the normal path for a task with no trigger.
        try
        {
            DateTime next = (DateTime)task.NextRunTime;
            if (next.Year > 2000) line.Next = next.ToString("ddd HH:mm");
        }
        catch { }

        return line;
    }

    // ------------------------------------------------------------ progress

    // Whether a run is mid-flight, and how far in.
    //
    // Read from a file the run itself writes, which is what makes a run started
    // by the scheduler -- or by hand from a shell -- as visible here as one
    // started by the buttons above. The file carries its own start time for the
    // same reason: only the run knows when it began.
    RunProgress GetProgress()
    {
        string[] files;
        try { files = Directory.GetFiles(tools, "*.progress"); }
        catch { return null; }

        foreach (string path in files)
        {
            string text;
            // Being written by the run at this very moment is normal, and is a
            // reason to try again next tick rather than to report a fault.
            try { text = File.ReadAllText(path).Trim(); }
            catch { continue; }

            string[] bits = text.Split('|');
            if (bits.Length < 4) continue;

            var p = new RunProgress();
            try { p.Written = File.GetLastWriteTime(path); }
            catch { p.Written = DateTime.Now; }
            try
            {
                if (bits.Length >= 5)
                {
                    p.Kind = bits[0];
                    p.Region = bits[1];
                    p.Done = int.Parse(bits[2]);
                    p.Total = int.Parse(bits[3]);
                    DateTime started;
                    if (DateTime.TryParseExact(bits[4], "yyyy-MM-dd HH:mm:ss",
                            CultureInfo.InvariantCulture, DateTimeStyles.None, out started))
                    {
                        p.Started = started;
                        p.HasStarted = true;
                    }

                    // A run that counts something other than its own steps says
                    // so, because "9 of 10 steps" for eight minutes reads as a
                    // hang rather than as work.
                    if (bits.Length >= 6) p.Unit = bits[5];
                }
                else
                {
                    // The older four-field form, which had no start time: still
                    // worth showing a bar for, just without a time remaining.
                    p.Kind = "specs";
                    p.Region = bits[0];
                    p.Done = int.Parse(bits[1]);
                    p.Total = int.Parse(bits[2]);
                }
            }
            catch { continue; }

            if (p.Total > 0) return p;
        }
        return null;
    }

    // ------------------------------------------------------------ on disk

    // Cached against the files' own timestamps.
    //
    // This reads both ladder files whole and regexes them, which is over a
    // megabyte of work -- once a second it made the window stutter when
    // dragged. The files change hourly at most, so the only sane trigger is
    // that they actually changed.
    string GetSummary()
    {
        string stamp = "";
        string[] watched = { "Leaderboard-us.lua", "Leaderboard-eu.lua", "Specs-us.lua", "Specs-eu.lua" };
        foreach (string file in watched)
        {
            string path = Path.Combine(root, file);
            if (File.Exists(path)) stamp += File.GetLastWriteTime(path).Ticks.ToString();
        }

        if (stamp == summaryStamp) return summaryText;

        var parts = new List<string>();
        foreach (string region in new[] { "us", "eu" })
        {
            string ladder = Path.Combine(root, "Leaderboard-" + region + ".lua");
            string specs  = Path.Combine(root, "Specs-" + region + ".lua");

            int rows = 0;
            string read = "-";
            if (File.Exists(ladder))
            {
                string text = SafeRead(ladder);
                rows = Regex.Matches(text, "rank=").Count;
                Match m = Regex.Match(text, "checked\\s*=\\s*\"([^\"]+)\"");
                if (m.Success) read = m.Groups[1].Value;
            }

            int known = 0;
            if (File.Exists(specs)) known = Regex.Matches(SafeRead(specs), "\\]=").Count;

            int withSpec = rows > 0 ? (int)Math.Round(100.0 * known / rows) : 0;
            parts.Add(string.Format("{0}: {1} places, {2} with a spec ({3}%)   read {4}",
                                    region.ToUpper(), rows, known, withSpec, read));
        }

        summaryStamp = stamp;
        summaryText = string.Join("\r\n", parts.ToArray());
        return summaryText;
    }

    static string SafeRead(string path)
    {
        try { return File.ReadAllText(path); } catch { return ""; }
    }

    // Requests recorded in the last hour, summed from what the scripts logged.
    //
    // Counted from our own logs rather than asked of Blizzard: there is no
    // endpoint that reports your usage, so the only honest number is the one we
    // kept.
    // What the last hour cost.
    //
    // A rolling hour, not a clock hour: nothing resets on the stroke of
    // anything, budget simply comes back as each run passes sixty minutes old.
    int GetRequestsThisHour()
    {
        DateTime cutoff = DateTime.Now.AddHours(-1);
        int total = 0;

        // The gear pass counts too. It was left out of this sum while it was a
        // rare, small job, and is neither: at 746 requests a run it was the
        // largest thing the budget line could not see.
        foreach (string log in new[] { "UpdateFromBlizzard.log", "UpdateSpecs.log", "UpdateInspect.log" })
        {
            string path = Path.Combine(tools, log);
            if (!File.Exists(path)) continue;

            string[] lines;
            try { lines = File.ReadAllLines(path); } catch { continue; }

            int from = Math.Max(0, lines.Length - 400);
            for (int i = from; i < lines.Length; i++)
            {
                Match m = Regex.Match(lines[i], @"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2} [AP]M)\s+.*requests=(\d+)");
                if (!m.Success) continue;

                DateTime when;
                if (DateTime.TryParseExact(m.Groups[1].Value, "yyyy-MM-dd hh:mm tt",
                        CultureInfo.InvariantCulture, DateTimeStyles.None, out when) && when >= cutoff)
                {
                    total += int.Parse(m.Groups[2].Value);
                }
            }
        }
        return total;
    }

    // What each task spent the last time it ran, per region.
    //
    // Read back out of the logs rather than worked out from the code. The
    // description in this very window used to say the ladder run was "about a
    // dozen requests" on exactly that kind of reasoning, and it is seven.
    //
    // The region leads the message in both logs ("US: ..."), which is the only
    // way to tell the two runs of one task apart after the fact.
    // Several logs as one cost, added per region.
    //
    // One task, two scripts, two logs: what the section costs is what both of
    // them last spent, and reading only the first would have the ladder row
    // claiming seven requests on a run that made two thousand.
    RunCost LastRunCost(string[] logFiles)
    {
        var total = new RunCost();
        foreach (string file in logFiles)
        {
            RunCost one = LastRunCost(file);
            foreach (KeyValuePair<string, int> pair in one.ByRegion)
            {
                int had;
                total.ByRegion.TryGetValue(pair.Key, out had);
                total.ByRegion[pair.Key] = had + pair.Value;
            }
            if (one.Latest > total.Latest) total.Latest = one.Latest;
        }
        return total;
    }

    RunCost LastRunCost(string logFile)
    {
        var cost = new RunCost();
        string path = Path.Combine(tools, logFile);
        if (!File.Exists(path)) return cost;

        string[] lines;
        try { lines = File.ReadAllLines(path); } catch { return cost; }

        // Later lines overwrite earlier ones, so what survives is the most
        // recent run for each region.
        int from = Math.Max(0, lines.Length - 400);
        for (int i = from; i < lines.Length; i++)
        {
            Match m = Regex.Match(lines[i], @"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2} [AP]M)\s+(?:([A-Za-z]{2}):\s*)?.*requests=(\d+)");
            if (!m.Success) continue;

            // Runs from before the region was logged are still worth counting,
            // just not attributable to one region.
            string region = m.Groups[2].Success ? m.Groups[2].Value.ToUpper() : "?";
            cost.ByRegion[region] = int.Parse(m.Groups[3].Value);

            DateTime when;
            if (DateTime.TryParseExact(m.Groups[3].Value, "yyyy-MM-dd hh:mm tt",
                    CultureInfo.InvariantCulture, DateTimeStyles.None, out when) && when > cost.Latest)
            {
                cost.Latest = when;
            }
        }

        // Runs from before the region was logged are superseded the moment a
        // labelled run exists. Left in, they are counted as a third region and
        // the daily total comes out half as large again as the truth.
        if (cost.ByRegion.Count > 1) cost.ByRegion.Remove("?");

        return cost;
    }

    static string DescribeCost(RunCost cost, int scheduled)
    {
        if (cost.ByRegion.Count == 0) return "not run yet";

        var parts = new List<string>();
        foreach (string region in new[] { "US", "EU", "?" })
        {
            if (!cost.ByRegion.ContainsKey(region)) continue;
            parts.Add(string.Format("{0} {1:N0}", region == "?" ? "region unknown" : region, cost.ByRegion[region]));
        }

        string text = string.Join(", ", parts.ToArray());

        // Only when both regions are actually going to run. Adding up one live
        // region and one switched-off one gives a number that describes nothing
        // that is going to happen.
        if (parts.Count > 1 && scheduled > 1) text += string.Format("  --  {0:N0} for both", cost.Total);
        // Which run these numbers are from. Without it the figures read as a
        // standing rate, and the specs cost in particular is nothing of the
        // kind: a first pass and the top-up after it differ by a factor of
        // four hundred.
        if (cost.Latest > DateTime.MinValue) text += ", " + cost.Latest.ToString("ddd HH:mm");
        return text;
    }


    // ------------------------------------------------------------ tick

    void UpdateEverything()
    {
        RunProgress progress = GetProgress();

        // Every row, matched to the run in flight by both job and region: with
        // six tasks, "something is running" is no longer enough to know which
        // line should say so.
        foreach (TaskRow row in rows)
        {
            TaskLine line = GetTaskLine(row.Task);
            // The ladder task runs two scripts, and the second one reports itself
            // as "specs". It is the same row's work, so it lights the same row.
            bool sameJob = (progress != null
                            && (progress.Kind == row.Kind
                                || (row.Kind == "ladder" && progress.Kind == "specs")));

            bool running = (sameJob
                            && string.Equals(progress.Region, row.Region, StringComparison.OrdinalIgnoreCase));

            if (line.Missing)
            {
                row.Status.Text = "task not found";
                row.Run.Enabled = false;
                row.Halt.Enabled = false;
                continue;
            }

            if (running)
            {
                // The counts and the time go in the row's own status, so a
                // running job needs no second line anywhere else.
                row.Status.Text = Describe(progress);
                row.Bar.Maximum = Math.Max(1, progress.Total);
                row.Bar.Value = Math.Max(0, Math.Min(progress.Done, progress.Total));
                row.Bar.Visible = true;
            }
            else if (line.Running)
            {
                row.Status.Text = "Running";
                row.Bar.Visible = false;
            }
            else
            {
                row.Status.Text = string.Format("last {0}, next {1}", line.Last, line.Next);
            }

            if (!running) row.Bar.Visible = false;
            row.Run.Enabled = !line.Running && !running;

            // Stoppable exactly when there is something to stop -- including a
            // task the scheduler still thinks is running after the run behind
            // it has died, which is the case this button exists for.
            row.Halt.Enabled = line.Running || running;
        }


        summary.Text = GetSummary();

        ticks = (ticks + 1) % 10;
        if (ticks == 1)
        {
            quotaUsed = GetRequestsThisHour();

            // What a ladder run costs, measured, for the budget line below --
            // and the per-section text while the logs are open anyway.
            ladderRunCost = LastRunCost(spendLog["ladder"]).Total;


            foreach (KeyValuePair<string, string[]> pair in spendLog)
            {
                lastCost[pair.Key] = LastRunCost(pair.Value);
            }

            Recalculate();
        }


        int left = HourlyCap - quotaUsed;

        foreach (KeyValuePair<string, Label> pair in spend)
        {
            string text;
            if (spendText.TryGetValue(pair.Key, out text)) pair.Value.Text = text;
        }
        // Two lines, because there are only two things worth knowing: whether
        // the schedule fits, and what it is actually spending.
        //
        // This block grew to four lines and stopped being readable. It had the
        // allowance on one line and the usage on another, a countdown saying
        // when the rolling hour would hand some budget back, and a count of
        // "ladder runs' worth" that divided by both regions while sounding like
        // one. All of it was true and none of it answered "am I all right?".
        quota.Text = string.Format("Using {0:N0} of {1:N0} requests an hour. {2}",
                                   forecast, HourlyCap,
                                   forecast > HourlyCap
                                       ? "Over the limit -- make something run less often."
                                       : "Within the limit.") + "\r\n" +
                     string.Format("Actually spent in the last hour: {0:N0}.", quotaUsed);

        // Green while the schedule fits, red when it does not. The figure it
        // colours is a forecast from the last run of each job, so a one-off
        // catch-up pass makes it read high until the next ordinary run.
        quota.ForeColor = forecast > HourlyCap
            ? Color.FromArgb(180, 40, 40)
            : Color.FromArgb(40, 130, 60);

        footer.Text = "refreshed " + DateTime.Now.ToString("HH:mm:ss");

        // The tray tooltip is the whole window when the window is hidden, so it
        // carries the one thing worth knowing: whether anything is running.
        if (tray != null)
        {
            string hover = progress == null
                ? "ArenaPlus data -- idle"
                : string.Format("ArenaPlus data -- {0} {1}, {2} of {3}",
                                progress.Kind == "specs" ? "specs" : "ladder",
                                progress.Region.ToUpper(), progress.Done, progress.Total);

            // Silently capped: NotifyIcon throws above 63 characters rather
            // than truncating, and a crash dialog over a tooltip would be absurd.
            if (hover.Length > 63) hover = hover.Substring(0, 63);
            tray.Text = hover;
        }
    }


    // The hourly forecast and the per-section lines, from figures already read.
    //
    // Separate from reading the logs so that changing an interval can show its
    // effect at once. It used to wait for the ten-second refresh, which is a
    // long time to sit looking at a number you just changed and cannot see move.
    void Recalculate()
    {
        int remaining = HourlyCap - quotaUsed;
        forecast = 0;

        foreach (KeyValuePair<string, string[]> pair in spendLog)
        {
            RunCost cost;
            if (!lastCost.TryGetValue(pair.Key, out cost)) continue;

            // This section's rows: how many are scheduled, and what they will
            // spend between them in an hour.
            int scheduled = 0;
            double hourly = 0;
            foreach (TaskRow row in rows)
            {
                if (row.Kind != pair.Key) continue;
                if (!IsScheduled(row)) continue;
                scheduled++;
                hourly += PerHour(row, cost);
            }

            forecast += hourly;

            spendText[pair.Key] = string.Format("last run {0}   |   {1}",
                                                DescribeCost(cost, scheduled),
                                                scheduled == 0
                                                    ? "not scheduled"
                                                    : string.Format("{0:N0} an hour at this rate", hourly));
        }
    }

    // A run that has written nothing for this long is not working slowly.
    //
    // The file is written every batch and deleted when the run ends, so silence
    // means the run is stuck or gone. Measured 2026-08-22: a pass stopped at
    // 3,008 of 5,879 and the window showed a confident time remaining for the
    // next twelve hours, because a frozen bar and a slow one look identical.
    static readonly TimeSpan Stalled = TimeSpan.FromMinutes(5);

    // Hours included.
    //
    // The old format was mm:ss, which shows a twelve hour wait as "59:43" --
    // the one case where the number most needed reading was the one dropped.
    static string HowLong(TimeSpan span)
    {
        if (span.TotalHours >= 1)
            return string.Format(@"{0}:{1:mm\:ss}", (int)span.TotalHours, span);
        return string.Format(@"{0:mm\:ss}", span);
    }

    // How far in, and how much longer, for the row that is doing it.
    static string Describe(RunProgress p)
    {
        string unit = (p.Unit != "") ? p.Unit
                    : (p.Kind == "ladder") ? "steps"
                    : "characters";

        TimeSpan quiet = DateTime.Now - p.Written;
        if (quiet > Stalled)
        {
            return string.Format("stalled at {0} of {1} {2} -- nothing for {3}",
                                 p.Done, p.Total, unit, HowLong(quiet));
        }

        string timing = "";

        if (p.HasStarted)
        {
            TimeSpan span = DateTime.Now - p.Started;
            if (span.TotalSeconds < 0) span = TimeSpan.Zero;

            if (p.Done > 0)
            {
                double perItem = span.TotalSeconds / p.Done;
                TimeSpan left = TimeSpan.FromSeconds(perItem * (p.Total - p.Done));
                timing = ", " + HowLong(left) + " left";
            }
            else
            {
                // Before the first item there is no rate to extrapolate from,
                // and a made up estimate is worse than none.
                timing = ", estimating";
            }
        }

        return string.Format("{0} of {1} {2}{3}", p.Done, p.Total, unit, timing);
    }
}
