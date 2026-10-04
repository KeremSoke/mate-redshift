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

[CCode (cname = "PACKAGE_VERSION")]
extern const string PACKAGE_VERSION;

namespace MateRedshift {

public class App : Gtk.Application {
    public App () {
        Object (application_id: "com.github.KeremSoke.NightLight",
                flags: ApplicationFlags.DEFAULT_FLAGS);
    }

    protected override void activate () {
        var win = active_window ?? new Window (this);
        win.present ();
    }
}

}

int main (string[] args) {
    Intl.setlocale (LocaleCategory.ALL, "");
    Environment.set_prgname ("mate-redshift");
    Environment.set_application_name (_("Night Light Settings"));
    return new MateRedshift.App ().run (args);
}
