#!/usr/bin/env node
// Extracts exact pure production/model/test decisions. Root runs it, never an app/SDK build.
import assert from 'node:assert/strict';
import { readFile, writeFile, realpath } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { dirname, resolve, sep } from 'node:path';
import { fileURLToPath } from 'node:url';

const repo = resolve(dirname(fileURLToPath(import.meta.url)), '../..');
const output = process.argv[2];
assert(output, 'exclusive output path required');
const destination = resolve(output);
const allowed = await realpath(resolve(repo, 'android/app/build'));
const parent = await realpath(dirname(destination));
assert(parent.startsWith(allowed + sep), 'fresh private build subdirectory required');
const prefix = 'android/app/src/';
const inputs = [
  'main/kotlin/com/vortx/android/model/Media.kt',
  'main/kotlin/com/vortx/android/sources/SourceQuickFilters.kt',
  'main/kotlin/com/vortx/android/ui/components/SourceQuickFilterControls.kt',
  'main/kotlin/com/vortx/android/ui/viewmodel/DetailViewModel.kt',
  'main/kotlin/com/vortx/android/ui/screens/DetailScreen.kt',
  'main/kotlin/com/vortx/android/ui/tv/TvSourceList.kt',
  'main/kotlin/com/vortx/android/ui/tv/TvDetailScreen.kt',
  'main/kotlin/com/vortx/android/engine/EngineState.kt',
  'main/kotlin/com/vortx/android/profile/LastStreamStore.kt',
  'main/kotlin/com/vortx/android/communityjs/CommunityJsProviderSource.kt',
  'main/kotlin/com/vortx/android/torbox/TorBoxSearchSource.kt',
  'main/kotlin/com/vortx/android/singularity/SourceIndexClient.kt',
  'main/kotlin/com/vortx/android/engine/StreamRanking.kt',
  'main/kotlin/com/vortx/android/engine/SourceListModel.kt',
  'main/kotlin/com/vortx/android/debrid/DebridKeys.kt',
  'main/kotlin/com/vortx/android/integrations/NativeProviderAccess.kt',
  'main/kotlin/com/vortx/android/ui/VortXApp.kt',
  'main/kotlin/com/vortx/android/ui/tv/TvApp.kt',
  'test/kotlin/com/vortx/android/sources/SourceQuickFilterPolicyCases.kt',
  'test/kotlin/com/vortx/android/sources/SourceQuickFilterCallerContractTest.kt',
].map(path => prefix + path);
const texts = new Map();
for (const path of inputs) texts.set(path, await readFile(resolve(repo, path), 'utf8'));
const read = path => assert(texts.has(prefix + path)) || texts.get(prefix + path);
const media = read('main/kotlin/com/vortx/android/model/Media.kt');
const from = media.indexOf('data class StreamSource(');
const to = media.indexOf('/// A resolved, directly-playable handle', from);
assert(from >= 0 && to > from && media.slice(from, to).includes('data class StreamGroup('), 'actual full stream models required');
const models = media.slice(from, to);
function body(text) {
  return text.replace(/^package [^\n]+\n/m, '').replace(/^import [^\n]+\n/gm, '');
}
const policy = body(read('main/kotlin/com/vortx/android/sources/SourceQuickFilters.kt'));
const cases = body(read('test/kotlin/com/vortx/android/sources/SourceQuickFilterPolicyCases.kt'));
const contractSource = read('test/kotlin/com/vortx/android/sources/SourceQuickFilterCallerContractTest.kt');
const methods = [...contractSource.matchAll(/@Test fun `([^`]+)`\(\)/g)].map(match => match[1]);
assert(methods.length === 7, 'review all caller-contract enrollment changes');
const contracts = body(contractSource).replace(/@Test /g, '');
const generated = `import java.io.File
import java.security.MessageDigest
import java.util.Locale
fun assertTrue(value: Boolean) { check(value) }
fun assertTrue(message: String, value: Boolean) { check(value) { message } }
fun assertFalse(value: Boolean) { check(!value) }
fun assertFalse(message: String, value: Boolean) { check(!value) { message } }
fun assertEquals(expected: Any?, actual: Any?) { check(expected == actual) { "values differ" } }
${models}
${policy}
${cases}
${contracts}
fun main() {
    check(sourceQuickFilterPolicyCases() == 17)
    println("PASS: 17 actual-source model/policy case groups")
    val contracts = SourceQuickFilterCallerContractTest()
${methods.map(name => `    contracts.\`${name}\`()` ).join('\n')}
    println("PASS: 7 actual caller/source contract groups")
}
`;
await writeFile(destination, generated, { flag: 'wx', mode: 0o600 });
const sha = text => createHash('sha256').update(text).digest('hex');
const snapshot = { schema: 1, inputs: Object.fromEntries([...texts].map(([path, text]) => [path, sha(text)])), generated_sha256: sha(generated) };
await writeFile(resolve(parent, 'source-before.json'), JSON.stringify(snapshot, null, 2) + '\n', { flag: 'wx', mode: 0o600 });
console.log(JSON.stringify({ source_count: texts.size, models: sha(models), policy: sha(policy), cases: sha(cases), contracts: sha(contracts), generated: sha(generated) }));
