/*
 * Copyright (C) 2026 Kerem Soke
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <https://www.gnu.org/licenses/>.
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/* Tracks and controls the running redshift-gtk instance.
 *
 * redshift-gtk has no IPC of its own. We use, in order of preference:
 *   - its tray menu over dbusmenu (full, two-way integration), see TrayMenu;
 *   - SIGUSR1 to redshift-gtk, which it relays to its redshift child and then
 *     picks up the new status from redshift's output (toggle only, state is
 *     tracked by us and can't see toggles made from the tray).
 */

namespace MateRedshift {

/* A process found in /proc. */
public class ProcInfo : Object {
    public int pid;
    public int ppid;
    public string start_time;
    public char state;
    public string comm;
    public string[] argv;

    public static ProcInfo? read (int pid) {
        var dir = "/proc/%d".printf (pid);
        var info = new ProcInfo ();
        info.pid = pid;
        try {
            string stat;
            FileUtils.get_contents (dir + "/stat", out stat);
            // Fields after the parenthesised comm; comm itself may contain spaces.
            var rest = stat.substring (stat.last_index_of_char (')') + 2).split (" ");
            info.state = rest[0][0];
            info.ppid = int.parse (rest[1]);
            info.start_time = rest[19];

            FileUtils.get_contents (dir + "/comm", out info.comm);
            info.comm = info.comm.strip ();

            uint8[] raw;
            FileUtils.get_data (dir + "/cmdline", out raw);
            string[] args = {};
            int begin = 0;
            for (int i = 0; i < raw.length; i++) {
                if (raw[i] == 0) {
                    args += (string) raw[begin:i];
                    begin = i + 1;
                }
            }
            info.argv = args;
        } catch (Error e) {
            return null;
        }
        return info;
    }

    public static GenericArray<ProcInfo> list_own () {
        var result = new GenericArray<ProcInfo> ();
        var uid = Posix.getuid ();
        try {
            var dir = Dir.open ("/proc");
            string? name;
            while ((name = dir.read_name ()) != null) {
                int pid;
                if (!int.try_parse (name, out pid))
                    continue;
                Posix.Stat st;
                if (Posix.stat ("/proc/" + name, out st) != 0 || st.st_uid != uid)
                    continue;
                var info = read (pid);
                if (info != null)
                    result.add (info);
            }
        } catch (Error e) {
            warning ("Cannot list processes: %s", e.message);
        }
        return result;
    }

    public bool alive () {
        var now = read (pid);
        return now != null && now.start_time == start_time && now.state != 'Z';
    }

    /* Index of the redshift-gtk script in argv, or -1. */
    public int script_index () {
        for (int i = 0; i < argv.length && i < 4; i++) {
            if (Path.get_basename (argv[i]) == "redshift-gtk")
                return i;
        }
        return -1;
    }

    /* Arguments redshift-gtk was started with. */
    public string[] gtk_args () {
        string[] args = {};
        int idx = script_index ();
        for (int i = idx + 1; idx >= 0 && i < argv.length; i++)
            args += argv[i];
        return args;
    }

    public string? systemd_unit () {
        try {
            string cgroup;
            FileUtils.get_contents ("/proc/%d/cgroup".printf (pid), out cgroup);
            if ("/redshift-gtk.service" in cgroup)
                return "redshift-gtk.service";
        } catch (Error e) {}
        return null;
    }
}

public class Controller : Object {

    /* Overridable for testing. */
    public static string gtk_command () {
        return Environment.get_variable ("MATE_REDSHIFT_GTK") ?? "redshift-gtk";
    }

    public static string redshift_command () {
        return Environment.get_variable ("MATE_REDSHIFT_BIN") ?? "redshift";
    }

    public signal void changed ();

    public ProcInfo? process { get; private set; }
    public TrayMenu? tray { get; private set; }
    public bool running { get { return process != null; } }
    public bool enabled { get; private set; }
    public bool autostart { get; private set; }
    public bool busy { get; private set; }
    public int64 suspend_until { get; private set; }

    /* redshift-gtk's -c argument, and options that override redshift.conf. */
    public string? config_override { get; private set; }
    public string[] overriding_options { get; private set; default = {}; }

    private DBusConnection? bus;
    private bool enabled_guess = true;
    private int64 last_tray_search = 0;
    private bool restart_pending = false;

