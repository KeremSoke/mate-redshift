#!/bin/sh
# Runs the integration test against the real redshift-gtk Python code, with a
# fake redshift binary (screen untouched), a private D-Bus session with a
# minimal tray watcher (nothing appears in the panel) and throwaway
# config/runtime dirs (your real autostart and config are untouched).
#
# Usage: tests/run-integration.sh BUILD_DIR [REDSHIFT_GTK_PYTHON_DIR]
set -eu
build=$(realpath "$1")
here=$(dirname "$(realpath "$0")")
src=${2:-$(python3 -c 'import redshift_gtk, os; print(os.path.dirname(redshift_gtk.__file__))')}

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/py" "$tmp/config" "$tmp/runtime"
chmod 700 "$tmp/runtime"
cp -r "$src" "$tmp/py/redshift_gtk"
cp "$here/fake-redshift" "$tmp/bin/redshift"
sed -i "s|^BINDIR = .*|BINDIR = '$tmp/bin'|" "$tmp/py/redshift_gtk/defs.py"
cat > "$tmp/bin/redshift-gtk" <<EOS
#!/usr/bin/python3
import sys
sys.path.insert(0, '$tmp/py')
from redshift_gtk.statusicon import run
run()
EOS
chmod +x "$tmp/bin/redshift-gtk"

export FAKE_REDSHIFT_LOG="$tmp/redshift.log"
export MATE_REDSHIFT_GTK="$tmp/bin/redshift-gtk"
export MATE_REDSHIFT_BIN="$tmp/bin/redshift"
export XDG_CONFIG_HOME="$tmp/config"
export XDG_RUNTIME_DIR="$tmp/runtime"
export GIO_USE_VFS=local    # don't spawn gvfs daemons on the private bus

dbus-run-session -- sh -c "
  python3 '$here/fake-watcher.py' &
  watcher=\$!
  sleep 0.5
  '$build/integration-test'
  status=\$?
  pkill -TERM -f '^/usr/bin/python3 $tmp/bin/redshift-gtk' 2>/dev/null
  kill \$watcher
  exit \$status"
