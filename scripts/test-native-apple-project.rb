#!/usr/bin/env ruby
require 'tmpdir'
require 'yaml'
require 'fileutils'
require 'open3'

root = File.expand_path('..', __dir__)
app = File.join(root, 'app')
generator = File.join(__dir__, 'generate-native-apple-project.rb')
revision = 'ec96c6c6e3d18f0aec0dc9c9895ba37bc0523fd4'
output = File.join(app, ".native-project-contract-#{Process.pid}.yml")
legacy_bytes = File.binread(File.join(app, 'project.yml'))
begin
  # The generator exercises the actual local manifest; it does not load ignored binary inputs.
  stdout, stderr, status = Open3.capture3('ruby', generator, '--engine-revision', revision,
    '--mpvkit', File.join(app, 'Vendor', 'MPVKit-DVFEL'), '--output', output)
  abort "generator failed: #{stdout} #{stderr}" unless status.success?
  spec = YAML.safe_load(File.read(output), permitted_classes: [], permitted_symbols: [], aliases: false)
  expected = %w[VortXiOSNative VortXMac VortXTV VortXTVLite VortXTopShelf]
  abort 'unexpected native target roster' unless spec.fetch('targets').keys.sort == expected.sort
  abort 'web/diagnostic scheme survived native generation' unless spec.fetch('schemes').keys.sort == (expected - ['VortXTopShelf']).sort
  expected[0...-1].each do |name|
    target = spec.fetch('targets').fetch(name)
    settings = target.fetch('settings').fetch('base')
    conditions = settings.fetch('SWIFT_ACTIVE_COMPILATION_CONDITIONS').split
    %w[VORTX_NATIVE_DATA_ENGINE VORTX_ENGINE_STATE_BRIDGE VORTX_ENGINE_RESOURCE_HOST].each do |flag|
      abort "#{name} omitted #{flag}" unless conditions.include?(flag)
    end
    if %w[VortXiOSNative VortXTV].include?(name)
      abort "#{name} omitted the real in-process native server" unless conditions.include?('VORTX_ENGINE_SERVER')
      abort "#{name} native server provenance is absent" unless settings['INFOPLIST_KEY_VortXNativeTransport'] == 'in-process'
    else
      abort "#{name} incorrectly selected an in-process server" if conditions.include?('VORTX_ENGINE_SERVER')
    end
    abort "#{name} omitted native framework" unless target.fetch('dependencies').any? { |d| d['framework'] == 'Vendor/VortxEngine.xcframework' }
    abort "#{name} retained legacy framework" if target.fetch('dependencies').any? { |d| d.fetch('framework', '').match?(/StremioXCore|NodeMobile/) }
    abort "#{name} retained Node resources" if target.fetch('sources').any? { |s| (s.is_a?(Hash) ? s['path'] : s).match?(/server\.js|node-darwin/) }
    abort "#{name} provenance is absent" unless settings['INFOPLIST_KEY_VortXEngineSourceRevision'] == revision
    abort "#{name} omitted linker map" unless settings['LD_GENERATE_MAP_FILE']
  end
  abort 'Lite lost its transport boundary' unless spec.dig('targets', 'VortXTVLite', 'settings', 'base', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS').split.include?('VORTX_NO_EMBEDDED_SERVER')
  abort 'macOS floor changed' unless spec.dig('targets', 'VortXMac', 'deploymentTarget') == '14.0'
  abort 'iOS floor changed' unless spec.dig('options', 'deploymentTarget', 'iOS') == '16.0'
  abort 'tvOS floor changed' unless spec.dig('options', 'deploymentTarget', 'tvOS') == '18.0'
  abort 'macOS unexpectedly fetches Node' if spec.dig('targets', 'VortXMac', 'preBuildScripts')
  embed = spec.dig('targets', 'VortXMac', 'postBuildScripts').fetch(0).fetch('script')
  abort 'macOS daemon is still optional' unless embed.include?('test -s "$source" && test -x "$source"')
  abort 'legacy comparison spec was modified' unless File.binread(File.join(app, 'project.yml')) == legacy_bytes
  _, _, bad_revision = Open3.capture3('ruby', generator, '--engine-revision', 'latest', '--mpvkit', app, '--output', output)
  abort 'mutable engine revision was accepted' if bad_revision.success?
  _, _, overwrite = Open3.capture3('ruby', generator, '--engine-revision', revision,
    '--mpvkit', File.join(app, 'Vendor', 'MPVKit-DVFEL'), '--output', File.join(app, 'project.yml'))
  abort 'generator overwrote the legacy project' if overwrite.success?
  workflow = File.read(File.join(root, '.github', 'workflows', 'release-tvos.yml'))
  abort 'release workflow does not generate the native spec' unless workflow.include?('xcodegen generate --spec .native-project.yml')
  abort 'release workflow does not capture inputs before compilation' unless workflow.include?('verify-native-apple-package.py snapshot')
  %w[tvos-sim ios-sim tvos ios macos].each do |platform|
    abort "release workflow omits #{platform} native app proof" unless workflow.include?("--platform #{platform} ")
  end
  %w[tvos tvos-lite ios macos].each do |platform|
    abort "release workflow omits #{platform} archive proof" unless workflow.include?("--receipt out/native-package-#{platform}.json")
  end
  abort 'release workflow omits input and package receipts from its handoff' unless workflow.include?('out/native-*.json')
  abort 'native workflow accepts old player provenance' unless workflow.include?('the old FFmpeg 8/GnuTLS package cannot supply a native release')
  abort 'release workflow lost the existing complete ABI gate' unless workflow.include?('./scripts/verify-native-engine-abi.sh apple app/Vendor/VortxEngine.xcframework resource-host')
  abort 'release workflow lost the existing aggregate artifact gate' unless workflow.include?('./scripts/verify-apple-engine-artifacts.sh')
  puts 'PASS: native Apple project selection, dependency/resource removal, floors and required Mac server'
ensure
  FileUtils.rm_f(output)
end