    public Controller () {
        try {
            bus = Bus.get_sync (BusType.SESSION);
        } catch (Error e) {
            warning ("No session bus: %s", e.message);
        }
        refresh ();
        Timeout.add_seconds (2, () => {
            if (!busy)
                refresh ();
            return Source.CONTINUE;
        });
    }

    private static int64 now () {
        return get_real_time () / 1000000;
    }

    private static async void sleep_ms (uint ms) {
        Timeout.add (ms, () => {
            sleep_ms.callback ();
            return Source.REMOVE;
        });
        yield;
    }

    /* ---- state persisted per redshift-gtk instance ---- */

    private static string state_path () {
        return Path.build_filename (Environment.get_user_runtime_dir (), "mate-redshift.state");
    }

    private void load_state () {
        enabled_guess = true;    // redshift-gtk always starts enabled
        suspend_until = 0;
        var kf = new KeyFile ();
        try {
            kf.load_from_file (state_path (), KeyFileFlags.NONE);
            if (kf.get_integer ("state", "pid") == process.pid &&
                kf.get_string ("state", "start") == process.start_time) {
                enabled_guess = kf.get_boolean ("state", "enabled");
                suspend_until = kf.get_int64 ("state", "suspend-until");
            }
        } catch (Error e) {}
    }

    private void save_state () {
        if (process == null)
            return;
        var kf = new KeyFile ();
        kf.set_integer ("state", "pid", process.pid);
        kf.set_string ("state", "start", process.start_time);
        kf.set_boolean ("state", "enabled", enabled_guess);
        kf.set_int64 ("state", "suspend-until", suspend_until);
        try {
            kf.save_to_file (state_path ());
        } catch (Error e) {}
    }

    /* ---- discovery ---- */

    private ProcInfo? find_gtk () {
        // With an overridden command (e.g. the test suite), only ever touch
        // instances of that command, never a real redshift-gtk.
        var custom = Environment.get_variable ("MATE_REDSHIFT_GTK");
        ProcInfo? fallback = null;
        foreach (var p in ProcInfo.list_own ()) {
            if (p.state == 'Z')
                continue;
            if (custom != null && !(custom in p.argv))
                continue;
            // redshift-gtk sets its process name with prctl().
            if (p.comm == "redshift-gtk")
                return p;
            if (p.script_index () == 1)
                fallback = p;
        }
        return fallback;
    }

    public ProcInfo? find_redshift_child () {
        if (process == null)
            return null;
        foreach (var p in ProcInfo.list_own ()) {
            if (p.ppid == process.pid && p.comm == "redshift")
                return p;
        }
        return null;
    }

    private void parse_arguments () {
        config_override = null;
        string[] overriding = {};
        int idx = process.script_index ();
        var args = process.argv;
        for (int i = idx + 1; idx >= 0 && i < args.length; i++) {
            var a = args[i];
            if (a == "-c" && i + 1 < args.length) {
                config_override = args[++i];
            } else if (a.has_prefix ("-c") && a.length > 2) {
                config_override = a.substring (2);
            } else if (a.length >= 2 && a[0] == '-' && "ltbgm".index_of_char (a[1]) >= 0) {
                overriding += a.substring (0, 2);
            }
        }
        overriding_options = overriding;
    }

    public void refresh () {
        var p = find_gtk ();
        bool fresh = p == null || process == null || p.pid != process.pid ||
                     p.start_time != process.start_time;
        if (fresh) {
            tray = null;
            process = p;
            if (p != null) {
                load_state ();
                parse_arguments ();
            } else {
                config_override = null;
                overriding_options = {};
            }
            // Never leave redshift frozen if a previous preview was interrupted.
            var child = find_redshift_child ();
            if (child != null && child.state == 'T' && preview_stopped_pid == 0)
                Posix.kill (child.pid, Posix.Signal.CONT);
        }

        if (process != null && tray == null && bus != null) {
            // The deep search walks the whole bus, so rate-limit it.
            bool deep = fresh || busy || now () - last_tray_search >= 6;
            if (deep)
                last_tray_search = now ();
            tray = TrayMenu.find (bus, process.pid, deep);
            if (tray != null)
                tray.changed.connect (() => { if (!busy) refresh (); });
        } else if (tray != null) {
            try {
                tray.update ();
            } catch (Error e) {
                tray = null;
            }
        }

        if (process == null) {
            enabled = false;
        } else if (tray != null) {
            enabled = enabled_guess = tray.enabled;
        } else {
            enabled = enabled_guess;
        }
        if (enabled || suspend_until <= now ())
            suspend_until = 0;
        autostart = Autostart.is_enabled ();
        save_state ();
        changed ();
    }

