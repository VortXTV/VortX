"""Offline regressions for official native archive observations."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

SCRIPTS = Path(__file__).resolve().parents[1]
def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module
archive = load("archive_test", "dependency_archive_adapter.py")
health = load("health_archive_test", "dependency-health.py")
native = load("native_archive_test", "dependency_native_adapter.py")
render = load("render_archive_test", "render-dependency-health.py")
maintained = load("maintained_archive_test", "tests/test_dependency_health.py")

def listing(page, names):
    path = archive.urllib.parse.urlsplit(page).path
    anchors = ''.join('<a href="' + n + '">' + n + '</a>' for n in names)
    group = next(g for g, pages in archive.SOURCES.items() if page in pages)
    heading = '<html><body><h1>Index of ' + path + '</h1>'
    if group == 'freetype':
        return (heading + '<table><tbody>' + anchors + '</tbody></table>'
                '<i><font size="-1">Downloads will redirect to your nearest mirror site.<br>'
                'Files on mirrors may be subject to a replication delay of up to 24 hours.</br>'
                'In case of problems use an official mirror.</font></i>').encode()
    tag = 'pre' if group in ('ffmpeg','gmp') else 'table'
    return (heading + '<'+tag+'>' + anchors + '</'+tag+'></body></html>').encode()

def metadata(group, versions):
    page = archive.SOURCES[group][0]
    return {"versions": sorted(versions), "latest_stable": None, "source": page,
            "archive_urls": {v: [page + group + '-' + v + '.tar.gz'] for v in sorted(versions)}}

def inventory(group="ffmpeg"):
    return {"entries": [{"ecosystem":"native-archive", "name":group,
                         "current":"native-pin-unverified", "kind":"native-archive-upstream",
                         "source":archive.SOURCES[group][0], "repository":"native-monitor/"+group}],
            "coverage_gaps": []}

class ArchiveTests(unittest.TestCase):
    def test_all_sources_parse_distinct_versions_and_required_child(self):
        for group, pages in archive.SOURCES.items():
            with self.subTest(group=group):
                payloads = {}
                for index, page in enumerate(pages):
                    names = [group+'-1.0.tar.gz', group+'-1.0.tar.xz',
                             group+'-1.0.tar.gz.sig', group+'-1.0.tar.gz.md5',
                             group+'-1.0.changelog', group+'-2.0-rc1.tar.gz']
                    if index == 0 and len(pages) > 1:
                        names += [pages[1].rstrip('/').rsplit('/', 1)[1] + '/']
                    if index == 1: names += [group+'-0.9.pre-1.tar.bz2']
                    payloads[page] = listing(page, names)
                value = archive.releases(group, health.stable_key, reader=payloads.__getitem__)
                expected = ['1.0', '2.0-rc1'] + (['0.9.pre-1'] if len(pages)>1 else [])
                self.assertEqual(value['versions'], sorted(expected))
                self.assertEqual(len(value['archive_urls']['1.0']), 2 * len(pages))
                self.assertTrue(archive.valid_metadata(group, value))

    def test_bad_listing_and_unsafe_links_fail_closed(self):
        page = archive.SOURCES['ffmpeg'][0]
        for raw in (b'<h1>Download here</h1>', listing(page, ['https://127.0.0.1/ffmpeg-1.0.tar.gz']),
                    listing(page, ['//evil.invalid/ffmpeg-1.0.tar.gz']),
                    listing(page, ['ffmpeg-1.0.tar.unknown']), b'x'*(archive.MAX_BYTES+1)):
            with self.subTest(raw=raw[:80]), self.assertRaises(archive.ArchiveCoverageError):
                archive.parse_listing('ffmpeg', page, raw)
        child = archive.SOURCES['gmp'][0]
        with self.assertRaises(archive.ArchiveCoverageError):
            archive.parse_listing('gmp', child, listing(child, ['gmp-1.0.tar.gz']))
        with self.assertRaises(archive.ArchiveCoverageError):
            archive.parse_listing('ffmpeg', page, listing(page, ['<ignored>'] * (archive.MAX_LINKS+1)))
        self.assertFalse(archive.archive_url('ffmpeg', 'https://ffmpeg.org@127.0.0.1/releases/ffmpeg-1.0.tar.gz'))
        self.assertFalse(archive.archive_url('ffmpeg', 'https://ffmpeg.org/releases/ffmpeg-1.0.tar.gz?secret=1'))

    def test_unknown_directories_and_pagination(self):
        page = archive.SOURCES['ffmpeg'][0]
        for unknown in ('old/', 'history/', '2025/', '?page=2', 'next.html'):
            with self.subTest(unknown=unknown), self.assertRaises(archive.ArchiveCoverageError):
                archive.parse_listing('ffmpeg', page, listing(page, ['ffmpeg-1.0.tar.gz', unknown]))
        page = archive.SOURCES['freetype'][0]
        self.assertTrue(archive.parse_listing('freetype', page, listing(page,
            ['freetype-old/', 'ttfautohint-old/', 'freetype-2.0.tar.gz'])))

    def test_outer_anchors_never_establish_or_advance_a_cursor(self):
        # Source-shaped complete controls: observed sort/parent navigation lives
        # inside each listing. Savannah's closing footer has no anchor.
        for group, pages in archive.SOURCES.items():
            control = {}
            for index, page in enumerate(pages):
                navigation = ['../']
                if group == 'ffmpeg': navigation = ['/', '?C=N;O=D']
                if group == 'nettle': navigation = ['/gnu/', '?C=N;O=D']
                if group == 'freetype': navigation += ['?C=N&amp;O=A']
                if index == 0 and len(pages) > 1:
                    navigation += [pages[1].rstrip('/').rsplit('/', 1)[1] + '/']
                    if group == 'freetype': navigation += ['ttfautohint-old/']
                control[page] = listing(page, navigation + [group+'-1.0.tar.gz', group+'-1.1.tar.gz'])
            self.assertEqual(archive.releases(group, health.stable_key, reader=control.__getitem__)['versions'], ['1.0', '1.1'])
            for changed_page in pages:
                for location in ('head', 'header', 'footer'):
                    for href in ('?page=2', 'next.html', 'history/'):
                        with self.subTest(group=group, page=changed_page, location=location, href=href):
                            bad = dict(control)
                            anchor = ('<a href="' + href + '">more</a>').encode()
                            raw = bad[changed_page]
                            if location == 'head': raw = raw.replace(b'<html>', b'<html><head>'+anchor+b'</head>', 1)
                            elif location == 'header': raw = raw.replace(b'<body>', b'<body>'+anchor, 1)
                            else:
                                end = b'</pre>' if group in ('ffmpeg', 'gmp') else b'</table>'
                                raw = raw.replace(end, end+anchor, 1)
                            bad[changed_page] = raw
                            def fetch(ecosystem, name):
                                return archive.releases(name, health.stable_key, reader=bad.__getitem__)
                            checkpoints = []
                            with patch.object(health, 'releases', side_effect=fetch):
                                first = health.compare(inventory(group), {'releases': {}}, 1,
                                                       lambda *args: checkpoints.append(args))
                            key = 'native-archive:' + group
                            self.assertNotIn(key, first['releases'])
                            self.assertNotIn(key, first['successful_observations'])
                            self.assertIsNone(checkpoints[0][1])
                            prior = metadata(group, ['1.0'])
                            prior['observed_at'] = 'before'
                            checkpoints = []
                            with patch.object(health, 'releases', side_effect=fetch):
                                later = health.compare(inventory(group), {'releases': {key: prior}}, 1,
                                                       lambda *args: checkpoints.append(args))
                            self.assertEqual(later['releases'][key], prior)
                            self.assertNotIn(key, later['successful_observations'])
                            self.assertIsNone(checkpoints[0][1])
                            self.assertTrue(later['registry_errors'])

    def test_non_anchor_navigation_and_http_headers_fail_closed(self):
        mechanisms = (
            '<link rel="next" href="?page=2">', '<base href="https://example.invalid/">',
            '<meta http-equiv="refresh" content="0;url=?page=2">',
            '<meta name="continuation" content="page2">', '<script src="page2.js"></script>',
            '<form action="?page=2"></form>', '<iframe src="?page=2"></iframe>',
            '<object data="?page=2"></object>', '<embed src="?page=2">',
        )
        for group, pages in archive.SOURCES.items():
            control = {}
            for index, page in enumerate(pages):
                names = [group+'-1.0.tar.gz', group+'-1.1.tar.gz']
                if index == 0 and len(pages)>1:
                    names.append(pages[1].rstrip('/').rsplit('/', 1)[1]+'/')
                if group == 'freetype' and index == 0: names.append('ttfautohint-old/')
                raw = listing(page, names)
                raw = raw.replace(b'<html>', b'<html><head><meta http-equiv="content-type" content="text/html; charset=utf-8"><meta name="viewport" content="width=device-width"></head>', 1)
                control[page] = raw
            self.assertEqual(archive.releases(group, health.stable_key, reader=control.__getitem__)['versions'], ['1.0','1.1'])
            key = 'native-archive:' + group
            prior = {**metadata(group, ['1.0']), 'observed_at':'before'}
            def assert_rejected(fetch):
                for previous in ({'releases': {}}, {'releases': {key: prior}}):
                    checkpoints = []
                    with patch.object(health, 'releases', side_effect=fetch):
                        result = health.compare(inventory(group), previous, 1, lambda *args: checkpoints.append(args))
                    self.assertTrue(result['registry_errors'])
                    self.assertNotIn(key, result['successful_observations'])
                    self.assertIsNone(checkpoints[0][1])
                    if key in previous['releases']: self.assertEqual(result['releases'][key], prior)
                    else: self.assertNotIn(key, result['releases'])
            for mechanism in mechanisms:
                with self.subTest(group=group, mechanism=mechanism):
                    bad = dict(control)
                    bad[pages[0]] = bad[pages[0]].replace(b'</head>', mechanism.encode()+b'</head>', 1)
                    def html_fetch(ecosystem, name):
                        return archive.releases(name, health.stable_key, reader=bad.__getitem__)
                    assert_rejected(html_fetch)
            for extra in ('Link', 'Content-Range'):
                with self.subTest(group=group, header=extra):
                    class Headers:
                        def __init__(self, page): self.page = page
                        def get_all(self, name, default):
                            if name == 'Content-Length': return [str(len(control[self.page]))]
                            if name == extra: return ['<page2>; rel="next"' if extra == 'Link' else 'bytes 0-1/10']
                            return default
                    class Response:
                        status = 200
                        def __init__(self, page): self.page, self.headers = page, Headers(page)
                        def geturl(self): return self.page
                        def read(self, count): return control[self.page]
                        def __enter__(self): return self
                        def __exit__(self, *args): pass
                    class Opener:
                        def open(self, request, timeout): return Response(request.full_url)
                    def header_fetch(ecosystem, name):
                        with patch.object(archive.urllib.request, 'build_opener', return_value=Opener()):
                            return archive.releases(name, health.stable_key)
                    assert_rejected(header_fetch)

    def test_complete_transport_and_truncated_documents_fail(self):
        page = archive.SOURCES['ffmpeg'][0]
        complete = listing(page, ['ffmpeg-1.0.tar.gz', 'ffmpeg-1.1.tar.gz', 'ffmpeg-1.2.tar.gz'])
        partial = complete[:complete.index(b'ffmpeg-1.2.tar.gz')]
        with self.assertRaises(archive.ArchiveCoverageError): archive.parse_listing('ffmpeg', page, partial)
        class Headers:
            def get_all(self, key, default):
                return {'Content-Length':[str(len(complete))]}.get(key, default)
        class Response:
            status = 200
            headers = Headers()
            def geturl(self): return page
            def read(self, count): return partial
            def __enter__(self): return self
            def __exit__(self, *args): pass
        class Opener:
            def open(self, request, timeout): return Response()
        with patch.object(archive.urllib.request, 'build_opener', return_value=Opener()):
            with self.assertRaises(archive.ArchiveCoverageError): archive.read_page(page)
        class CompleteResponse(Response):
            def read(self, count): return complete
        class CompleteOpener:
            def open(self, request, timeout): return CompleteResponse()
        with patch.object(archive.urllib.request, 'build_opener', return_value=CompleteOpener()):
            self.assertEqual(archive.read_page(page), complete)
        class NoFramingHeaders:
            def get_all(self, key, default): return default
        class UnframedResponse(CompleteResponse):
            headers = NoFramingHeaders()
        class UnframedOpener:
            def open(self, request, timeout): return UnframedResponse()
        with patch.object(archive.urllib.request, 'build_opener', return_value=UnframedOpener()):
            with self.assertRaises(archive.ArchiveCoverageError): archive.read_page(page)
        previous = metadata('ffmpeg', ['1.0'])
        previous['observed_at'] = 'before'
        def fetch(ecosystem, name):
            return archive.releases(name, health.stable_key, reader=lambda _: partial)
        checkpoints = []
        with patch.object(health, 'releases', side_effect=fetch):
            result = health.compare(inventory(), {'releases': {'native-archive:ffmpeg': previous}}, 1,
                                    lambda *args: checkpoints.append(args))
        self.assertEqual(result['releases']['native-archive:ffmpeg'], previous)
        self.assertEqual(result['registry_errors'][0]['component'], 'native-archive:ffmpeg')
        self.assertIsNone(checkpoints[0][1])
        self.assertNotIn('native-archive:ffmpeg', result['successful_observations'])
        with patch.object(health, 'releases', side_effect=fetch):
            first = health.compare(inventory(), {'releases': {}}, 1)
        self.assertNotIn('native-archive:ffmpeg', first['releases'])
        self.assertFalse(first['newly_tracked'])

    def test_resume_entry_does_not_replace_fresh_archive_fetch(self):
        fresh = metadata('ffmpeg', ['1.0', '2.0-rc1'])
        stale = metadata('ffmpeg', ['1.0'])
        with patch.object(health, 'releases', return_value=fresh) as fetch:
            result = health.compare(inventory(), {'releases': {}}, 1,
                                    reuse={'native-archive:ffmpeg': stale})
        fetch.assert_called_once_with('native-archive', 'ffmpeg')
        self.assertEqual(result['releases']['native-archive:ffmpeg']['versions'], fresh['versions'])
        self.assertEqual(result['successful_observations']['native-archive:ffmpeg']['kind'], 'fresh')
        capture = json.loads((SCRIPTS / 'tests/fixtures/native-manifest-capture.json').read_text())
        manifest = maintained.NativeDependencyAdapterTests.manifest_from_capture(capture)
        coverage = native.coverage_after_compare(manifest, None, result)
        self.assertEqual(coverage['groups']['ffmpeg']['status'], 'observed')
        npm_entry = {'entries':[{'ecosystem':'npm', 'name':'example', 'current':'1.0.0',
                                 'kind':'resolved', 'source':'fixture', 'repository':'fixture'}],
                     'coverage_gaps':[]}
        npm_metadata = {'versions':['1.0.0'], 'latest_stable':'1.0.0',
                        'source':'https://registry.npmjs.org/example', 'observed_at':'before'}
        with patch.object(health, 'releases') as fetch:
            npm_result = health.compare(npm_entry, {}, 1, reuse={'npm:example': npm_metadata})
        fetch.assert_not_called()
        self.assertEqual(npm_result['successful_observations']['npm:example']['kind'], 'reused')

    def test_archive_cursor_preserves_journal_and_generic_retention(self):
        previous = {'groups': {'ffmpeg': {'status':'unverified', 'last_success': {'old':True},
                                         'journal_refs':['journal-a']},
                               'mpv': {'status':'observed', 'last_success': {'github':True},
                                       'journal_refs':['journal-b']},
                               'media3': {'status':'observed', 'last_success': {'parent':True},
                                          'journal_refs':['journal-c']}}}
        current = {'groups': {'ffmpeg': {'status':'observed', 'last_success': {'new':True},
                                        'observation_source':'official-archive-index-observer'},
                              'mpv': {'status':'observed'}, 'media3': {'status':'observed'}},
                   'coverage_gaps': []}
        merged = native.merge_native_coverage(previous, current)['groups']
        self.assertEqual(merged['ffmpeg']['last_success'], {'new':True})
        self.assertEqual(merged['ffmpeg']['journal_refs'], ['journal-a'])
        self.assertEqual(merged['ffmpeg']['previous_status'], 'unverified')
        self.assertEqual(merged['mpv']['last_success'], {'github':True})
        self.assertEqual(merged['mpv']['journal_refs'], ['journal-b'])
        self.assertEqual(merged['media3']['last_success'], {'parent':True})
        self.assertEqual(merged['media3']['journal_refs'], ['journal-c'])

    def test_redirect_handler_and_page_allowlist(self):
        self.assertIsNone(archive.NoRedirect().redirect_request(None, None, 302, '', {}, 'https://127.0.0.1/'))
        with self.assertRaises(archive.ArchiveCoverageError): archive.read_page('https://127.0.0.1/')
        with self.assertRaises(archive.ArchiveCoverageError): archive.read_page('https://ffmpeg.org/releases/../private/')

    def test_compare_baseline_catchup_contraction_and_failure(self):
        entry = inventory()
        base = metadata('ffmpeg', ['1.0'])
        with patch.object(health, 'releases', return_value=base):
            first = health.compare(entry, {'releases': {}}, 1)
        self.assertEqual(first['new_releases'], [])
        self.assertEqual(first['newly_tracked'][0]['component'], 'native-archive:ffmpeg')
        second_data = metadata('ffmpeg', ['1.0', '1.0.1', '2.0-rc1', '3.0'])
        with patch.object(health, 'releases', return_value=second_data):
            second = health.compare(inventory(), first, 1)
        self.assertEqual(second['new_releases'][0]['new_versions'], ['1.0.1', '2.0-rc1', '3.0'])
        self.assertEqual(second['new_releases'][0]['archive_urls']['2.0-rc1'], second_data['archive_urls']['2.0-rc1'])
        checkpoints = []
        with patch.object(health, 'releases', return_value=base):
            contracted = health.compare(inventory(), second, 1, lambda *args: checkpoints.append(args))
        self.assertEqual(contracted['releases']['native-archive:ffmpeg'], second['releases']['native-archive:ffmpeg'])
        self.assertEqual(contracted['registry_errors'][0]['reason'], 'ArchiveHistoryContraction')
        self.assertIsNone(checkpoints[0][1])
        self.assertNotIn('native-archive:ffmpeg', contracted['successful_observations'])
        with patch.object(health, 'releases', side_effect=OSError('offline')):
            failed = health.compare(inventory(), second, 1)
        self.assertEqual(failed['releases']['native-archive:ffmpeg'], second['releases']['native-archive:ffmpeg'])
        self.assertEqual(failed['entries'][0]['status'], 'unverified')

    def test_native_and_render_provenance(self):
        capture = json.loads((SCRIPTS / 'tests/fixtures/native-manifest-capture.json').read_text())
        manifest = maintained.NativeDependencyAdapterTests.manifest_from_capture(capture)
        augmented = native.augment_inventory({'entries': [], 'coverage_gaps': []}, manifest)
        self.assertEqual({e['name'] for e in augmented['entries'] if e['ecosystem']=='native-archive'}, set(archive.SOURCES))
        data = metadata('ffmpeg', ['1.0', '2.0-rc1'])
        with patch.object(health, 'releases', return_value=data):
            compared = health.compare(inventory(), {'releases': {'native-archive:ffmpeg': {**metadata('ffmpeg',['1.0']), 'observed_at':'old'}}}, 1)
        previous_native = native.build_native_coverage(manifest)
        previous_native['groups']['ffmpeg']['last_success'] = {'old': True}
        previous_native['groups']['ffmpeg']['journal_refs'] = ['journal-prior']
        coverage = native.coverage_after_compare(manifest, previous_native, compared)
        self.assertEqual(coverage['groups']['ffmpeg']['status'], 'observed')
        self.assertEqual(coverage['groups']['gmp']['status'], 'unverified')
        self.assertEqual(coverage['groups']['ffmpeg']['last_success']['archive_urls'], data['archive_urls'])
        self.assertEqual(coverage['groups']['ffmpeg']['journal_refs'], ['journal-prior'])
        compared['native_monitor'] = coverage
        output = render.render(compared)
        self.assertIn('prerelease or nonstandard', output)
        self.assertIn('native-archive:ffmpeg', output)
        self.assertIn('ffmpeg-2.0-rc1.tar.gz', output)
        compared['registry_errors'].append({'component':'native-archive:ffmpeg','reason':'failure'})
        failed = native.coverage_after_compare(manifest, coverage, compared)
        self.assertEqual(failed['groups']['ffmpeg']['status'], 'unverified')
        self.assertEqual(failed['groups']['ffmpeg']['last_success'], coverage['groups']['ffmpeg']['last_success'])
