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
 
 /* Autostart handling, compatible with redshift-gtk's own "Autostart" toggle.
 *
 * redshift-gtk copies its .desktop file to ~/.config/autostart and flips
 * Hidden / X-GNOME-Autostart-enabled. mate-session additionally honours
 * X-MATE-Autostart-enabled (written by "Startup Applications"), so we keep
 * all three in sync. The packaged systemd user unit is an alternative way of
 * autostarting, so it counts too.
 */

namespace MateRedshift.Autostart {

const string DESKTOP = "redshift-gtk.desktop";
const string UNIT = "redshift-gtk.service";
const string GROUP = "Desktop Entry";

string desktop_path () {
    return Path.build_filename (Environment.get_user_config_dir (), "autostart", DESKTOP);
}

string unit_link () {
    return Path.build_filename (Environment.get_user_config_dir (),
                                "systemd", "user", "default.target.wants", UNIT);
}

bool systemd_enabled () {
    return FileUtils.test (unit_link (), FileTest.EXISTS);
}

bool desktop_enabled () {
    var kf = new KeyFile ();
    try {
        kf.load_from_file (desktop_path (), KeyFileFlags.KEEP_COMMENTS | KeyFileFlags.KEEP_TRANSLATIONS);
    } catch (Error e) {
        return false;
    }
    try {
        if (kf.has_key (GROUP, "Hidden") && kf.get_boolean (GROUP, "Hidden"))
            return false;
        foreach (var key in new string[] { "X-GNOME-Autostart-enabled", "X-MATE-Autostart-enabled" }) {
            if (kf.has_key (GROUP, key) && !kf.get_boolean (GROUP, key))
                return false;
        }
    } catch (Error e) {
        return false;
    }
    return true;
}

public bool is_enabled () {
    return desktop_enabled () || systemd_enabled ();
}

KeyFile load_or_seed () throws Error {
    var kf = new KeyFile ();
    var flags = KeyFileFlags.KEEP_COMMENTS | KeyFileFlags.KEEP_TRANSLATIONS;
    if (FileUtils.test (desktop_path (), FileTest.IS_REGULAR)) {
        kf.load_from_file (desktop_path (), flags);
        return kf;
    }
    string full;
    if (kf.load_from_data_dirs (Path.build_filename ("applications", DESKTOP), out full, flags))
        return kf;
    // redshift-gtk isn't installed system-wide; write a minimal entry.
    kf.set_string (GROUP, "Type", "Application");
    kf.set_string (GROUP, "Name", "Redshift");
    kf.set_string (GROUP, "Exec", "redshift-gtk");
    kf.set_string (GROUP, "Icon", "redshift");
    return kf;
}

/* Writes the autostart file. The caller toggles redshift-gtk's tray item
 * separately (when available) so its checkbox stays in sync. */
public void set_enabled (bool on) throws Error {
    var kf = load_or_seed ();
    kf.set_string (GROUP, "Hidden", on ? "false" : "true");
    kf.set_string (GROUP, "X-GNOME-Autostart-enabled", on ? "true" : "false");
    kf.set_string (GROUP, "X-MATE-Autostart-enabled", on ? "true" : "false");
    DirUtils.create_with_parents (Path.get_dirname (desktop_path ()), 0755);
    kf.save_to_file (desktop_path ());

    if (!on && systemd_enabled ()) {
        Process.spawn_command_line_sync ("systemctl --user disable " + UNIT);
    }
}

}
