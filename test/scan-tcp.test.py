#!/usr/bin/env python3
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def scan(env=None, probes=None):
    command = ['bash', str(ROOT / 'scripts/scan-ports.sh')]
    if probes:
        command += ['--probe', probes]
    process = subprocess.run(command, env=env, text=True, capture_output=True, timeout=15)
    assert process.returncode == 0 and not process.stderr, process.stderr
    return json.loads(process.stdout)


with tempfile.TemporaryDirectory(prefix='portal-tcp-parser-') as temporary:
    directory = Path(temporary)
    stub = directory / 'ss'
    stub.write_text('''#!/bin/bash
case "$*" in
  '-tlnpH') printf '%s\\n' 'LISTEN 0 10 127.0.0.1:35001 0.0.0.0:* users:(("fixture",pid=999999,fd=4))' 'LISTEN 0 10 [::1]:35002 [::]:* users:(("fixture",pid=999999,fd=5))' ;;
  '-tniHO state established') /usr/bin/cat "$SOCKET_FIXTURE" ;;
  *) exit 1 ;;
esac
''')
    stub.chmod(0o700)
    fixture = directory / 'sockets'
    fixture.write_text('''0 0 127.0.0.1:35001 127.0.0.1:49001 cubic rtt:0.125/0.01
0 0 [::1]:35001 [::1]:49002 cubic rtt:0.375/0.02
0 0 [::ffff:127.0.0.1]:35001 [::ffff:127.0.0.1]:49003 cubic rtt:0/0
0 0 127.0.0.1:35001 127.0.0.1:49004 cubic rcv_rtt:99 minrtt:100
0 0 127.0.0.1:35001 127.0.0.1:49005 cubic rtt:-1/0
0 0 127.0.0.1:35001 127.0.0.1:49006 cubic rtt:NaN/0
0 0 127.0.0.1:35001 127.0.0.1:49007 cubic rtt:1/2junk
0 0 127.0.0.1:35001 127.0.0.1:49008 cubic rtt:9999999999999999999/0
0 0 [::1]:35002 [::1]:49009 cubic
0 0 127.0.0.1:49001 127.0.0.1:35001 cubic rtt:800/0
''')
    env = {**os.environ, 'PATH': str(directory) + ':/usr/bin:/bin', 'SOCKET_FIXTURE': str(fixture)}
    data = {row['port']: row for row in scan(env)['ports']}
    assert data[35001]['conns'] == 8 and data[35001]['tcpRttCount'] == 3
    assert abs(data[35001]['tcpRttMs'] - 1/6) < 1e-12
    assert data[35002]['conns'] == 1 and data[35002]['tcpRttMs'] is None and data[35002]['tcpRttCount'] == 0
    assert data[35001]['exclusiveOwner'] is True
    curl = directory / 'curl'
    curl.write_text('#!/bin/bash\nprintf "200 0.000546"\n')
    curl.chmod(0o700)
    row = next(row for row in scan(env, '35001')['ports'] if row['port'] == 35001)
    assert row['latMs'] == 0.546 and abs(row['tcpRttMs'] - 1/6) < 1e-12
    fixture.write_text('0 0 127.0.0.1:35001 127.0.0.1:49001 rtt:1/0\n' * 16385)
    assert scan(env)['error'] == 'established socket snapshot exceeds row limit'
    fixture.write_text('x' * 4194305)
    assert 'error' in scan(env)
    fixture.write_text('0 0 127.0.0.1:35001 127.0.0.1:49001 ' + 'é' * 2097152)
    assert 'error' in scan({**env, 'LC_ALL': 'C.UTF-8'})
    print('ok fractional mean, null/malformed RTT, IPv4/IPv6 attribution, connection counts and snapshot bounds')

    line = '0 0 127.0.0.1:35001 127.0.0.1:49001 cubic rtt:123456789.12345678/0.045 '
    fixture.write_text((line + 'x' * (254 - len(line)) + '\n') * 16384)
    started = time.monotonic()
    result = scan(env)
    elapsed = time.monotonic() - started
    assert 'error' not in result, result
    row = next(row for row in result['ports'] if row['port'] == 35001)
    assert row['conns'] == row['tcpRttCount'] == 16384
    assert abs(row['tcpRttMs'] - 123456789.12345678) < 0.0001
    assert elapsed < 5, f'near-cap socket aggregation took {elapsed:.3f}s'
    print(f'ok 16,384 sockets / {fixture.stat().st_size} bytes aggregate in {elapsed:.3f}s')

for family, host in [(socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')]:
    with socket.socket(family) as listener:
        listener.bind((host, 0))
        listener.listen(1)
        port = listener.getsockname()[1]
        with socket.socket(family) as client:
            client.connect((host, port))
            peer, _ = listener.accept()
            with peer:
                peer.sendall(b'x')
                assert client.recv(1) == b'x'
                row = next(row for row in scan()['ports'] if row['port'] == port)
                assert row['conns'] == 1 and row['tcpRttCount'] == 1, row
                assert isinstance(row['tcpRttMs'], (int, float)) and row['tcpRttMs'] >= 0
                assert row['latMs'] is None and row['httpCode'] is None
    print('ok real ' + family.name + ' existing connection exposes passive TCP RTT without HTTP probes')
