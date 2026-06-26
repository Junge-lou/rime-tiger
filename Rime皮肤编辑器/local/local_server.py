#!/usr/bin/env python3
import argparse
import json
import mimetypes
import os
import secrets
import subprocess
import sys
import urllib.parse
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

BACKUP_ROOT = 'Rime皮肤编辑器备份'
FRONTEND_FILES = {'squirrel.custom.yaml', 'weasel.custom.yaml', 'default.custom.yaml'}
STATIC_ROOT = Path(__file__).resolve().parents[1]


def resolve_allowed_path(root, requested_path):
    raw = str(requested_path or '')
    if not raw or raw.startswith('/') or raw.startswith('\\') or '\0' in raw:
        raise ValueError('不允许访问这个路径。')
    parts = [part for part in raw.replace('\\', '/').split('/') if part]
    if '..' in parts:
        raise ValueError('不允许访问这个路径。')

    is_frontend_file = len(parts) == 1 and parts[0] in FRONTEND_FILES
    is_schema_file = len(parts) == 1 and parts[0].endswith('.schema.yaml')
    is_backup_file = len(parts) >= 2 and parts[0] == BACKUP_ROOT
    if not is_frontend_file and not is_schema_file and not is_backup_file:
        raise ValueError('不允许访问这个路径。')

    root_path = Path(root).resolve()
    target = (root_path / Path(*parts)).resolve()
    try:
        target.relative_to(root_path)
    except ValueError as exc:
        raise ValueError('不允许访问这个路径。') from exc
    return target


def read_config_snapshot(root):
    root_path = Path(root).resolve()
    raw_files = {}
    file_exists = {}
    for key, filename in {
        'squirrel': 'squirrel.custom.yaml',
        'weasel': 'weasel.custom.yaml',
        'default': 'default.custom.yaml',
    }.items():
        file_path = resolve_allowed_path(root_path, filename)
        exists = file_path.exists()
        file_exists[key] = exists
        raw_files[key] = file_path.read_text(encoding='utf-8') if exists else ''
    return {
        'folderName': root_path.name or str(root_path),
        'rawFiles': raw_files,
        'fileExists': file_exists,
        'hasAnySchemaFile': any(path.is_file() and path.name.endswith('.schema.yaml') for path in root_path.iterdir()),
    }


def list_backups(root):
    root_path = Path(root).resolve()
    backup_root = root_path / BACKUP_ROOT
    if not backup_root.exists():
        return []
    backups = []
    for entry in backup_root.iterdir():
        if not entry.is_dir():
            continue
        files = sorted(path.name for path in entry.iterdir() if path.is_file())
        manifest_path = entry / 'manifest.json'
        manifest = read_manifest(manifest_path)
        backups.append({'name': entry.name, 'manifest': manifest, 'availableFiles': files})
    backups.sort(key=lambda item: item['name'], reverse=True)
    return backups


def read_manifest(manifest_path):
    if not manifest_path.exists():
        return None
    try:
        return json.loads(manifest_path.read_text(encoding='utf-8'))
    except json.JSONDecodeError:
        return None


