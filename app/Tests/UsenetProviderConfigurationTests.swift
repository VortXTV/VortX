// Executable regression contract for multiple saved NNTP servers: legacy decode, malformed payloads,
// enabled ordering, routing priority/dedupe/fallback/cancellation, secret redaction and the owner
// account boundary.
//
// Run from repository root:
// swiftc -parse-as-library -strict-concurrency=complete -warnings-as-errors -o /tmp/usenet-provider-config \
//   app/SourcesShared/UsenetProviderConfiguration.swift app/SourcesShared/UsenetRoutingPolicy.swift \
//   app/Tests/UsenetProviderConfigurationTests.swift && /tmp/usenet-provider-config

import Foundation

private actor AttemptRecorder {
    private(set) var attempts: [(route: DebridUsenetRoute, servers: [String])] = []
    func record(_ attempt: UsenetRoutingPolicy.LocalAttempt) { attempts.append((attempt.route, attempt.servers)) }
}

@main
private enum UsenetProviderConfigurationTests {
    static func main() async throws {
        try legacyDecodeKeepsEveryField()
        try malformedAndFuturePayloadsAreDroppedFailSoft()
        try encodedPayloadValidationIsFailClosed()
        try emptyAndDisabledListsYieldNoEnabledServers()
        try enabledOrderIsPriorityOrder()
        try savedServersSubmitAsOneOrderedCreateAfterAddon()
        try exactIdentitiesDedupeWithinSavedAndAgainstAddon()
        try exclusionsAndLegacySingleServerAPIRemainIntact()
        try await fallbackAdvancesOnceAndCancellationIsTerminal()
        try secretsNeverReachRedactedSurfaces()
        try ownerAccountsNeverCrossOwners()
        try reencodeRoundTripsAndStableIDsSurviveEdits()
        try delimiterCredentialsHaveUnambiguousIdentity()
        print("PASS  multiple saved NNTP servers: legacy decode, ordering, dedupe, fallback, cancellation, redaction, owner boundary")
    }

    // MARK: Legacy decode / migration

    private static func legacyDecodeKeepsEveryField() throws {
        let legacy = #"{"host":"news.example.com","port":563,"username":"u1","password":"p1","maxConnections":8,"useSSL":true}"#
        let list = try decode(legacy)
        try check(list.servers.count == 1, "legacy single credential decodes into a one-server list")
        let server = try unwrap(list.servers.first)
        try check(server.enabled, "migrated legacy server is enabled")
        try check(server.host == "news.example.com" && server.port == 563 && server.username == "u1"
                  && server.password == "p1" && server.maxConnections == 8 && server.useSSL,
                  "legacy fields survive migration verbatim")
        try check(!server.id.isEmpty, "migrated server gets a stable id")
        let second = try unwrap(decode(legacy).servers.first)
        try check(second.id == server.id && server.id == UsenetProviderServer.legacyServerID,
                  "legacy loads reuse the reserved stable server id")
        let creds = try unwrap(list.firstEnabledCredentials)
        try check(creds == UsenetProviderCredentials(host: "news.example.com", port: 563, username: "u1",
                                                     password: "p1", maxConnections: 8, useSSL: true),
                  "compat loadCredentials shape equals the legacy object")
        try check(!UsenetProviderConfiguration.isBareHost("2001:db8::1")
                  && !UsenetProviderConfiguration.isBareHost("nntps://news.example:563"),
                  "saved server host rejects unsupported IPv6 and URL authorities")
    }

