Pod::Spec.new do |spec|
  spec.name = 'PhysioAIDynamicWeightShiftSDK'
  spec.version = '2.0.0'
  spec.summary = 'Standalone native DWS Pose + TCN + Hybrid runtime.'
  spec.homepage = 'https://physioai.local/dws-native'
  spec.license = { :type => 'Proprietary' }
  spec.author = { 'PhysioAI' => 'dev@physioai.local' }
  spec.source = { :path => '.' }
  spec.platform = :ios, '17.0'
  spec.swift_version = '5.0'
  spec.static_framework = true
  spec.source_files = 'Sources/PhysioAIDynamicWeightShiftSDK/**/*.swift'
  spec.resource_bundles = {
    'PhysioAIDynamicWeightShiftSDK' => [
      'Resources/pose_landmarker_heavy.task',
      'Resources/dws_manifest.json',
      'Resources/PhysioAIDynamicWeightShiftTCN.mlmodelc',
    ]
  }
  spec.frameworks = 'AVFoundation', 'CoreMedia', 'CoreML', 'SwiftUI', 'UIKit'
  spec.dependency 'MediaPipeTasksVision', '0.10.35'
end
