project(
  'yabridge-coordinate-probe',
  'c',
  version: '1',
  meson_version: '>=1.3.0',
  default_options: ['c_std=c99', 'warning_level=2', 'werror=true'],
)

cc = meson.get_compiler('c')
clap_dep = dependency('clap', fallback: ['clap', 'clap_dep'])

if host_machine.system() == 'windows'
  fs = import('fs')
  win32_deps = [
    cc.find_library('user32', required: true),
    cc.find_library('ws2_32', required: true),
  ]
  reproducible_args = [
    '-ffile-prefix-map=' + meson.project_source_root() + '=.',
    '-ffile-prefix-map=' + fs.relative_to(
      meson.project_source_root(),
      meson.project_build_root(),
    ) + '=.',
    '-ffile-prefix-map=' + meson.project_build_root() + '=.',
  ]
  probe_includes = include_directories('include', 'src/common', 'src/plugin')
  common_sources = files('src/common/jsonl.c')
  plugin_sources = files(
    'src/plugin/entry.c',
    'src/plugin/gui.c',
    'src/plugin/window.c',
    'src/plugin/report.c',
  )

  shared_library(
    'coordprobe',
    common_sources,
    plugin_sources,
    dependencies: [clap_dep, win32_deps],
    include_directories: probe_includes,
    c_args: reproducible_args,
    link_args: ['-Wl,--no-insert-timestamp'],
    name_prefix: '',
    name_suffix: 'clap-win',
  )

  shared_library(
    'coordprobe-test',
    common_sources,
    plugin_sources,
    dependencies: [clap_dep, win32_deps],
    include_directories: probe_includes,
    c_args: reproducible_args + ['-DCOORDPROBE_TEST_HOOKS'],
    link_args: ['-Wl,--no-insert-timestamp'],
    name_prefix: '',
    name_suffix: 'clap-win',
  )

  executable(
    'coordprobe-selftest',
    files('src/selftest/win_selftest.c'),
    dependencies: [clap_dep, win32_deps],
    include_directories: probe_includes,
    c_args: reproducible_args,
    link_args: ['-Wl,--no-insert-timestamp'],
  )
endif

if host_machine.system() == 'linux'
  host_dependencies = [
    clap_dep,
    dependency('json-c', required: true),
    dependency('x11', required: true),
    dependency('xtst', required: true),
    dependency('xext', required: true),
    dependency('threads', required: true),
    cc.find_library('dl', required: true),
  ]

  executable(
    'clap-probe-host',
    files(
      'src/host/main.c',
      'src/host/clap_host.c',
      'src/host/hierarchy.c',
      'src/host/xprobe.c',
    ),
    dependencies: host_dependencies,
    include_directories: include_directories('include', 'src/host'),
  )

  shared_library(
    'native-clap-fixture',
    files('src/selftest/native_clap_fixture.c'),
    dependencies: [
      clap_dep,
      dependency('x11', required: true),
      dependency('threads', required: true),
    ],
    name_prefix: '',
  )
endif
