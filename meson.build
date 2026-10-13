project('mate-redshift', 'vala', 'c',
  version: '0.1.0',
  license: 'GPL-3.0-or-later',
  meson_version: '>= 0.59')

add_project_arguments('-DGETTEXT_PACKAGE="mate-redshift"',
  '-DLOCALEDIR="@0@"'.format(get_option('prefix') / get_option('localedir')),
  '-DPACKAGE_VERSION="@0@"'.format(meson.project_version()),
  '-w', language: 'c')

valac = meson.get_compiler('vala')
i18n = import('i18n')

executable('mate-redshift',
  'src/main.vala',
  'src/window.vala',
  'src/controller.vala',
  'src/tray-menu.vala',
  'src/config.vala',
  'src/autostart.vala',
  dependencies: [
    dependency('gtk+-3.0', version: '>= 3.22'),
    dependency('gio-2.0', version: '>= 2.74'),
    valac.find_library('posix'),
    meson.get_compiler('c').find_library('m'),
  ],
  install: true)

i18n.merge_file(
  input: 'data/mate-redshift.desktop',
  output: 'mate-redshift.desktop',
  type: 'desktop',
  po_dir: 'po',
  install_dir: get_option('datadir') / 'applications')

subdir('po')

integration_test = executable('integration-test',
  'tests/integration.vala',
  'src/controller.vala',
  'src/tray-menu.vala',
  'src/config.vala',
  'src/autostart.vala',
  dependencies: [
    dependency('gtk+-3.0'),
    dependency('gio-2.0'),
    valac.find_library('posix'),
  ],
  build_by_default: false)
