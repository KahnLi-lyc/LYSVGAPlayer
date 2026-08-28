# frozen_string_literal: true

require "xcodeproj"

root = File.expand_path(__dir__)
project_path = File.join(root, "LYSVGADemo.xcodeproj")
project = Xcodeproj::Project.new(project_path)
target = project.new_target(:application, "LYSVGADemo", :ios, "16.0")

source_group = project.main_group.new_group("LYSVGADemo", "LYSVGADemo")
Dir.glob(File.join(root, "LYSVGADemo", "*.swift")).sort.each do |path|
  target.add_file_references([source_group.new_file(File.basename(path))])
end

resource_group = project.main_group.new_group("Samples", "Samples")
Dir.glob(File.join(root, "Samples", "*.svga")).sort.each do |path|
  reference = resource_group.new_file(File.basename(path))
  target.resources_build_phase.add_file_reference(reference)
end

package_reference = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
package_reference.relative_path = ".."
project.root_object.package_references << package_reference

product_dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
product_dependency.package = package_reference
product_dependency.product_name = "LYSVGAPlayer"
target.package_product_dependencies << product_dependency

build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
build_file.product_ref = product_dependency
target.frameworks_build_phase.files << build_file

target.build_configurations.each do |configuration|
  settings = configuration.build_settings
  settings["CODE_SIGN_STYLE"] = "Automatic"
  settings["CURRENT_PROJECT_VERSION"] = "1"
  settings["DEVELOPMENT_TEAM"] = ""
  settings["GENERATE_INFOPLIST_FILE"] = "YES"
  settings["INFOPLIST_KEY_UILaunchScreen_Generation"] = "YES"
  settings["IPHONEOS_DEPLOYMENT_TARGET"] = "16.0"
  settings["MARKETING_VERSION"] = "0.1.0"
  settings["PRODUCT_BUNDLE_IDENTIFIER"] = "com.lysvga.demo"
  settings["PRODUCT_NAME"] = "$(TARGET_NAME)"
  settings["SUPPORTED_PLATFORMS"] = "iphoneos iphonesimulator"
  settings["SWIFT_VERSION"] = "6.0"
  settings["TARGETED_DEVICE_FAMILY"] = "1,2"
end

project.save
