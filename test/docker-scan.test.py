import contextlib
import copy
import importlib.util
import io
import json
import os
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("docker_metadata", Path(__file__).resolve().parents[1] / "scripts/lib/docker.py")
docker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(docker)

ROW = {"port": 4000, "addresses": ["127.0.0.1"], "pid": None, "comm": "", "conns": 3, "tcpRttMs": 2}
CONTAINER = {"State": "running", "Names": ["/gateway"], "Image": "ghcr.io/berriai/litellm:latest",
             "Ports": [{"IP": "127.0.0.1", "PublicPort": 4000, "PrivatePort": 8000, "Type": "tcp"}]}


def enriched(records=None, **changes):
    row = copy.deepcopy(ROW)
    row.update(changes)
    return docker.enrich({"ports": [row]}, records if records is not None else [CONTAINER])["ports"][0]


class MetadataTests(unittest.TestCase):
    def test_published_tcp_and_proxy_facts(self):
        row = enriched(pid=999999, comm="docker-proxy", cpuTicks=33, rssKb=123, argv=["proxy"], start=12)
        self.assertEqual(row["container"], {"name": "gateway", "image": CONTAINER["Image"]})
        for field in ("pid", "start", "cpuTicks", "rssKb"):
            self.assertIsNone(row[field])
        self.assertEqual(row["argv"], [])
        self.assertFalse(row["exclusiveOwner"])
        self.assertEqual((row["conns"], row["tcpRttMs"]), (3, 2))
        self.assertNotIn("container", enriched(pid=999999, comm="ruby"))

    def test_private_udp_malformed_and_stopped(self):
        variants = [None, {}, {**CONTAINER, "State": "exited"}, {**CONTAINER, "Names": [False]},
                    {**CONTAINER, "Image": "bad\nimage"}, {**CONTAINER, "Ports": None}]
        for mapping in ({"PrivatePort": 4000, "Type": "tcp"},
                        {"PublicPort": 4000, "IP": "127.0.0.1", "Type": "udp"},
                        {"PublicPort": True, "IP": "127.0.0.1", "Type": "tcp"},
                        {"PublicPort": 4000, "IP": [], "Type": "tcp"}, None):
            variants.append({**CONTAINER, "Ports": [mapping]})
        for record in variants:
            with self.subTest(record=record):
                self.assertNotIn("container", enriched([record]))
        self.assertEqual(docker.enrich({"ports": []}, [CONTAINER]), {"ports": []})

    def test_addresses_and_ambiguity(self):
        for host, local, expected in [("127.0.0.1", "127.0.0.2", False), ("0.0.0.0", "127.0.0.1", True),
                                      ("::1", "::", True), ("::", "127.0.0.1", False),
                                      ("::ffff:127.0.0.1", "127.0.0.1", True), ("::1", "*", True)]:
            record = copy.deepcopy(CONTAINER)
            record["Ports"][0]["IP"] = host
            self.assertEqual("container" in enriched([record], addresses=[local]), expected)
        self.assertIn("container", enriched([{**CONTAINER, "Ports": CONTAINER["Ports"] * 2}]))
        self.assertNotIn("container", enriched([CONTAINER, CONTAINER]))
        self.assertNotIn("container", enriched([CONTAINER, {**CONTAINER, "Names": ["/other"]}]))

    def run_server(self, body=b"[]", delay=0, status=200):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        path = temp.name + "/docker.sock"
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        server.listen(1)
        self.addCleanup(server.close)
        requests = []

        def respond():
            with server.accept()[0] as client:
                requests.append(client.recv(4096))
                time.sleep(delay)
                try:
                    client.sendall(f"HTTP/1.1 {status} OK\r\nContent-Length: {len(body)}\r\n\r\n".encode() + body)
                except BrokenPipeError:
                    pass

        thread = threading.Thread(target=respond, daemon=True)
        thread.start()
        return path, requests, thread

    def test_local_socket_get_ignores_remote_context(self):
        path, requests, thread = self.run_server(json.dumps([CONTAINER]).encode())
        with patch.object(docker, "SOCKET_PATHS", (path,)), patch.dict(os.environ, {"DOCKER_HOST": "ssh://remote", "DOCKER_CONTEXT": "remote"}):
            self.assertEqual(docker.containers(), [CONTAINER])
        thread.join(1)
        self.assertTrue(requests[0].startswith(b"GET /containers/json HTTP/1.1\r\n"))

    def test_both_local_daemons(self):
        first, _, thread1 = self.run_server(json.dumps([CONTAINER]).encode())
        second_record = {**CONTAINER, "Names": ["/second"]}
        second, _, thread2 = self.run_server(json.dumps([second_record]).encode())
        with patch.object(docker, "SOCKET_PATHS", (first, second)):
            self.assertEqual(docker.containers(), [CONTAINER, second_record])
        thread1.join(1)
        thread2.join(1)

    def test_errors_limits_and_socket_type(self):
        for body, status in [(b"invalid", 200), (b"{}", 200), (b"x" * (docker.MAX_RESPONSE + 1), 200), (b"[]", 403)]:
            path, _, thread = self.run_server(body, status=status)
            with patch.object(docker, "SOCKET_PATHS", (path,)):
                self.assertEqual(docker.containers(), [])
            thread.join(1)
        path, _, thread = self.run_server(b"[]")
        with patch.object(docker, "SOCKET_PATHS", (path,)), patch.object(docker.json, "loads", side_effect=RecursionError):
            self.assertEqual(docker.containers(), [])
        thread.join(1)
        with patch.object(docker, "SOCKET_PATHS", (__file__, "/absent/docker.sock")):
            self.assertEqual(docker.containers(), [])
        with patch.object(docker.os, "stat", side_effect=PermissionError):
            self.assertEqual(docker.containers(), [])

    def test_total_deadline_preserves_socket_scan(self):
        path, _, thread = self.run_server(delay=0.7)
        output = io.StringIO()
        start = time.monotonic()
        with patch.object(docker, "SOCKET_PATHS", (path, path)), patch.object(docker.sys, "stdin", io.StringIO(json.dumps({"ports": [ROW]}))), contextlib.redirect_stdout(output):
            docker.main()
        self.assertLess(time.monotonic() - start, 0.65)
        self.assertEqual(json.loads(output.getvalue()), {"ports": [ROW]})
        thread.join(1)


unittest.main()
