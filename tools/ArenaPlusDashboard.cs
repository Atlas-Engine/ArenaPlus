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
using System.Diagnostics;
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
// One schedulable pass: which row it draws, and what the pass itself calls
// itself in its log and .progress files.
//
// Label and Token are separate because they answer to different readers. The
// label is for a person -- "TBC US" reads better with a space. The token is
// matched against what the PowerShell pass writes, and follows the same
// version-qualified region key the addon uses for its BY_REGION tables, so one
// convention covers the scraper, the shipped data and this window.
//
// MoP keeps the bare "US"/"EU" tokens it already writes, so every log and
// .progress file on disk right now keeps matching without a migration.
class JobSlot
{
    public string Label;
    public string Token;
    public string Task;

    public JobSlot(string label, string token, string task)
    {
        Label = label; Token = token; Task = task;
    }
}

class TaskRow
{
    public string Task;        // the scheduled task's name
    public string Region;      // "US", "EU", "TBC-US", "TBC-EU"
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

    // Dark, and defined in one place.
    //
    // WinForms has no dark mode: every control paints itself from system
    // colours unless told otherwise, so this is a palette plus the Darken pass
    // below that walks the tree and applies it. Anything added later is styled
    // by being a child of this window rather than by remembering to.
    //
    // PANEL is a step lighter than BACK so buttons and boxes read as surfaces
    // on the window rather than holes in it, and EDGE draws their borders --
    // without one, a flat dark button on a dark window has no shape at all.
    static readonly Color BACK  = Color.FromArgb(32, 32, 32);
    static readonly Color PANEL = Color.FromArgb(48, 48, 51);
    static readonly Color TEXT  = Color.FromArgb(228, 228, 228);
    // Measured against the window ground rather than eyeballed: 150,150,152 came
    // out at 5.52:1, which clears the minimum and is still tiring to read a
    // paragraph of. This is 7.85:1.
    //
    // Very slightly blue, so it sits with the accent instead of reading as an
    // unconsidered grey.
    static readonly Color FADED = Color.FromArgb(176, 180, 190);
    static readonly Color EDGE  = Color.FromArgb(72, 72, 76);

    // Blue for the headings, and for the one button that publishes.
    //
    // Used where it means something rather than for decoration: the headings
    // because they are the only thing that divides a tall window into parts,
    // and Publish because it is the single control here that reaches other
    // people. Everything else stays grey so those two are worth looking at.
    static readonly Color ACCENT = Color.FromArgb(96, 165, 250);

    // Held, not broken. Amber reads as "on purpose" where red would read as an
    // error, and Pause is a state somebody chose.
    static readonly Color HELD = Color.FromArgb(232, 172, 84);

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

    // TBC Anniversary, scraped from the dynamic-classicann-<region> and
    // profile-classicann-<region> namespaces rather than the MoP ones. Separate
    // tasks for the same reason the regions are separate: each ladder rebuilds
    // on its own clock, and either can be run or held on its own.
    //
    // These four have to be created in Task Scheduler by hand, like the others
    // were. Until they exist the rows show "not scheduled", which is the honest
    // answer rather than an error.
    const string TaskDataTbcUS = "ArenaPlus Data TBC US";
    const string TaskDataTbcEU = "ArenaPlus Data TBC EU";
    const string TaskInspectTbcUS = "ArenaPlus Inspect TBC US";
    const string TaskInspectTbcEU = "ArenaPlus Inspect TBC EU";

    // The step that puts it all on GitHub, and the only one with no row here.
    // Which is why four hours of it failing looked exactly like nothing being
    // wrong: the ladder was current on disk, and this window only ever showed
    // what was on disk.
    const string TaskPublish = "ArenaPlus Publish";

    readonly string tools;
    readonly string root;

    Label summary, quota, footer, publishNote;
    Button pauseButton;
    Label pauseNote;
    TextBox versionBox;
    Button publishButton;
    Button commitButton;
    Label addonNote;
    readonly ToolTip tips = new ToolTip();

    // The tasks the pause button switched off, by name, and empty when nothing
    // is paused. A list rather than a flag, for the reason set out on PauseAll.
    readonly List<string> pausedTasks = new List<string>();

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

