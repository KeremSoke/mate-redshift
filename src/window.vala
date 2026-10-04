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
 
namespace MateRedshift {

public class Window : Gtk.ApplicationWindow {
    const int DEFAULT_NIGHT = 4500;
    const int DEFAULT_DAY = 6500;
    const int TRANSITION = 30;   // minutes of fade for a manual schedule
    const uint PREVIEW_HOLD = 3000;   // ms a live preview stays after the last change
    const string S = "redshift";

    const string CSS = """
        .night-light-scale trough {
            background-image: linear-gradient(to right, #fde3c4, #f47a2f);
            border: none;
            min-height: 8px;
            border-radius: 4px;
        }
        .night-light-scale highlight {
            background-image: none;
            background-color: transparent;
            border-color: transparent;
        }
        .dim-label { opacity: 0.6; }
        .night-light-list > row > separator,
        .night-light-list separator {
            min-height: 1px;
            background-color: alpha(currentColor, 0.15);
        }
        .night-light-list button.apply {
            border: 1px solid alpha(currentColor, 0.25);
            border-radius: 3px;
            padding: 6px;
        }
    """;

    private Controller controller;
    private RedshiftConfig config;
    private bool updating = false;
    private bool dirty = false;       // changes not yet applied
    private uint preview_timer = 0;
    private Gtk.SizeGroup label_group = new Gtk.SizeGroup (Gtk.SizeGroupMode.HORIZONTAL);

    private Gtk.InfoBar info_bar;
    private Gtk.Label info_label;
    private Gtk.Switch enable_switch;
    private Gtk.Label enable_subtitle;
    private Gtk.Scale night_scale;
    private Gtk.Label night_value;
    private Gtk.Button apply_button;
    private Gtk.Stack apply_stack;
    private Gtk.Spinner apply_spinner;

    private Gtk.ListBox schedule_list;
    private Gtk.ComboBoxText schedule_combo;
    private Gtk.ComboBoxText location_combo;
    private Gtk.SpinButton lat_spin;
    private Gtk.SpinButton lon_spin;
    private Gtk.SpinButton from_hour;
    private Gtk.SpinButton from_min;
    private Gtk.SpinButton to_hour;
    private Gtk.SpinButton to_min;
    private Gtk.Label schedule_error;
    private Gtk.ListBoxRow location_row;
    private Gtk.ListBoxRow lat_row;
    private Gtk.ListBoxRow lon_row;
    private Gtk.ListBoxRow from_row;
    private Gtk.ListBoxRow to_row;
    private Gtk.ListBoxRow error_row;

    private Gtk.Switch autostart_switch;
    private Gtk.Box suspend_box;
    private Gtk.Label status_label;
    private Gtk.Button status_button;

    private Gtk.SpinButton day_spin;
    private Gtk.Scale brightness_scale;
    private Gtk.Switch fade_switch;
    private Gtk.Label path_label;
    private Gtk.ScrolledWindow scroller;
    private Gtk.Widget content;

    public Window (Gtk.Application application) {
        Object (application: application, title: _("Night Light Settings"), icon_name: "redshift",
                resizable: false);

        var css = new Gtk.CssProvider ();
        try {
            css.load_from_data (CSS);
        } catch (Error e) {}
        Gtk.StyleContext.add_provider_for_screen (Gdk.Screen.get_default (), css,
                                                  Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION);

        controller = new Controller ();
        config = new RedshiftConfig (controller.config_override);

        build ();
        load_settings ();
        update_status ();
        controller.changed.connect (update_status);
        fix_height ();

        delete_event.connect (() => {
            if (dirty) {
                // Don't lose changes; keep the app alive until applied.
                var app = application;
                app.hold ();
                apply_now (() => {
                    app.release ();
                    return Source.REMOVE;
                });
            }
            return false;
        });
        destroy.connect (() => controller.end_preview ());
    }

    /* Pin the scrolled area to the content's initial height. */
    private void fix_height () {
        int min, natural;
        content.get_preferred_height (out min, out natural);
        scroller.min_content_height = natural;
        scroller.max_content_height = natural;
    }

    /* ---- layout helpers ---- */

    private Gtk.ListBox new_list (Gtk.Box parent) {
        var frame = new Gtk.Frame (null);
        frame.shadow_type = Gtk.ShadowType.IN;
        var list = new Gtk.ListBox ();
        list.selection_mode = Gtk.SelectionMode.NONE;
        list.get_style_context ().add_class ("night-light-list");
        list.set_header_func ((row, before) => {
            if (before != null && row.get_header () == null)
                row.set_header (new Gtk.Separator (Gtk.Orientation.HORIZONTAL));
        });
        frame.add (list);
        parent.pack_start (frame, false, false, 0);
        return list;
    }

