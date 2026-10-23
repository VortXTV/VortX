# Opt-in actual Foundation closure for full current Session/Facade fixtures.
# Compose with native_watched_swift_inputs and existing Runtime/resource/host inputs.
# No app/Manager/UI, fake authority, feature exclusion or activation flags are added.
native_owner_history_fixture_swift_inputs=(
  app/SourcesShared/VortxNativeProfiles.swift
  app/SourcesShared/VortxNativeProviderCredentials.swift
  app/SourcesShared/VortxNativeAccountCredentials.swift
  app/SourcesShared/AuthenticatedHTTPTransport.swift
  app/SourcesShared/LinkAuthService.swift
  app/SourcesShared/VortxLegacyWatchedMetadataTransport.swift
  app/SourcesShared/CredentialScope.swift
  app/SourcesShared/Keychain.swift
  app/SourcesShared/VortXSyncCrypto.swift
  app/SourcesShared/XperienceCollections.swift
  app/SourcesShared/XperienceAddonBinding.swift
  app/SourcesShared/XperienceNativePersistence.swift
  app/SourcesShared/XperienceExportObservation.swift
  app/SourcesShared/OwnerHistoryAccountExport.swift
  app/SourcesShared/OwnerHistoryCapturedSource.swift
  app/SourcesShared/OwnerHistoryExactSourceValidation.swift
  app/SourcesShared/OwnerHistoryLoginPreparation.swift
  app/SourcesShared/OwnerHistoryPeerMaterial.swift
  app/SourcesShared/OwnerHistoryRawAccountPreparation.swift
  app/SourcesShared/OwnerHistoryRawAccountPreparationWorker.swift
  app/SourcesShared/OwnerHistorySessionCoordinator.swift
  app/SourcesShared/OwnerHistorySessionPublication.swift
  app/SourcesShared/OwnerHistorySessionRuntime.swift
  app/SourcesShared/VortxNativeOwnerHistorySource.swift
  app/SourcesShared/VortxNativeOwnerHistoryPreparation.swift
  app/SourcesShared/VortxNativeOwnerHistoryCanonicalizer.swift
  app/SourcesShared/VortxNativeOwnerHistoryJournal.swift
)
