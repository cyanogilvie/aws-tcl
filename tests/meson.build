test('tcltest', tclsh,
  args: [
    files('../tools/runtests.tcl'),
    meson.project_source_root(),
    # Pass the tm/ subdir rather than the build root — the aws .tm
    # files live there and we don't want the build root on tm::path
    # (would conflict with subproject dirs under subprojects/*).
    meson.project_build_root() / 'tm',
  ],
  depends:  [tm],
  env: {
    'ERROR_ON_FAILURES':  '1',
    'TCLLIBPATH':         ' '.join(dep_builddirs_trad),
    'TCL'+tclver_major+'_'+tclver_minor+'_TM_PATH': ':'.join(dep_builddirs_tm),
  },
  timeout:  300,
  verbose:  true,
)
