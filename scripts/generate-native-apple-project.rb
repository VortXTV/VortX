#!/usr/bin/env ruby
# Generate the explicit native release project without modifying the retained legacy spec.
# All source and package paths remain relative to app/, where XcodeGen reads this file.
require 'optparse'
require 'yaml'
require 'pathname'

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
abort 'refusing to replace the retained legacy project.yml' if output == File.join(app, 'project.yml')
mpvkit = File.realpath(options[:mpvkit])
abort 'MPVKit Package.swift is missing' unless File.file?(File.join(mpvkit, 'Package.swift'))

spec = YAML.safe_load(File.read(File.join(app, 'project.yml')), permitted_classes: [], permitted_symbols: [], aliases: false)
native_targets = %w[VortXiOSNative VortXMac VortXTV VortXTVLite]
retained_targets = native_targets + ['VortXTopShelf']
abort 'native release target roster changed; review the generator' unless (retained_targets - spec.fetch('targets').keys).empty?
spec['targets'].select! { |name, _| retained_targets.include?(name) }
spec.fetch('schemes').select! { |name, _| native_targets.include?(name) }
spec.fetch('packages').fetch('MPVKit')['path'] = Pathname.new(mpvkit).relative_path_from(Pathname.new(app)).to_s

native_targets.each do |name|
  target = spec.fetch('targets').fetch(name)
  target.fetch('dependencies').reject! do |dependency|
    %w[Vendor/StremioXCore.xcframework Vendor/nodejs-mobile/NodeMobile.xcframework].include?(dependency['framework'])
  end
  unless target.fetch('dependencies').any? { |dependency| dependency['framework'] == 'Vendor/VortxEngine.xcframework' }
    target.fetch('dependencies') << { 'framework' => 'Vendor/VortxEngine.xcframework', 'embed' => false }
  end
  target.fetch('sources').reject! do |source|
    path = source.is_a?(Hash) ? source['path'] : source
    %w[Resources/server.js Resources/node-darwin-arm64].include?(path)
  end
  settings = target.fetch('settings').fetch('base')
  conditions = settings.fetch('SWIFT_ACTIVE_COMPILATION_CONDITIONS', '$(inherited)').split
  conditions.concat(%w[VORTX_NATIVE_DATA_ENGINE VORTX_ENGINE_STATE_BRIDGE VORTX_ENGINE_RESOURCE_HOST])
  conditions << 'VORTX_ENGINE_SERVER' if %w[VortXiOSNative VortXTV].include?(name)
  settings['SWIFT_ACTIVE_COMPILATION_CONDITIONS'] = conditions.uniq.join(' ')
  settings['SWIFT_INCLUDE_PATHS'] = '$(inherited) $(BUILT_PRODUCTS_DIR)/include/vortx'
  settings['INFOPLIST_KEY_VortXNativeDataEngine'] = true
  settings['INFOPLIST_KEY_VortXNativeResourceHost'] = true
  settings['INFOPLIST_KEY_VortXEngineSourceRevision'] = options[:revision]
  settings['INFOPLIST_KEY_VortXNativeTransport'] = name == 'VortXMac' ? 'daemon' : (name == 'VortXTVLite' ? 'none' : 'in-process')
  # A retained linker map lets package acceptance prove which exact static archive was consumed.
  settings['LD_GENERATE_MAP_FILE'] = true
  settings['LD_MAP_FILE_PATH'] = '$(TARGET_TEMP_DIR)/$(PRODUCT_NAME)-$(CURRENT_ARCH).map'
end

mac = spec.fetch('targets').fetch('VortXMac')
mac.delete('preBuildScripts') # The native package contains no Node runtime to fetch.
mac['postBuildScripts'] = [{
  'name' => 'Embed required native streaming server',
  'basedOnDependencyAnalysis' => false,
  'inputFiles' => ['$(SRCROOT)/Vendor/vortx-streaming-server'],
  'outputFiles' => ['$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/vortx-streaming-server'],
  'script' => <<~SCRIPT
    set -euo pipefail
    source="${SRCROOT}/Vendor/vortx-streaming-server"
    test -s "$source" && test -x "$source" || { echo "error: native Mac server is required" >&2; exit 1; }
    destination="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/vortx-streaming-server"
    cp -f "$source" "$destination"
    chmod +x "$destination"
  SCRIPT
}]
# The reviewed VortxEngine Mac SDK and daemon currently contain arm64, never an implicit universal build.
mac.fetch('settings').fetch('base')['ARCHS'] = 'arm64'

File.write(output, YAML.dump(spec))
puts "Generated native Apple project spec: #{output} (engine #{options[:revision]})"
