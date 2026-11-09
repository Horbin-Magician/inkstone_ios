#!/usr/bin/env python3
"""Run Swift mobile <-> actual sibling Rust core against a disposable local DAV server.
No user vault or external server is used. Requires the sibling inkstone checkout.
"""
import base64
import hashlib
import http.server
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading

repo = Path(__file__).resolve().parent.parent
desktop = repo.parent / 'inkstone'
objects = {}
lock = threading.Lock()

class DAV(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, code, data=b'', etag=None):
        self.send_response(code)
        self.send_header('Content-Length', str(len(data)))
        if etag:
            self.send_header('ETag', etag)
        self.end_headers()
        self.wfile.write(data)

    def dispatch(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
        if self.command == 'GET' and self.path.startswith('/image-test/'):
            with lock:
                current = objects.get('/dav/inkstone/objects/' + self.path.removeprefix('/image-test/'))
            try:
                return self.respond(404) if current is None else self.respond(200, current)
            except (BrokenPipeError, ConnectionResetError):
                return  # Expected when the bounded image download cancels.
        expected = 'Basic ' + base64.b64encode(b'interop:test-only').decode()
        if self.headers.get('Authorization') != expected:
            return self.respond(401)
        with lock:
            current = objects.get(self.path)
            tag = '"' + hashlib.sha256(current).hexdigest() + '"' if current is not None else None
            if self.command == 'PROPFIND':
                return self.respond(207, b'<d:multistatus xmlns:d="DAV:"/>')
            if self.command == 'MKCOL':
                return self.respond(201)
            if self.command == 'GET':
                return self.respond(404) if current is None else self.respond(200, current, tag)
            if self.command == 'PUT':
                if self.headers.get('If-None-Match') == '*' and current is not None:
                    return self.respond(412)
                if self.headers.get('If-Match') and self.headers['If-Match'] != tag:
                    return self.respond(412)
                objects[self.path] = body
                return self.respond(201 if current is None else 204)
            return self.respond(405)

    do_GET = do_PUT = do_MKCOL = do_PROPFIND = dispatch

with tempfile.TemporaryDirectory(prefix='inkstone-interop-') as temp:
    project = Path(temp)
    (project / 'src').mkdir()
    (project / 'src/main.rs').write_bytes((repo / 'scripts/interop/desktop.rs').read_bytes())
    (project / 'Cargo.toml').write_text('[package]\nname="inkstone-mobile-interop"\nversion="0.1.0"\nedition="2024"\n[dependencies]\ninkstone-core={path=' + json.dumps(str(desktop / 'crates/inkstone-core')) + '}\n')
    env = os.environ.copy()
    env['CARGO_TARGET_DIR'] = str(desktop / 'target')
    subprocess.run(['cargo', 'build', '--offline', '--manifest-path', str(project / 'Cargo.toml')], cwd=desktop, env=env, check=True)
    server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), DAV)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env['INKSTONE_INTEROP_URL'] = f'http://127.0.0.1:{server.server_port}/dav/'
    env['INKSTONE_INTEROP_DESKTOP'] = str(desktop / 'target/debug/inkstone-mobile-interop')
    try:
        subprocess.run(['bash', '-c', 'source scripts/developer_env.sh; swift test --filter \"desktopHTTPInterop|webDAVFileTransport|remoteImagePreview\"'], cwd=repo, env=env, check=True)
        manifest = json.loads(objects['/dav/inkstone/manifest.json'])
        assert manifest['version'] == 1
        print('PASS: actual Rust desktop core and Swift mobile core exchanged notes, attachments, moves, conflicts and deletions over HTTP WebDAV.')
    finally:
        server.shutdown()
