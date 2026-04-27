pandoc = find_program('pandoc', native: true, required: false)

if pandoc.found()
  include_filter = meson.project_source_root() / 'tools/include-code.lua'
  doc_source_dir = meson.project_source_root() / 'doc'

  doc_conf = configuration_data()
  doc_conf.set('PACKAGE_NAME',    meson.project_name())
  doc_conf.set('PACKAGE_VERSION', meson.project_version())
  doc_md = configure_file(
    input:          'aws.md.in',
    output:         'aws.md',
    configuration:  doc_conf,
  )

  # Any file the manpage pulls in via the include-code filter should be
  # listed here so that pandoc re-runs when examples change.
  doc_includes = files(
    'examples/cli_vs_tcl.tcl',
    'examples/pagination.tcl',
    'examples/error_handling.tcl',
  )

  doc_targets = []

  doc_targets += custom_target('htmldoc',
    input:            [doc_md, doc_includes],
    output:           meson.project_name() + '.html',
    command: [pandoc, '--standalone',
      '--metadata',       'title=' + meson.project_name(),
      '--lua-filter',     include_filter,
      '--resource-path',  doc_source_dir,
      '--from',           'markdown',
      '--to',             'html',
      '@INPUT0@',
      '--output',         '@OUTPUT@'],
    install:          true,
    install_dir:      get_option('datadir') / 'doc' / meson.project_name(),
    build_by_default: true,
  )

  doc_targets += custom_target('manpage',
    input:            [doc_md, doc_includes],
    output:           meson.project_name() + '.n',
    command: [pandoc, '--standalone',
      '--lua-filter',     include_filter,
      '--resource-path',  doc_source_dir,
      '--from',           'markdown',
      '--to',             'man',
      '@INPUT0@',
      '--output',         '@OUTPUT@'],
    install:          true,
    install_dir:      get_option('mandir') / 'mann',
    build_by_default: true,
  )

  doc_targets += custom_target('readme',
    input:            [doc_md, doc_includes],
    output:           'README.md',
    command: [pandoc,
      '--lua-filter',     include_filter,
      '--resource-path',  doc_source_dir,
      '--from',           'markdown',
      '--to',             'gfm',
      '@INPUT0@',
      '--output',         '@OUTPUT@'],
    install:          false,
    build_by_default: false,
  )

  alias_target('doc', doc_targets)
endif
