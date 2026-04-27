# Master .tm and per-service tree generation.
#
# build_tm.tcl wraps the legacy build.tcl pipeline: it copies aws.tcl
# verbatim into aws-VER.tm and then runs build.tcl to populate the
# aws/ subdirectory with per-service modules. The two stages are
# driven from a single tclsh invocation so meson sees one custom_target
# output and a single dependency edge.
#
# The output dir is $builddir/tm/ rather than $builddir/, so the build
# root can host subprojects/<name>/ without Tcl's tcl::tm::path
# refusing the subproject .tm dirs as "subdirectory of existing module
# path" (parent already on the path for our own .tm tree).
#
# Variables `tclsh`, `tm_build_dir`, `tcllibpath`, `awstcl_extra_tm`,
# and `dep_targets` are defined in the project root meson.build.

tm_master = custom_target('tm_master',
  output:        'aws-' + meson.project_version() + '.tm',
  input:         files(
    meson.project_source_root() / 'aws.tcl',
    meson.project_source_root() / 'build.tcl',
  ),
  depend_files:  files(
    meson.project_source_root() / 'tools/build_tm.tcl',
  ),
  command: [
    find_program('env'),
    'TCLLIBPATH=' + tcllibpath,
    'AWSTCL_EXTRA_TM_PATH=' + awstcl_extra_tm,
    tclsh,
    meson.project_source_root() / 'tools/build_tm.tcl',
    '--tclsh',       tclsh,
    '--version',     meson.project_version(),
    '--source',      meson.project_source_root(),
    '--builddir',    tm_build_dir,
    '--definitions', meson.project_source_root() / 'botocore/botocore/data',
    '--mode',        get_option('tm_mode'),
  ],
  depends:           dep_targets,
  build_by_default:  true,
  install:           true,
  install_dir:       tm_install_dir,
)
