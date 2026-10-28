#!/usr/bin/env python3
"""Smoke-test an installed macOS container tracing app without starting a capture."""
import http.client
import socket
import struct
import subprocess

APP = 'Profile'
path = subprocess.check_output(
    ['launchctl', 'getenv', 'OUTERSHELL_SOCKET_org.outershell.' + APP], text=True
).strip()
assert path, 'Install the user app first with ./app deploy --local'


def request(target):
    connection = http.client.HTTPConnection('localhost', timeout=30)
    connection.sock = socket.socket(socket.AF_UNIX)
    connection.sock.settimeout(30)
    connection.sock.connect(path)
    connection.request('GET', target)
    response = connection.getresponse()
    body = response.read()
    connection.close()
    return response.status, body


def u32(body, offset):
    return struct.unpack_from('<I', body, offset)[0]


def string(body, offset):
    start, size = struct.unpack_from('<II', body, offset)
    assert start + size <= len(body)
    return body[start:start + size].decode()


for resource in ['/', '/favicon.ico']:
    status, body = request(resource)
    assert status == 200 and body, (resource, status)

if APP == 'Profile':
    status, body = request('/api/capabilities')
    assert status == 200 and body == b'\x01\0\0\0'
    status, body = request('/api/processes?containers=1')
    assert status == 200 and body[:4] == b'PRFL'
    for index in range(u32(body, 16)):
        identity = string(body, 32 + index * 56 + 32)
        assert len(identity) == 64 and set(identity) <= set('0123456789abcdef')
    for endpoint in ['/api/profile?pid=1', '/api/profile/start?pid=1']:
        assert request(endpoint)[0] == 403, endpoint
else:
    status, body = request('/api/containers')
    assert status == 200 and body[:4] == b'CTXT'
    for index in range(u32(body, 12)):
        assert string(body, 16 + index * 16) != 'host'
    status, body = request('/api/events?count=1&filterCount=1&f0column=container&f0op=equals&f0value=host')
    assert status == 200 and struct.unpack_from('<Q', body, 8)[0] == 0
print('PASS', APP, 'container-only API, host exclusion, HTML, and favicon')
