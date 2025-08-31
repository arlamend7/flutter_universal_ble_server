Pod::Spec.new do |s|
  s.name             = 'universal_ble_server'
  s.version          = '0.0.1'
  s.summary          = 'Universal BLE server plugin'
  s.description      = <<-DESC
Cross-platform BLE peripheral plugin.
  DESC
  s.homepage         = 'https://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Author' => 'author@example.com' }
  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.requires_arc     = true
  s.dependency 'FlutterMacOS'
  s.platform     = :osx, '10.14'
end
