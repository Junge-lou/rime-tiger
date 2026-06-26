import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';

import {
  createApp,
  createLocalStore,
  listBackups,
  readConfigSnapshot,
  resolveAllowedPath,
} from '../local/local_server.mjs';

test('local store resolves only allowed Rime files and backup paths', () => {
  const root = mkdtempSync(join(tmpdir(), 'rime-editor-store-'));
  try {
    const realRoot = realpathSync(root);
    assert.equal(resolveAllowedPath(root, 'squirrel.custom.yaml'), join(realRoot, 'squirrel.custom.yaml'));
    assert.equal(
      resolveAllowedPath(root, 'Rime皮肤编辑器备份/2026-06-26 保存/manifest.json'),
      join(realRoot, 'Rime皮肤编辑器备份', '2026-06-26 保存', 'manifest.json'),
    );
    assert.throws(() => resolveAllowedPath(root, '../squirrel.custom.yaml'), /不允许访问/);
    assert.throws(() => resolveAllowedPath(root, '/tmp/squirrel.custom.yaml'), /不允许访问/);
    assert.throws(() => resolveAllowedPath(root, 'not-rime.txt'), /不允许访问/);
    assert.throws(() => resolveAllowedPath(root, 'Rime皮肤编辑器备份/../squirrel.custom.yaml'), /不允许访问/);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('local store rejects allowed-looking symlinks that leave the root', () => {
  const root = mkdtempSync(join(tmpdir(), 'rime-editor-store-'));
  const outside = mkdtempSync(join(tmpdir(), 'rime-editor-outside-'));
  try {
    symlinkSync(join(outside, 'squirrel.custom.yaml'), join(root, 'squirrel.custom.yaml'));

    assert.throws(() => resolveAllowedPath(root, 'squirrel.custom.yaml'), /不允许访问/);
  } finally {
    rmSync(root, { recursive: true, force: true });
    rmSync(outside, { recursive: true, force: true });
  }
});

test('local store reads config snapshot and lists readable backups', () => {
  const root = mkdtempSync(join(tmpdir(), 'rime-editor-store-'));
  try {
    writeFileSync(join(root, 'squirrel.custom.yaml'), 'patch:\n  style:\n    color_scheme: luna\n');
    writeFileSync(join(root, 'default.custom.yaml'), 'patch:\n');
    writeFileSync(join(root, 'tiger.schema.yaml'), 'schema:\n  schema_id: tiger\n');
    const backupDir = join(root, 'Rime皮肤编辑器备份', '2026-06-26 15-30-12 保存鼠须管-luna');
    createLocalStore(root).mkdir('Rime皮肤编辑器备份/2026-06-26 15-30-12 保存鼠须管-luna');
    writeFileSync(join(backupDir, 'manifest.json'), JSON.stringify({ operation: 'save', files: ['squirrel.custom.yaml'] }));
    writeFileSync(join(backupDir, 'squirrel.custom.yaml'), 'patch:\n');

    const snapshot = readConfigSnapshot(root);
    assert.equal(snapshot.folderName, 'rime-editor-store-' + root.split('rime-editor-store-')[1]);
    assert.equal(snapshot.fileExists.squirrel, true);
    assert.equal(snapshot.fileExists.weasel, false);
    assert.equal(snapshot.fileExists.default, true);
    assert.equal(snapshot.hasAnySchemaFile, true);
    assert.match(snapshot.rawFiles.squirrel, /color_scheme/);

    const backups = listBackups(root);
    assert.equal(backups.length, 1);
    assert.equal(backups[0].name, '2026-06-26 15-30-12 保存鼠须管-luna');
    assert.deepEqual(backups[0].availableFiles, ['manifest.json', 'squirrel.custom.yaml']);
    assert.equal(backups[0].manifest.operation, 'save');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('local store keeps listing backups when one manifest is malformed', () => {
  const root = mkdtempSync(join(tmpdir(), 'rime-editor-store-'));
  try {
    const store = createLocalStore(root);
    store.mkdir('Rime皮肤编辑器备份/2026-06-26 15-30-12 保存鼠须管-luna');
    store.mkdir('Rime皮肤编辑器备份/2026-06-26 15-31-12 保存小狼毫-luna');
    writeFileSync(
      join(root, 'Rime皮肤编辑器备份', '2026-06-26 15-30-12 保存鼠须管-luna', 'manifest.json'),
      JSON.stringify({ operation: 'save', files: ['squirrel.custom.yaml'] }),
    );
    writeFileSync(
      join(root, 'Rime皮肤编辑器备份', '2026-06-26 15-31-12 保存小狼毫-luna', 'manifest.json'),
      '{broken json',
    );

    const backups = listBackups(root);

    assert.equal(backups.length, 2);
    assert.equal(backups.find((backup) => backup.name.includes('小狼毫')).manifest, null);
    assert.equal(backups.find((backup) => backup.name.includes('鼠须管')).manifest.operation, 'save');
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('local server API requires token and writes only allowed files', async () => {
  const root = mkdtempSync(join(tmpdir(), 'rime-editor-api-'));
  const token = 'test-token';
  const server = createApp({ root, token });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  const baseUrl = `http://127.0.0.1:${server.address().port}`;

  try {
    const denied = await fetch(`${baseUrl}/api/config`);
    assert.equal(denied.status, 403);

    const writeOk = await fetch(`${baseUrl}/api/file`, {
      method: 'PUT',
      headers: { 'content-type': 'application/json', 'x-rime-editor-token': token },
      body: JSON.stringify({ path: 'squirrel.custom.yaml', text: 'patch:\n' }),
    });
    assert.equal(writeOk.status, 200);
    assert.equal(readFileSync(join(root, 'squirrel.custom.yaml'), 'utf8'), 'patch:\n');

    const writeBad = await fetch(`${baseUrl}/api/file`, {
      method: 'PUT',
      headers: { 'content-type': 'application/json', 'x-rime-editor-token': token },
      body: JSON.stringify({ path: '../outside.txt', text: 'bad' }),
    });
    assert.equal(writeBad.status, 400);

    const deleteOk = await fetch(`${baseUrl}/api/file?path=${encodeURIComponent('squirrel.custom.yaml')}`, {
      method: 'DELETE',
      headers: { 'x-rime-editor-token': token },
    });
    assert.equal(deleteOk.status, 200);
    assert.equal(existsSync(join(root, 'squirrel.custom.yaml')), false);

    const store = createLocalStore(root);
    store.write('weasel.custom.yaml', 'patch:\n');
    store.remove('weasel.custom.yaml');
    assert.equal(existsSync(join(root, 'weasel.custom.yaml')), false);
  } finally {
    await new Promise((resolve) => server.close(resolve));
    rmSync(root, { recursive: true, force: true });
  }
});
