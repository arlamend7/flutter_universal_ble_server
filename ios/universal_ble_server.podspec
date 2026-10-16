#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint flutter_universal_ble_server.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'universal_ble_server'
  s.version          = '0.2.0'
  s.summary          = 'Native BLE clients and servers.'
  s.description      = <<-DESC
Native BLE clients and servers configured from Dart.
                       DESC
  s.homepage         = 'https://github.com/arlamend7/flutter_universal_ble_server'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'universal_ble_server contributors'
  s.source           = { :path => '.' }
  s.source_files = 'universal_ble_server/Sources/universal_ble_server/**/*.swift'
  s.resource_bundles = {'universal_ble_server_privacy' => ['universal_ble_server/Sources/universal_ble_server/PrivacyInfo.xcprivacy']}
  s.dependency 'Flutter'
  s.platform = :ios, '12.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'flutter_universal_ble_server_privacy' => ['Resources/PrivacyInfo.xcprivacy']}
end
