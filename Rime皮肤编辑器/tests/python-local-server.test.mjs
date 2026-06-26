import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
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
