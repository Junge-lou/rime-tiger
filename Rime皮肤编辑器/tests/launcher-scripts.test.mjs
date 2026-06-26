import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const editorRoot = resolve(import.meta.dirname, '..');

test('PowerShell launcher keeps single path segments as arrays and binds localhost', () => {
  const script = readFileSync(resolve(editorRoot, 'local/local_server.ps1'), 'utf8');

  assert.match(script, /\$Parts = @\(\$RequestedPath -replace/);
  assert.match(script, /http:\/\/localhost:\$CandidatePort\//);
  assert.match(script, /http:\/\/localhost:\$ActualPort\/\?token=\$Token/);
});

test('macOS launcher verifies python can run before selecting it', () => {
  const script = readFileSync(resolve(editorRoot, '启动.command'), 'utf8');

  assert.match(script, /\/usr\/bin\/python3 -c 'import sys; sys\.exit\(0\)'/);
  assert.match(script, /python3 -c 'import sys; sys\.exit\(0\)'/);
});
