#!/usr/bin/env node
import { createHash } from "node:crypto";
import { execFile } from "node:child_process";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { promisify } from "node:util";
import { resolve } from "node:path";

const execFileAsync = promisify(execFile);
const repo = resolve(new URL("..", import.meta.url).pathname);
const swiftFixture = resolve(repo, "app/Tests/NativeProfileSwitchAdmissionLiveTests.swift");

function sha256(data) { return createHash("sha256").update(data).digest("hex"); }

function balancedMember(source, marker, { attributes = true } = {}) {
  const markerOffset = source.indexOf(marker);
  if (markerOffset < 0) throw new Error(`production source marker not found: ${marker}`);
  let start = source.lastIndexOf("\n", markerOffset) + 1;
  if (attributes) {
    // Keep exact declaration attributes such as @MainActor, but never carry surrounding #if
    // directives into the synthetic translation unit.
    for (;;) {
      const previousEnd = Math.max(0, start - 1);
      const previousStart = source.lastIndexOf("\n", previousEnd - 1) + 1;
      const line = source.slice(previousStart, previousEnd).trim();
      if (line.startsWith("@") || line.startsWith("///")) start = previousStart;
      else break;
    }
  }
  const bodyStart = source.indexOf("{", markerOffset);
  if (bodyStart < 0) throw new Error(`declaration has no body: ${marker}`);
  let depth = 0;
  let quote = null;
  let escaped = false;
  let lineComment = false;
  let blockComment = false;
  for (let i = bodyStart; i < source.length; i += 1) {
    const c = source[i];
    const n = source[i + 1];
    if (lineComment) { if (c === "\n") lineComment = false; continue; }
    if (blockComment) { if (c === "*" && n === "/") { blockComment = false; i += 1; } continue; }
    if (quote) {
      if (escaped) { escaped = false; continue; }
      if (c === "\\") { escaped = true; continue; }
      if (c === quote) quote = null;
      continue;
    }
    if (c === "/" && n === "/") { lineComment = true; i += 1; continue; }
    if (c === "/" && n === "*") { blockComment = true; i += 1; continue; }
    if (c === '"' || c === "'") { quote = c; continue; }
    if (c === "{") depth += 1;
    if (c === "}" && --depth === 0) return source.slice(start, i + 1).trim();
  }
  throw new Error(`unbalanced production declaration: ${marker}`);
}

function optionalMember(source, marker, options = {}) {
  return source.includes(marker) ? balancedMember(source, marker, options) : null;
}

function sourceFor(ref, path) {
  if (!ref) return readFile(resolve(repo, path), "utf8");
  return execFileAsync("git", ["show", `${ref}:${path}`], { cwd: repo, maxBuffer: 32 * 1024 * 1024 })
    .then(({ stdout }) => stdout);
}

function replaceJournalRoot(member) {
  const pattern = /let root = try FileManager\.default\.url[\s\S]*?\.appendingPathComponent\("VortX\/native-preference-intents", isDirectory: true\)/;
  if (!pattern.test(member)) throw new Error("nativePreferenceStore production root expression not found");
  return member.replace(pattern, "let root = NativeProfileSwitchAdmissionEnvironment.journalRoot");
}

