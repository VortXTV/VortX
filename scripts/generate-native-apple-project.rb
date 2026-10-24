#!/usr/bin/env ruby
# Generate the release project spec from project.yml without modifying it: release targets only, the
# verified MPVKit package, engine provenance in each app's Info.plist, and linker maps.
# All source and package paths remain relative to app/, where XcodeGen reads this file.
require 'optparse'
require 'yaml'
require 'pathname'
require 'fileutils'
require 'json'
require 'open3'
require_relative 'native-apple-swift6-policy'

options = {}
OptionParser.new do |parser|
  parser.banner = 'Usage: generate-native-apple-project.rb --engine-revision <40-hex> --mpvkit <verified-package> --output <app/spec.yml>'
  parser.on('--engine-revision SHA') { |value| options[:revision] = value }
  parser.on('--mpvkit PATH') { |value| options[:mpvkit] = value }
  parser.on('--output PATH') { |value| options[:output] = value }
end.parse!
abort 'engine revision must be a full immutable SHA' unless options[:revision]&.match?(/\A[0-9a-f]{40}\z/)
abort 'an explicit verified MPVKit package is required' unless options[:mpvkit]
abort 'an output spec path is required' unless options[:output]

app = File.realpath(File.join(__dir__, '..', 'app'))
output = File.expand_path(options[:output])
abort 'generated spec must be directly inside app/' unless File.dirname(output) == app
abort 'refusing to replace project.yml' if output == File.join(app, 'project.yml')
native_info_stem = File.basename(output, '.yml')
abort 'generated spec must have a non-collapsed directory name' if %w[. ..].include?(native_info_stem)
mpvkit = File.realpath(options[:mpvkit])
abort 'MPVKit Package.swift is missing' unless File.file?(File.join(mpvkit, 'Package.swift'))

spec = YAML.safe_load(File.read(File.join(app, 'project.yml')), permitted_classes: [], permitted_symbols: [], aliases: false)
NativeAppleSwift6Policy.validate!(spec)
native_targets = %w[VortXiOSNative VortXMac VortXTV VortXTVLite]
retained_targets = native_targets + ['VortXTopShelf']
abort 'native release target roster changed; review the generator' unless (retained_targets - spec.fetch('targets').keys).empty?
spec['targets'].select! { |name, _| retained_targets.include?(name) }
spec.fetch('schemes').select! { |name, _| native_targets.include?(name) }
spec.fetch('packages').fetch('MPVKit')['path'] = Pathname.new(mpvkit).relative_path_from(Pathname.new(app)).to_s
native_info_directory = File.join('build', 'native-info', native_info_stem)
FileUtils.mkdir_p(File.join(app, native_info_directory))

native_targets.each do |name|
  target = spec.fetch('targets').fetch(name)
  frameworks = target.fetch('dependencies').map { |dependency| dependency['framework'] }.compact
  abort "#{name} must link Vendor/VortxEngine.xcframework" unless frameworks.include?('Vendor/VortxEngine.xcframework')
  abort "#{name} links a framework outside the release set: #{frameworks}" unless (frameworks - ['Vendor/VortxEngine.xcframework']).empty?
  resources = target.fetch('sources').map { |source| source.is_a?(Hash) ? source['path'] : source }
  abort "#{name} bundles a removed server runtime" if resources.any? { |path| path.match?(/server\.js|node-darwin/) }
  settings = target.fetch('settings').fetch('base')
  in_process = settings.fetch('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '').split.include?('VORTX_ENGINE_SERVER')
  abort "#{name} in-process server selection changed; review the generator" unless in_process == %w[VortXiOSNative VortXTV].include?(name)
  settings['INFOPLIST_KEY_VortXNativeDataEngine'] = true
  settings['INFOPLIST_KEY_VortXNativeResourceHost'] = true
  settings['INFOPLIST_KEY_VortXEngineSourceRevision'] = options[:revision]
  settings['INFOPLIST_KEY_VortXNativeTransport'] = name == 'VortXMac' ? 'daemon' : (name == 'VortXTVLite' ? 'none' : 'in-process')
  # Xcode does not emit arbitrary INFOPLIST_KEY_* settings into an explicit base plist.
  # Preserve every existing property/build-variable placeholder in a generated, spec-owned
  # base instead. Do not modify the retained legacy plists shared by comparison targets.
  base_plist = File.realpath(File.join(app, settings.fetch('INFOPLIST_FILE')))
  abort "#{name} base plist escaped app/" unless base_plist.start_with?(app + File::SEPARATOR)
  plist_json, plist_error, plist_status = Open3.capture3('/usr/bin/plutil', '-convert', 'json', '-o', '-', base_plist)
  abort "#{name} base plist could not be read: #{plist_error}" unless plist_status.success?
  properties = JSON.parse(plist_json)
  %w[VortXNativeDataEngine VortXNativeResourceHost VortXEngineSourceRevision VortXNativeTransport].each do |key|
    properties[key] = settings.fetch("INFOPLIST_KEY_#{key}")
  end
  native_plist = File.join(native_info_directory, "#{name}.plist")
  _, write_error, write_status = Open3.capture3('/usr/bin/plutil', '-convert', 'xml1', '-o', File.join(app, native_plist), '--', '-',
    stdin_data: JSON.generate(properties))
  abort "#{name} native plist could not be generated: #{write_error}" unless write_status.success?
  settings['INFOPLIST_FILE'] = native_plist
  # A retained linker map lets package acceptance prove which exact static archive was consumed.
  settings['LD_GENERATE_MAP_FILE'] = true
  settings['LD_MAP_FILE_PATH'] = '$(TARGET_TEMP_DIR)/$(PRODUCT_NAME)-$(CURRENT_ARCH).map'
end

mac = spec.fetch('targets').fetch('VortXMac')
abort 'macOS must not fetch a separate runtime before build' if mac['preBuildScripts']
embed = mac.fetch('postBuildScripts', []).map { |phase| phase['script'].to_s }.join("\n")
abort 'macOS must embed the required native streaming server' unless embed.include?('test -s "$source" && test -x "$source"')
# The reviewed VortxEngine Mac SDK and daemon contain arm64, never an implicit universal build.
abort 'macOS must build arm64 only' unless mac.fetch('settings').fetch('base')['ARCHS'] == 'arm64'

File.write(output, YAML.dump(spec))
puts "Generated native Apple project spec: #{output} (engine #{options[:revision]})"
