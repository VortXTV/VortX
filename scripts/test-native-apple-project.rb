#!/usr/bin/env ruby
require 'tmpdir'
require 'yaml'
require 'fileutils'
require 'open3'
require 'json'
require_relative 'native-apple-swift6-policy'

root = File.expand_path('..', __dir__)
app = File.join(root, 'app')
generator = File.join(__dir__, 'generate-native-apple-project.rb')
revision = 'ec96c6c6e3d18f0aec0dc9c9895ba37bc0523fd4'
output = File.join(app, ".native-project-contract-#{Process.pid}.yml")
project_bytes = File.binread(File.join(app, 'project.yml'))
project_spec = YAML.safe_load(project_bytes, permitted_classes: [], permitted_symbols: [], aliases: false)
NativeAppleSwift6Policy.validate!(project_spec)
policy_checks = 1
%w[CinemaUISmokeRenderer.yml CinemaUISmokeIOSRenderer.yml].each do |filename|
  diagnostic = YAML.safe_load(File.read(File.join(app, filename)), permitted_classes: [], permitted_symbols: [], aliases: false)
  NativeAppleSwift6Policy.validate!(diagnostic)
  policy_checks += 1
end
# Exercise the production validator with RAM-only settings mutations, never by
# rewriting project.yml or a credential-bearing xcconfig.
NativeAppleSwift6Policy::REQUIRED.each do |key, expected|
  wrong = { 'SWIFT_VERSION' => '5.0', 'SWIFT_STRICT_CONCURRENCY' => 'minimal',
            'SWIFT_TREAT_WARNINGS_AS_ERRORS' => 'NO' }.fetch(key)
  %w[project-base project-config target-base target-config sdk-conditional template group].each do |scope|
    candidate = Marshal.load(Marshal.dump(project_spec))
    target = candidate.fetch('targets').fetch('VortXMac')
    case scope
    when 'project-base' then candidate.fetch('settings').fetch('base')[key] = wrong
    when 'project-config' then candidate.fetch('settings')['configs'] = { 'Release' => { key => wrong } }
    when 'target-base' then target.fetch('settings').fetch('base')[key] = wrong
    when 'target-config' then target.fetch('settings')['configs'] = { 'Debug' => { key => wrong } }
    when 'sdk-conditional' then target.fetch('settings').fetch('base')["#{key}[sdk=appletvos*]"] = wrong
    when 'template' then candidate['targetTemplates'] = { 'Test' => { 'settings' => { 'base' => { key => wrong } } } }
    when 'group' then candidate['settingGroups'] = { 'Test' => { key => wrong } }
    end
    begin
      NativeAppleSwift6Policy.validate!(candidate)
    rescue ArgumentError => error
      abort "wrong policy failure for #{scope}/#{key}: #{error}" unless error.message.include?(key)
      policy_checks += 1
      next
    end
    abort "Swift 6 downgrade accepted: #{scope}/#{key}"
  end
  inherited = Marshal.load(Marshal.dump(project_spec))
  inherited.fetch('targets').fetch('VortXTV').fetch('settings')['configs'] = { 'Release' => { key => expected } }
  NativeAppleSwift6Policy.validate!(inherited)
  policy_checks += 1
end
objects = {
  'project' => { 'isa' => 'PBXProject', 'buildConfigurationList' => 'project-list', 'targets' => [] },
  'project-list' => { 'isa' => 'XCConfigurationList', 'buildConfigurations' => %w[project-debug project-release] }
}
%w[Debug Release].each do |configuration|
  objects["project-#{configuration.downcase}"] = {
    'isa' => 'XCBuildConfiguration', 'name' => configuration,
    'buildSettings' => NativeAppleSwift6Policy::REQUIRED.dup
  }
end
NativeAppleSwift6Policy::ROSTERS.fetch('native').each do |target|
  objects['project']['targets'] << target
  objects[target] = { 'isa' => 'PBXNativeTarget', 'name' => target, 'buildConfigurationList' => "#{target}-list" }
  objects["#{target}-list"] = { 'isa' => 'XCConfigurationList', 'buildConfigurations' => [] }
  %w[Debug Release].each do |configuration|
    id = "#{target}-#{configuration}"
    objects["#{target}-list"]['buildConfigurations'] << id
    objects[id] = { 'isa' => 'XCBuildConfiguration', 'name' => configuration, 'buildSettings' => {} }
  end
