Pod::Spec.new do |s|
  s.name           = 'Lattice'
  s.version        = '1.0.0'
  s.summary        = 'Composable architecture utilities with macros'
  s.description    = 'Lattice runtime + macros (prebuilt plugin) for Swift 6'
  s.author         = 'Lattice'
  s.homepage       = 'https://example.com'
  s.license        = { type: 'MIT' }
  s.platforms      = { ios: '17.0', macos: '14.0', watchos: '10.0' }
  s.source         = { git: 'https://github.com/mibattaglia/lattice.git', tag: s.version.to_s }
  s.swift_version  = '6.2'

  s.static_framework = true

  # Runtime library sources (exclude macro target and test helpers)
  s.source_files = 'Sources/Lattice/**/*.{swift}'
  s.exclude_files = 'Sources/Lattice/Testing/**/*.{swift}'

  # Preserve the prebuilt macro binary (you must provide this at release time)
  s.preserve_paths = ['Macros/LatticeMacros']

  # Build the macro plugin with the local Swift toolchain during pod install.
  # Runs in the pod root for both local and remote installs.
  s.prepare_command = 'bash ./scripts/rebuild-macro.sh'

  # Configure build flags to load the macro plugin
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_SWIFT_FLAGS' => '-load-plugin-executable ${PODS_TARGET_SRCROOT}/Macros/LatticeMacros#LatticeMacros -enable-upcoming-feature InferIsolatedConformances -enable-upcoming-feature NonisolatedNonsendingByDefault'
  }

  # For the main app target (if it uses macros directly)
  lattice_macros_path = ENV['LATTICE_MACROS_PATH'] || '${PODS_ROOT}/Lattice/Macros/LatticeMacros'
  s.user_target_xcconfig = {
    'LATTICE_MACROS_PATH' => lattice_macros_path,
    'OTHER_SWIFT_FLAGS' => '-load-plugin-executable ${LATTICE_MACROS_PATH}#LatticeMacros'
  }

  # CocoaPods dependencies for modules imported by Lattice
  s.dependency 'swift-collections', '~> 1.1'
  s.dependency 'DequeModule', '~> 1.0.2'
  s.dependency 'OrderedCollections', '~> 1.0.2'
  s.dependency 'swift-identified-collections', '0.1.0'
  s.dependency 'CasePaths', '0.1.1'
  s.dependency 'CasePathsCore', '0.1.1'
end
