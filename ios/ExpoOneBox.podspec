require 'json'

package = JSON.parse(File.read(File.join(__dir__, '..', 'package.json')))

Pod::Spec.new do |s|
  s.name           = 'ExpoOneBox'
  s.version        = package['version']
  s.summary        = package['description']
  s.description    = package['description']
  s.license        = package['license']
  s.author         = package['author']
  s.homepage       = package['homepage']
  s.platforms      = { :ios => '15.1' }
  s.swift_version  = '5.9'
  s.source         = { git: 'https://github.com/OneOhCloud/expo-onebox' }
  s.static_framework = true

  s.dependency 'ExpoModulesCore'

  # Main module files + core/ helpers (moved out of root to keep ExpoOneBox* files at root)
  s.source_files = ["*.{h,m,mm,swift,hpp,cpp}", "core/*.{h,m,mm,swift,hpp,cpp}"]

  # Include the Libbox.xcframework (sing-box Go library)
  s.vendored_frameworks = "Libbox.xcframework"

  # System frameworks required by the module
  s.frameworks = 'Network', 'UserNotifications'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC'
  }
end
