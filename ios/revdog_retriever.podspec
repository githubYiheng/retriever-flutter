#
# Retriever Flutter 插件的 iOS 垫片（CocoaPods 路径；SwiftPM 路径见 revdog_retriever/Package.swift，同一份源码）。
#
Pod::Spec.new do |s|
  s.name             = 'revdog_retriever'
  s.version          = '0.1.0'
  s.summary          = 'Retriever client log transport for Flutter (iOS shim).'
  s.description      = <<-DESC
Thin native shim for the Retriever Flutter plugin: root directory, owner engine,
foreground tracker, background task bookkeeping and configuration diagnostics.
                       DESC
  s.homepage         = 'https://revdog.org'
  s.license          = { :file => '../LICENSE' }
  s.author           = 'Revdog'
  s.source           = { :path => '.' }
  s.source_files     = 'revdog_retriever/Sources/revdog_retriever/**/*.swift'
  s.resource_bundles = { 'revdog_retriever_privacy' => ['revdog_retriever/Sources/revdog_retriever/PrivacyInfo.xcprivacy'] }
  s.dependency 'Flutter'
  s.platform = :ios, '15.0'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'
end