    private Gtk.ListBoxRow add_row (Gtk.ListBox list, Gtk.Widget content) {
        var row = new Gtk.ListBoxRow ();
        row.activatable = false;
        content.margin_start = content.margin_end = 16;
        content.margin_top = content.margin_bottom = 8;
        row.add (content);
        list.add (row);
        return row;
    }

    private Gtk.ListBoxRow add_labeled (Gtk.ListBox list, string text, Gtk.Widget widget,
                                       bool expand_widget = false) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        var label = new Gtk.Label (text);
        label.xalign = 0;
        label.hexpand = !expand_widget;
        if (expand_widget)
            label_group.add_widget (label);
        box.pack_start (label, !expand_widget, true, 0);
        widget.valign = Gtk.Align.CENTER;
        if (expand_widget)
            widget.hexpand = true;
        box.pack_end (widget, expand_widget, true, 0);
        return add_row (list, box);
    }

    private Gtk.SpinButton time_spin (int max, int step) {
        var spin = new Gtk.SpinButton.with_range (0, max, step);
        spin.wrap = true;
        spin.numeric = true;
        spin.width_chars = 2;
        spin.output.connect (() => {
            spin.text = "%02d".printf ((int) spin.adjustment.value);
            return true;
        });
        spin.value_changed.connect (schedule_changed);
        return spin;
    }

