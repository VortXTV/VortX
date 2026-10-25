import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';

const repo = resolve(fileURLToPath(new URL('..', import.meta.url)));
const path = 'android/app/src/main/kotlin/com/vortx/android/';
const source = readFileSync(join(repo, path, 'ui/profilepicker/ProfilePickerPresentation.kt'), 'utf8');
const fallback = readFileSync(join(repo, path, 'ui/components/ArtworkFallback.kt'), 'utf8');
const phone = readFileSync(join(repo, path, 'ui/screens/WhosWatchingScreen.kt'), 'utf8');
const tv = readFileSync(join(repo, path, 'ui/tv/TvWhosWatchingScreen.kt'), 'utf8');

test('warm public seed is attempted before live catalog await', () => {
    assert.match(source, /suspend fun run\(reducedMotion: Boolean\) = coroutineScope \{\s*seedFromCache\(\)\s*ensureCandidates\(\)/);
    const seed = source.slice(source.indexOf('    private suspend fun seedFromCache()'),
        source.indexOf('    private suspend fun ensureCandidates()'));
    assert.match(seed, /loadCachedArtwork\(url\)/);
    assert.match(seed, /_movie\.value = candidate\.copy\(artworkURLs = listOf\(url\)\)/);
    assert.doesNotMatch(seed, /fetchCandidates\(|loadArtwork\(|unavailableIDs\s*\+=/);
});

test('the first displayed image and both preloads share winning URL and bounded decode geometry', () => {
    assert.match(source, /_movie\.value = candidate\.copy\(artworkURLs = listOf\(winner\)\)/);
    assert.match(source, /urls = current\.artworkURLs,[\s\S]*?maxDecodePx = PICKER_ARTWORK_DECODE_PX,\s*decodeScale = coil3\.size\.Scale\.FIT,/);
    assert.equal((source.match(/\.size\(PICKER_ARTWORK_DECODE_PX, PICKER_ARTWORK_DECODE_PX\)/g) ?? []).length, 2);
    assert.equal((source.match(/\.scale\(coil3\.size\.Scale\.FIT\)/g) ?? []).length, 2);
    assert.equal((source.match(/\.precision\(coil3\.size\.Precision\.INEXACT\)/g) ?? []).length, 2);
    assert.match(fallback, /decodeScale: coil3\.size\.Scale = coil3\.size\.Scale\.FILL/);
    // Crossfade is now an independent optional request setting. The bounded decode branch
    // still uses the caller's scale and INEXACT precision; the no-options path keeps a URL model.
    assert.match(fallback, /val model = if \(maxDecodePx != null \|\| crossfade != null\) \{/);
    assert.match(fallback, /ImageRequest\.Builder\(context\)\.data\(url\)\.apply \{/);
    assert.match(fallback, /maxDecodePx\?\.let \{\s*size\(it\)\.scale\(decodeScale\)\.precision\(coil3\.size\.Precision\.INEXACT\)/);
    assert.match(fallback, /crossfade\?\.let \{ requested -> crossfade\(requested\) \}/);
    assert.match(fallback, /\}\.build\(\)\s*\} else \{\s*url\s*\}\s*AsyncImage\(\s*model = model,/);
    assert.match(fallback, /^    contentScale: ContentScale = ContentScale\.Crop,/m);
    assert.match(fallback, /contentScale = contentScale,/);
    assert.match(source, /private const val PICKER_ARTWORK_DECODE_PX = 1920/);
});

test('cached probe uses app image-cache bytes, never URL/network image input', () => {
    const cached = source.slice(source.indexOf('private suspend fun loadCachedPickerArtwork('),
        source.indexOf('/** Read the Android equivalent'));
    assert.match(cached, /imageLoader\.diskCache\?\.openSnapshot\(url\)/);
    assert.match(cached, /\.data\(it\.data\.toFile\(\)\)/);
    assert.match(cached, /\.memoryCacheKey\(url\)/);
    assert.doesNotMatch(cached, /\.data\(url\)|URL\(|openConnection|fetchPublicFamilyMovies/);
    assert.match(cached, /catch \(cancel: CancellationException\) \{ throw cancel \}/);
});

test('cache ownership is bounded public app cache, not account or preferences', () => {
    assert.match(source, /java\.io\.File\(context\.cacheDir, "profile-picker-public-art-v1\.json"\)/);
    const cache = source.slice(source.indexOf('internal object ProfilePickerPublicArtworkCacheCodec'),
        source.indexOf('/** Local-data probe only'));
    assert.match(cache, /MAX_BYTES = 32 \* 1024/);
    assert.match(cache, /cinemeta-family-public-v1/);
    assert.match(cache, /java\.nio\.file\.StandardCopyOption\.ATOMIC_MOVE/);
    assert.doesNotMatch(cache, /SharedPreferences|ProfileStore|currentSession|currentAccount|libraryItems/);
});

test('phone and Android TV retain the shared lifecycle/PIN-scoped artwork owner', () => {
    for (const surface of [phone, tv]) {
        assert.match(surface, /val artworkVisible = lifecycleActive && pinTarget == null/);
        assert.match(surface, /rememberProfilePickerMovie\(visible = artworkVisible, reducedMotion = reducedMotion\)/);
        assert.match(surface, /ProfilePickerCinematicBackdrop\(movie = movie, reducedMotion = reducedMotion/);
    }
    assert.match(source, /LaunchedEffect\(controller, visible, reducedMotion\) \{\s*if \(visible\) controller\.run\(reducedMotion\)/);
});
