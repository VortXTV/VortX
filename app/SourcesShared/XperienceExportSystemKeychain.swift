import Foundation
#if canImport(Security)
import Security
#if !os(tvOS)
import LocalAuthentication
#endif
#endif

/// Connector-only system Security storage. Existing Keychain.swift uses a file backend on macOS;
/// that backend is deliberately not used for export URLs. No plist/defaults/file/volatile fallback.
enum XperienceExportSystemKeychain {
    #if canImport(Security)
    private static let secure = KeychainFailureClosedStore(
        readSecure: read, writeSecure: write,
        invalidationAccount: { "invalidated." + $0 }, invalidationSentinel: "invalidated-v1",
        isLegacyInvalidated: { _ in false }, clearLegacyInvalidated: { _ in },
        purgeAllLegacy: {}, purgeLegacy: { _ in })
    static let credentials = XperienceExportCredentialStore(
        read: { secure.confirmedString($0) }, write: { secure.set($0, for: $1) })

    private static func query(_ account: String) -> [String: Any] {
        var value: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "tv.vortx.xperience.profile-export.v1",
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false
        ]
        #if os(tvOS)
        // Explicit TV-only SDK compatibility exception, not a completed API migration.
        // The typed C boundary returns the original public Fail constant because the
        // recommended LAContext.interactionNotAllowed replacement is unavailable here.
        // Preserve protected-item failures; never silently Skip or permit default Allow.
        value[kSecUseAuthenticationUI as String] = VortXTVKeychainAuthenticationUIFailCompatibilityValue()
        #else
        // Fresh per query: never reuse a previously authenticated context across operations.
        let context = LAContext()
        context.interactionNotAllowed = true
        value[kSecUseAuthenticationContext as String] = context
        #endif
        #if os(macOS)
        value[kSecUseDataProtectionKeychain as String] = true
        #endif
        return value
    }
    private static func read(_ account: String) -> CredentialDurableReadResult {
        var request = query(account)
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return .missing }
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8) else { return .failure }
        return .value(value)
    }
    private static func write(_ value: String?, _ account: String) -> CredentialMutationResult {
        let request = query(account)
        guard let value else {
            let status = SecItemDelete(request as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound ? .success : .failure
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(request as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return .success }
        guard status == errSecItemNotFound else { return .failure }
        var addition = request
        addition[kSecValueData as String] = data
        addition[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        return SecItemAdd(addition as CFDictionary, nil) == errSecSuccess ? .success : .failure
    }
    #else
    static let credentials = XperienceExportCredentialStore(read: { _ in .failure }, write: { _, _ in .failure })
    #endif
}
