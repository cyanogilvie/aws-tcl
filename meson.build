project('aws',
  version:            '2.0a26',
  meson_version:      '>=1.3.0',
)
# Pure-Tcl module. No C sources — the implicit 'c' project language stays
# unused, but meson always wants a language set. Adding explicit sources
# later (e.g. a generator tool in C) would slot in here.

fs = import('fs')

# Tcl dependency discovery. Mirrors the convention used across the
# batteries-included runtime: PKG_CONFIG_PATH=/opt/tcl9g/lib/pkgconfig
# (or equivalent) selects the Tcl we're building for. The detected
# version drives both the tclsh we run and the .tm install path.
tcl_dep       = dependency('tcl')
tclver_full   = tcl_dep.version()
tclver_parts  = tclver_full.split('.')
tclver_major  = tclver_parts[0]
tclver_minor  = tclver_parts[1].split('a')[0].split('b')[0].split('rc')[0]
tclver        = tclver_major + '.' + tclver_minor

exec_prefix = tcl_dep.get_variable('exec_prefix')

# tclsh lookup follows the same pattern as teabase/init: prefer the
# versioned name from the tcl.pc exec_prefix, fall back to PATH. Unlike
# the C-extension teabase we don't need a build_tclsh distinct from the
# runtime tclsh — the build-time generator (build.tcl) runs in the same
# Tcl we'll ship against.
if tcl_dep.type_name() == 'internal'
  tcl_subproj = subproject('tcl')
  tclsh = tcl_subproj.get_variable('tclsh_exe')
else
  tclsh_search = []
  foreach name : [exec_prefix / 'bin/tclsh', exec_prefix / 'tclsh', 'tclsh']
    tclsh_search += [name + tclver, name]
  endforeach
  tclsh = find_program(tclsh_search, required: true)

  # Defensive version check. `dependency('tcl')` + `find_program('tclsh')`
  # can legally pick different Tcls if PATH and pkg-config disagree —
  # reject that up front rather than letting build.tcl fail obscurely.
  tclsh_patchlevel = run_command(tclsh,
    files('tools/print_patchlevel.tcl'),
    check: true,
  ).stdout()
  if tclsh_patchlevel.split('.')[0] + '.' + tclsh_patchlevel.split('.')[1] != tclver
    error('Tcl mismatch: pkg-config found @0@, tclsh reports @1@. Set PKG_CONFIG_PATH to point at the same Tcl install.'
      .format(tclver_full, tclsh_patchlevel))
  endif
endif

# ===========================================================================
# Runtime Tcl dependencies
#
# aws-tcl's .tm modules are loaded by a tclsh that needs a handful of
# other Tcl packages on its search path — some (rl_json, parse_args,
# chantricks, brotli) are exercised by build.tcl at build time; the
# rest (rl_http, tomcrypt, reuri, tdom, tcl-s2n) are only needed at
# runtime/test time.
#
# Each dep is resolved via `dependency(name, fallback: [name, name_dep])`:
#   - pkg-config first; if found, the .pc file exposes the
#     `tcl_pkg_path` (C extensions) or `tcl_tm_path` (.tm modules)
#     variable. The Tcl package is loadable by the system interpreter
#     without any TCLLIBPATH wrangling — we just record the path for
#     reference.
#   - subproject fallback if not system-installed; the cloned wrap
#     calls `meson.override_dependency()` with a declare_dependency
#     whose `variables` dict carries the same path key, so the call
#     site here doesn't change shape. The build-tree path needs
#     adding to TCLLIBPATH (C-ext) or AWSTCL_EXTRA_TM_PATH (.tm
#     modules) so build.tcl and tests find the just-built artifact.
#
# This relies on every dep having a tagged release that ships
# `<name>.pc.in` with the right variable plus a matching
# `meson.override_dependency()` call — see the cross-package
# pkg-config convention at ~/.claude/skills/tea-meson/pkg-config-convention.md.

# Separate lists by package kind: .tm modules go on tcl::tm::path, which
# the wrapper scripts feed via AWSTCL_EXTRA_TM_PATH; traditional C
# extensions (with pkgIndex.tcl) go on auto_path, which tclsh populates
# from TCLLIBPATH at init. Co-mingling the two triggers Tcl's
# "subdirectory of existing module path" rejection when a tm path's
# parent is already there for auto_path.
dep_builddirs_tm   = []
dep_builddirs_trad = []
# Targets that must complete before tm (which runs build.tcl)
# so that `package require <dep>` during the build phase finds built
# artifacts. Empty when a dep was system-resolved (no targets needed)
# or pure-Tcl (configure_file runs at generate time, no build target).
dep_targets = []