    /* ---- actions ---- */

    public void request_enabled (bool on) {
        if (process == null) {
            if (on)
                launch ();
            return;
        }
        if (tray != null) {
            try {
                if (tray.enabled != on)
                    tray.click (tray.enabled_id);
            } catch (Error e) {
                warning ("Tray toggle failed: %s", e.message);
                tray = null;
            }
        }
        if (tray == null && enabled_guess != on) {
            Posix.kill (process.pid, Posix.Signal.USR1);
            enabled_guess = on;
        }
        suspend_until = 0;
        Timeout.add (300, () => { refresh (); return Source.REMOVE; });
    }

    public bool can_suspend {
        get { return tray != null && tray.can_suspend; }
    }

    public void suspend (int minutes) {
        if (!can_suspend)
            return;
        try {
            int used = tray.suspend (minutes);
            suspend_until = now () + used * 60;
            save_state ();
        } catch (Error e) {
            warning ("Suspend failed: %s", e.message);
        }
        Timeout.add (300, () => { refresh (); return Source.REMOVE; });
    }

    public void request_autostart (bool on) throws Error {
        Autostart.set_enabled (on);
        // Keep redshift-gtk's own checkbox in sync; it rewrites the same keys.
        if (tray != null && tray.autostart_id >= 0 && tray.autostart != on)
            tray.click (tray.autostart_id);
        refresh ();
    }

    /* Start redshift-gtk detached from us, keeping `args` from a previous
     * instance. */
    public void launch (string[] args = {}) {
        try {
            if (Autostart.systemd_enabled ()) {
                Process.spawn_command_line_async ("systemctl --user start " + Autostart.UNIT);
            } else {
                string[] argv = { gtk_command () };
                foreach (var a in args)
                    argv += a;
                Pid pid;
                Process.spawn_async (null, argv, null,
                                     SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL |
                                     SpawnFlags.STDERR_TO_DEV_NULL,
                                     () => { Posix.setsid (); }, out pid);
            }
        } catch (Error e) {
            warning ("Could not start redshift-gtk: %s", e.message);
        }
        Timeout.add (1500, () => { refresh (); return Source.REMOVE; });
    }

    public string config_path () {
        return config_override ?? RedshiftConfig.find_path ();
    }

    private async void stop (ProcInfo old) {
        Posix.kill (old.pid, Posix.Signal.TERM);
        // redshift fades back to neutral before exiting; give it time.
        for (int i = 0; i < 60 && old.alive (); i++)
            yield sleep_ms (100);
        if (old.alive ()) {
            foreach (var p in ProcInfo.list_own ()) {
                if (p.ppid == old.pid)
                    Posix.kill (p.pid, Posix.Signal.KILL);
            }
            Posix.kill (old.pid, Posix.Signal.KILL);
        }
    }

    /* Restart redshift-gtk so it re-reads redshift.conf, then restore the
     * enabled/suspended state it had. */
    public async void restart () {
        if (busy) {
            restart_pending = true;
            return;
        }
        busy = true;
        changed ();
        do {
            restart_pending = false;
            refresh ();
            var old = process;
            if (old == null) {
                // Nothing running; the new config is picked up on next start.
                end_preview ();
                break;
            }
            bool was_enabled = enabled;
            int64 until = suspend_until;
            var unit = old.systemd_unit ();
            var args = old.gtk_args ();

            // redshift must be running again to exit; the restart replaces
            // whatever the preview shows anyway.
            end_preview (false);
            if (unit != null) {
                try {
                    Process.spawn_command_line_async ("systemctl --user restart " + unit);
                } catch (Error e) {
                    warning ("%s", e.message);
                }
            } else {
                yield stop (old);
                launch (args);
            }

            // Wait for the new instance and, if it has one, its tray menu.
            for (int i = 0; i < 80; i++) {
                yield sleep_ms (100);
                refresh ();
                if (process != null && process.pid != old.pid && (tray != null || i >= 40))
                    break;
            }

            if (process != null && process.pid != old.pid && !was_enabled) {
                int64 remaining = until - now ();
                if (remaining > 0 && can_suspend)
                    suspend ((int) ((remaining + 59) / 60));
                else
                    request_enabled (false);
            }
        } while (restart_pending);
        busy = false;
        refresh ();
    }

