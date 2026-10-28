#!/usr/bin/env python3
"""Small ABI/stdlib check and CPU workload for disposable Python core trials."""
import asyncio
import ctypes
import hashlib
import json
import sqlite3
import ssl
import statistics
import sys
import time
import zlib

payload = {'status': [{'name': 'extruder', 'temperature': 205.125, 'target': 210,
                       'position': [1.5, 20.25, 0.2], 'ready': True}] * 8}
encoded = json.dumps(payload)
assert json.loads(encoded) == payload
assert zlib.decompress(zlib.compress(encoded.encode())) == encoded.encode()
assert hashlib.sha256(b'reforge').hexdigest() == '0579c4308edb1e42fb85432eaefb2db53994dd59dc4eb6e757290ab55c4ce23e'
with sqlite3.connect(':memory:') as database:
    assert database.execute('select 6 * 7').fetchone() == (42,)
libc = ctypes.CDLL('libc.so.6')
libc.strlen.argtypes = [ctypes.c_char_p]
libc.strlen.restype = ctypes.c_size_t
assert libc.strlen(b'ABI check') == 9
assert ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)


async def check_event_loop():
    await asyncio.sleep(0)
    return 42


assert asyncio.run(check_event_loop()) == 42
samples = []
for _ in range(3):
    start = time.perf_counter()
    for i in range(5000):
        assert json.loads(json.dumps(payload)) == payload
    samples.append(time.perf_counter() - start)
print(json.dumps({'version': sys.version, 'json_roundtrips': 5000,
                  'seconds': samples, 'median_seconds': statistics.median(samples),
                  'openssl': ssl.OPENSSL_VERSION, 'sqlite': sqlite3.sqlite_version,
                  'abi_checks': 'passed'}))
