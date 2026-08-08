const assert = require('assert');
const fs = require('fs');
const path = require('path');

const root = path.resolve(__dirname, '..');
const launcher = fs.readFileSync(path.join(root, 'Rime皮肤编辑器/启动.bat'), 'utf8');
const localServerBytes = fs.readFileSync(path.join(root, 'Rime皮肤编辑器/local/local_server.ps1'));
const localServer = localServerBytes.toString('utf8');

function test(name, fn) {
  try {
    fn();
    console.log(`ok - ${name}`);
  } catch (error) {
    console.error(`not ok - ${name}`);
    throw error;
  }
}

test('windows launcher does not hardcode Chinese editor directory in command text', () => {
  assert.ok(!launcher.includes('Rime皮肤编辑器\\local\\local_server.ps1'), launcher);
});

test('launcher is self-contained and does not depend on another bat file', () => {
  assert.ok(launcher.includes('set "EDITOR_DIR=%~dp0"'), launcher);
  assert.ok(!launcher.includes('start_editor.bat'), launcher);
  assert.ok(!launcher.match(/call\s+"/i), launcher);
});

test('launcher resolves PowerShell server path from its own directory', () => {
  assert.ok(launcher.includes('set "SERVER=%EDITOR_DIR%local\\local_server.ps1"'), launcher);
  assert.ok(launcher.includes('-File "%SERVER%"'), launcher);
  assert.ok(launcher.includes('-Root "%RIME_ROOT%"'), launcher);
});

test('launcher declares utf8 code page before running powershell', () => {
  assert.ok(launcher.includes('chcp 65001 >nul'), launcher);
});

test('local PowerShell server source is ascii so Windows PowerShell codepage cannot corrupt literals', () => {
  for (const byte of localServerBytes) {
    assert.ok(byte <= 0x7f, `non-ascii byte: ${byte}`);
  }
});

test('local PowerShell server declares utf8 runtime encoding', () => {
  assert.ok(localServer.includes('$OutputEncoding'), localServer);
  assert.ok(localServer.includes('[Console]::OutputEncoding'), localServer);
  assert.ok(localServer.includes('UTF8Encoding'), localServer);
});

test('local PowerShell server avoids PowerShell 7 only random token APIs', () => {
  assert.ok(!localServer.includes('RandomNumberGenerator]::Fill'), localServer);
  assert.ok(localServer.includes('RandomNumberGenerator]::Create()'), localServer);
  assert.ok(localServer.includes('.GetBytes($TokenBytes)'), localServer);
});
