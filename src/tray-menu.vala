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

 
/* Drives redshift-gtk's own tray menu over D-Bus.
 *
 * redshift-gtk uses AppIndicator when available, which exports its GtkMenu
 * through com.canonical.dbusmenu. Activating those items runs redshift-gtk's
 * own callbacks, so the tray checkbox, icon, autostart file and suspend timer
 * all stay consistent with what we do here.
 *
 * Items are identified by structure, not by (translated) label:
 *   1st checkmark item  -> "Enabled"
 *   submenu item        -> "Suspend for" (30 min, 1 hour, 2 hours)
 *   2nd checkmark item  -> "Autostart" (only if redshift-gtk has pyxdg)
 */

namespace MateRedshift {

public class TrayMenu : Object {
    const string WATCHER = "org.kde.StatusNotifierWatcher";
    const string ITEM_IFACE = "org.kde.StatusNotifierItem";
    const string MENU_IFACE = "com.canonical.dbusmenu";
    const int TIMEOUT = 1500;

    /* Must match the order of redshift-gtk's "Suspend for" submenu. */
    public const int SUSPEND_MINUTES[] = { 30, 60, 120 };

    public signal void changed ();

    private DBusConnection bus;
    private string name;
    private string menu_path;
    private uint subscription = 0;

    public int enabled_id { get; private set; default = -1; }
    public bool enabled { get; private set; }
    public int autostart_id { get; private set; default = -1; }
    public bool autostart { get; private set; }
    private int suspend_parent = -1;
    private int[] suspend_ids = {};

    private TrayMenu (DBusConnection bus, string name, string menu_path) {
        this.bus = bus;
        this.name = name;
        this.menu_path = menu_path;
        subscription = bus.signal_subscribe (name, MENU_IFACE, null, menu_path, null,
                                             DBusSignalFlags.NONE, () => changed ());
    }

    ~TrayMenu () {
        if (subscription != 0)
            bus.signal_unsubscribe (subscription);
    }

    private static Variant? dbus_property (DBusConnection bus, string dest, string path,
                                          string iface, string prop) {
        try {
            var r = bus.call_sync (dest, path, "org.freedesktop.DBus.Properties", "Get",
                                   new Variant ("(ss)", iface, prop), new VariantType ("(v)"),
                                   DBusCallFlags.NONE, TIMEOUT);
            return r.get_child_value (0).get_variant ();
        } catch (Error e) {
            return null;
        }
    }

    private static int connection_pid (DBusConnection bus, string name) {
        try {
            var r = bus.call_sync ("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                   "org.freedesktop.DBus", "GetConnectionUnixProcessID",
                                   new Variant ("(s)", name), new VariantType ("(u)"),
                                   DBusCallFlags.NONE, TIMEOUT);
            return (int) r.get_child_value (0).get_uint32 ();
        } catch (Error e) {
            return -1;
        }
    }

    /* Collect object paths under `path` that implement StatusNotifierItem. */
    private static void find_items (DBusConnection bus, string dest, string path, int depth,
                                    GenericArray<string> found) {
        DBusNodeInfo node;
        try {
            var r = bus.call_sync (dest, path, "org.freedesktop.DBus.Introspectable", "Introspect",
                                   null, new VariantType ("(s)"), DBusCallFlags.NONE, TIMEOUT);
            node = new DBusNodeInfo.for_xml (r.get_child_value (0).get_string ());
        } catch (Error e) {
            return;
        }
        if (node.lookup_interface (ITEM_IFACE) != null)
            found.add (path);
        if (depth >= 6)
            return;
        foreach (var child in node.nodes) {
            find_items (bus, dest, (path == "/" ? "" : path) + "/" + child.path,
                        depth + 1, found);
        }
    }

    private static TrayMenu? open (DBusConnection bus, string dest, string path) {
        var menu = dbus_property (bus, dest, path, ITEM_IFACE, "Menu");
        if (menu == null)
            return null;
        var tray = new TrayMenu (bus, dest, menu.get_string ());
        try {
            tray.update ();
        } catch (Error e) {
            return null;
        }
        return tray.enabled_id >= 0 ? tray : null;
    }

