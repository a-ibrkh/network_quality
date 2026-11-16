Pod::Spec.new do |s|
  s.name             = 'network_quality'
  s.version          = '0.1.0'
  s.summary          = 'Network quality measurement SDK: cellular radio, connectivity, location and speed-test telemetry.'
  s.description      = <<-DESC
Network quality measurement SDK: cellular radio, connectivity, location and speed-test telemetry.
                       DESC
  s.homepage         = 'https://github.com/a-ibrkh/network_quality'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'BuildX'
  s.source           = { :path => '.' }
  s.source_files     = 'network_quality/Sources/network_quality/**/*.swift'
  s.resource_bundles = { 'network_quality_privacy' => ['network_quality/Sources/network_quality/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.frameworks       = 'CoreTelephony', 'CoreMotion', 'Network'
  s.platform         = :ios, '13.0'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version    = '5.0'
end
