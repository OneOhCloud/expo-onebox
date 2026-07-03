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

  # 主模块文件 + core/ 辅助文件（core/ 单独放，让 ExpoOneBox* 文件留在根目录）
  s.source_files = ["*.{h,m,mm,swift,hpp,cpp}", "core/*.{h,m,mm,swift,hpp,cpp}"]

  # 引入 Libbox.xcframework（sing-box Go 库）
  s.vendored_frameworks = "Libbox.xcframework"

  # 模块所需的系统 framework
  s.frameworks = 'Network', 'UserNotifications', 'BackgroundTasks'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'OTHER_LDFLAGS' => '$(inherited) -ObjC'
  }
end
