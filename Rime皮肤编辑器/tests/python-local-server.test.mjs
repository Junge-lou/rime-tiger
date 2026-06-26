import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

const testDir = dirname(fileURLToPath(import.meta.url));
const editorRoot = resolve(testDir, '..');

test('python local server exposes token-protected config and file APIs', async () => {
  const root = mkdtempSync(join(tmpdir(), 'rime-editor-python-'));
  writeFileSync(join(root, 'squirrel.custom.yaml'), 'patch:\n');
  let server;
  try {
    server = spawn('python3', [
      resolve(editorRoot, 'local/local_server.py'),
      '--root',
      root,
      '--no-open',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
    const url = await waitForServerUrl(server);
    const token = new URL(url).searchParams.get('token');
    const baseUrl = `${new URL(url).origin}`;

    const denied = await fetch(`${baseUrl}/api/config`);
    assert.equal(denied.status, 403);

    const config = await fetch(`${baseUrl}/api/config`, {
      headers: { 'x-rime-editor-token': token },
    });
    assert.equal(config.status, 200);
    const snapshot = await config.json();
    assert.equal(snapshot.fileExists.squirrel, true);

    const writeOk = await fetch(`${baseUrl}/api/file`, {
      method: 'PUT',
      headers: { 'content-type': 'application/json', 'x-rime-editor-token': token },
      body: JSON.stringify({ path: 'weasel.custom.yaml', text: 'patch:\n' }),
    });
    assert.equal(writeOk.status, 200);
    assert.equal(readFileSync(join(root, 'weasel.custom.yaml'), 'utf8'), 'patch:\n');

    const writeBad = await fetch(`${baseUrl}/api/file`, {
      method: 'PUT',
      headers: { 'content-type': 'application/json', 'x-rime-editor-token': token },
      body: JSON.stringify({ path: '../outside.txt', text: 'bad' }),
    });
    assert.equal(writeBad.status, 400);
    assert.equal(existsSync(join(root, '..', 'outside.txt')), false);
  } finally {
    if (server) server.kill();
    rmSync(root, { recursive: true, force: true });
  }
});

test('python local server keeps listing backups when one manifest is malformed', async () => {
  const root = mkdtempSync(join(tmpdir(), 'rime-editor-python-'));
  const valid = join(root, 'Rime皮肤编辑器备份', '2026-06-26 15-30-12 保存鼠须管-luna');
  const broken = join(root, 'Rime皮肤编辑器备份', '2026-06-26 15-31-12 保存小狼毫-luna');
  mkdirSync(valid, { recursive: true });
  mkdirSync(broken, { recursive: true });
  writeFileSync(join(valid, 'manifest.json'), JSON.stringify({ operation: 'save' }));
  writeFileSync(join(broken, 'manifest.json'), '{broken json');
  let server;
  try {
    server = spawn('python3', [
      resolve(editorRoot, 'local/local_server.py'),
      '--root',
      root,
      '--no-open',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
    const url = await waitForServerUrl(server);
    const token = new URL(url).searchParams.get('token');
    const response = await fetch(`${new URL(url).origin}/api/backups`, {
      headers: { 'x-rime-editor-token': token },
    });
    const payload = await response.json();

    assert.equal(response.status, 200);
    assert.equal(payload.backups.length, 2);
    assert.equal(payload.backups.find((backup) => backup.name.includes('小狼毫')).manifest, null);
    assert.equal(payload.backups.find((backup) => backup.name.includes('鼠须管')).manifest.operation, 'save');
  } finally {
    if (server) server.kill();
    rmSync(root, { recursive: true, force: true });
  }
});

test('python local server rejects allowed-looking symlinks that leave the root', async () => {
  const root = mkdtempSync(join(tmpdir(), 'rime-editor-python-'));
  const outside = mkdtempSync(join(tmpdir(), 'rime-editor-python-outside-'));
  symlinkSync(join(outside, 'squirrel.custom.yaml'), join(root, 'squirrel.custom.yaml'));
  let server;
  try {
    server = spawn('python3', [
      resolve(editorRoot, 'local/local_server.py'),
      '--root',
      root,
      '--no-open',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
    const url = await waitForServerUrl(server);
    const token = new URL(url).searchParams.get('token');
    const response = await fetch(`${new URL(url).origin}/api/file?path=squirrel.custom.yaml`, {
      headers: { 'x-rime-editor-token': token },
    });

    assert.equal(response.status, 400);
  } finally {
    if (server) server.kill();
    rmSync(root, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  }
});

function waitForServerUrl(server) {
  return new Promise((resolveUrl, reject) => {
    let output = '';
    const timer = setTimeout(() => reject(new Error(`server did not start: ${output}`)), 5000);
    server.stdout.on('data', (chunk) => {
      output += chunk.toString('utf8');
      const match = output.match(/http:\/\/127\.0\.0\.1:\d+\/\?token=[a-f0-9]+/);
      if (match) {
        clearTimeout(timer);
        resolveUrl(match[0]);
      }
    });
    server.stderr.on('data', (chunk) => {
      output += chunk.toString('utf8');
    });
    server.on('exit', (code) => {
      reject(new Error(`server exited ${code}: ${output}`));
    });
  });
}
