test_env = {
  'ERROR_ON_FAILURES': '1',
  # Same split as the tm_master target: traditional C-ext packages on
  # TCLLIBPATH (→ auto_path), .tm modules on AWSTCL_EXTRA_TM_PATH which
  # runtests.tcl reads and pushes onto tcl::tm::path.
  'TCLLIBPATH':          tcllibpath,
  'AWSTCL_EXTRA_TM_PATH': awstcl_extra_tm,
}

test('tcltest', tclsh,
  args: [
    files('../tools/runtests.tcl'),
    meson.project_source_root(),
    # Pass the tm/ subdir rather than the build root — the aws .tm
    # files live there and we don't want the build root on tm::path
    # (would conflict with subproject dirs under subprojects/*).
    meson.project_build_root() / 'tm',
  ],
  depends:  [tm_master],
  env:      test_env,
  timeout:  300,
  verbose:  true,
)