end
generated_fixture = { 'rootObject' => 'project', 'objects' => objects }
abort 'generated policy omits target configurations' unless NativeAppleSwift6Policy.validate_generated!(generated_fixture, 'native').length == 10
policy_checks += 1
mutations = {
  'target Swift 5' => ->(pbx) { pbx['objects']['VortXMac-Release']['buildSettings']['SWIFT_VERSION'] = '5.0' },
  'SDK-specific Swift 5' => ->(pbx) { pbx['objects']['VortXTV-Release']['buildSettings']['SWIFT_VERSION[sdk=appletvos*]'] = '5.0' },
  # Keep project/target lists consistent so only the exact configuration-roster
  # guard can reject these, rather than the separate inheritance-shape guard.
  'missing Release' => ->(pbx) {
    pbx['objects'].each_value do |object|
      object['buildConfigurations'].pop if object['isa'] == 'XCConfigurationList'
    end
  },
  'extra configuration' => ->(pbx) {
    lists = pbx['objects'].select { |_, object| object['isa'] == 'XCConfigurationList' }
    lists.each do |id, list|
      extra = "#{id}-extra"
      list['buildConfigurations'] << extra
      pbx['objects'][extra] = { 'isa' => 'XCBuildConfiguration', 'name' => 'Extra',
                               'buildSettings' => NativeAppleSwift6Policy::REQUIRED.dup }
    end
  },
  'missing target' => ->(pbx) { pbx['objects']['project']['targets'].pop },
  'external xcconfig' => ->(pbx) { pbx['objects']['VortXMac-Release']['baseConfigurationReference'] = 'unresolved-config' }
}
mutations.each do |label, mutate|
  candidate = Marshal.load(Marshal.dump(generated_fixture))
  mutate.call(candidate)
  begin
    NativeAppleSwift6Policy.validate_generated!(candidate, 'native')
  rescue ArgumentError => error
    if ['missing Release', 'extra configuration'].include?(label)
      abort "wrong configuration-roster failure for #{label}: #{error}" unless error.message == 'expected exactly Debug and Release configurations'
    end
    policy_checks += 1
    next
  end
  abort "generated project policy accepted #{label}"
end
native_names = %w[VortXiOSNative VortXMac VortXTV VortXTVLite]
base_plists = native_names.to_h do |name|
  relative = project_spec.dig('targets', name, 'settings', 'base', 'INFOPLIST_FILE')
  [name, { path: relative, bytes: File.binread(File.join(app, relative)) }]
