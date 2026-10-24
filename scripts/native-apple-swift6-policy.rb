# frozen_string_literal: true
# Shared source-of-truth policy for XcodeGen and the native release generator.
# This checks declared settings, not external xcconfig/command-line overrides
# or a compiler/build result. Inspect generated projects and real build receipts too.
module NativeAppleSwift6Policy
  REQUIRED = {
    'SWIFT_VERSION' => '6.0',
    'SWIFT_STRICT_CONCURRENCY' => 'complete',
    'SWIFT_TREAT_WARNINGS_AS_ERRORS' => 'YES'
  }.freeze
  ROSTERS = {
    'native' => %w[VortXiOSNative VortXMac VortXTV VortXTVLite VortXTopShelf],
    'main' => %w[VortXiOSNative VortXMac VortXTV VortXTVLite VortXTopShelf CinemaUISmokeRenderer],
    'mac-smoke' => %w[CinemaUISmokeRenderer],
    'ios-smoke' => %w[CinemaUISmokeIOSRenderer]
  }.each_value(&:freeze).freeze

  def self.validate!(spec)
    base = spec.fetch('settings').fetch('base')
    REQUIRED.each do |key, value|
      raise ArgumentError, "project.settings.base must declare #{key}=#{value}" unless base[key] == value
    end
    scopes = { 'project.settings' => spec.fetch('settings') }
    spec.fetch('targets').each do |name, target|
      scopes["#{name}.settings"] = target.fetch('settings', {})
    end
    %w[targetTemplates settingGroups].each do |section|
      spec.fetch(section, {}).each do |name, entry|
        scopes["#{section}.#{name}"] = entry
      end
    end
    scopes.each { |scope, settings| validate_overrides!(settings, scope) }
    true
  end

  def self.validate_overrides!(settings, scope)
    raise ArgumentError, "#{scope} must be a settings map" unless settings.is_a?(Hash)
    settings.each do |key, value|
      setting = REQUIRED.keys.find { |name| key == name || key.to_s.start_with?(name + '[') }
      if setting && value != REQUIRED.fetch(setting)
        raise ArgumentError, "#{scope}.#{key} must preserve #{setting}=#{REQUIRED.fetch(setting)}"
      end
      validate_overrides!(value, "#{scope}.#{key}") if value.is_a?(Hash)
    end
  end

  def self.generated_configurations(objects, owner)
    list = objects.fetch(owner.fetch('buildConfigurationList'))
    raise ArgumentError, 'expected an Xcode configuration list' unless list.fetch('isa') == 'XCConfigurationList'
    configurations = list.fetch('buildConfigurations').map do |id|
      configuration = objects.fetch(id)
      raise ArgumentError, 'expected an Xcode build configuration' unless configuration.fetch('isa') == 'XCBuildConfiguration'
      raise ArgumentError, 'resolve external xcconfig before accepting Swift policy' if configuration.key?('baseConfigurationReference')
      [configuration.fetch('name'), configuration.fetch('buildSettings')]
    end
    raise ArgumentError, 'empty or duplicate Xcode configurations' if configurations.empty? || configurations.map(&:first).uniq.length != configurations.length
    configurations.to_h
  end

  def self.validate_generated!(project, scope)
    objects = project.fetch('objects')
    root = objects.fetch(project.fetch('rootObject'))
    raise ArgumentError, 'expected an Xcode project' unless root.fetch('isa') == 'PBXProject'
    defaults = generated_configurations(objects, root)
    raise ArgumentError, 'expected exactly Debug and Release configurations' unless defaults.keys.sort == %w[Debug Release]
    targets = root.fetch('targets').map { |id| objects.fetch(id) }
    raise ArgumentError, 'unexpected generated target kind' unless targets.all? { |target| target.fetch('isa') == 'PBXNativeTarget' }
    raise ArgumentError, 'generated target roster differs' unless targets.map { |target| target.fetch('name') }.sort == ROSTERS.fetch(scope).sort
    targets.flat_map do |target|
      configurations = generated_configurations(objects, target)
      raise ArgumentError, 'target/project configurations differ' unless configurations.keys.sort == defaults.keys.sort
      configurations.map do |name, settings|
        effective = defaults.fetch(name).merge(settings)
        validate_overrides!(effective, "#{target.fetch('name')}.#{name}")
        REQUIRED.each do |key, value|
          raise ArgumentError, "#{target.fetch('name')}.#{name} lacks #{key}=#{value}" unless effective[key] == value
        end
        { 'target' => target.fetch('name'), 'configuration' => name }.merge(REQUIRED)
      end
    end
  end
end

if $PROGRAM_NAME == __FILE__
  require 'json'
  require 'open3'
  require 'digest'
  abort 'Usage: native-apple-swift6-policy.rb <project.xcodeproj> <native|main|mac-smoke|ios-smoke>' unless ARGV.length == 2 && NativeAppleSwift6Policy::ROSTERS.key?(ARGV[1])
  file = File.join(File.realpath(ARGV[0]), 'project.pbxproj')
  abort 'generated project metadata exceeds 16MiB' if File.size(file) > 16 * 1024 * 1024
  bytes = File.binread(file)
  json, error, status = Open3.capture3('/usr/bin/plutil', '-convert', 'json', '-o', '-', '--', '-', stdin_data: bytes)
  abort "generated project metadata is invalid: #{error}" unless status.success?
  rows = NativeAppleSwift6Policy.validate_generated!(JSON.parse(json), ARGV[1])
  abort 'generated project changed during validation' unless File.binread(file) == bytes
  puts JSON.pretty_generate('scope' => ARGV[1], 'projectSHA256' => Digest::SHA256.hexdigest(bytes),
                            'configurations' => rows, 'compiled' => false)
end