    /* ---- preview ---- */

    private bool preview_active = false;
    private int preview_stopped_pid = 0;
    private int restore_temp = 0;
    private string[]? pending_args = null;
    private bool applying = false;

    private string[] redshift_argv (string config_path, string[] extra) {
        string[] argv = { redshift_command () };
        if (FileUtils.test (config_path, FileTest.IS_REGULAR)) {
            argv += "-c";
            argv += config_path;
        }
        foreach (var e in extra)
            argv += e;
        return argv;
    }

    private void run_redshift (string config_path, string[] extra) {
        try {
            Process.spawn_sync (null, redshift_argv (config_path, extra), null,
                                SpawnFlags.SEARCH_PATH | SpawnFlags.STDOUT_TO_DEV_NULL |
                                SpawnFlags.STDERR_TO_DEV_NULL, null);
        } catch (Error e) {
            warning ("redshift failed: %s", e.message);
        }
    }

    public bool previewing { get { return preview_active; } }

    /* Freeze the running redshift so it doesn't overwrite what we show. */
    private void freeze (string config_path) {
        if (preview_active)
            return;
        preview_active = true;
        restore_temp = 0;
        var child = find_redshift_child ();
        if (child != null) {
            Posix.kill (child.pid, Posix.Signal.STOP);
            preview_stopped_pid = child.pid;
            if (enabled)
                compute_current_temp.begin (config_path);
        }
    }

    /* Run the newest requested one-shot adjustment; intermediate ones
     * requested while a slider is dragged are skipped. */
    private async void apply_pending () {
        applying = true;
        while (pending_args != null) {
            var argv = pending_args;
            pending_args = null;
            try {
                var proc = new Subprocess.newv (argv, SubprocessFlags.STDOUT_SILENCE |
                                                SubprocessFlags.STDERR_SILENCE);
                yield proc.wait_async ();
            } catch (Error e) {
                warning ("redshift failed: %s", e.message);
            }
        }
        applying = false;
    }

    /* Show a color setting on screen until end_preview() or a restart. */
    public void show_live (string config_path, int temp, double brightness) {
        freeze (config_path);
        char[] buf = new char[double.DTOSTR_BUF_SIZE];
        var b = brightness.format (buf, "%.2f");
        pending_args = redshift_argv (config_path, {
            "-P", "-O", temp.to_string (), "-b", "%s:%s".printf (b, b)
        });
        if (!applying)
            apply_pending.begin ();
    }

    /* Ask redshift what it would set right now, to restore without a flash. */
    private async void compute_current_temp (string config_path) {
        try {
            var proc = new Subprocess.newv (redshift_argv (config_path, { "-p" }),
                                            SubprocessFlags.STDOUT_PIPE | SubprocessFlags.STDERR_SILENCE);
            string out_text;
            yield proc.communicate_utf8_async (null, null, out out_text, null);
            var re = new Regex ("Color temperature: (\\d+)K");
            MatchInfo m;
            if (re.match (out_text, 0, out m))
                restore_temp = int.parse (m.fetch (1));
        } catch (Error e) {}
    }

    /* Stop previewing. With `restore`, put back what redshift would show;
     * without, the caller is about to replace redshift anyway. */
    public void end_preview (bool restore = true) {
        if (!preview_active)
            return;
        preview_active = false;
        pending_args = null;
        if (restore) {
            if (running && enabled && restore_temp > 0)
                run_redshift (config_path (), { "-P", "-O", restore_temp.to_string () });
            else if (!running || !enabled)
                run_redshift (config_path (), { "-x" });
            // Otherwise the resumed redshift reapplies its value within seconds.
        }
        if (preview_stopped_pid != 0) {
            Posix.kill (preview_stopped_pid, Posix.Signal.CONT);
            preview_stopped_pid = 0;
        }
    }
}

}