end
generated_plists = []
begin
  %w[..yml ...yml].each do |filename|
    rejected_output = File.join(app, filename)
    rejected_directory = File.expand_path(File.join(app, 'build', 'native-info', File.basename(filename, '.yml')))
    protected_paths = [rejected_output] + native_names.map { |name| File.join(rejected_directory, "#{name}.plist") }
    original_bytes = protected_paths.to_h { |path| [path, File.exist?(path) ? File.binread(path) : nil] }
    _, rejection_error, rejection_status = Open3.capture3('ruby', generator, '--engine-revision', revision,
      '--mpvkit', File.join(app, 'Vendor', 'MPVKit-DVFEL'), '--output', rejected_output)
    abort "collapsed #{filename} output was accepted" if rejection_status.success?
    abort "collapsed #{filename} output did not fail before generation" unless rejection_error.include?('non-collapsed directory name')
    protected_paths.each do |path|
      actual_bytes = File.exist?(path) ? File.binread(path) : nil
      abort "rejected #{filename} output modified #{path}" unless actual_bytes == original_bytes.fetch(path)
    end
  end
  # The generator exercises the actual local manifest; it does not load ignored binary inputs.
  stdout, stderr, status = Open3.capture3('ruby', generator, '--engine-revision', revision,
    '--mpvkit', File.join(app, 'Vendor', 'MPVKit-DVFEL'), '--output', output)
  abort "generator failed: #{stdout} #{stderr}" unless status.success?
  spec = YAML.safe_load(File.read(output), permitted_classes: [], permitted_symbols: [], aliases: false)
  NativeAppleSwift6Policy.validate!(spec)
  abort 'native generator changed shared Swift policy' unless spec.fetch('settings') == project_spec.fetch('settings')
  policy_checks += 1
  expected = %w[VortXiOSNative VortXMac VortXTV VortXTVLite VortXTopShelf]
  abort 'unexpected native target roster' unless spec.fetch('targets').keys.sort == expected.sort
  abort 'web/diagnostic scheme survived native generation' unless spec.fetch('schemes').keys.sort == (expected - ['VortXTopShelf']).sort
  expected[0...-1].each do |name|
    target = spec.fetch('targets').fetch(name)
    settings = target.fetch('settings').fetch('base')
    conditions = settings.fetch('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split
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
    generated_path = settings.fetch('INFOPLIST_FILE')
    abort "#{name} still uses its provenance-free base plist" if generated_path == base_plists.fetch(name).fetch(:path)
    expected_path = File.join('build', 'native-info', File.basename(output, '.yml'), "#{name}.plist")
    abort "#{name} generated plist escaped its spec-owned directory" unless generated_path == expected_path
    full_path = File.join(app, generated_path)
    generated_plists << full_path
    plist_json, plist_error, plist_status = Open3.capture3('/usr/bin/plutil', '-convert', 'json', '-o', '-', full_path)
    abort "#{name} generated plist is invalid: #{plist_error}" unless plist_status.success?
    plist = JSON.parse(plist_json)
    expected_provenance = {
      'VortXNativeDataEngine' => true,
      'VortXNativeResourceHost' => true,
      'VortXEngineSourceRevision' => revision,
      'VortXNativeTransport' => name == 'VortXMac' ? 'daemon' : (name == 'VortXTVLite' ? 'none' : 'in-process')
    }
    expected_provenance.each do |key, value|
      abort "#{name} emitted wrong native plist value/type for #{key}" unless plist.fetch(key, nil) == value
    end
    base_json, base_error, base_status = Open3.capture3('/usr/bin/plutil', '-convert', 'json', '-o', '-',
      File.join(app, base_plists.fetch(name).fetch(:path)))
    abort "#{name} base plist is invalid: #{base_error}" unless base_status.success?
    abort "#{name} generated plist lost retained base properties" unless plist == JSON.parse(base_json).merge(expected_provenance)
    abort "#{name} base plist was modified" unless File.binread(File.join(app, base_plists.fetch(name).fetch(:path))) == base_plists.fetch(name).fetch(:bytes)
    abort "#{name} omitted linker map" unless settings['LD_GENERATE_MAP_FILE']
  end
  abort 'Lite lost its transport boundary' unless spec.dig('targets', 'VortXTVLite', 'settings', 'base', 'SWIFT_ACTIVE_COMPILATION_CONDITIONS').split.include?('VORTX_NO_EMBEDDED_SERVER')
  abort 'macOS floor changed' unless spec.dig('targets', 'VortXMac', 'deploymentTarget') == '14.0'
  abort 'iOS floor changed' unless spec.dig('options', 'deploymentTarget', 'iOS') == '16.0'
  abort 'tvOS floor changed' unless spec.dig('options', 'deploymentTarget', 'tvOS') == '18.0'
  abort 'macOS unexpectedly fetches Node' if spec.dig('targets', 'VortXMac', 'preBuildScripts')
  embed = spec.dig('targets', 'VortXMac', 'postBuildScripts').fetch(0).fetch('script')
  abort 'macOS daemon is still optional' unless embed.include?('test -s "$source" && test -x "$source"')
  abort 'project.yml was modified' unless File.binread(File.join(app, 'project.yml')) == project_bytes
  # project.yml itself is native-only: no target links a removed engine or bundles a removed server.
  project_spec.fetch('targets').each do |name, target|
    frameworks = (target['dependencies'] || []).map { |d| d['framework'] }.compact
    abort "#{name} links a removed framework in project.yml" if frameworks.any? { |f| f.match?(/StremioXCore|NodeMobile/) }
    sources = (target['sources'] || []).map { |src| src.is_a?(Hash) ? src['path'] : src }
    abort "#{name} bundles a removed server runtime in project.yml" if sources.any? { |p| p.match?(/server\.js|node-darwin/) }
  end
  abort 'project.yml still has the web-host target' if project_spec.fetch('targets').key?('VortX')
  _, _, bad_revision = Open3.capture3('ruby', generator, '--engine-revision', 'latest', '--mpvkit', app, '--output', output)
  abort 'mutable engine revision was accepted' if bad_revision.success?
  _, _, overwrite = Open3.capture3('ruby', generator, '--engine-revision', revision,
    '--mpvkit', File.join(app, 'Vendor', 'MPVKit-DVFEL'), '--output', File.join(app, 'project.yml'))
  abort 'generator overwrote project.yml' if overwrite.success?
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
  puts 'PASS: native Apple project selection, rejected collapsed output paths, four actual provenance plists, retained base properties, dependency/resource removal, floors and required Mac server'
  puts "PASS: Swift 6/complete/warnings-as-errors shared policy, both diagnostic specs and #{policy_checks} real-validator checks"
ensure
  FileUtils.rm_f(output)
  generated_plists.each { |path| FileUtils.rm_f(path) }
  generated_dir = File.join(app, 'build', 'native-info', File.basename(output, '.yml'))
  Dir.rmdir(generated_dir) if Dir.exist?(generated_dir) && Dir.empty?(generated_dir)
end
