#!/usr/bin/env ruby
# 简化版本：为已有的 Xcode 项目添加 OneBoxMTunnel Network Extension
# 使用方法：在脚本所在目录运行: ruby add_onebox_tunnel.rb /path/to/ios/dir

require 'xcodeproj'
require 'fileutils'

# 获取 iOS 项目目录（从命令行参数或默认路径）
IOS_DIR = ARGV[0] || File.expand_path('../../../ios', __dir__)
PROJECT_PATH = File.join(IOS_DIR, 'OneBoxM.xcodeproj')
TARGET_NAME = 'OneBoxMTunnel'
EXTENSION_BUNDLE_ID = 'cloud.oneoh.networktools.tunnel'
MAIN_APP_NAME = 'OneBoxM'
EXTENSION_SOURCE = File.expand_path('OneBoxMTunnel', __dir__)
LIBBOX_FRAMEWORK = File.expand_path('Libbox.xcframework', __dir__)

puts "📦 OneBoxMTunnel Extension Installer"
puts "=" * 50

# 打开项目
project = Xcodeproj::Project.open(PROJECT_PATH)

# 检查 target 是否已存在
existing_target = project.targets.find { |t| t.name == TARGET_NAME }
if existing_target
  puts "✅ Target '#{TARGET_NAME}' already exists. Nothing to do."
  exit 0
end

puts "📝 Adding '#{TARGET_NAME}' Network Extension target..."

# 1. 创建扩展 group
extension_group = project.main_group.find_subpath(TARGET_NAME, true)
extension_group.set_source_tree('<group>')
# 设置相对于项目根目录的路径
extension_group.set_path("../modules/expo-onebox/ios/#{TARGET_NAME}")

# 2. 添加源文件到 group
swift_files = Dir.glob(File.join(EXTENSION_SOURCE, '*.swift')).map { |f| File.basename(f) }
swift_files.each do |filename|
  file_ref = extension_group.new_reference(filename)
  file_ref.set_last_known_file_type('sourcecode.swift')
end

# 添加 Info.plist 和 entitlements
info_plist_ref = extension_group.new_reference('Info.plist')
entitlements_ref = extension_group.new_reference("#{TARGET_NAME}.entitlements")

# 3. 创建扩展 target
extension_target = project.new_target(:app_extension, TARGET_NAME, :ios, '15.1')

# 4. 添加源文件到 build phase
swift_files.each do |filename|
  file_ref = extension_group.files.find { |f| f.display_name == filename }
  extension_target.source_build_phase.add_file_reference(file_ref) if file_ref
end

# 5. 添加 Libbox.xcframework
libbox_ref = project.main_group.find_subpath('Frameworks', true).new_reference(LIBBOX_FRAMEWORK)
libbox_ref.name = 'Libbox.xcframework'
libbox_ref.source_tree = '<absolute>'
extension_target.frameworks_build_phase.add_file_reference(libbox_ref, true)

# 6. 添加系统 frameworks
['NetworkExtension', 'Network', 'UserNotifications', 'UIKit'].each do |fw_name|
  fw_ref = project.frameworks_group.new_reference("System/Library/Frameworks/#{fw_name}.framework")
  fw_ref.name = "#{fw_name}.framework"
  fw_ref.source_tree = 'SDKROOT'
  extension_target.frameworks_build_phase.add_file_reference(fw_ref, true)
end

# 7. 配置 build settings
extension_target.build_configurations.each do |config|
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = EXTENSION_BUNDLE_ID
  config.build_settings['PRODUCT_NAME'] = TARGET_NAME
  config.build_settings['INFOPLIST_FILE'] = "../modules/expo-onebox/ios/#{TARGET_NAME}/Info.plist"
  config.build_settings['CODE_SIGN_ENTITLEMENTS'] = "../modules/expo-onebox/ios/#{TARGET_NAME}/#{TARGET_NAME}.entitlements"
  config.build_settings['SWIFT_VERSION'] = '5.0'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '15.1'
  config.build_settings['TARGETED_DEVICE_FAMILY'] = '1,2'
  config.build_settings['SKIP_INSTALL'] = 'YES'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['FRAMEWORK_SEARCH_PATHS'] = ['$(inherited)', "\"#{File.dirname(LIBBOX_FRAMEWORK)}\""]
  config.build_settings['OTHER_LDFLAGS'] = '$(inherited) -ObjC'
  config.build_settings['DEFINES_MODULE'] = 'YES'
  config.build_settings['ENABLE_USER_SCRIPT_SANDBOXING'] = 'NO'  # 重要：允许脚本运行
end

# 8. 将扩展添加为主应用的依赖
main_target = project.targets.find { |t| t.name == MAIN_APP_NAME }
if main_target
  main_target.add_dependency(extension_target)
  
  # 9. 创建 Embed App Extensions 阶段
  embed_phase = main_target.copy_files_build_phases.find { |phase| 
    phase.name == 'Embed App Extensions' 
  } || main_target.new_copy_files_build_phase('Embed App Extensions')
  
  embed_phase.dst_subfolder_spec = '13'  # PlugIns folder
  embed_phase.dst_path = ''
  
  # 添加扩展产物到 embed 阶段
  product_ref = extension_target.product_reference
  build_file = embed_phase.add_file_reference(product_ref, true)
  build_file.settings = { 'ATTRIBUTES' => ['RemoveHeadersOnCopy'] }
end

# 10. 保存项目
project.save

puts "✅ Successfully added '#{TARGET_NAME}' target!"
puts "✅ Extension will be embedded in main app"
puts "\n📝 Next steps:"
puts "   1. Open Xcode and set signing team for #{TARGET_NAME} target"
puts "   2. Run: npx expo run:ios --device"