    /* Locate the tray item of the redshift-gtk process `pid`. `deep` also
     * searches redshift-gtk's own connections, which is slower. */
    public static TrayMenu? find (DBusConnection bus, int pid, bool deep) {
        // Fast path: the StatusNotifierWatcher's list of items, with entries
        // like ":1.90/org/ayatana/NotificationItem/redshift".
        var items = dbus_property (bus, WATCHER, "/StatusNotifierWatcher", WATCHER,
                                   "RegisteredStatusNotifierItems");
        if (items != null) {
            foreach (var entry in items.get_strv ()) {
                if (entry.has_prefix ("/"))
                    continue;
                int slash = entry.index_of_char ('/');
                string dest = slash < 0 ? entry : entry.substring (0, slash);
                string path = slash < 0 ? "/StatusNotifierItem" : entry.substring (slash);
                if (connection_pid (bus, dest) != pid)
                    continue;
                var tray = open (bus, dest, path);
                if (tray != null)
                    return tray;
            }
        }

        // Some hosts (e.g. Ayatana's indicator service) don't publish their
        // item list, so look at redshift-gtk's own bus connections instead.
        if (!deep)
            return null;
        try {
            var r = bus.call_sync ("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                   "org.freedesktop.DBus", "ListNames", null,
                                   new VariantType ("(as)"), DBusCallFlags.NONE, TIMEOUT);
            foreach (var name in r.get_child_value (0).get_strv ()) {
                if (!name.has_prefix (":") || connection_pid (bus, name) != pid)
                    continue;
                var paths = new GenericArray<string> ();
                find_items (bus, name, "/", 0, paths);
                foreach (var path in paths) {
                    var tray = open (bus, name, path);
                    if (tray != null)
                        return tray;
                }
            }
        } catch (Error e) {
            warning ("Cannot list bus names: %s", e.message);
        }
        return null;
    }

    private Variant get_layout (int parent) throws Error {
        var args = new Variant.tuple ({
            new Variant.int32 (parent), new Variant.int32 (-1), new Variant.strv ({})
        });
        var r = bus.call_sync (name, menu_path, MENU_IFACE, "GetLayout", args,
                               new VariantType ("(u(ia{sv}av))"), DBusCallFlags.NONE, TIMEOUT);
        return r.get_child_value (1);
    }

    private static string? prop_string (Variant props, string key) {
        var v = props.lookup_value (key, VariantType.STRING);
        return v != null ? v.get_string () : null;
    }

    private static bool prop_bool (Variant props, string key, bool fallback) {
        var v = props.lookup_value (key, VariantType.BOOLEAN);
        return v != null ? v.get_boolean () : fallback;
    }

    private static int[] child_ids (Variant node) {
        int[] ids = {};
        var children = node.get_child_value (2);
        for (size_t i = 0; i < children.n_children (); i++) {
            var child = children.get_child_value (i).get_variant ();
            var props = child.get_child_value (1);
            if (prop_string (props, "type") == "separator" || !prop_bool (props, "visible", true))
                continue;
            ids += child.get_child_value (0).get_int32 ();
        }
        return ids;
    }

    /* Re-read the menu state. Throws if redshift-gtk went away. */
    public void update () throws Error {
        var root = get_layout (0);
        var children = root.get_child_value (2);
        int checks = 0;
        enabled_id = autostart_id = suspend_parent = -1;

        for (size_t i = 0; i < children.n_children (); i++) {
            var child = children.get_child_value (i).get_variant ();
            int id = child.get_child_value (0).get_int32 ();
            var props = child.get_child_value (1);

            if (prop_string (props, "toggle-type") == "checkmark") {
                var state = props.lookup_value ("toggle-state", VariantType.INT32);
                bool on = state != null && state.get_int32 () == 1;
                if (checks == 0) {
                    enabled_id = id;
                    enabled = on;
                } else if (checks == 1 && prop_bool (props, "enabled", true)) {
                    autostart_id = id;
                    autostart = on;
                }
                checks++;
            } else if (prop_string (props, "children-display") == "submenu" && suspend_parent < 0) {
                suspend_parent = id;
                suspend_ids = child_ids (child);
            }
        }

        // libdbusmenu may only populate a submenu once it is about to be shown.
        if (suspend_parent >= 0 && suspend_ids.length < SUSPEND_MINUTES.length) {
            bus.call_sync (name, menu_path, MENU_IFACE, "AboutToShow",
                           new Variant ("(i)", suspend_parent), null, DBusCallFlags.NONE, TIMEOUT);
            suspend_ids = child_ids (get_layout (suspend_parent));
        }
    }

    public bool can_suspend {
        get { return suspend_ids.length >= SUSPEND_MINUTES.length; }
    }

    public void click (int id) throws Error {
        var args = new Variant.tuple ({
            new Variant.int32 (id), new Variant.string ("clicked"),
            new Variant.variant (new Variant.int32 (0)),
            new Variant.uint32 ((uint32) (get_real_time () / 1000000))
        });
        bus.call_sync (name, menu_path, MENU_IFACE, "Event", args, null,
                       DBusCallFlags.NONE, TIMEOUT);
    }

    /* Activate redshift-gtk's "Suspend for" entry; returns minutes used. */
    public int suspend (int minutes) throws Error {
        int idx = SUSPEND_MINUTES.length - 1;
        for (int i = 0; i < SUSPEND_MINUTES.length; i++) {
            if (SUSPEND_MINUTES[i] >= minutes) {
                idx = i;
                break;
            }
        }
        click (suspend_ids[idx]);
        return SUSPEND_MINUTES[idx];
    }
}

}
