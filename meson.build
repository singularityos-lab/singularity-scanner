project('singularity-scanner', ['vala', 'c'],
  version: '0.1.0',
  meson_version: '>= 0.59.0'
)

i18n = import('i18n')
fs = import('fs')
add_project_arguments('-DGETTEXT_PACKAGE="singularity-scanner"', language: 'c')
subdir('po')

gtk_dep = dependency('gtk4')
gee_dep = dependency('gee-0.8')
cairo_dep = dependency('cairo')
sane_dep = dependency('sane-backends')

libsingularity_dep = dependency('singularity-1.0',
  fallback: ['libsingularity', 'libsingularity_dep']
)

if not meson.is_subproject() and libsingularity_dep.type_name() == 'internal'
  libsingularity_vapi_dir = join_paths(meson.project_build_root(), 'subprojects', 'libsingularity')
  add_project_arguments(['--vapidir=' + libsingularity_vapi_dir], language: 'vala')
endif

bridge = static_library('scanner-bridge', 'src/sane-bridge.c', 'src/pdf-helper.c',
  dependencies: [dependency('glib-2.0'), sane_dep, cairo_dep])

executable('singularity-scanner',
  files('src/scan.vala', 'src/export.vala', 'src/window.vala', 'src/app.vala'),
  vala_args: ['--vapidir=' + meson.current_source_dir() / 'vapi', '--pkg=sanebridge', '--pkg=pdfhelper'],
  include_directories: include_directories('src'),
  link_with: bridge,
  dependencies: [gtk_dep, gee_dep, cairo_dep, libsingularity_dep],
  install: true
)

install_data('data/dev.sinty.scanner.desktop',
  install_dir: get_option('datadir') / 'applications'
)

if fs.exists('data/icons/dev.sinty.scanner.svg')
  install_data('data/icons/dev.sinty.scanner.svg',
    install_dir: get_option('datadir') / 'icons' / 'hicolor' / 'scalable' / 'apps'
  )
endif

test_export = executable('export-test', files('src/scan.vala', 'src/export.vala', 'tests/export_test.vala'),
  vala_args: ['--vapidir=' + meson.current_source_dir() / 'vapi', '--pkg=sanebridge', '--pkg=pdfhelper'],
  include_directories: include_directories('src'),
  link_with: bridge,
  dependencies: [gtk_dep, gee_dep, cairo_dep])
test('export', test_export)
