#!/usr/bin/python3
"""Minimal org.kde.StatusNotifierWatcher so AppIndicator exports its menu
on a private bus (nothing shows up in the real panel).

With FAKE_WATCHER_HIDE_ITEMS=1 it reports no registered items, like
Ayatana's indicator service does."""
import os
from gi.repository import Gio, GLib

HIDE = os.environ.get('FAKE_WATCHER_HIDE_ITEMS') == '1'

XML = '''<node><interface name="org.kde.StatusNotifierWatcher">
  <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
  <method name="RegisterStatusNotifierHost"><arg type="s" direction="in"/></method>
  <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
  <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
  <property name="ProtocolVersion" type="i" access="read"/>
  <signal name="StatusNotifierItemRegistered"><arg type="s"/></signal>
  <signal name="StatusNotifierHostRegistered"/>
</interface></node>'''
items = []

def call(conn, sender, path, iface, method, params, inv):
    if method == 'RegisterStatusNotifierItem':
        arg = params.unpack()[0]
        entry = sender + arg if arg.startswith('/') else arg + '/StatusNotifierItem'
        items.append(entry)
        conn.emit_signal(None, path, iface, 'StatusNotifierItemRegistered',
                         GLib.Variant('(s)', (entry,)))
    inv.return_value(None)

def get(conn, sender, path, iface, prop):
    return {'RegisteredStatusNotifierItems': GLib.Variant('as', [] if HIDE else items),
            'IsStatusNotifierHostRegistered': GLib.Variant('b', True),
            'ProtocolVersion': GLib.Variant('i', 0)}[prop]

def acquired(conn, name):
    info = Gio.DBusNodeInfo.new_for_xml(XML).interfaces[0]
    conn.register_object('/StatusNotifierWatcher', info, call, get, None)

Gio.bus_own_name(Gio.BusType.SESSION, 'org.kde.StatusNotifierWatcher',
                 Gio.BusNameOwnerFlags.NONE, acquired, None, None)
loop = GLib.MainLoop()
loop.run()
