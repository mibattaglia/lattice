Pod::Spec.new do |s|
  s.name           = 'UnoArchitecture'
  s.version        = '0.1.0'
  s.summary        = 'Composable architecture utilities with macros'
  s.description    = 'Uno Architecture runtime + macros (prebuilt plugin) for Swift 6'
  s.author         = 'Uno Architecture'
  s.homepage       = 'https://example.com'
  s.license        = { type: 'MIT' }
  s.platforms      = { ios: '17.0', macos: '14.0', watchos: '10.0' }
  s.source         = { git: '', tag: s.version.to_s }
  s.swift_version  = '6.0'

  s.static_framework = true

  # Runtime library sources (exclude macro target)
  s.source_files = 'Sources/UnoArchitecture/**/*.{swift}'

  # Preserve the prebuilt macro binary (you must provide this at release time)
  s.preserve_paths = ['Macros/UnoArchitectureMacros']

  # Configure build flags to load the macro plugin
  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_SWIFT_FLAGS' => '-load-plugin-executable ${PODS_TARGET_SRCROOT}/Macros/UnoArchitectureMacros#UnoArchitectureMacros'
  }

  # For the main app target (if it uses macros directly)
  s.user_target_xcconfig = {
    'OTHER_SWIFT_FLAGS' => '-load-plugin-executable $(PODS_ROOT)/Development\\ Pods/UnoArchitecture/Macros/UnoArchitectureMacros#UnoArchitectureMacros'
  }

  # CocoaPods dependencies for modules imported by UnoArchitecture
  s.dependency 'swift-collections', '~> 1.1'
  s.dependency 'OrderedCollections', '~> 1.0.2'
end
