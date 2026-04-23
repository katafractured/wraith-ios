#!/usr/bin/env ruby

require 'xcodeproj'

project_path = 'WraithVPN.xcodeproj'
project = Xcodeproj::Project.open(project_path)

main_target = project.targets.find { |t| t.name == 'WraithVPN' }
unless main_target
  puts "Error: WraithVPN target not found"
  exit 1
end

# Create UITests target with explicit product type
ui_tests_target = project.new_target(:ui_tests, 'WraithVPNUITests', :ios, '16.0')

# Get/create UITests group
wraith_group = project['WraithVPN']
ui_tests_group = nil
wraith_group.children.each do |child|
  if child.is_a?(Xcodeproj::Project::Object::PBXGroup) && child.display_name == 'UITests'
    ui_tests_group = child
    break
  end
end
ui_tests_group ||= wraith_group.new_group('UITests')

# Add source files
screenshot_tests = ui_tests_group.new_file('ScreenshotTests.swift')
snapshot_helper = ui_tests_group.new_file('SnapshotHelper.swift')

build_phase = ui_tests_target.source_build_phase
build_phase.add_file_reference(screenshot_tests)
build_phase.add_file_reference(snapshot_helper)

# Add app target dependency
dependency = project.new(Xcodeproj::Project::Object::PBXTargetDependency)
dependency.target = main_target
ui_tests_target.dependencies << dependency

# Configure build settings
ui_tests_target.build_configurations.each do |config|
  config.build_settings['BUNDLE_LOADER'] = '$(TEST_HOST)'
  config.build_settings['CODE_SIGN_STYLE'] = 'Automatic'
  config.build_settings['DEFINES_MODULE'] = 'YES'
  config.build_settings['GENERATE_INFOPLIST_FILE'] = 'YES'
  config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = '16.0'
  config.build_settings['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.katafract.wraith.tests.ui'
  config.build_settings['PRODUCT_NAME'] = '$(TARGET_NAME)'
  config.build_settings['SWIFT_EMIT_LOC_STRINGS'] = 'NO'
  config.build_settings['SWIFT_VERSION'] = '5.9'
  config.build_settings['TARGET_DEVICE_FAMILY'] = '1,2'
  config.build_settings['TEST_HOST'] = "$(BUILT_PRODUCTS_DIR)/WraithVPN.app/WraithVPN"
  config.build_settings['TEST_TARGET_NAME'] = 'WraithVPN'
end

project.save
puts "WraithVPNUITests target created successfully"
