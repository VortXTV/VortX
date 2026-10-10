# Shared explicit Swift inputs for checkpoint fixtures. Source after changing to the repo root.
# Session diagnostics stay inert in these standalone fixtures, never in application targets.
native_watched_swift_inputs=(
  app/Tests/NativeSessionDiagnosticsStub.swift
  app/SourcesShared/LegacyWatchedBitfieldDecoder.swift
  app/SourcesShared/LegacyWatchedBitfieldMigrationEvidence.swift
  app/SourcesShared/VortxLegacyWatchedMigration.swift
  app/SourcesShared/VortxLegacyBootstrapMaterial.swift
  app/SourcesShared/VortxNativeWatchedArchive.swift
  app/SourcesShared/VortxNativeWatchlist.swift
  app/SourcesShared/VortxNativeWebsiteAddonEdits.swift
  -lz
)
