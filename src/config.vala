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
 
 /* Comment-preserving reader/writer for redshift.conf.
 *
 * Redshift's INI dialect is simple: [section] headers, key=value lines and
 * comments starting with ';' or '#'. Later assignments win. The file is
 * edited line by line so the user's comments and ordering survive.
 */

namespace MateRedshift {

public class RedshiftConfig {
    public string path { get; private set; }
    private GenericArray<string> lines = new GenericArray<string> ();

    private struct Entry {
        int index;
        string? section;
        string key;
        string value;
    }

    /* Paths redshift 1.12 searches in the user's home, in order. */
    public static string[] user_candidates () {
        var home = Environment.get_user_config_dir ();
        return {
            Path.build_filename (home, "redshift", "redshift.conf"),
            Path.build_filename (home, "redshift.conf"),
            Path.build_filename (Environment.get_home_dir (), ".config", "redshift.conf"),
        };
    }

    public static string? system_config () {
        foreach (var dir in Environment.get_system_config_dirs ()) {
            foreach (var p in new string[] {
                Path.build_filename (dir, "redshift", "redshift.conf"),
                Path.build_filename (dir, "redshift.conf") }) {
                if (FileUtils.test (p, FileTest.IS_REGULAR))
                    return p;
            }
        }
        return null;
    }

    /* Debian confines /usr/bin/redshift with AppArmor and only lets it read
     * ~/.config/redshift.conf; any other config file is silently ignored. */
    public static bool apparmor_restricted () {
        if (!FileUtils.test ("/etc/apparmor.d/usr.bin.redshift", FileTest.EXISTS))
            return false;
        try {
            string enabled;
            FileUtils.get_contents ("/sys/module/apparmor/parameters/enabled", out enabled);
            return enabled.strip () == "Y";
        } catch (FileError e) {
            return false;
        }
    }

    public static string apparmor_path () {
        return Path.build_filename (Environment.get_home_dir (), ".config", "redshift.conf");
    }

    /* The file redshift reads, or where a new user config should go. */
    public static string find_path () {
        if (apparmor_restricted ())
            return apparmor_path ();
        var candidates = user_candidates ();
        foreach (var p in candidates) {
            if (FileUtils.test (p, FileTest.IS_REGULAR))
                return p;
        }
        return candidates[0];
    }

    public RedshiftConfig (string? path = null) {
        this.path = path ?? find_path ();
        string? source = this.path;
        if (!FileUtils.test (source, FileTest.IS_REGULAR)) {
            // Seed a new file from another user config (e.g. one redshift
            // can't read under AppArmor), else from the system-wide one.
            source = null;
            foreach (var p in user_candidates ()) {
                if (p != this.path && FileUtils.test (p, FileTest.IS_REGULAR)) {
                    source = p;
                    break;
                }
            }
            if (source == null)
                source = system_config ();
        }
        if (source != null) {
            try {
                string contents;
                FileUtils.get_contents (source, out contents);
                foreach (var l in contents.split ("\n"))
                    lines.add (l);
                // split() leaves an empty element after the final newline.
                if (lines.length > 0 && lines[lines.length - 1] == "")
                    lines.remove_index (lines.length - 1);
            } catch (FileError e) {
                warning ("Could not read %s: %s", source, e.message);
            }
        }
    }

    private static string? section_name (string line) {
        var s = line.strip ();
        if (s.has_prefix ("[") && s.has_suffix ("]"))
            return s.substring (1, s.length - 2).strip ();
        return null;
    }

    private GenericArray<Entry?> entries () {
        var result = new GenericArray<Entry?> ();
        string? section = null;
        for (int i = 0; i < lines.length; i++) {
            var s = lines[i].strip ();
            if (s == "" || s[0] == ';' || s[0] == '#')
                continue;
            var name = section_name (s);
            if (name != null) {
                section = name;
                continue;
            }
            int eq = s.index_of_char ('=');
            if (eq <= 0)
                continue;
            result.add (Entry () {
                index = i,
                section = section,
                key = s.substring (0, eq).strip (),
                value = s.substring (eq + 1).strip ()
            });
        }
        return result;
    }

    public string? get (string section, string key) {
        string? value = null;
        foreach (var e in entries ()) {
            if (e.section == section && e.key == key)
                value = e.value;
        }
        return value;
    }

    public bool has (string section, string key) {
        return get (section, key) != null;
    }

    public double get_double (string section, string key, double fallback) {
        var v = get (section, key);
        double d = 0;
        if (v != null && double.try_parse (v, out d))
            return d;
        return fallback;
    }

    public int get_int (string section, string key, int fallback) {
        return (int) get_double (section, key, fallback);
    }

    public void set (string section, string key, string value) {
        var line = "%s=%s".printf (key, value);
        int last = -1;
        foreach (var e in entries ()) {
            if (e.section == section && e.key == key)
                last = e.index;
        }
        if (last >= 0) {
            lines[last] = line;
            return;
        }

        int header = -1;
        for (int i = 0; i < lines.length; i++) {
            if (section_name (lines[i]) == section)
                header = i;
        }
        if (header < 0) {
            if (lines.length > 0 && lines[lines.length - 1].strip () != "")
                lines.add ("");
            lines.add ("[%s]".printf (section));
            lines.add (line);
            return;
        }

        // Append to the end of the section, before any trailing blank lines.
        int insert_at = header + 1;
        for (int i = header + 1; i < lines.length; i++) {
            if (section_name (lines[i]) != null)
                break;
            if (lines[i].strip () != "")
                insert_at = i + 1;
        }
        lines.insert (insert_at, line);
    }

    public void set_double (string section, string key, double value) {
        char[] buf = new char[double.DTOSTR_BUF_SIZE];
        set (section, key, value.format (buf, "%.2f"));
    }

    public void remove (string section, string key) {
        var doomed = new GenericSet<int> (direct_hash, direct_equal);
        foreach (var e in entries ()) {
            if (e.section == section && e.key == key)
                doomed.add (e.index);
        }
        var kept = new GenericArray<string> ();
        for (int i = 0; i < lines.length; i++) {
            if (!doomed.contains (i))
                kept.add (lines[i]);
        }
        lines = kept;
    }

    public void save () throws Error {
        DirUtils.create_with_parents (Path.get_dirname (path), 0755);
        var sb = new StringBuilder ();
        foreach (var l in lines) {
            sb.append (l);
            sb.append_c ('\n');
        }
        FileUtils.set_contents (path, sb.str);
    }

    /* Parse redshift's "H:MM" or "H:MM-H:MM" into minutes since midnight. */
    public static bool parse_time_range (string? value, out int start, out int end) {
        start = end = 0;
        if (value == null)
            return false;
        var parts = value.split ("-");
        if (parts.length < 1 || parts.length > 2)
            return false;
        int[] mins = {};
        foreach (var p in parts) {
            var hm = p.strip ().split (":");
            int h = 0, m = 0;
            if (hm.length != 2 || !int.try_parse (hm[0], out h) || !int.try_parse (hm[1], out m))
                return false;
            mins += h * 60 + m;
        }
        start = mins[0];
        end = mins[mins.length - 1];
        return true;
    }

    public static string format_time (int minutes) {
        return "%d:%02d".printf (minutes / 60, minutes % 60);
    }
}

}
