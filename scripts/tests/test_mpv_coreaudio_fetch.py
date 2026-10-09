#!/usr/bin/env python3
"""Local transport faults for the actual CoreAudio source fetch; no network or audio calls."""
import hashlib
import http.client
import importlib.util
from pathlib import Path
import ssl
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "coreaudio_lifecycle", Path(__file__).resolve().parents[1] / "test-mpv-coreaudio-lifecycle.py")
lifecycle = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lifecycle)
NAME = "ao_coreaudio.c"
BODY = b"local source transport fixture\n"


class Response:
    def __init__(self, status=200, body=BODY, headers=None, fault=None):
        self.status, self.body, self.headers, self.fault = status, body, headers or {}, fault
        self.read_sizes = []

    def getheader(self, name, default=None):
        return self.headers.get(name, default)

    def read(self, size):
        self.read_sizes.append(size)
        if self.fault:
            raise self.fault
        return self.body[:size]


class Connection:
    def __init__(self, response, fault=None):
        self.response, self.fault = response, fault
        self.requests = []
        self.closed = False

    def request(self, *args, **kwargs):
        self.requests.append((args, kwargs))
        if self.fault:
            raise self.fault

    def getresponse(self):
        return self.response

    def close(self):
        self.closed = True


class FetchTests(unittest.TestCase):
    def fetch(self, response, fault=None):
        connection = Connection(response, fault)
        # Only the local fixture digest is substituted. Production constants are checked below;
        # the red/green lifecycle runner separately verifies the three actual upstream bodies.
        with patch.dict(lifecycle.HASHES, {NAME: hashlib.sha256(BODY).hexdigest()}), \
                patch.object(lifecycle.http.client, "HTTPSConnection", return_value=connection) as factory:
            try:
                result = lifecycle.fetch_source(NAME)
            finally:
                self.assertTrue(connection.closed)
                args, kwargs = factory.call_args
                self.assertEqual(args, ("raw.githubusercontent.com",))
                self.assertEqual(kwargs["timeout"], 30)
                self.assertTrue(kwargs["context"].check_hostname)
                self.assertEqual(kwargs["context"].verify_mode, ssl.CERT_REQUIRED)
                self.assertEqual(connection.requests, [(("GET",
                    f"/mpv-player/mpv/{lifecycle.PIN}/audio/out/{NAME}"),
                    {"headers": {"Accept-Encoding": "identity"}})])
            return result

    def test_production_pin_and_three_hashes_unchanged(self):
        self.assertEqual(lifecycle.PIN, "8c67647b50059406c5c0444903597281b81516cf")
        self.assertEqual(lifecycle.HASHES, {
            "ao_coreaudio.c": "ea11a0cf81cd479479faf4534e63f01d4d49c89b9f8b388e5732f4417d2a4b27",
            "ao.c": "5fd091c800dbeb0d6f2c236ce9b1d88852266994c652f0c5317346ddc1d344e3",
            "buffer.c": "e053296cdfe58a07b6bd2aa5554774ff5c54ca57c622a56636fb6fe8f0fed105",
        })

    def test_fixed_https_success_with_and_without_length(self):
        for headers in ({}, {"Content-Length": str(len(BODY))}):
            response = Response(headers=headers)
            self.assertEqual(self.fetch(response), BODY)
            self.assertEqual(response.read_sizes, [lifecycle.MAX_SOURCE_BYTES + 1])

    def test_unallowlisted_names_never_connect(self):
        with patch.object(lifecycle.http.client, "HTTPSConnection") as factory:
            for name in ("file:///etc/passwd", "https://example.com/ao.c", "../ao.c", "other.c"):
                with self.subTest(name=name), self.assertRaises(ValueError):
                    lifecycle.fetch_source(name)
            factory.assert_not_called()

    def test_non_200_including_redirects_never_reads_body(self):
        for status in (204, 301, 302, 307, 404, 500):
            response = Response(status=status)
            with self.subTest(status=status), self.assertRaisesRegex(ValueError, "not 200"):
                self.fetch(response)
            self.assertEqual(response.read_sizes, [])

    def test_content_length_limits_fail_before_body_read(self):
        for length in ("0", "-1", "invalid", str(lifecycle.MAX_SOURCE_BYTES + 1)):
            response = Response(headers={"Content-Length": length})
            with self.subTest(length=length), self.assertRaisesRegex(ValueError, "Content-Length"):
                self.fetch(response)
            self.assertEqual(response.read_sizes, [])

    def test_truncated_declared_body_fails(self):
        with self.assertRaisesRegex(ValueError, "length differs"):
            self.fetch(Response(headers={"Content-Length": str(len(BODY) + 1)}))

    def test_unbounded_headerless_body_is_bounded_and_rejected(self):
        response = Response(body=b"x" * (lifecycle.MAX_SOURCE_BYTES + 2))
        with self.assertRaisesRegex(ValueError, "byte limit"):
            self.fetch(response)
        self.assertEqual(response.read_sizes, [lifecycle.MAX_SOURCE_BYTES + 1])

    def test_empty_and_hash_mismatched_bodies_fail(self):
        for body in (b"", b"wrong source bytes"):
            with self.subTest(body=body), self.assertRaises(ValueError):
                self.fetch(Response(body=body))

    def test_encoded_body_is_rejected_before_read(self):
        response = Response(headers={"Content-Encoding": "gzip"})
        with self.assertRaisesRegex(ValueError, "content encoding"):
            self.fetch(response)
        self.assertEqual(response.read_sizes, [])

    def test_request_and_read_faults_close_connection(self):
        with self.assertRaises(TimeoutError):
            self.fetch(Response(), fault=TimeoutError("fixture timeout"))
        with self.assertRaises(http.client.IncompleteRead):
            self.fetch(Response(fault=http.client.IncompleteRead(b"partial")))


if __name__ == "__main__":
    unittest.main()