async function extract(outDir, baselineRef) {
  await mkdir(outDir, { recursive: true });
  const [profiles, core, manager, discovery, fixture] = await Promise.all([
    sourceFor(baselineRef, "app/SourcesShared/Profiles.swift"),
    sourceFor(baselineRef, "app/SourcesShared/CoreBridge.swift"),
    readFile(resolve(repo, "app/SourcesShared/VortXSyncManager.swift"), "utf8"),
    readFile(resolve(repo, "app/SourcesShared/ProfileDiscoveryPreferences.swift"), "utf8"),
    readFile(swiftFixture, "utf8"),
  ]);

  const userProfile = balancedMember(profiles, "struct UserProfile");
  const profileMembers = [
    balancedMember(profiles, "func applyNativeProfiles("),
    balancedMember(profiles, "private func prepareNativeAction("),
    balancedMember(profiles, "func saveNative(_ profile: UserProfile, creating: Bool, admission:"),
    balancedMember(profiles, "func selectNative(_ profile: UserProfile, admission:"),
    balancedMember(profiles, "func saveNative(_ profile: UserProfile, creating: Bool, target:"),
    balancedMember(profiles, "func selectNative(_ profile: UserProfile, target:"),
    balancedMember(profiles, "private func currentPlaybackPrefs("),
    balancedMember(profiles, "private func profileCapturingPlayback("),
    balancedMember(profiles, "private func currentDiscoveryPrefs("),
    balancedMember(profiles, "func nativePreferenceProjectionMatches("),
    balancedMember(profiles, "private func nativePlaybackProjectionRepresents("),
    balancedMember(profiles, "private func nativeDiscoveryProjectionRepresents("),
    balancedMember(profiles, "private static func nativeDiscoveryProjectionIsRepresented("),
    balancedMember(profiles, "private func currentNativeThemeProjection("),
    balancedMember(profiles, "var activeSharesMainAddons: Bool"),
    balancedMember(profiles, "private var ownerAddonRanking: ProfileAddonRanking"),
    balancedMember(profiles, "private func addonPreferences(for profile: UserProfile)"),
    balancedMember(profiles, "private func effectiveAddonRanking(for profile: UserProfile)"),
    balancedMember(profiles, "private func effectiveDisabledAddons(for profile: UserProfile)"),
    balancedMember(profiles, "private func applyAddonPreferences(_ profile: UserProfile)"),
    balancedMember(profiles, "private func applyPlayback(_ profile: UserProfile"),
    balancedMember(profiles, "private func applyDiscovery(_ profile: UserProfile"),
  ];
  const nativeSwitchPreferenceCapture = optionalMember(profiles, "private struct NativeSwitchPreferenceCapture");
  const coreMembers = [
    balancedMember(core, "func captureNativePlaybackTarget()"),
    balancedMember(core, "func nativePlaybackTargetIsCurrent("),
    balancedMember(core, "func captureNativeProfileActionAdmission()"),
    balancedMember(core, "private func currentNativePlaybackBinding()"),
    balancedMember(core, "private func nativePlaybackBinding("),
    balancedMember(core, "private func refreshNativeProfiles(reloadCredentials: Bool = true)"),
    balancedMember(core, "@MainActor\n    func prepareNativeProfileActionTarget("),
    balancedMember(core, "func saveNativeProfile(_ profile: UserProfile"),
    balancedMember(core, "private final class NativeProfilePreferenceAuthority"),
    balancedMember(core, "func switchNativeProfile(_ id: UUID"),
  ];
  const managerMembers = [
    balancedMember(manager, "private func quarantineNativePreferenceStamps("),
    balancedMember(manager, "private static var nativePreferenceProjectionKeys"),
    balancedMember(manager, "nonisolated static func nativePreferenceProjectionWillMount("),
    balancedMember(manager, "private func nativePreferenceStampIsAttributed("),
    replaceJournalRoot(balancedMember(manager, "private func nativePreferenceStore(")),
    balancedMember(manager, "private struct NativePreferenceContext"),
    balancedMember(manager, "private func nativePreferenceContext("),
    balancedMember(manager, "nonisolated private static func makeNativePreferenceContext("),
    balancedMember(manager, "nonisolated private static func nativePreferenceValue("),
    balancedMember(manager, "nonisolated private static func nativePreferenceSnapshot("),
    balancedMember(manager, "func nativePreferenceAdmission("),
    balancedMember(manager, "func normalizedNativePreferenceSubmission("),
    balancedMember(manager, "func nativePreferenceIsLocalRevert("),
    balancedMember(manager, "func prepareNativePreferenceIntents("),
    balancedMember(manager, "func finishNativePreferenceIntents("),
  ];

  const capturePropertyShell = nativeSwitchPreferenceCapture
    ? "    private var nativeSwitchPreferenceCapture: NativeSwitchPreferenceCapture?"
    : "";
  const capturePropertyMarker = "    // NATIVE_SWITCH_PREFERENCE_CAPTURE_PROPERTY_SHELL";
  if (!fixture.includes(capturePropertyMarker)) {
    throw new Error("fixture capture-property marker not found");
  }
  const fixtureWithCaptureShell = fixture.replace(
    capturePropertyMarker,
    capturePropertyShell,
  );
  const combined = [
    "import Foundation",
    "import CryptoKit",
    "",
    userProfile,
    "",
    discovery,
    "",
    fixtureWithCaptureShell,
    "",
    "extension ProfileStore {",
    ...(nativeSwitchPreferenceCapture ? [nativeSwitchPreferenceCapture] : []),
    ...profileMembers,
    "}",
    "",
    "extension CoreBridge {",
    ...coreMembers,
    "}",
    "",
    "extension VortXSyncManager {",
    ...managerMembers,
    "}",
    "",
  ].join("\n");
  const combinedPath = resolve(outDir, "Combined.swift");
  await writeFile(combinedPath, combined);
  const sourcePaths = [
    "app/SourcesShared/Profiles.swift", "app/SourcesShared/CoreBridge.swift", "app/SourcesShared/VortXSyncManager.swift",
    "app/SourcesShared/VortxNativeProfiles.swift", "app/SourcesShared/NativePreferenceIntentStore.swift",
    "app/SourcesShared/ProfileDiscoveryPreferences.swift",
    "app/SourcesShared/VortxNativeCoreFacade.swift", "app/SourcesShared/VortxNativeSession.swift",
    "app/Tests/NativeProfileSwitchAdmissionLiveTests.swift",
  ];
  const sourceHashes = {};
  for (const path of sourcePaths) {
    const selected = (baselineRef && (path === "app/SourcesShared/Profiles.swift" || path === "app/SourcesShared/CoreBridge.swift"))
      ? await sourceFor(baselineRef, path)
      : await readFile(resolve(repo, path));
    sourceHashes[path] = sha256(selected);
  }
  const bodyHashes = {
    "ProfileStore.applyNativeProfiles": sha256(profileMembers[0]),
    "ProfileStore.prepareNativeAction": sha256(profileMembers[1]),
    "ProfileStore.saveNative(admission)": sha256(profileMembers[2]),
    "ProfileStore.selectNative(admission)": sha256(profileMembers[3]),
    "ProfileStore.saveNative(target)": sha256(profileMembers[4]),
    "ProfileStore.selectNative(target)": sha256(profileMembers[5]),
    "ProfileStore.applyPlayback": sha256(profileMembers[20]),
    "ProfileStore.applyDiscovery": sha256(profileMembers[21]),
    "ProfileStore.activeSharesMainAddons": sha256(profileMembers[14]),
    "ProfileStore.effectiveDisabledAddons": sha256(profileMembers[18]),
    "ProfileStore.applyAddonPreferences": sha256(profileMembers[19]),
    "ProfileStore.addonPreferences": sha256(profileMembers[16]),
    "ProfileStore.effectiveAddonRanking": sha256(profileMembers[17]),
    "CoreBridge.captureNativePlaybackTarget": sha256(coreMembers[0]),
    "CoreBridge.nativePlaybackTargetIsCurrent": sha256(coreMembers[1]),
    "CoreBridge.captureNativeProfileActionAdmission": sha256(coreMembers[2]),
    "CoreBridge.currentNativePlaybackBinding": sha256(coreMembers[3]),
    "CoreBridge.nativePlaybackBinding": sha256(coreMembers[4]),
    "CoreBridge.refreshNativeProfiles": sha256(coreMembers[5]),
    "CoreBridge.prepareNativeProfileActionTarget": sha256(coreMembers[6]),
    "CoreBridge.saveNativeProfile": sha256(coreMembers[7]),
    "CoreBridge.switchNativeProfile": sha256(coreMembers[9]),
    "VortXSyncManager.quarantineNativePreferenceStamps": sha256(managerMembers[0]),
    "VortXSyncManager.prepareNativePreferenceIntents": sha256(managerMembers[13]),
    "VortXSyncManager.finishNativePreferenceIntents": sha256(managerMembers[14]),
  };
  if (nativeSwitchPreferenceCapture) {
    bodyHashes["ProfileStore.NativeSwitchPreferenceCapture"] = sha256(nativeSwitchPreferenceCapture);
  }
  const receipt = {
    format: "vortx-native-profile-switch-admission-extraction-v1",
    sourceRef: baselineRef || "working-tree",
    sourceHead: process.env.VORTX_PROFILE_SWITCH_SOURCE_HEAD || "unprovided",
    sdk: {
      path: process.env.VORTX_PROFILE_SWITCH_SDK || "unprovided",
      librarySHA256: process.env.VORTX_PROFILE_SWITCH_LIBRARY_SHA256 || "unprovided",
      headerSHA256: process.env.VORTX_PROFILE_SWITCH_HEADER_SHA256 || "unprovided",
      moduleSHA256: process.env.VORTX_PROFILE_SWITCH_MODULE_SHA256 || "unprovided",
      verifiedByWrapper: process.env.VORTX_PROFILE_SWITCH_SDK_VERIFIED === "1",
    },
    sourceHashes,
    bodyHashes,
    combinedSHA256: sha256(combined),
    boundary: {
      productionBodies: [
        "ProfileStore.applyNativeProfiles", "ProfileStore.prepareNativeAction", "ProfileStore.selectNative",
        "ProfileStore.saveNative", "ProfileStore.applyPlayback", "ProfileStore.applyDiscovery",
        "ProfileStore.activeSharesMainAddons", "ProfileStore.addonPreferences", "ProfileStore.effectiveAddonRanking",
        "CoreBridge.captureNativePlaybackTarget", "CoreBridge.nativePlaybackTargetIsCurrent",
        "CoreBridge.captureNativeProfileActionAdmission", "CoreBridge.currentNativePlaybackBinding",
        "CoreBridge.nativePlaybackBinding", "CoreBridge.refreshNativeProfiles",
        "CoreBridge.prepareNativeProfileActionTarget", "CoreBridge.saveNativeProfile",
        "CoreBridge.switchNativeProfile", "VortXSyncManager.prepareNativePreferenceIntents",
        "VortXSyncManager.finishNativePreferenceIntents", "VortXSyncManager.quarantineNativePreferenceStamps",
        ...(nativeSwitchPreferenceCapture ? ["ProfileStore.NativeSwitchPreferenceCapture"] : []),
      ],
      journalRoot: "NativeProfileSwitchAdmissionEnvironment.journalRoot",
      externalState: "inert defaults, synthetic credential, command-line checkpoint root, no Keychain",
    },
  };
  await writeFile(resolve(outDir, "extraction-receipt.json"), `${JSON.stringify(receipt, null, 2)}\n`);
  return { combinedPath, receipt };
}

