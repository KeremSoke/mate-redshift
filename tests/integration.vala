/* End-to-end test of Controller against the real redshift-gtk code.
 * Run through run-integration.sh, which sets up the fake environment. */

using MateRedshift;

Controller c;
MainLoop loop;
int failures = 0;

void check (bool ok, string what) {
    print ("%s %s\n", ok ? "PASS" : "FAIL", what);
    if (!ok)
        failures++;
}

async void sleep_ms (uint ms) {
    Timeout.add (ms, () => { sleep_ms.callback (); return Source.REMOVE; });
    yield;
}

/* Poll until cond holds (refreshing state), or time out. */
async bool wait_for (owned Func0<bool> cond, uint ms = 8000) {
    for (uint t = 0; t < ms; t += 200) {
        c.refresh ();
        if (cond ())
            return true;
        yield sleep_ms (200);
    }
    return false;
}

delegate bool Func0<T> ();

string read_log () {
    string s = "";
    try {
        FileUtils.get_contents (Environment.get_variable ("FAKE_REDSHIFT_LOG"), out s);
    } catch (Error e) {}
    return s;
}

string autostart_file () {
    string s = "";
    try {
        FileUtils.get_contents (Path.build_filename (Environment.get_user_config_dir (),
                                                     "autostart", "redshift-gtk.desktop"), out s);
    } catch (Error e) {}
    return s;
}

async void run () {
    c = new Controller ();
    check (!c.running, "nothing running initially");

    c.launch ();
    check (yield wait_for (() => c.running && c.tray != null), "launch: redshift-gtk up with tray menu");
    check (c.enabled, "starts enabled");
    check (c.can_suspend, "suspend submenu found");
    check (c.process.comm == "redshift-gtk", "found by process name");
    var child = c.find_redshift_child ();
    check (child != null, "redshift child found");

    c.request_enabled (false);
    check (yield wait_for (() => !c.enabled), "disable via tray menu");
    check ("status off" in read_log (), "redshift child actually received toggle");
    check (!c.tray.enabled, "tray checkbox unticked");

    c.request_enabled (true);
    check (yield wait_for (() => c.enabled), "re-enable via tray menu");

    // Toggle from "the tray" side (signal relay), make sure we see it.
    Posix.kill (c.process.pid, Posix.Signal.USR1);
    check (yield wait_for (() => !c.enabled), "external toggle (SIGUSR1 relay) observed");
    c.request_enabled (true);
    yield wait_for (() => c.enabled);

    try {
        c.request_autostart (true);
    } catch (Error e) { check (false, e.message); }
    var f = autostart_file ();
    check ("Hidden=false" in f && "X-MATE-Autostart-enabled=true" in f &&
           "X-GNOME-Autostart-enabled=true" in f, "autostart on: file keys");
    check (yield wait_for (() => c.tray.autostart), "autostart on: tray checkbox ticked");
    check (c.autostart, "autostart reported on");
    try {
        c.request_autostart (false);
    } catch (Error e) { check (false, e.message); }
    f = autostart_file ();
    check ("Hidden=true" in f && "X-MATE-Autostart-enabled=false" in f, "autostart off: file keys");
    check (yield wait_for (() => !c.tray.autostart), "autostart off: tray checkbox unticked");

    c.suspend (30);
    check (yield wait_for (() => !c.enabled), "suspend disables");
    check (c.suspend_until > get_real_time () / 1000000 + 29 * 60, "suspend deadline recorded");

    var old_pid = c.process.pid;
    yield c.restart ();
    check (c.running && c.process.pid != old_pid, "restart: new redshift-gtk instance");
    check (c.tray != null, "restart: tray reconnected");
    check (yield wait_for (() => !c.enabled), "restart: still suspended");
    check (c.suspend_until > 0, "restart: suspend re-armed");

    c.request_enabled (true);
    check (yield wait_for (() => c.enabled && c.suspend_until == 0), "enable clears suspend");


    // Live preview: freezes redshift, shows only the latest value, then restores.
    child = c.find_redshift_child ();
    for (int t = 3000; t <= 3200; t += 100)
        c.show_live ("/nonexistent", t, 0.8);
    var frozen = ProcInfo.read (child.pid);
    check (frozen != null && frozen.state == 'T', "preview: redshift frozen");
    check (yield wait_for (() => "-P -O 3200 -b 0.80:0.80" in read_log (), 3000),
           "preview: latest value applied");
    yield sleep_ms (1500);   // let redshift -p report the current temperature
    c.end_preview ();
    var thawed = ProcInfo.read (child.pid);
    check (thawed != null && thawed.state != 'T', "preview: redshift resumed");
    check (read_log ().has_suffix ("run -P -O 4100\n"), "preview: restored current temperature");

    // Applying while a preview is shown restarts normally.
    c.show_live ("/nonexistent", 3400, 1.0);
    old_pid = c.process.pid;
    yield c.restart ();
    check (c.running && c.process.pid != old_pid, "apply: new instance");
    check (!c.previewing, "apply: preview ended");
    check (ProcInfo.read (child.pid) == null || ProcInfo.read (child.pid).state == 'Z',
           "apply: old redshift gone");
    var new_child = c.find_redshift_child ();
    check (new_child != null && new_child.state != 'T', "apply: new redshift running");
    check (c.enabled, "apply: still enabled");

    // Quit redshift-gtk the way its menu does.
    Posix.kill (c.process.pid, Posix.Signal.TERM);
    check (yield wait_for (() => !c.running), "redshift-gtk exit noticed");
    check (!c.enabled, "reported disabled when not running");

    loop.quit ();
}

int main () {
    string[] argv = {};
    unowned string[] a = argv;
    Gtk.init (ref a);
    loop = new MainLoop ();
    run.begin ();
    loop.run ();
    print ("%d failure(s)\n", failures);
    return failures == 0 ? 0 : 1;
}