    private static func malformedAndFuturePayloadsAreDroppedFailSoft() throws {
        try check(decodeOption("{\"version\":2}") == nil, "versioned payload without servers is malformed")
        try check(decodeOption("{\"version\":99,\"servers\":[]}") == nil, "unknown future version is rejected, not half-read")
        try check(decodeOption("not json at all") == nil, "garbage is dropped fail-soft")
        try check(decodeOption("{}") == nil, "empty object is neither a list nor a valid legacy credential")
        // An INVALID legacy credential (no password) is dropped exactly like the old single-credential store.
        try check(decodeOption(#"{"host":"h","port":563,"username":"u","password":"","maxConnections":8,"useSSL":true}"#) == nil,
                  "invalid legacy credential is dropped, never migrated as a passwordless server")
    }

    private static func encodedPayloadValidationIsFailClosed() throws {
        let valid = server("valid", host: "news.example")
        var future = UsenetProviderServerList(servers: [valid]); future.version = 99
        try check(future.encoded() == nil, "save encoding rejects future versions")
        var duplicate = UsenetProviderServerList(servers: [valid, valid]); duplicate.version = 2
        try check(duplicate.encoded() == nil, "save encoding rejects duplicate IDs")
        let invalid = UsenetProviderServer(name: "bad", host: "nntps://news.example:563", port: 563,
                                           username: "u", password: "p", maxConnections: 4, useSSL: true)
        try check(UsenetProviderServerList(servers: [invalid]).encoded() == nil,
                  "save encoding rejects URL-form hosts")
    }

    private static func emptyAndDisabledListsYieldNoEnabledServers() throws {
        let empty = try decode(#"{"version":2,"servers":[]}"#)
        try check(empty.servers.isEmpty == true, "an explicitly empty server list decodes")
        try check(empty.enabledServers.isEmpty == true, "empty list has no enabled servers")
        let allDisabled = try decode(#"{"version":2,"servers":[{"id":"a","name":"A","host":"a.example","port":563,"username":"u","password":"p","maxConnections":4,"useSSL":true,"enabled":false}]}"#)
        try check(allDisabled.servers.count == 1, "disabled servers stay saved")
        try check(allDisabled.enabledServers.isEmpty == true, "disabled servers are never enabled/submitted")
        try check(allDisabled.firstEnabledCredentials == nil, "compat first-enabled returns nil when all are off")
    }

    private static func enabledOrderIsPriorityOrder() throws {
        let list = UsenetProviderServerList(servers: [
            server("primary", host: "one.example", enabled: false),
            server("second", host: "two.example"),
            server("third", host: "three.example"),
        ])
        try check(list.enabledServers.map(\.name) == ["second", "third"],
                  "enabled servers keep array (priority) order with disabled ones skipped in place")
    }

    // MARK: Routing

    private static func savedServersSubmitAsOneOrderedCreateAfterAddon() throws {
        let addon = ["nntps://addon-a.example:563/4", "nntps://addon-b.example:563/4"]
        let saved = ["nntps://one.example:563/8", "nntps://two.example:119/4"]
        let attempts = UsenetRoutingPolicy.localAttempts(addonServers: addon, savedServers: saved)
        try check(attempts.map(\.route) == [.addonNNTP, .savedNNTP], "addon route first, saved route second")
        try check(attempts.first?.servers == addon, "all add-on servers ride one create")
        // ONE saved create carrying BOTH servers in user priority order: the Node engine owns per-article
        // failover inside a create, so the app never blindly re-downloads per server.
        try check(attempts.last?.servers == saved, "saved servers submit as one ordered create, not N retries")
    }

    private static func exactIdentitiesDedupeWithinSavedAndAgainstAddon() throws {
        let samePrimaryTwice = ["nntps://one.example:563/8", "nntps://one.example:563/8", "nntps://two.example:563/8"]
        let deduped = UsenetRoutingPolicy.localAttempts(addonServers: [], savedServers: samePrimaryTwice)
        try check(deduped.last?.servers.count == 2, "exact duplicate saved servers are submitted once")
        // Scheme/host/port/user/password all matter; a differing password is a different identity.
        let differing = ["nntps://one.example:563/8", "nntps://one.example:563/8", "nntps://u2:other@one.example:563/8"]
        try check(UsenetRoutingPolicy.localAttempts(addonServers: [], savedServers: differing).last?.servers.count == 2,
                  "identities differing only by credentials are NOT deduped")
        // Host case-insensitivity is part of the normalized identity.
        let caseVariant = ["nntps://one.example:563/8", "nntps://ONE.EXAMPLE:563/8"]
        try check(UsenetRoutingPolicy.localAttempts(addonServers: [], savedServers: caseVariant).last?.servers.count == 1,
                  "case-only host differences are the same server identity")
        let addonHostingSaved = UsenetRoutingPolicy.localAttempts(
            addonServers: ["nntps://one.example:563/8"], savedServers: ["nntps://one.example:563/8", "nntps://two.example:563/8"])
        try check(addonHostingSaved.map(\.route) == [.addonNNTP, .savedNNTP],
                  "an add-on server identical to a saved one consumes only that saved server")
        try check(addonHostingSaved.last?.servers == ["nntps://two.example:563/8"],
                  "the remaining distinct saved server is still submitted, the duplicate is not retried")
    }

    private static func exclusionsAndLegacySingleServerAPIRemainIntact() throws {
        let addon = ["nntps://addon.example:563/4"]
        let saved = "nntps://saved.example:563/8"
        // Preserved legacy entry point: existing savedServer callers and tests keep their behaviour.
        try check(UsenetRoutingPolicy.localAttempts(addonServers: addon, savedServer: saved)
                  .map(\.route) == [.addonNNTP, .savedNNTP], "legacy savedServer API still orders addon then saved")
        try check(UsenetRoutingPolicy.localAttempts(addonServers: addon, savedServer: saved, excluding: [.addonNNTP])
                  .map(\.route) == [.savedNNTP], "legacy API still honours exclusions")
        try check(UsenetRoutingPolicy.localAttempts(addonServers: [saved], savedServer: saved)
                  .map(\.route) == [.addonNNTP], "legacy API still dedupes an equivalent saved provider")
        try check(UsenetRoutingPolicy.localAttempts(addonServers: addon, savedServers: [saved],
                                                    excluding: [.addonNNTP, .savedNNTP]).isEmpty,
                  "excluding every local route yields no local attempt (cloud stays reachable)")
    }

    private static func fallbackAdvancesOnceAndCancellationIsTerminal() async throws {
        let attempts = UsenetRoutingPolicy.localAttempts(
            addonServers: ["nntps://addon.example:563/4"],
            savedServers: ["nntps://one.example:563/8", "nntps://two.example:563/8"])
        let recorder = AttemptRecorder()
        let resolved = try await UsenetRoutingPolicy.firstSuccessful(attempts) { attempt in
            await recorder.record(attempt)
            if attempt.route == .addonNNTP { throw URLError(.cannotConnectToHost) }
            return "loopback-stream"
        }
        try check(resolved?.0 == .savedNNTP, "a genuine addon create failure advances exactly one route")
        let calls = await recorder.attempts
        try check(calls.map(\.route) == [.addonNNTP, .savedNNTP], "transport stays sequential")
        try check(calls.last?.servers == ["nntps://one.example:563/8", "nntps://two.example:563/8"],
                  "the fallback create carries the whole ordered saved array")

        let cancelled = Task {
            try await UsenetRoutingPolicy.firstSuccessful(attempts) { attempt in
                if attempt.route == .addonNNTP { throw CancellationError() }
                return "must-not-run"
            }
        }
        do {
            _ = try await cancelled.value
            throw failure("cancellation must propagate")
        } catch is CancellationError {
            // expected: a cancelled task is never converted into the next provider attempt
        }
    }

    // MARK: Secret preservation / owner boundary

    private static func secretsNeverReachRedactedSurfaces() throws {
        let server = server("Primary", host: "news.example.com")
        let summary = server.redactedSummary
        try check(!summary.contains(server.password) && !summary.contains(server.username),
                  "redacted summary never contains the password or the username")
        try check(summary.contains("news.example.com"), "redacted summary still identifies the server usefully")
        // The engine URL percent-encodes credential delimiters away (unchanged legacy contract).
        let tricky = UsenetProviderServer(name: "T", host: "h.example", port: 563,
                                          username: "u:ser@name", password: "p@ss:wo/rd",
                                          maxConnections: 4, useSSL: true)
        let url = tricky.nntpServerURL
        try check(!url.dropFirst("nntps://".count).contains(":") || url.contains("%"), "delimiter-bearing credentials stay encoded")
        try check(url.hasPrefix("nntps://u%3Aser%40name:p%40ss%3Awo%2Frd@h.example:563/4"),
                  "engine URL encodes exactly the legacy credential contract")
    }

    private static func ownerAccountsNeverCrossOwners() throws {
        let a = try unwrap(UsenetProviderConfiguration.keychainAccount(ownerID: "11111111-1111-1111-1111-111111111111"))
        let b = try unwrap(UsenetProviderConfiguration.keychainAccount(ownerID: "22222222-2222-2222-2222-222222222222"))
        try check(a.hasPrefix(UsenetProviderConfiguration.accountPrefix) && b.hasPrefix(UsenetProviderConfiguration.accountPrefix),
                  "both owners stay under the usenet keychain prefix")
        try check(a != b, "two owners can never share one keychain account, so passwords cannot cross owners")
        try check(!a.contains(b.dropFirst(UsenetProviderConfiguration.accountPrefix.count)),
                  "one owner's account string never embeds the other owner's id")
        try check(UsenetProviderConfiguration.keychainAccount(ownerID: "") == nil
                  && UsenetProviderConfiguration.keychainAccount(ownerID: "   ") == nil,
                  "an ownerless boundary can never read or write any server entry")
    }

    private static func reencodeRoundTripsAndStableIDsSurviveEdits() throws {
        let list = UsenetProviderServerList(servers: [server("Primary", host: "one.example"),
                                                      server("Backup", host: "two.example", enabled: false)])
        let data = try unwrap(list.encoded())
        let roundTrip = try unwrap(UsenetProviderServerList.decode(data))
        try check(roundTrip == list, "encode/decode round-trips the whole ordered list")
        try check(roundTrip.version == UsenetProviderServerList.currentVersion, "writes always carry the current version")
        // An edit (rename + host change + blank-password retention model) keeps the stable id and slot.
        var edited = roundTrip.servers[0]
        edited.name = "Renamed"; edited.host = "new.example"
        let editedList = UsenetProviderServerList(servers: [edited, roundTrip.servers[1]])
        let again = try unwrap(UsenetProviderServerList.decode(try unwrap(editedList.encoded())))
        try check(again.servers.map(\.id) == roundTrip.servers.map(\.id),
                  "stable ids and priority slots survive a save unchanged")
    }

    // MARK: helpers

    private static func decode(_ json: String) throws -> UsenetProviderServerList {
        try unwrap(UsenetProviderServerList.decode(Data(json.utf8)))
    }

    private static func decodeOption(_ json: String) -> UsenetProviderServerList? {
        UsenetProviderServerList.decode(Data(json.utf8))
    }

    private static func server(_ name: String, host: String, enabled: Bool = true) -> UsenetProviderServer {
        UsenetProviderServer(id: "id-\(name)", name: name, host: host, port: 563, username: "user-\(name)",
                             password: "pass-\(name)", maxConnections: 4, useSSL: true, enabled: enabled)
    }

    private static func unwrap<T>(_ value: T?) throws -> T {
        guard let value else { throw failure("unexpected nil") }
        return value
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw failure(message) }
    }

    private static func delimiterCredentialsHaveUnambiguousIdentity() throws {
        let a = UsenetRoutingPolicy.normalizedServerIdentity("nntps://u%7Cv:p@news.example:563/4")
        let b = UsenetRoutingPolicy.normalizedServerIdentity("nntps://u:v%7Cp@news.example:563/4")
        try check(a != b, "credential delimiters cannot collide in normalized identity")
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "UsenetProviderConfiguration", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