    private Gtk.Box time_box (out Gtk.SpinButton hour, out Gtk.SpinButton minute) {
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 4);
        hour = time_spin (23, 1);
        minute = time_spin (59, 5);
        box.pack_start (hour, false, false, 0);
        box.pack_start (new Gtk.Label (":"), false, false, 0);
        box.pack_start (minute, false, false, 0);
        return box;
    }

    /* ---- UI ---- */

    private Gtk.MenuItem menu_item (Gtk.Menu menu, string label, Gtk.AccelGroup accel,
                                    uint key, Gdk.ModifierType mods) {
        var item = new Gtk.MenuItem.with_mnemonic (label);
        if (key != 0)
            item.add_accelerator ("activate", accel, key, mods, Gtk.AccelFlags.VISIBLE);
        menu.append (item);
        return item;
    }

    private Gtk.MenuBar build_menubar () {
        var accel = new Gtk.AccelGroup ();
        add_accel_group (accel);

        var menu = new Gtk.Menu ();
        menu.accel_group = accel;
        menu_item (menu, _("_Help"), accel, Gdk.Key.F1, 0).activate.connect (open_help);
        menu_item (menu, _("_About"), accel, 0, 0).activate.connect (show_about);
        menu.append (new Gtk.SeparatorMenuItem ());
        menu_item (menu, _("_Quit"), accel, Gdk.Key.q, Gdk.ModifierType.CONTROL_MASK)
            .activate.connect (() => close ());

        var top = new Gtk.MenuItem.with_mnemonic (_("_Night Light"));
        top.submenu = menu;
        var bar = new Gtk.MenuBar ();
        bar.append (top);
        return bar;
    }

    private void open_help () {
        // Redshift's manual page in the MATE help browser, else its website.
        try {
            Gtk.show_uri_on_window (this, "man:redshift", Gtk.get_current_event_time ());
        } catch (Error e) {
            try {
                Gtk.show_uri_on_window (this, "http://jonls.dk/redshift/", Gtk.get_current_event_time ());
            } catch (Error e2) {
                show_error (_("Could not open help"), e2.message);
            }
        }
    }

    private void show_about () {
        Gtk.show_about_dialog (this,
            "program-name", _("Night Light Settings"),
            "version", PACKAGE_VERSION,
            "logo-icon-name", "redshift",
            "comments", _("Night light settings for MATE, powered by redshift-gtk."),
            "website", "http://jonls.dk/redshift/",
            "website-label", _("Redshift website"),
            "license-type", Gtk.License.GPL_3_0);
    }

    private void build () {
        var root = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        add (root);
        root.pack_start (build_menubar (), false, false, 0);

        // The window keeps the size it opens with; content that grows later
        // (e.g. opening "Advanced") scrolls instead. See fix_height ().
        root.width_request = 560;
        scroller = new Gtk.ScrolledWindow (null, null);
        scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
        root.pack_start (scroller, true, true, 0);

        // Content is a fixed 380px column, so wide content in "Advanced"
        // (e.g. the settings path) can't widen the layout when opened.
        var outer = new Gtk.Box (Gtk.Orientation.VERTICAL, 24);
        outer.margin = 24;
        outer.margin_start = outer.margin_end = (560 - 380) / 2;
        scroller.add (outer);
        content = outer;

        info_bar = new Gtk.InfoBar ();
        info_bar.message_type = Gtk.MessageType.WARNING;
        info_label = new Gtk.Label (null);
        info_label.wrap = true;
        info_label.max_width_chars = 50;
        info_label.xalign = 0;
        info_bar.get_content_area ().add (info_label);
        info_bar.no_show_all = true;
        outer.pack_start (info_bar, false, false, 0);

        build_main (outer);
        build_schedule (outer);
        build_integration (outer);
        build_advanced (outer);

        root.show_all ();
    }

    private void build_main (Gtk.Box outer) {
        var list = new_list (outer);

        // Enable night light   (i)   [switch]
        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        var titles = new Gtk.Box (Gtk.Orientation.VERTICAL, 2);
        titles.valign = Gtk.Align.CENTER;
        var title = new Gtk.Label (_("Enable night light"));
        title.xalign = 0;
        enable_subtitle = new Gtk.Label (null);
        enable_subtitle.xalign = 0;
        enable_subtitle.get_style_context ().add_class ("dim-label");
        enable_subtitle.no_show_all = true;
        titles.pack_start (title, false, false, 0);
        titles.pack_start (enable_subtitle, false, false, 0);
        box.pack_start (titles, true, true, 0);

        var info = new Gtk.Image.from_icon_name ("dialog-information-symbolic", Gtk.IconSize.BUTTON);
        info.tooltip_text = _("Night light makes the screen colours warmer at night to reduce eye strain.\nIt is applied by redshift-gtk, which keeps running in the notification area.");
        box.pack_start (info, false, false, 0);

        enable_switch = new Gtk.Switch ();
        enable_switch.valign = Gtk.Align.CENTER;
        enable_switch.state_set.connect ((on) => {
            if (!updating)
                controller.request_enabled (on);
            return false;
        });
        box.pack_start (enable_switch, false, false, 0);
        add_row (list, box);

        // Color temperature slider: warmer to the right.
        var temp_box = new Gtk.Box (Gtk.Orientation.VERTICAL, 4);
        var heading = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 6);
        heading.halign = Gtk.Align.CENTER;
        heading.pack_start (new Gtk.Label (_("Color temperature")), false, false, 0);
        night_value = new Gtk.Label (null);
        night_value.get_style_context ().add_class ("dim-label");
        heading.pack_start (night_value, false, false, 0);
        temp_box.pack_start (heading, false, false, 0);

        night_scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 1700, 6500, 100);
        night_scale.inverted = true;
        night_scale.draw_value = false;
        night_scale.has_origin = false;
        night_scale.round_digits = 0;
        night_scale.add_mark (DEFAULT_NIGHT, Gtk.PositionType.TOP, null);
        night_scale.get_style_context ().add_class ("night-light-scale");
        night_scale.value_changed.connect (() => {
            var temp = snap (night_scale.get_value ());
            night_value.label = "(%d K)".printf (temp);
            if (!updating) {
                config.set (S, "temp-night", temp.to_string ());
                preview_night ();
                mark_changed ();
            }
        });
        temp_box.pack_start (night_scale, false, false, 0);
        add_row (list, temp_box);

        // The label turns into a spinner while redshift-gtk restarts.
        apply_stack = new Gtk.Stack ();
        apply_stack.add_named (new Gtk.Label (_("Apply")), "label");
        apply_spinner = new Gtk.Spinner ();
        apply_stack.add_named (apply_spinner, "spinner");
        apply_button = new Gtk.Button ();
        apply_button.add (apply_stack);
        apply_button.get_style_context ().add_class ("apply");
        apply_button.tooltip_text = _("Save the settings and restart redshift-gtk to use them");
        apply_button.sensitive = false;
        apply_button.clicked.connect (() => {
            if (!controller.busy)
                apply_now ();
        });
        add_row (list, apply_button);
    }

    private void build_schedule (Gtk.Box outer) {
        schedule_list = new_list (outer);

        schedule_combo = new Gtk.ComboBoxText ();
        schedule_combo.append ("auto", _("Automatic"));
        schedule_combo.append ("manual", _("Manual schedule"));
        schedule_combo.tooltip_text = _("Automatic follows sunset and sunrise at your location.");
        schedule_combo.changed.connect (schedule_changed);
        add_labeled (schedule_list, _("Schedule"), schedule_combo, true);

        location_combo = new Gtk.ComboBoxText ();
        location_combo.append ("geoclue2", _("Detect automatically"));
        location_combo.append ("manual", _("Set manually"));
        location_combo.changed.connect (schedule_changed);
        location_row = add_labeled (schedule_list, _("Location"), location_combo, true);

        lat_spin = new Gtk.SpinButton.with_range (-90, 90, 0.1);
        lat_spin.digits = 2;
        lat_spin.tooltip_text = _("Degrees north; use negative values for the southern hemisphere.");
        lat_spin.value_changed.connect (schedule_changed);
        lat_row = add_labeled (schedule_list, _("Latitude"), lat_spin);

        lon_spin = new Gtk.SpinButton.with_range (-180, 180, 0.1);
        lon_spin.digits = 2;
        lon_spin.tooltip_text = _("Degrees east; use negative values west of Greenwich.");
        lon_spin.value_changed.connect (schedule_changed);
        lon_row = add_labeled (schedule_list, _("Longitude"), lon_spin);

        from_row = add_labeled (schedule_list, _("Turn on at"), time_box (out from_hour, out from_min));
        to_row = add_labeled (schedule_list, _("Turn off at"), time_box (out to_hour, out to_min));

        schedule_error = new Gtk.Label (_("Night light has to turn on in the evening and off in the morning (the schedule must cross midnight)."));
        schedule_error.wrap = true;
        schedule_error.max_width_chars = 40;
        schedule_error.xalign = 0;
        schedule_error.get_style_context ().add_class ("dim-label");
        error_row = add_row (schedule_list, schedule_error);
    }

    private void build_integration (Gtk.Box outer) {
        var list = new_list (outer);

        autostart_switch = new Gtk.Switch ();
        autostart_switch.state_set.connect ((on) => {
            if (updating)
                return false;
            try {
                controller.request_autostart (on);
            } catch (Error e) {
                show_error (_("Could not change autostart"), e.message);
            }
            return false;
        });
        add_labeled (list, _("Start at login"), autostart_switch);

        suspend_box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 0);
        suspend_box.get_style_context ().add_class ("linked");
        string[] labels = { _("30 min"), _("1 hour"), _("2 hours") };
        for (int i = 0; i < TrayMenu.SUSPEND_MINUTES.length; i++) {
            var minutes = TrayMenu.SUSPEND_MINUTES[i];
            var b = new Gtk.Button.with_label (labels[i]);
            b.clicked.connect (() => controller.suspend (minutes));
            suspend_box.pack_start (b, false, false, 0);
        }
        add_labeled (list, _("Suspend for"), suspend_box);

        var box = new Gtk.Box (Gtk.Orientation.HORIZONTAL, 12);
        status_label = new Gtk.Label (null);
        status_label.wrap = true;
        status_label.xalign = 0;
        status_label.max_width_chars = 34;
        status_label.get_style_context ().add_class ("dim-label");
        box.pack_start (status_label, true, true, 0);
        status_button = new Gtk.Button ();
        status_button.valign = Gtk.Align.CENTER;
        status_button.clicked.connect (() => {
            if (controller.running)
                controller.restart.begin ();
            else
                controller.launch ();
        });
        box.pack_end (status_button, false, false, 0);
        add_row (list, box);
    }

    private void build_advanced (Gtk.Box outer) {
        var expander = new Gtk.Expander (_("Advanced"));
        var box = new Gtk.Box (Gtk.Orientation.VERTICAL, 0);
        box.margin_top = 8;
        expander.add (box);
        outer.pack_start (expander, false, false, 0);
        var list = new_list (box);

        day_spin = new Gtk.SpinButton.with_range (1000, 25000, 100);
        day_spin.tooltip_text = _("6500 K is neutral. Lower values are warmer.");
        day_spin.value_changed.connect (() => {
            if (updating)
                return;
            config.set (S, "temp-day", ((int) day_spin.get_value ()).to_string ());
            show_live ((int) day_spin.get_value (),
                       config.get_double (S, "brightness-day",
                                          config.get_double (S, "brightness", 1.0)));
            mark_changed ();
        });
        add_labeled (list, _("Daytime temperature (K)"), day_spin);

        brightness_scale = new Gtk.Scale.with_range (Gtk.Orientation.HORIZONTAL, 0.1, 1.0, 0.05);
        brightness_scale.value_pos = Gtk.PositionType.RIGHT;
        brightness_scale.width_request = 160;
        brightness_scale.format_value.connect ((v) => "%d%%".printf ((int) Math.round (v * 100)));
        brightness_scale.value_changed.connect (() => {
            if (updating)
                return;
            // A plain "brightness" key would override per-period values.
            var both = config.get (S, "brightness");
            if (both != null) {
                if (!config.has (S, "brightness-day"))
                    config.set (S, "brightness-day", both);
                config.remove (S, "brightness");
            }
            config.set_double (S, "brightness-night", brightness_scale.get_value ());
            preview_night ();
            mark_changed ();
        });
        add_labeled (list, _("Night brightness"), brightness_scale);

        fade_switch = new Gtk.Switch ();
        fade_switch.state_set.connect ((on) => {
            if (!updating) {
                config.set (S, "fade", on ? "1" : "0");
                mark_changed ();
            }
            return false;
        });
        add_labeled (list, _("Smooth transitions"), fade_switch);

        path_label = new Gtk.Label (null);
        path_label.xalign = 0;
        path_label.ellipsize = Pango.EllipsizeMode.MIDDLE;
        path_label.get_style_context ().add_class ("dim-label");
        path_label.margin_top = 6;
        box.pack_start (path_label, false, false, 0);
    }

    private static int snap (double v) {
        return (int) (Math.round (v / 100) * 100);
    }

    /* ---- settings <-> widgets ---- */

    private void load_settings () {
        updating = true;

        night_scale.set_value (config.get_int (S, "temp-night", DEFAULT_NIGHT));
        night_value.label = "(%d K)".printf (snap (night_scale.get_value ()));
        day_spin.value = config.get_int (S, "temp-day", DEFAULT_DAY);
        brightness_scale.set_value (config.get_double (S, "brightness-night",
                                    config.get_double (S, "brightness", 1.0)));
        fade_switch.active = config.get (S, "fade") != "0";
        path_label.label = _("Settings file: %s").printf (config.path);
        path_label.tooltip_text = config.path;

        int dusk_start, dusk_end, dawn_start, dawn_end;
        bool timed = RedshiftConfig.parse_time_range (config.get (S, "dusk-time"), out dusk_start, out dusk_end)
                   & RedshiftConfig.parse_time_range (config.get (S, "dawn-time"), out dawn_start, out dawn_end);
        schedule_combo.active_id = timed ? "manual" : "auto";
        if (!timed) {
            dusk_start = 20 * 60;
            dawn_end = 7 * 60;
        }
        from_hour.value = dusk_start / 60;
        from_min.value = dusk_start % 60;
        to_hour.value = dawn_end / 60;
        to_min.value = dawn_end % 60;

        location_combo.active_id = config.get (S, "location-provider") == "manual" ? "manual" : "geoclue2";
        lat_spin.value = config.get_double ("manual", "lat", 0);
        lon_spin.value = config.get_double ("manual", "lon", 0);

        updating = false;
        update_schedule_rows ();
    }

    private bool schedule_valid () {
        int from = (int) (from_hour.value * 60 + from_min.value);
        int to = (int) (to_hour.value * 60 + to_min.value);
        // redshift requires dawn to end before dusk starts within one day.
        return to <= from;
    }

    private void update_schedule_rows () {
        bool manual_times = schedule_combo.active_id == "manual";
        bool manual_loc = location_combo.active_id == "manual";
        location_row.visible = !manual_times;
        lat_row.visible = lon_row.visible = !manual_times && manual_loc;
        from_row.visible = to_row.visible = manual_times;
        error_row.visible = manual_times && !schedule_valid ();
        schedule_list.invalidate_headers ();
    }

    private void schedule_changed () {
        if (updating)
            return;
        update_schedule_rows ();

        if (schedule_combo.active_id == "manual") {
            if (!schedule_valid ())
                return;
            int from = (int) (from_hour.value * 60 + from_min.value);
            int to = (int) (to_hour.value * 60 + to_min.value);
            int dusk_end = int.min (from + TRANSITION, 23 * 60 + 59);
            int dawn_start = int.max (to - TRANSITION, 0);
            config.set (S, "dusk-time", "%s-%s".printf (RedshiftConfig.format_time (from),
                                                        RedshiftConfig.format_time (dusk_end)));
            config.set (S, "dawn-time", "%s-%s".printf (RedshiftConfig.format_time (dawn_start),
                                                        RedshiftConfig.format_time (to)));
        } else {
            config.remove (S, "dusk-time");
            config.remove (S, "dawn-time");
            config.set (S, "location-provider", location_combo.active_id);
            if (location_combo.active_id == "manual") {
                config.set_double ("manual", "lat", lat_spin.value);
                config.set_double ("manual", "lon", lon_spin.value);
            }
        }
        mark_changed ();
    }

    /* Changes are kept in memory until Apply (or closing the window). */
    private void mark_changed () {
        dirty = true;
        update_apply_button ();
    }

    private void update_apply_button () {
        // Stays sensitive while applying so the spinner isn't greyed out;
        // clicks are ignored meanwhile.
        apply_button.sensitive = dirty || controller.busy;
        apply_stack.visible_child_name = controller.busy ? "spinner" : "label";
        apply_spinner.active = controller.busy;
    }

    /* Save and restart redshift-gtk, which can only read its config at startup. */
    private void apply_now (owned SourceFunc? done = null) {
        // Cut a running preview short; the restart applies the real setting.
        if (preview_timer != 0) {
            Source.remove (preview_timer);
            preview_timer = 0;
        }
        controller.end_preview ();
        try {
            config.save ();
        } catch (Error e) {
            controller.end_preview ();
            show_error (_("Could not save settings"), e.message);
            if (done != null)
                done ();
            return;
        }
        dirty = false;
        update_apply_button ();
        // restart() also ends any preview, or just restores it if
        // redshift-gtk isn't running.
        controller.restart.begin ((obj, res) => {
            controller.restart.end (res);
            if (done != null)
                done ();
        });
    }

    /* ---- preview ---- */

    /* Show a setting on screen while it is being adjusted; the screen goes
     * back to the current setting shortly after the last change. */
    private void show_live (int temp, double brightness) {
        controller.show_live (config.path, temp, brightness);
        if (preview_timer != 0)
            Source.remove (preview_timer);
        preview_timer = Timeout.add (PREVIEW_HOLD, () => {
            preview_timer = 0;
            controller.end_preview ();
            return Source.REMOVE;
        });
    }

    private void preview_night () {
        show_live (snap (night_scale.get_value ()), brightness_scale.get_value ());
    }

    /* ---- controller -> widgets ---- */

    private void update_status () {
        updating = true;
        enable_switch.active = controller.enabled;
        autostart_switch.active = controller.autostart;
        updating = false;

        string? subtitle = null;
        if (controller.suspend_until > 0) {
            var until = new DateTime.from_unix_local (controller.suspend_until);
            subtitle = _("Suspended until %s").printf (until.format ("%H:%M"));
        } else if (!controller.running) {
            subtitle = _("redshift-gtk is not running");
        }
        enable_subtitle.label = subtitle ?? "";
        enable_subtitle.visible = subtitle != null;

        suspend_box.sensitive = controller.can_suspend && !controller.busy;
        update_apply_button ();

        if (controller.busy) {
            status_label.label = _("Applying settings…");
        } else if (!controller.running) {
            status_label.label = _("redshift-gtk is not running.");
        } else if (controller.tray != null) {
            status_label.label = _("Connected to redshift-gtk.");
        } else {
            status_label.label = _("redshift-gtk has no tray menu on D-Bus (is the Ayatana or libappindicator GObject introspection package installed?). Toggling works; suspend and tray sync do not.");
        }
        status_button.label = controller.running ? _("Restart") : _("Start");
        status_button.sensitive = !controller.busy;
        status_button.tooltip_text = controller.running
            ? _("Restart redshift-gtk (PID %d) to reload settings").printf (controller.process.pid)
            : null;

        if (controller.overriding_options.length > 0) {
            info_label.label = _("redshift-gtk was started with %s, which overrides some of these settings.")
                .printf (string.joinv (" ", controller.overriding_options));
            info_bar.show ();
            info_label.show ();
        } else {
            info_bar.hide ();
        }

        // redshift-gtk may have been started with -c pointing elsewhere.
        var wanted = controller.config_override ?? RedshiftConfig.find_path ();
        if (wanted != config.path && !dirty) {
            config = new RedshiftConfig (wanted);
            load_settings ();
        }
    }

    private void show_error (string primary, string secondary) {
        var dialog = new Gtk.MessageDialog (this, Gtk.DialogFlags.MODAL, Gtk.MessageType.ERROR,
                                            Gtk.ButtonsType.CLOSE, "%s", primary);
        dialog.secondary_text = secondary;
        dialog.run ();
        dialog.destroy ();
    }
}

}