async function run() {
  const args = process.argv.slice(2);
  const extractIndex = args.indexOf("--extract");
  const extractOnly = args.includes("--extract-only");
  const baselineIndex = args.indexOf("--baseline-ref");
  const baselineRef = baselineIndex >= 0 ? args[baselineIndex + 1] : undefined;
  if (extractIndex >= 0 || extractOnly) {
    const outDir = resolve(args[extractIndex >= 0 ? extractIndex + 1 : 1] || resolve(repo, "app/build/native-profile-switch-admission"));
    const { combinedPath, receipt } = await extract(outDir, baselineRef);
    console.log(`extracted ${combinedPath}`);
    console.log(`sourceRef=${receipt.sourceRef} combinedSHA256=${receipt.combinedSHA256}`);
    return;
  }
  if (args.length < 2) throw new Error("runtime mode requires <executable> <output-directory>");
  const executable = resolve(args[0]);
  const outDir = resolve(args[1]);
  const receiptPath = resolve(outDir, "extraction-receipt.json");
  const receipt = JSON.parse(await readFile(receiptPath, "utf8"));
  let executableSHA256 = "unavailable";
  try {
    executableSHA256 = sha256(await readFile(executable));
  } catch (error) {
    await writeFile(resolve(outDir, "run-receipt.json"), `${JSON.stringify({
      ...receipt,
      result: "RED",
      executable: { path: executable, sha256: executableSHA256, readable: false },
      exitCode: error?.code ?? "unreadable-executable",
    }, null, 2)}\n`);
    throw new Error(`live harness executable could not be hashed (${error?.code ?? "unknown"})`);
  }
  const executableReceipt = { path: executable, sha256: executableSHA256, readable: true };
  async function retainRuntimeLogs(stdout, stderr) {
    const stdoutPath = resolve(outDir, "run-stdout.log");
    const stderrPath = resolve(outDir, "run-stderr.log");
    await writeFile(stdoutPath, stdout);
    await writeFile(stderrPath, stderr);
    return {
      stdout: { path: stdoutPath, sha256: sha256(stdout), bytes: Buffer.byteLength(stdout) },
      stderr: { path: stderrPath, sha256: sha256(stderr), bytes: Buffer.byteLength(stderr) },
    };
  }
  let stdout = "";
  let stderr = "";
  try {
    ({ stdout, stderr } = await execFileAsync(executable, [outDir], { cwd: repo, maxBuffer: 32 * 1024 * 1024 }));
  } catch (error) {
    stdout = error?.stdout || "";
    stderr = error?.stderr || "";
    if (stdout) process.stdout.write(stdout);
    if (stderr) process.stderr.write(stderr);
    const logs = await retainRuntimeLogs(stdout, stderr);
    await writeFile(resolve(outDir, "run-receipt.json"), `${JSON.stringify({
      ...receipt, result: "RED", executable: executableReceipt, logs, exitCode: error?.code ?? "unknown",
    }, null, 2)}\n`);
    throw new Error(`live harness exited RED (${error?.code ?? "unknown"})`);
  }
  process.stdout.write(stdout);
  if (stderr) process.stderr.write(stderr);
  const logs = await retainRuntimeLogs(stdout, stderr);
  if (!stdout.includes("GREEN native profile switch admission")) {
    await writeFile(resolve(outDir, "run-receipt.json"), `${JSON.stringify({
      ...receipt, result: "RED", executable: executableReceipt, logs, exitCode: 0,
    }, null, 2)}\n`);
    throw new Error("live harness did not emit GREEN receipt");
  }
  await writeFile(resolve(outDir, "run-receipt.json"), `${JSON.stringify({ ...receipt, result: "GREEN", executable: executableReceipt, logs }, null, 2)}\n`);
}

run().catch((error) => { console.error(error?.stack || error); process.exitCode = 1; });