        // The gladiator helmet in the title bar and in Alt+Tab as well.
        //
        // WinForms does not take the executable's icon for its windows -- it
        // draws its own default there regardless -- so setting /win32icon only
        // reaches Explorer and the taskbar. Read back off the running exe, the
        // same way the tray icon below does, so there is one icon to change and
        // not three.
        try { Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath); }
        catch { Icon = SystemIcons.Application; }

        ClientSize = new Size(640, 690);
        StartPosition = FormStartPosition.CenterScreen;
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        Font = new Font("Segoe UI", 9F);
        BackColor = BACK;
        ForeColor = TEXT;

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
        // Bold means a section heading here, and nothing else uses it.
        l.ForeColor = grey ? FADED : (bold ? ACCENT : TEXT);
        Controls.Add(l);
        return l;
    }

    // One section per job, one row per version and region in each.
    //
    // Took a taskUS/taskEU pair while MoP was the only version. A pair cannot
    // express four rows, and adding a second pair beside it is exactly the
    // "six of everything named by hand" the TaskRow comment warns about -- so
    // the slots arrive as a list and the loop stops knowing how many there are.
    int AddSection(int y, string heading, string what, string kind,
                   JobSlot[] slots)
    {
        AddLabel(heading, 16, y, 300, 20, true, false);

        // The spend rides on the heading line, right-aligned, instead of taking
        // a line of its own beneath the rows. Four rows a section rather than
        // two had pushed this window past 1000px, and a figure nobody reads
        // until they go looking does not need a row to itself.
        spend[kind] = AddLabel("", 320, y + 2, 296, 18, false, true);
        spend[kind].TextAlign = ContentAlignment.TopRight;

        // 32, not 46: the descriptions were cut to two lines to match.
        AddLabel(what, 16, y + 20, 596, 32, false, true);
        y += 56;

        foreach (JobSlot slot in slots)
        {
            var row = new TaskRow();
            row.Region = slot.Token;
            row.Kind = kind;
            row.Task = slot.Task;

            // 56 wide, not 28: "TBC US" does not fit the width two-letter
            // region names were given, and a clipped label reads as a bug.
            // Everything to its right shifts by the same amount.
            AddLabel(slot.Label, 16, y + 2, 56, 20, false, true);
            row.Status = AddLabel("", 78, y + 2, 218, 20, false, false);
            row.Every = AddEvery(302, y, EveryName);
            row.Run = AddButton("Run now", 458, y, 92, row.Task);
            row.Halt = AddStop(556, y, 60, row);

            // Under its own row, so which job is working is never in question.
            // One shared bar was fine for three tasks and ambiguous for six.
            row.Bar = new ProgressBar();
            // As wide as the status text it belongs to, not the whole row. Run
            // to the far edge it read as a bar for the window rather than for
            // this job, and ran on under buttons it has nothing to do with.
            row.Bar.Location = new Point(78, y + 21);
            row.Bar.Size = new Size(218, 4);
            row.Bar.Visible = false;
            Controls.Add(row.Bar);

            rows.Add(row);
            y += 26;
        }

        return y + 10;
    }

    // One row, because publishing has no regions -- it pushes whatever both
    // passes have written.
    int AddPublishSection(int y)
    {
        AddLabel("Publishing to GitHub", 16, y, 300, 20, true, false);
        AddLabel("Copies what the passes wrote into ArenaPlus_Data, commits, tags and pushes it. On its " +
                 "own clock, so GitHub can be an interval behind disk. Keeps the newest ten tags.",
                 16, y + 20, 596, 32, false, true);
        y += 56;

        var row = new TaskRow();
        row.Region = "";
        row.Kind = "publish";
        row.Task = TaskPublish;

        row.Status = AddLabel("", 46, y + 2, 250, 20, false, false);
        row.Every = AddEvery(302, y, EveryName);
        row.Run = AddButton("Run now", 458, y, 92, row.Task);
        row.Halt = AddStop(556, y, 60, row);

        // Never shown -- this pass reports no progress -- but the tick loop
        // expects every row to have one.
        row.Bar = new ProgressBar();
        row.Bar.Location = new Point(46, y + 21);
        row.Bar.Size = new Size(250, 4);
        row.Bar.Visible = false;
        Controls.Add(row.Bar);

        rows.Add(row);
        y += 26;

        publishNote = AddLabel("", 46, y, 570, 18, false, true);
        return y + 24;
    }

    // What the publish log says happened last, and whether anything has been
    // written since.
    //
    // That log is the only record there is: the task reports wscript's exit
    // code, which is zero whatever PowerShell did inside it.
    string PublishState()
    {
        string log = Path.Combine(tools, "Publish-Data.log");
        if (!File.Exists(log)) return "nothing recorded yet";

        string published = null, failed = null;
        try
        {
            foreach (string line in File.ReadAllLines(log))
            {
                if (line.Contains("Published ")) { published = line; failed = null; }
                else if (line.Contains("FAILED:")) { failed = line; }
            }
        }
        catch { return "log unreadable"; }

        if (failed != null) return "last run FAILED -- see Publish-Data.log";
        if (published == null) return "nothing published yet";

        DateTime when;
        if (published.Length < 19 || !DateTime.TryParse(published.Substring(0, 19), out when))
            return published;

        // The tag's own shape. "[0-9.]+" also ate the full stop that ends the
        // sentence after it, so the line read "GitHub has 2026.08.28.1747.,".
        Match v = Regex.Match(published, @"Published (\d{4}\.\d{2}\.\d{2}\.\d{4})");
        string tag = v.Success ? v.Groups[1].Value : "?";

        // Anything written since that publish is waiting for the next one.
        int waiting = 0;
        try
        {
            foreach (string f in Directory.GetFiles(root, "*.lua"))
                if (File.GetLastWriteTime(f) > when) waiting++;
        }
        catch { }

        return waiting == 0
            ? string.Format("GitHub has {0}, and nothing has changed since", tag)
            : string.Format("GitHub has {0} -- {1} file(s) written since, waiting for the next run",
                            tag, waiting);
    }

    // ------------------------------------------------------------ pause

    // Which tasks are switched off, kept beside the exe so closing the window
    // does not lose them. The tasks themselves are off in Windows either way;
    // this is only how the button knows what it is holding.
    const string PausedSetting = "pausedTasks";

    // Everything off at once, and back on exactly as it was.
    //
    // The pickers below can already do this one job at a time -- "never"
    // switches a task off and leaves its interval underneath -- but doing that
    // five times and then remembering what five things were set to is the part
    // worth having a button for.
    //
    // It earns its place when the data is going somewhere public. A publish
    // every thirty minutes is a CurseForge build every thirty minutes, and a
    // project still in moderation does not want fifty of them arriving while
    // somebody is looking at it.
    int AddPauseRow(int y)
    {
        pauseButton = new Button();
        pauseButton.Location = new Point(16, y);
        pauseButton.Size = new Size(150, 28);
        pauseButton.Click += delegate { TogglePause(); };
        Controls.Add(pauseButton);

        pauseNote = AddLabel("", 176, y + 6, 448, 20, false, true);

        // Whatever was paused when this last closed is still paused -- the
        // tasks are switched off in Windows, not in here -- so the button has
        // to come back up saying so rather than offering to pause again.
        foreach (string name in ReadSetting(PausedSetting).Split('|'))
            if (name.Trim().Length > 0) pausedTasks.Add(name.Trim());

        UpdatePauseButton();
        return y + 40;
    }

    void UpdatePauseButton()
    {
        bool paused = (pausedTasks.Count > 0);
        pauseButton.Text = paused ? "Resume everything" : "Pause everything";

        // Amber while it holds, so a window left paused says so from across the
        // room rather than only in the sentence beside the button.
        pauseButton.ForeColor = paused ? HELD : TEXT;
        pauseNote.ForeColor = paused ? HELD : FADED;
        pauseNote.Text = paused
            ? string.Format("{0} job(s) switched off. Nothing runs on its own until you resume.",
                            pausedTasks.Count)
            : "Switches every job below off at once, remembering what each was set to.";
    }

    void TogglePause()
    {
        try
        {
            if (pausedTasks.Count > 0) ResumeAll();
            else PauseAll();
        }
        catch (Exception e)
        {
            MessageBox.Show("Could not change the schedule:" + Environment.NewLine +
                            Environment.NewLine + e.Message,
                            "ArenaPlus data", MessageBoxButtons.OK, MessageBoxIcon.Warning);
        }

        WriteSetting(PausedSetting, string.Join("|", pausedTasks.ToArray()));

        // Re-read rather than set by hand: the pickers answer from the tasks
        // themselves, so they fall to "never" while this holds and the forecast
        // falls to nothing with them. One answer to "what is the schedule".
        LoadSchedules();
        UpdatePauseButton();
        Recalculate();
        UpdateEverything();
    }

    // Only what was actually running, and each one remembered by name.
    //
    // A plain "is paused" flag would have to switch everything back on to
    // resume, which would start jobs their owner had deliberately set to
    // "never" -- silently, and looking exactly like this button misbehaving.
    // Recording the ones it switched off lets resume put back precisely those.
    //
    // A run already in flight is left alone. The passes rewrite whole .lua
    // tables, and one stopped mid-write leaves a truncated table that the next
    // publish would ship. This stops the next run, not the one happening. The
    // per-row Stop button is still the way to end a run that is going wrong.
    void PauseAll()
    {
        pausedTasks.Clear();

        foreach (TaskRow row in rows)
        {
            try
            {
                dynamic task = RootFolder().GetTask(row.Task);

                // Already off, so not this button's to switch back on.
                if (!(bool)task.Enabled) continue;

                task.Enabled = false;
                pausedTasks.Add(row.Task);
            }
            catch { scheduler = null; }
        }
    }

    void ResumeAll()
    {
        foreach (string name in pausedTasks.ToArray())
        {
            try { RootFolder().GetTask(name).Enabled = true; }
            catch { scheduler = null; }
        }
        pausedTasks.Clear();
    }

    // A prompt with room to write in.
    //
    // Not a text box on the window itself: a commit message and a changelog are
    // both several lines, and two multi-line boxes would take more of a 640
    // pixel window than the jobs they sit under. A dialog also gives Cancel a
    // meaning, which matters when the button behind it pushes to GitHub.
    //
    // Returns null when cancelled or left empty, which every caller treats as
    // "do nothing" rather than as an empty message.
    static string AskForText(string title, string prompt, string preset)
    {
        using (var box = new Form())
        {
            box.Text = title;
            box.FormBorderStyle = FormBorderStyle.FixedDialog;
            box.StartPosition = FormStartPosition.CenterParent;
            box.MinimizeBox = false;
            box.MaximizeBox = false;
            box.Font = new Font("Segoe UI", 9F);

            // Measured, not assumed.
            //
            // The prompt was given a fixed 34 pixels, which is fine for one
            // sentence and wrong for the commit prompt -- that one carries the
            // list of files about to go, so it ran to a dozen lines, was clipped
            // to two, and the text box was drawn over the rest of it.
            //
            // Capped, because a hundred outstanding files should make the list
            // scroll rather than make the dialog taller than the screen.
            const int WIDTH = 496;
            Size measured = TextRenderer.MeasureText(prompt, box.Font,
                                                     new Size(WIDTH, 0),
                                                     TextFormatFlags.WordBreak);
            int promptHeight = Math.Max(20, Math.Min(measured.Height + 6, 190));

            var label = new Label();
            label.Text = prompt;
            label.Location = new Point(12, 10);
            label.Size = new Size(WIDTH, promptHeight);
            label.AutoEllipsis = true;
            label.ForeColor = FADED;
            box.Controls.Add(label);

            var text = new TextBox();
            text.Multiline = true;
            text.ScrollBars = ScrollBars.Vertical;
            text.AcceptsReturn = true;
            text.Location = new Point(12, label.Bottom + 8);
            text.Size = new Size(WIDTH, 160);
            text.Text = preset ?? "";
            box.Controls.Add(text);

            int buttons = text.Bottom + 12;

            var ok = new Button();
            ok.Text = "OK";
            ok.DialogResult = DialogResult.OK;
            ok.Location = new Point(336, buttons);
            ok.Size = new Size(84, 26);
            box.Controls.Add(ok);

            var cancel = new Button();
            cancel.Text = "Cancel";
            cancel.DialogResult = DialogResult.Cancel;
            cancel.Location = new Point(424, buttons);
            cancel.Size = new Size(84, 26);
            box.Controls.Add(cancel);

            // Last, so it fits whatever the prompt turned out to need.
            box.ClientSize = new Size(520, buttons + 38);

            // Enter inside a multiline box types a newline rather than
            // accepting, so OK is not the AcceptButton. Escape still cancels.
            box.BackColor = BACK;
            box.ForeColor = TEXT;
            box.CancelButton = cancel;
            Darken(box);

            if (box.ShowDialog() != DialogResult.OK) return null;

            string typed = text.Text.Trim();
            return typed.Length == 0 ? null : typed;
        }
    }

    // ------------------------------------------------- releasing the addon

    // Where releases are cut from, which is NOT the folder this exe is in.
    //
    // The window runs from the live AddOns copy, because that is where the
    // scheduled tasks put it. The repository is in Dev. Publish-Data.ps1 names
    // the same two places for the same reason.
    const string AddonRepo = @"G:\My Drive\Dev\Atlas\ArenaPlus";

    int AddAddonPublishSection(int y)
    {
        AddLabel("Releasing ArenaPlus", 16, y, 300, 20, true, false);
        AddLabel("The addon itself, by hand: hand-written code deserves a commit message somebody " +
                 "wrote. Commit first; this tags the version and pushes. CurseForge builds the tag.",
                 16, y + 20, 596, 32, false, true);
        y += 56;

        AddLabel("Version", 46, y + 5, 56, 20, false, true);

        versionBox = new TextBox();
        versionBox.Location = new Point(106, y + 2);
        versionBox.Size = new Size(80, 24);
        Controls.Add(versionBox);

        publishButton = new Button();
        publishButton.Text = "Publish";
        // Marked out after Darken has been over it: this is the one button on
        // the window that reaches anybody else.
        publishButton.ForeColor = ACCENT;
        publishButton.Location = new Point(196, y);
        publishButton.Size = new Size(92, 26);
        publishButton.Click += delegate { PublishAddon(); };
        Controls.Add(publishButton);

        commitButton = new Button();
        commitButton.Text = "Commit";
        commitButton.Location = new Point(296, y);
        commitButton.Size = new Size(92, 26);
        commitButton.Click += delegate { CommitChanges(); };
        Controls.Add(commitButton);

        addonNote = AddLabel("", 396, y + 5, 220, 20, false, true);

        // Asking git costs a process, so this is not on the one-second tick.
        // The answer only changes when you commit -- which happens in another
        // window, and coming back to this one is the moment it matters.
        Activated += delegate { RefreshAddonPublish(); };
        RefreshAddonPublish();

        return y + 44;
    }

    // The next version, by the rule the tags already follow: a, b, c, and then
    // the minor moves on and it starts at a again. 1.0b, 1.0c, 1.1a.
    //
    // Only ever a suggestion -- the box is editable, because the rule cannot
    // know that a release is big enough to deserve the next minor early, and
    // the socialplus tags show that being done.
    static string NextVersion(string latest)
    {
        Match m = Regex.Match(latest ?? "", @"^(\d+)\.(\d+)([a-z])$");
        if (!m.Success) return "";

        int major = int.Parse(m.Groups[1].Value);
        int minor = int.Parse(m.Groups[2].Value);
        char letter = m.Groups[3].Value[0];

        if (letter < 'c') return string.Format("{0}.{1}{2}", major, minor, (char)(letter + 1));
        return string.Format("{0}.{1}a", major, minor + 1);
    }

    // Highest tag of the release shape, ordered as versions rather than as text
    // -- "1.10a" sorts before "1.9a" alphabetically, and 1.10a is the later one.
    string LatestTag()
    {
        string best = null;
        int bestMajor = -1, bestMinor = -1;
        char bestLetter = ' ';

        foreach (string line in Git("tag --list").Split('\n'))
        {
            Match m = Regex.Match(line.Trim(), @"^(\d+)\.(\d+)([a-z])$");
            if (!m.Success) continue;

            int major = int.Parse(m.Groups[1].Value);
            int minor = int.Parse(m.Groups[2].Value);
            char letter = m.Groups[3].Value[0];

            if (major > bestMajor
                || (major == bestMajor && minor > bestMinor)
                || (major == bestMajor && minor == bestMinor && letter > bestLetter))
            {
                bestMajor = major; bestMinor = minor; bestLetter = letter;
                best = m.Groups[0].Value;
            }
        }
        return best;
    }

    string Git(string args)
    {
        try
        {
            var psi = new ProcessStartInfo("git", args);
            psi.WorkingDirectory = AddonRepo;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;

            using (Process p = Process.Start(psi))
            {
                string output = p.StandardOutput.ReadToEnd();
                p.WaitForExit(10000);
                return output;
            }
        }
        catch { return ""; }
    }

    // git, with its exit code and everything it said.
    //
    // The read-only Git above swallows failures because a status that cannot be
    // read is not worth a dialog. Anything that writes has to be able to say
    // what went wrong.
    int GitRun(string args, out string output)
    {
        output = "";
        try
        {
            var psi = new ProcessStartInfo("git", args);
            psi.WorkingDirectory = AddonRepo;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;

            using (Process p = Process.Start(psi))
            {
                output = (p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd()).Trim();
                p.WaitForExit(60000);
                return p.ExitCode;
            }
        }
        catch (Exception e) { output = e.Message; return -1; }
    }

    // What changed, as lines the commit will drop.
    //
    // Not a summary. This window has no way to know *why* anything changed, and
    // that is the half worth writing -- so it fills in the half a machine can
    // actually know: which files, how much, and which functions appeared or
    // went. Facts to write against, not a message to accept.
    //
    // Every line starts with "#", and the commit is made with --cleanup=strip,
    // which is git's own convention for exactly this: the notes disappear unless
    // you move something out of them.
    // C# keywords that match the method shape above and are not methods.
    static readonly string[] NotMethods =
    {
        "if", "for", "foreach", "while", "switch", "catch", "lock", "using",
        "return", "throw", "do", "else", "get", "set", "yield", "when", "fixed",
    };

    // What a file is, in the words somebody writing release notes would use.
    //
    // The paths are accurate and useless for the job the box is for: nobody
    // describes a release as "Modules/ArenaLadder.lua". Anything unlisted keeps
    // its path, which is the honest fallback -- a wrong friendly name would be
    // worse than a filename.
    //
    // "not shipped" matters most. tools/ is in .pkgmeta's ignore list, so those
    // changes reach nobody, and a release note about them is noise.
    static string Plainly(string path)
    {
        if (path.EndsWith("Modules/ArenaLadder.lua"))  return "Ladder window";
        if (path.EndsWith("Modules/ArenaHistory.lua")) return "Match history";
        if (path.EndsWith("Modules/InspectPanel.lua")) return "Inspect panel";
        if (path.EndsWith("Modules/LFGStanding.lua"))  return "Group finder";
        if (path.EndsWith("Modules/MinimapButton.lua"))return "Minimap button";
        if (path.EndsWith("Modules/UnitTooltip.lua"))  return "Unit tooltip";
        if (path.EndsWith("Modules/AuctionPvP.lua"))   return "Auction house";
        if (path.EndsWith("Modules/ArenaMMR.lua"))     return "Rating estimate";
        if (path.EndsWith("Modules/RatedPage.lua"))    return "Rated page";
        if (path.EndsWith("Modules/PvPDefaultPage.lua")) return "PvP page";
        if (path.EndsWith("Locales.lua"))              return "Wording";
        if (path.EndsWith("Core.lua"))                 return "Shared code";
        if (path.StartsWith("tools/"))                 return "Dashboard (not shipped)";
        if (path.StartsWith(".github/"))               return "Release workflow (not shipped)";
        if (path.EndsWith(".pkgmeta"))                 return "Packaging (not shipped)";
        if (path.EndsWith(".toc"))                     return "Addon manifest";
        return path;
    }

    // How a declaration looks in the language this file is written in.
    //
    // Shared by the added/removed scan and by the hunk headers, so both agree on
    // what counts as a name.
    static string NameIn(string file)
    {
        if (file.EndsWith(".lua"))
            return @"^\s*(?:local\s+)?function\s+([A-Za-z_][\w.:]*)";

        if (file.EndsWith(".ps1"))
            return @"^\s*function\s+([A-Za-z_][\w\-]*)";

        if (file.EndsWith(".cs"))
            // Anchored to four spaces, which is where a member sits in a class
            // body here while statements inside a method are indented further.
            // Without the anchor, "if (" indexes as a method called if.
            return @"^    (?:(?:public|private|internal|protected|static|override|"
                 + @"virtual|sealed|async|new|readonly)\s+)*"
                 + @"(?:[A-Za-z_][\w<>\[\],.?]*\s+)?([A-Za-z_]\w*)\s*\(";

        return null;
    }

    // A first draft of the release notes, from what changed since the last tag.
    //
    // Different from Scaffold in three ways that matter, all of them because a
    // player is reading this rather than whoever wrote it:
    //
    //   - the range is the last tag to HEAD, not the working tree. A release is
    //     everything since the last one, not everything not yet committed.
    //   - anything .pkgmeta ignores is left out entirely. The dashboard and the
    //     workflow never reach a download, so a note about them is a lie by
    //     implication.
    //   - no function names, no file table, no line counts. None of it means
    //     anything to somebody installing an addon.
    //
    // What is left is the wording, which is the one part of a diff already
    // written in the player's language.
    string DraftNotes()
    {
        string previous = LatestTag();
        if (previous == null) return "";

        string diff;
        if (GitRun("diff -U0 " + previous + "..HEAD", out diff) != 0) return "";

        var said = new List<string>();
        var areas = new List<string>();

        string file = "";
        foreach (string line in diff.Split('\n'))
        {
            if (line.StartsWith("+++ b/"))
            {
                file = line.Substring(6).Trim();

                string area = Plainly(file);
                if (!area.EndsWith("(not shipped)") && !areas.Contains(area))
                    areas.Add(area);
                continue;
            }

            if (!line.StartsWith("+") || line.StartsWith("+++")) continue;
            if (!file.EndsWith("Locales.lua")) continue;

            Match m = Regex.Match(line.Substring(1), "^\\s*L\\.[A-Z0-9_]+\\s*=\\s*\"(.*)\"");
            if (!m.Success) continue;

            string words = m.Groups[1].Value.Trim();
            if (words.Length == 0) continue;

            // Format templates read badly as a bullet on their own, and the
            // number they carry is the point rather than the sentence.
            if (words.IndexOf('%') >= 0) continue;

            if (!said.Contains(words)) said.Add(words);
        }

        var notes = new List<string>();
        foreach (string words in said) notes.Add(words);

        // Where nothing new was said, name where the work was. Vague, and the
        // honest amount of vague: there is no wording to quote.
        if (notes.Count == 0 && areas.Count > 0)
            notes.Add("Fixes and improvements in " + string.Join(", ", areas.ToArray()) + ".");

        return string.Join("\r\n", notes.ToArray());
    }

    string Scaffold()
    {
        string numstat, status;
        GitRun("diff --numstat HEAD", out numstat);
        GitRun("status --porcelain", out status);

        // Files with their sizes kept, so the list can be ordered by how much
        // actually changed. Sorted by filename it read alphabetically, which put
        // whichever file starts with C at the top and the real work at the
        // bottom.
        var paths = new List<string>();
        var churn = new List<int>();

        foreach (string line in numstat.Split('\n'))
        {
            string[] parts = line.Trim().Split('\t');
            if (parts.Length < 3) continue;

            int plusN, minusN;
            if (!int.TryParse(parts[0], out plusN)) plusN = 0;
            if (!int.TryParse(parts[1], out minusN)) minusN = 0;

            paths.Add(string.Format("{0,-24} +{1,-5} -{2,-5} {3}",
                                    Plainly(parts[2]), parts[0], parts[1], parts[2]));
            churn.Add(plusN + minusN);
        }

        // Biggest first. Insertion sort: this list is never long.
        for (int i = 1; i < paths.Count; i++)
        {
            for (int j = i; j > 0 && churn[j] > churn[j - 1]; j--)
            {
                int c = churn[j]; churn[j] = churn[j - 1]; churn[j - 1] = c;
                string p = paths[j]; paths[j] = paths[j - 1]; paths[j - 1] = p;
            }
        }

        foreach (string line in status.Split('\n'))
        {
            string t = line.Trim();
            if (t.StartsWith("??"))
            {
                paths.Add(t.Substring(2).Trim() + "   (new file)");
                churn.Add(0);
            }
        }

        if (paths.Count == 0) return "";

        var lines = new List<string>();

        // What appeared or went, by the shape of the language it appeared in.
        //
        // One Lua pattern for everything was the first version, and it meant a
        // commit touching only the dashboard listed its files and said nothing
        // whatever about them -- which is the case this window exists for.
        //
        // A rename shows as both a removal and an addition. That is honest: it
        // is both, and the callers may need to know.
        string diff;
        GitRun("diff -U0 HEAD", out diff);

        var added = new List<string>();
        var gone = new List<string>();
        var strings = new List<string>();

        var touched = new List<string>();

        string file = "";
        foreach (string line in diff.Split('\n'))
        {
            // Which file the following hunks belong to.
            if (line.StartsWith("+++ b/")) { file = line.Substring(6).Trim(); continue; }

            // What the change sits inside, which the added/removed lists cannot
            // say: rewriting the body of a function changes neither its
            // declaration nor its name, so it appeared in neither and the most
            // common kind of edit went unmentioned.
            //
            // Git puts the enclosing declaration after the second "@@" of every
            // hunk header, found by its own heuristic and with no configuration
            // needed for Lua. Reading it back is cheaper and more reliable than
            // walking the file for the nearest declaration ourselves.
            if (line.StartsWith("@@"))
            {
                int close = line.IndexOf("@@", 2);
                if (close < 0) continue;

                string context = line.Substring(close + 2).Trim();
                if (context.Length == 0) continue;

                Match head = Regex.Match(context, NameIn(file) ?? "(?!)");
                if (head.Success && !touched.Contains(head.Groups[1].Value))
                    touched.Add(head.Groups[1].Value);
                continue;
            }

            bool plus = line.StartsWith("+") && !line.StartsWith("+++");
            bool minus = line.StartsWith("-") && !line.StartsWith("---");
            if (!plus && !minus) continue;

            string body = line.Substring(1);
            var into = plus ? added : gone;

            // Locale keys first: they are assignments, not declarations, and
            // they are the user-facing text -- a changed one is usually what a
            // release note is actually about.
            if (file.EndsWith("Locales.lua"))
            {
                // The value, not the key. L.LADDER_HOME says nothing; "Home" is
                // the actual new words a player will read, and is as close to a
                // written release note as anything here gets automatically.
                Match loc = Regex.Match(body, "^\\s*L\\.[A-Z0-9_]+\\s*=\\s*\"(.*)\"");
                if (loc.Success)
                {
                    string said = loc.Groups[1].Value;
                    if (said.Length > 96) said = said.Substring(0, 93) + "...";
                    said = "\"" + said + "\"";

                    if (plus && said.Length > 2 && !strings.Contains(said))
                        strings.Add(said);
                    continue;
                }
            }

            string pattern = NameIn(file);
            if (pattern == null) continue;

            Match m = Regex.Match(body, pattern);
            if (!m.Success) continue;

            string name = m.Groups[1].Value;

            // Words that satisfy the C# shape and are not methods.
            if (file.EndsWith(".cs") && Array.IndexOf(NotMethods, name) >= 0) continue;

            if (!into.Contains(name)) into.Add(name);
        }

        // Only what is not already named as added or removed, so a new function
        // is not also listed as one that was touched.
        var changed = new List<string>();
        foreach (string name in touched)
            if (!added.Contains(name) && !gone.Contains(name)) changed.Add(name);

        // The wording first, because it is the only part of a diff written for
        // a player. Everything else here describes the code; these are the
        // actual sentences that will appear on somebody's screen, and they are
        // the closest a program gets to writing a release note.
        if (strings.Count > 0)
        {
            lines.Add("New or changed wording:");
            foreach (string said in strings) lines.Add("  " + said);
            lines.Add("");
        }

        foreach (string p in paths) lines.Add(p);

        var code = new List<string>();
        if (added.Count > 0) code.Add("new " + string.Join(", ", added.ToArray()));
        if (gone.Count > 0) code.Add("gone " + string.Join(", ", gone.ToArray()));
        if (changed.Count > 0) code.Add("changed " + string.Join(", ", changed.ToArray()));

        if (code.Count > 0)
        {
            lines.Add("");
            lines.Add("Code: " + string.Join("; ", code.ToArray()));
        }

        // The subject quotes the new wording rather than naming files.
        //
        // Naming the areas -- "Shared code, Wording, Match history and Ladder
        // window" -- is accurate and says nothing: every commit here touches
        // some files. The new strings are specific to this change and are
        // already in the player's language, so quoting them is both the most
        // concrete thing available and the least invented.
        //
        // Where a change adds no wording at all, the largest area is the
        // fallback. It is vague, but it is honest about there being nothing
        // better to say.
        // Short labels first, then anything else.
        //
        // A subject wants the words that name a feature -- "Home", "Ctrl+C to
        // copy" -- not a format template like "top %d players" or a tooltip
        // that runs to a full sentence. Both still appear in the body; this is
        // only about what leads.
        var headline = new List<string>();
        foreach (string said in strings)
            if (said.Length <= 34 && said.IndexOf('%') < 0) headline.Add(said);
        foreach (string said in strings)
            if (!headline.Contains(said)) headline.Add(said);

        string subject = "";
        foreach (string said in headline)
        {
            string next = (subject.Length == 0) ? said : subject + ", " + said;
            if (next.Length > 62) { if (subject.Length > 0) subject += ", ..."; break; }
            subject = next;
        }

        if (subject.Length == 0)
        {
            foreach (string p in paths)
            {
                int gap = p.IndexOf("  ");
                string area = (gap > 0 ? p.Substring(0, gap) : p).Trim();
                if (area.EndsWith("(not shipped)") || area.Length == 0) continue;
                subject = area;
                break;
            }
        }

        if (subject.Length == 0) subject = "Tooling and packaging";
        if (subject.Length > 68) subject = subject.Substring(0, 65) + "...";

        return subject + "\r\n\r\n" + string.Join("\r\n", lines.ToArray());
    }

    // Commit everything outstanding, with a message you wrote.
    //
    // Everything, deliberately: this window has no way to show a diff, and a
    // partial commit chosen from a list nobody can see is how a change ends up
    // described by a message about a different one.
    //
    // It commits and pushes together. A commit that stays here helps nobody --
    // the release path builds from what is on GitHub -- and leaving the two as
    // separate buttons would only invite the tag to go up without the code.
    // Whether a commit would actually record anything.
    //
    // Asked of the diff rather than of "git status", which is what both callers
    // used to ask and what put an empty message box on screen. This repo lives
    // on a Google Drive letter, and git there regularly reports a file as
    // modified when its bytes are identical to HEAD: the index keeps a stat that
    // Drive has changed underneath it, and neither status nor update-index
    // clears it. Status said Core.lua was modified; the diff said nothing had
    // changed; Scaffold, which writes the message from the diff, had nothing to
    // write. Both were right, and the pair of them was useless.
    //
    // One question, asked of the same source the message comes from: if there is
    // nothing to describe, there is nothing to commit.
    bool HasChanges()
    {
        string numstat, status;

        // Against HEAD, so staged and unstaged both count.
        GitRun("diff --numstat HEAD", out numstat);
        if (numstat.Trim().Length > 0) return true;

        // Untracked files have no diff against HEAD and still need committing.
        GitRun("status --porcelain", out status);
        foreach (string line in status.Split('\n'))
            if (line.Trim().StartsWith("??")) return true;

        return false;
    }

    void CommitChanges()
    {
        if (!HasChanges())
        {
            MessageBox.Show("Nothing to commit.", "ArenaPlus data",
                            MessageBoxButtons.OK, MessageBoxIcon.Information);
            RefreshAddonPublish();
            return;
        }

        string message = AskForText("Commit",
            "Written for you from the diff. Edit it or leave it as it is -- "
            + "the first line is the subject.",
            Scaffold());
        if (message == null) return;

        // Everything typed, minus the notes -- which is what git will be left
        // with, because the commit runs --cleanup=strip.
        //
        // Checked here rather than letting git refuse it. Pressing OK on the
        // scaffold alone is an easy thing to do, and "Aborting commit due to
        // empty commit message" explains neither what happened nor that the
        // hash-marked lines were never going to count.
        //
        // Before "git add -A", so a message that is not going to work does not
        // leave everything staged behind it.
        string written = "";
        foreach (string part in message.Split('\n'))
        {
            string t = part.Trim();
            if (t.Length > 0) written += t;
        }

        if (written.Length == 0)
        {
            MessageBox.Show("The message is empty.",
                            "No message", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }

        commitButton.Enabled = false;
        Cursor = Cursors.WaitCursor;
        try
        {
            string output;
            if (GitRun("add -A", out output) != 0)
            {
                MessageBox.Show("git add failed:\r\n\r\n" + output, "Not committed",
                                MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            // Through a file rather than -m, so a multi-line message survives
            // and nothing has to be escaped for a command line.
            string temp = Path.Combine(Path.GetTempPath(), "arenaplus-commit.txt");
            File.WriteAllText(temp, message);

            // whitespace, not strip: the message is written by Scaffold and has
            // no comment lines to drop. strip would also eat a line that
            // happened to begin with a hash.
            int code = GitRun("commit -q --cleanup=whitespace -F \"" + temp + "\"", out output);
            try { File.Delete(temp); } catch { }

            if (code != 0)
            {
                MessageBox.Show("git commit failed:\r\n\r\n" + output, "Not committed",
                                MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            if (GitRun("push -q origin HEAD", out output) != 0)
            {
                MessageBox.Show("Committed, but the push failed:\r\n\r\n" + output
                                + "\r\n\r\nThe commit is here; push it by hand.",
                                "Committed, not pushed",
                                MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return;
            }

            string shown;
            GitRun("log --oneline -1", out shown);
            MessageBox.Show("Committed and pushed:\r\n\r\n" + shown, "Committed",
                            MessageBoxButtons.OK, MessageBoxIcon.Information);
        }
        finally
        {
            Cursor = Cursors.Default;
            RefreshAddonPublish();
        }
    }

    void RefreshAddonPublish()
    {
        if (versionBox == null) return;

        // The same question the Commit button asks, so the two cannot disagree
        // about whether there is anything here.
        bool dirty = HasChanges();

        // Only read for the names once there is known to be something. Asked
        // first, it lists the phantom modifications this drive invents and the
        // row names files that a commit would not touch.
        string status = dirty ? Git("status --porcelain").Trim() : "";

        string latest = LatestTag();

        // No tags yet, so the .toc is the only thing that has ever named a
        // version. It says "1.0" where a tag would say "1.0a"; reading a
        // missing letter as "a" is what makes the first suggestion 1.0b, which
        // is the right one -- 1.0a is already on CurseForge, uploaded by hand.
        if (latest == null)
        {
            Match m = Regex.Match(TocVersion(), @"^(\d+\.\d+)([a-z]?)$");
            if (m.Success)
                latest = m.Groups[1].Value + (m.Groups[2].Value.Length == 0 ? "a" : m.Groups[2].Value);
        }

        string next = NextVersion(latest);

        // Only when it is untouched or still showing the last suggestion, so a
        // version being typed is never overwritten by a refresh.
        if (versionBox.Text.Trim().Length == 0 || versionBox.Text == versionBox.Tag as string)
        {
            versionBox.Text = next;
            versionBox.Tag = next;
        }

        // Opposites: you commit when there is something to commit, and you
        // release when there is not.
        publishButton.Enabled = !dirty;
        if (commitButton != null) commitButton.Enabled = dirty;

        // Which files, not just that there are some.
        //
        // "uncommitted changes" told you the button was disabled and nothing
        // about why, so the only way to find out was to open a terminal -- which
        // is the thing this row exists to avoid. The names go on the row and the
        // whole list, status letters included, goes in the tooltip.
        addonNote.Text = dirty
            ? Outstanding(status)
            : (latest == null
                ? "never tagged; the .toc says " + TocVersion()
                : "latest tag " + latest);

        tips.SetToolTip(addonNote, dirty ? status : "");
        tips.SetToolTip(commitButton, dirty ? status : "");
    }

    // "Core.lua, Locales.lua +2" from git's porcelain output.
    //
    // Names only, and the leaf rather than the path: "Modules/ArenaLadder.lua"
    // is mostly Modules/ and the row has about two hundred pixels. The full
    // list with its status letters is a hover away.
    static string Outstanding(string status)
    {
        var names = new List<string>();
        foreach (string line in status.Split('\n'))
        {
            string trimmed = line.Trim();
            if (trimmed.Length < 4) continue;

            // Porcelain is two status characters, a space, then the path.
            string path = trimmed.Substring(2).Trim();

            // A rename reads "old -> new"; the new name is the useful half.
            int arrow = path.IndexOf(" -> ");
            if (arrow >= 0) path = path.Substring(arrow + 4);

            int cut = path.LastIndexOfAny(new[] { '/', '\\' });
            names.Add(cut >= 0 ? path.Substring(cut + 1) : path);
        }

        if (names.Count == 0) return "uncommitted changes";
        if (names.Count == 1) return names[0] + " to commit";
        if (names.Count == 2) return names[0] + ", " + names[1];

        return string.Format("{0}, {1} +{2}", names[0], names[1], names.Count - 2);
    }

    string TocVersion()
    {
        try
        {
            foreach (string line in File.ReadAllLines(Path.Combine(AddonRepo, "ArenaPlus.toc")))
                if (line.StartsWith("## Version:"))
                    return line.Substring("## Version:".Length).Trim();
        }
        catch { }
        return "";
    }

    void PublishAddon()
    {
        string version = versionBox.Text.Trim();
        if (!Regex.IsMatch(version, @"^\d+\.\d+[a-z]$"))
        {
            MessageBox.Show("'" + version + "' is not a version of the form 1.0b.",
                            "ArenaPlus data", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        // What players will read, and the only thing they will read.
        //
        // It goes into CHANGELOG-RELEASE.md, which .pkgmeta points CurseForge at
        // and the release workflow copies into the GitHub release, so both say
        // the same thing. Without it CurseForge writes its own from the commits
        // between tags -- reasoning, measured numbers and Co-Authored-By
        // trailers, none of it written for a player.
        //
        // Cancelling here cancels the release. There is no accidental path to
        // publishing without notes.
        string changelog = AskForText("Changelog for " + version,
            "Drafted from what changed since the last release, leaving out anything "
            + "players never receive. Edit it or leave it -- one line per change.",
            DraftNotes());
        if (changelog == null) return;

        // Asked once, because pushing a tag is a build and a download for
        // everybody -- and a tag CurseForge has already built from cannot be
        // taken back quietly.
        if (MessageBox.Show("Tag and push ArenaPlus " + version + "?" + Environment.NewLine +
                            Environment.NewLine + "CurseForge will build a new file from it."
                            + Environment.NewLine + Environment.NewLine + changelog,
                            "ArenaPlus data", MessageBoxButtons.OKCancel, MessageBoxIcon.Question)
            != DialogResult.OK) return;

        // Handed over as a file, not as an argument. Passing it on the command
        // line was tried and measured: a newline written as a backtick-n arrived
        // literally so the whole changelog became one bullet, and a quotation
        // mark in the text split the argument, so three lines of notes reached
        // the script as the single line [- Fixed the "same]. A file has no
        // escaping to get wrong.
        string changelogFile = Path.Combine(Path.GetTempPath(), "arenaplus-changelog.txt");
        try { File.WriteAllText(changelogFile, changelog); }
        catch (Exception e)
        {
            MessageBox.Show("Could not write the changelog:" + Environment.NewLine
                            + Environment.NewLine + e.Message,
                            "ArenaPlus data", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        string script = Path.Combine(tools, "Publish-Addon.ps1");
        if (!File.Exists(script))
        {
            MessageBox.Show("Publish-Addon.ps1 is not beside this window.",
                            "ArenaPlus data", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return;
        }

        publishButton.Enabled = false;
        Cursor = Cursors.WaitCursor;

        string output;
        int code;
        try
        {
            var psi = new ProcessStartInfo("powershell.exe",
                string.Format("-ExecutionPolicy Bypass -NonInteractive -File \"{0}\" "
                              + "-Version {1} -ChangelogFile \"{2}\"",
                              script, version, changelogFile));
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;

            using (Process p = Process.Start(psi))
            {
                output = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
                p.WaitForExit();
                code = p.ExitCode;
            }
        }
        catch (Exception e) { output = e.Message; code = -1; }
        finally
        {
            Cursor = Cursors.Default;
            try { File.Delete(changelogFile); } catch { }
        }

        // The script's own words, whichever way it went: it says more about why
        // it stopped than an exit code can, and it has already written the same
        // thing to Publish-Addon.log.
        MessageBox.Show(output.Trim().Length > 0 ? output.Trim() : "Nothing was reported.",
                        code == 0 ? "Published" : "Not published",
                        MessageBoxButtons.OK,
                        code == 0 ? MessageBoxIcon.Information : MessageBoxIcon.Warning);

        // Cleared so the next refresh suggests the version after this one.
        versionBox.Text = "";
        RefreshAddonPublish();
    }

    // Paint a control and everything under it.
    //
    // By type rather than by name, so it reaches controls that did not exist
    // when it was written -- and so the two dialogs get it by passing their own
    // form in rather than by repeating any of this.
    //
    // Buttons and combo boxes need FlatStyle before their colours mean
    // anything: with the system renderer they paint themselves from the theme
    // and ignore BackColor entirely, which is why a first attempt at this can
    // look like it did nothing.
    static void Darken(Control root)
    {
        foreach (Control c in root.Controls)
        {
            var button = c as Button;
            if (button != null)
            {
                button.FlatStyle = FlatStyle.Flat;
                button.BackColor = PANEL;
                // Only where nothing has already spoken for it. Publish is
                // accented and Pause changes with its state, and a blanket
                // repaint here would quietly flatten both.
                if (button.ForeColor == SystemColors.ControlText) button.ForeColor = TEXT;
                button.FlatAppearance.BorderColor = EDGE;
                button.FlatAppearance.MouseOverBackColor = Color.FromArgb(64, 64, 68);
                button.FlatAppearance.MouseDownBackColor = Color.FromArgb(80, 80, 84);
                continue;
            }

            var combo = c as ComboBox;
            if (combo != null)
            {
                combo.FlatStyle = FlatStyle.Flat;
                combo.BackColor = PANEL;
                combo.ForeColor = TEXT;
                continue;
            }

            var text = c as TextBox;
            if (text != null)
            {
                text.BorderStyle = BorderStyle.FixedSingle;
                text.BackColor = PANEL;
                text.ForeColor = TEXT;
                continue;
            }

            var check = c as CheckBox;
            if (check != null)
            {
                // Left for Windows to draw, unlike everything else here.
                //
                // FlatStyle.Flat paints the box in BackColor and the tick in
                // ForeColor, so on a dark ground it became a dark tick in a dark
                // square -- ticked and invisible, which is worse than either
                // state being obvious. The system box is lighter than the window
                // around it, but it is unambiguous, and a control whose whole
                // job is to show one of two states has to show it.
                check.FlatStyle = FlatStyle.System;
                check.ForeColor = FADED;
                check.BackColor = BACK;
                continue;
            }

            var bar = c as ProgressBar;
            if (bar != null)
            {
                bar.BackColor = PANEL;
                continue;
            }

            // Labels keep whatever colour they were given: the budget line is
            // red or green on purpose and must not be flattened to grey.
            if (c is Label) continue;

            if (c.HasChildren) Darken(c);
        }
    }

    void BuildLayout()
    {
        // Which log each job writes what it spent into.
        spendLog["ladder"]  = new[] { "UpdateFromBlizzard.log", "UpdateSpecs.log" };
        spendLog["inspect"] = new[] { "UpdateInspect.log" };

        int y = 14;

        y = AddPauseRow(y);

        y = AddSection(y, "Ladder, cutoffs, class and spec",
            "Seven requests for the ladder, then class and spec for any new name plus a slice of the " +
            "roster, so everybody comes round once a week. Each region is scheduled on its own clock.",
            "ladder", new[] {
                new JobSlot("US",     "US",     TaskDataUS),
                new JobSlot("EU",     "EU",     TaskDataEU),
                new JobSlot("TBC US", "TBC-US", TaskDataTbcUS),
                new JobSlot("TBC EU", "TBC-EU", TaskDataTbcEU),
            });

        y = AddSection(y, "Gear, talents and glyphs",
            "Everything the inspect panel shows, for the best five of every spec in every bracket. " +
            "About 1,100 requests a region. The TBC rows fetch no glyphs -- that expansion has none.",
            "inspect", new[] {
                new JobSlot("US",     "US",     TaskInspectUS),
                new JobSlot("EU",     "EU",     TaskInspectEU),
                new JobSlot("TBC US", "TBC-US", TaskInspectTbcUS),
                new JobSlot("TBC EU", "TBC-EU", TaskInspectTbcEU),
            });

        y = AddPublishSection(y);
        y = AddAddonPublishSection(y);

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
        summary = AddLabel("", 16, y + 20, 600, 32, false, false);
        y += 58;

        AddLabel("Request budget", 16, y, 300, 20, true, false);
        quota = AddLabel("", 16, y + 20, 600, 44, false, true);
        y += 70;

        // Left of the footer rather than up with the tasks: it is a preference
        // about this window, not about the data.
        trayOption = new CheckBox();
        trayOption.Text = "Minimise to the notification area";
        trayOption.Location = new Point(16, y);
        trayOption.Size = new Size(280, 22);
        trayOption.ForeColor = FADED;
        trayOption.Checked = ReadSetting("minimizeToTray") == "true";
        trayOption.CheckedChanged += delegate
        {
            WriteSetting("minimizeToTray", trayOption.Checked ? "true" : "false");
            // Turning it off with the window already hidden would strand it.
            if (!trayOption.Checked) RestoreFromTray();
        };
        Controls.Add(trayOption);

        footer = AddLabel("", 16, y + 26, 600, 20, false, true);

        // Four rows a section instead of two made this about 140px taller, and
        // the window is FixedSingle with no maximise -- so anything past the
        // screen would simply be unreachable. Clamp to the working area and
        // scroll the remainder rather than growing off the bottom.
        int wanted = y + 56;
        int room = Screen.FromControl(this).WorkingArea.Height - 60;
        if (wanted > room)
        {
            AutoScroll = true;
            ClientSize = new Size(640, room);
        }
        else
        {
            ClientSize = new Size(640, wanted);
        }

        // Last, so it reaches everything the sections above added.
        Darken(this);
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
        menu.Items.Add("Run ladder, cutoffs, class and spec -- TBC US", null, delegate { TryRun(TaskDataTbcUS); });
        menu.Items.Add("Run ladder, cutoffs, class and spec -- TBC EU", null, delegate { TryRun(TaskDataTbcEU); });
        menu.Items.Add("Run gear, talents and glyphs -- US", null, delegate { TryRun(TaskInspectUS); });
        menu.Items.Add("Run gear, talents and glyphs -- EU", null, delegate { TryRun(TaskInspectEU); });
        menu.Items.Add("Run gear and talents -- TBC US", null, delegate { TryRun(TaskInspectTbcUS); });
        menu.Items.Add("Run gear and talents -- TBC EU", null, delegate { TryRun(TaskInspectTbcEU); });
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

    // The next scheduled run, pushed out to a whole interval from now.
    //
    // Running by hand used to leave the timer where it was, so pressing Run now
    // two minutes before a scheduled start got you two runs two minutes apart --
    // one because you asked and one because the clock came round anyway. That is
    // the opposite of what the button is for. It is worse than merely wasteful
    // on the publish row, where a second run means a second tag and a second
    // CurseForge build of data that has barely moved.
    //
    // Windows counts a repetition from its trigger's StartBoundary, so moving
    // that to this moment restarts the cycle. The definition goes back exactly
    // as it came apart from the boundary, so the interval is untouched and a
    // task that is switched off stays switched off -- which matters, because
    // Pause everything works by disabling and this must not quietly undo it.
    void RestartSchedule(string name)
    {
        dynamic folder = RootFolder();
        dynamic definition = folder.GetTask(name).Definition;
        dynamic triggers = definition.Triggers;

        // Nothing to move. The gear tasks began life with no trigger at all,
        // runnable by this button and by nothing else.
        if ((int)triggers.Count == 0) return;

        string now = DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss");
        for (int i = 1; i <= (int)triggers.Count; i++) triggers.Item(i).StartBoundary = now;

        // 6 is TASK_CREATE_OR_UPDATE. The principal is passed back as it came so
        // the task keeps running as whoever owns it rather than being quietly
        // re-registered as somebody else.
        folder.RegisterTaskDefinition(name, definition, 6, null, null,
                                      definition.Principal.LogonType, null);
    }

    void RunTask(string name)
    {
        // Before the run, so the clock has already moved by the time the job
        // starts. In its own try, and swallowed: failing to reschedule is not a
        // reason to refuse the run somebody just asked for -- the worst case is
        // the old behaviour, which is what this replaces rather than repairs.
        try { RestartSchedule(name); }
        catch
        {
            scheduler = null;
            try { RestartSchedule(name); } catch { }
        }

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

            // Only the specs table.
            //
            // This file carries three: the spec slug list, LOOKS_BY_REGION --
            // race and gender for the same characters -- and SPECS_BY_REGION.
            // Counting "]=" across the whole file summed the looks with the
            // specs, which is how this came to report 169% of the ladder as
            // having a spec. It read zero before the path above was corrected,
            // so the double count never had a chance to show.
            int known = 0;
            if (File.Exists(specs))
            {
                string body = SafeRead(specs);
                int from = body.IndexOf("SPECS_BY_REGION[\"" + region + "\"]");
                int open = from >= 0 ? body.IndexOf('{', from) : -1;
                // The table's closing brace is the first one at the start of a
                // line -- every entry inside it is indented.
                int close = open >= 0 ? body.IndexOf("\n}", open) : -1;
                if (close > open)
                    known = Regex.Matches(body.Substring(open, close - open), "\\]=").Count;
            }

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
        if (publishNote != null) publishNote.Text = PublishState();

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
        // Lifted for a dark ground: the old 180/40/40 and 40/130/60 were chosen
        // against white and disappear into it.
        quota.ForeColor = forecast > HourlyCap
            ? Color.FromArgb(235, 110, 110)
            : Color.FromArgb(120, 205, 140);

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