# Build deps: always required (build.tcl can't run without them).
# brotli is only needed when tm_mode=brlet; the default ziplet uses
# zlib which is a Tcl builtin.
#
# Each entry: name, kind ('tm' or 'pkg'), required.
deps_spec = [
  # --- Build deps: needed by build.tcl ---
  ['rl_json',    'pkg', true],
  ['parse_args', 'pkg', true],
  ['chantricks', 'tm',  true],
  ['brotli',     'pkg', get_option('tm_mode') == 'brlet'],
  # --- Test / runtime deps ---
  # gc_class is a transitive dep of rl_http (`package require gc_class`
  # at the top of rl_http.tcl). Listed here so its tm path is added to
  # AWSTCL_EXTRA_TM_PATH for build.tcl + tests under the fallback build.
  ['gc_class',   'tm',  get_option('build_tests')],
  ['rl_http',    'tm',  get_option('build_tests')],
  ['tomcrypt',   'pkg', get_option('build_tests')],
  # dedup is a transitive C-extension dep of reuri.  Same wasted-clone
  # tradeoff as gc_class for system builds (no .pc means meson always
  # resolves via the wrap), but listing it here is the simplest way to
  # get its build dir onto TCLLIBPATH for the fallback path.
  ['dedup',      'pkg', get_option('build_tests')],
  ['reuri',      'pkg', get_option('build_tests')],
  ['tdom',       'pkg', get_option('build_tests')],
  ['tcl-s2n',    'pkg', false],
]
if tcl_dep.type_name() == 'internal'
  deps_spec += [['thread', 'pkg', true]]
endif

foreach spec : deps_spec
  _name     = spec[0]
  _kind     = spec[1]
  _required = spec[2]
  _var      = (_kind == 'tm') ? 'tcl_tm_path' : 'tcl_pkg_path'

  # Wrap-file naming convention is lowercase + dashes-to-underscores:
  # the subproject identifier (the .wrap filename basename and meson
  # variable name) doesn't necessarily match the dependency name a
  # consumer asks for.  Thread is the canonical example (dep is
  # 'Thread' but the wrap is thread.wrap).  Lowercasing is a no-op for
  # the all-lowercase deps already in this list.
  _subproj  = _name.to_lower()
  _var_name = _subproj.replace('-', '_') + '_dep'
  _dep = dependency(_name,
    fallback: [_subproj, _var_name],
    required: _required,
  )
  if not _dep.found()
    continue
  endif

  if _dep.type_name() != 'internal'
    # System install via pkg-config — the Tcl interpreter already has
    # the package on its auto_path / tcl::tm::path. Adding the path
    # to our env-var lists would actually break things by prepending
    # the system tm dir ahead of our build dir, so an older
    # system-installed aws would be loaded instead of the just-built
    # one. Just record and move on.
    message('dep @0@: system install (@1@)'.format(_name, _dep.version()))
    continue
  endif

  # Subproject path: build dir needs adding to TCLLIBPATH or
  # AWSTCL_EXTRA_TM_PATH so build.tcl and tests find the artifact.
  _path = _dep.get_variable(_var)
  if _kind == 'tm'
    dep_builddirs_tm += _path
  else
    dep_builddirs_trad += _path
    # Record the underlying shared_module so meson sequences its
    # build before the tm target runs.  Pure-Tcl auto_path
    # subprojects (e.g. tcllib) have nothing to compile and expose
    # an empty list as the fallback, which += is happy to absorb.
    dep_targets += subproject(_subproj).get_variable('pkg_so', [])
  endif
  message('dep @0@: subproject at @1@'.format(_name, _path))
endforeach

# The output dir is $builddir/tm/ rather than $builddir/, so the build
# root can host subprojects/<name>/ without Tcl's tcl::tm::path
# refusing the subproject .tm dirs as "subdirectory of existing module
# path" (parent already on the path for our own .tm tree).
subdir('tm')

# pkg-config metadata so consumers can locate the install via
# `pkg-config --variable=tcl_tm_path aws` or
# `dependency('aws').get_variable('tcl_tm_path')`.
pc_conf = configuration_data()
pc_conf.set('PACKAGE_NAME',     meson.project_name())
pc_conf.set('PACKAGE_VERSION',  meson.project_version())
pc_conf.set('TCL_MAJOR',        tclver_major)
configure_file(
  input:          'aws.pc.in',
  output:         'aws.pc',
  configuration:  pc_conf,
  install:        true,
  # Match the convention used by Tcl-extension subprojects: install
  # alongside the resolving Tcl's pkgconfig dir.  In wrap-fallback
  # this resolves to ${prefix}/lib/pkgconfig; in system builds, to
  # the system Tcl's pkgconfig dir.
  install_dir:    tcl_dep.get_variable('libdir') / 'pkgconfig',
  install_tag:    meson.is_subproject() ? 'deps' : 'runtime',
)

subdir('tests')
subdir('doc')

# vim: foldmethod=marker foldmarker=<<<,>>> shiftwidth=2 expandtab