class RimeEditorHandler(BaseHTTPRequestHandler):
    root = None
    token = ''
    static_root = STATIC_ROOT

    def do_GET(self):
        self.handle_request()

    def do_PUT(self):
        self.handle_request()

    def do_POST(self):
        self.handle_request()

    def do_DELETE(self):
        self.handle_request()

    def log_message(self, format, *args):
        return

    def handle_request(self):
        try:
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path.startswith('/api/'):
                if self.headers.get('x-rime-editor-token') != self.token:
                    self.send_json(403, {'error': '访问令牌无效。'})
                    return
                self.handle_api(parsed)
                return
            self.serve_static(parsed.path)
        except Exception as exc:
            self.send_json(400, {'error': str(exc) or '请求失败。'})

    def handle_api(self, parsed):
        query = urllib.parse.parse_qs(parsed.query)
        if self.command == 'GET' and parsed.path == '/api/config':
            self.send_json(200, read_config_snapshot(self.root))
            return
        if self.command == 'GET' and parsed.path == '/api/backups':
            self.send_json(200, {'backups': list_backups(self.root)})
            return
        if self.command == 'GET' and parsed.path == '/api/file':
            path = query.get('path', [''])[0]
            target = resolve_allowed_path(self.root, path)
            if not target.exists():
                self.send_json(404, {'error': '文件不存在。'})
                return
            self.send_json(200, {'exists': True, 'text': target.read_text(encoding='utf-8')})
            return
        if self.command == 'PUT' and parsed.path == '/api/file':
            body = self.read_json_body()
            target = resolve_allowed_path(self.root, body.get('path', ''))
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(str(body.get('text', '')), encoding='utf-8')
            self.send_json(200, {'ok': True})
            return
        if self.command == 'DELETE' and parsed.path == '/api/file':
            path = query.get('path', [''])[0]
            target = resolve_allowed_path(self.root, path)
            if target.exists():
                target.unlink()
            self.send_json(200, {'ok': True})
            return
        if self.command == 'POST' and parsed.path == '/api/mkdir':
            body = self.read_json_body()
            target = resolve_allowed_path(self.root, f"{body.get('path', '')}/manifest.json")
            target.parent.mkdir(parents=True, exist_ok=True)
            self.send_json(200, {'ok': True})
            return
        self.send_json(404, {'error': '接口不存在。'})

    def serve_static(self, pathname):
        requested = urllib.parse.unquote(pathname)
        if requested == '/':
            requested = '/index.html'
        relative = requested.lstrip('/')
        target = (self.static_root / relative).resolve()
        try:
            target.relative_to(self.static_root)
        except ValueError:
            self.send_response(404)
            self.end_headers()
            return
        if not target.is_file():
            self.send_response(404)
            self.end_headers()
            return
        content_type = mimetypes.guess_type(str(target))[0] or 'application/octet-stream'
        if content_type.startswith('text/') or target.suffix in {'.js', '.json'}:
            content_type += '; charset=utf-8'
        self.send_response(200)
        self.send_header('content-type', content_type)
        self.send_header('cache-control', 'no-store')
        self.end_headers()
        with target.open('rb') as file:
            self.wfile.write(file.read())

    def read_json_body(self):
        length = int(self.headers.get('content-length') or 0)
        if length > 2 * 1024 * 1024:
            raise ValueError('请求内容过大。')
        if not length:
            return {}
        return json.loads(self.rfile.read(length).decode('utf-8'))

    def send_json(self, status, value):
        body = json.dumps(value, ensure_ascii=False).encode('utf-8')
        self.send_response(status)
        self.send_header('content-type', 'application/json; charset=utf-8')
        self.send_header('cache-control', 'no-store')
        self.send_header('content-length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def open_url(url):
    try:
        if sys.platform == 'darwin':
            subprocess.Popen(['open', url])
        elif os.name == 'nt':
            os.startfile(url)  # noqa: S606
        else:
            webbrowser.open(url)
    except Exception:
        webbrowser.open(url)


def main():
    parser = argparse.ArgumentParser(description='Rime 皮肤编辑器本地启动器')
    parser.add_argument('--root', default=str(STATIC_ROOT.parent))
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--no-open', action='store_true')
    args = parser.parse_args()

    root = Path(args.root).resolve()
    token = secrets.token_hex(18)
    handler = type('ConfiguredRimeEditorHandler', (RimeEditorHandler,), {
        'root': root,
        'token': token,
        'static_root': STATIC_ROOT,
    })
    server = ThreadingHTTPServer(('127.0.0.1', args.port), handler)
    port = server.server_address[1]
    url = f'http://127.0.0.1:{port}/?token={token}'
    print(f'Rime 皮肤编辑器已启动：{url}', flush=True)
    print(f'配置目录：{root}', flush=True)
    print('关闭这个窗口即可停止本地服务。', flush=True)
    if not args.no_open:
        open_url(url)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\n已停止本地服务。', flush=True)
    finally:
        server.server_close()


if __name__ == '__main__':
    main()
