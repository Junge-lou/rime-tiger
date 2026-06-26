import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const testDir = dirname(fileURLToPath(import.meta.url));
const editorRoot = resolve(testDir, '..');

test('browser classic scripts load core before app without global name collisions', () => {
  const context = vm.createContext({
    document: {
      listeners: {},
      addEventListener(event, handler) {
        this.listeners[event] ||= [];
        this.listeners[event].push(handler);
      },
    },
    navigator: { platform: 'MacIntel', userAgent: 'Chrome' },
  });
  context.window = context;

  const coreSource = readFileSync(resolve(editorRoot, 'src/core.js'), 'utf8');
  const appSource = readFileSync(resolve(editorRoot, 'src/app.js'), 'utf8');

  vm.runInContext(coreSource, context, { filename: 'core.js' });

  assert.doesNotThrow(() => {
    vm.runInContext(appSource, context, { filename: 'app.js' });
  });
  assert.equal(typeof context.RimeSkinCore.detectBrowserCapabilities, 'function');
  assert.equal(context.document.listeners.DOMContentLoaded.length, 1);
});

test('startup reports a visible error instead of leaving browser detection pending', () => {
  const elements = createElementMap([
    'supportStatus',
    'blockedPanel',
    'blockedReason',
    'chooseFolderButton',
  ]);
  const context = vm.createContext({
    console: { error() {} },
    document: {
      listeners: {},
      addEventListener(event, handler) {
        this.listeners[event] ||= [];
        this.listeners[event].push(handler);
      },
      getElementById(id) {
        return elements[id] || null;
      },
    },
    navigator: { platform: 'MacIntel', userAgent: 'Chrome' },
  });
  context.window = context;

  const appSource = readFileSync(resolve(editorRoot, 'src/app.js'), 'utf8');

  assert.doesNotThrow(() => {
    vm.runInContext(appSource, context, { filename: 'app.js' });
    context.document.listeners.DOMContentLoaded[0]();
  });
  assert.notEqual(elements.supportStatus.textContent, '正在检测浏览器能力...');
  assert.match(elements.supportStatus.textContent, /加载失败|启动失败/);
  assert.equal(elements.chooseFolderButton.disabled, true);
});

function createElementMap(ids) {
  const elements = {};
  for (const id of ids) {
    elements[id] = {
      id,
      textContent: '',
      disabled: false,
      classList: {
        removed: [],
        add() {},
        remove(name) {
          this.removed.push(name);
        },
      },
    };
  }
  return elements;
}
