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

  return Promise.resolve().then(async () => {
    vm.runInContext(appSource, context, { filename: 'app.js' });
    await context.document.listeners.DOMContentLoaded[0]();
  }).then(() => {
    assert.notEqual(elements.supportStatus.textContent, '正在检测浏览器能力...');
    assert.match(elements.supportStatus.textContent, /加载失败|启动失败/);
    assert.equal(elements.chooseFolderButton.disabled, true);
  });
});

test('startup detects local launcher mode from tokenized localhost URL', () => {
  const elements = createElementMap([
    'supportStatus',
    'chooseFolderButton',
    'folderName',
    'blockedPanel',
    'blockedReason',
    'workspace',
    'squirrelTab',
    'weaselTab',
    'platformHint',
    'skinList',
    'newSkinButton',
    'duplicateSkinButton',
    'deleteSkinButton',
    'previewPlatform',
    'candidatePreview',
    'colorControls',
    'layoutMode',
    'fontFace',
    'fontPoint',
    'fontPointNumber',
    'fontPointValue',
    'cornerRadius',
    'cornerRadiusNumber',
    'cornerRadiusValue',
    'candidateSpacing',
    'candidateSpacingNumber',
    'candidateSpacingValue',
    'shadowSize',
    'shadowSizeNumber',
    'shadowSizeValue',
    'displayName',
    'author',
    'skinId',
    'setActiveButton',
    'saveButton',
    'copyButton',
    'reloadBackupsButton',
    'backupList',
    'messageLog',
  ]);
  addSelectShim(elements.fontFace);
  const fetchCalls = [];
  const context = vm.createContext({
    console: { error() {} },
    fetch(url, options = {}) {
      fetchCalls.push({ url, options });
      if (url === '/api/config') {
        return Promise.resolve(jsonResponse({
          folderName: 'Rime',
          rawFiles: {
            squirrel: 'patch:\n  preset_color_schemes:\n  style:\n',
            weasel: '',
            default: 'patch:\n',
          },
          fileExists: { squirrel: true, weasel: false, default: true },
          hasAnySchemaFile: false,
        }));
      }
      if (url === '/api/backups') return Promise.resolve(jsonResponse({ backups: [] }));
      throw new Error(`unexpected fetch ${url}`);
    },
    document: {
      listeners: {},
      createElement(tagName) {
        return createFakeElement(tagName);
      },
      addEventListener(event, handler) {
        this.listeners[event] ||= [];
        this.listeners[event].push(handler);
      },
      getElementById(id) {
        return elements[id] || null;
      },
    },
    location: new URL('http://127.0.0.1:17890/?token=abc123'),
    navigator: { platform: 'MacIntel', userAgent: 'Chrome' },
    URLSearchParams,
  });
  context.window = context;

  const coreSource = readFileSync(resolve(editorRoot, 'src/core.js'), 'utf8');
  const appSource = readFileSync(resolve(editorRoot, 'src/app.js'), 'utf8');
  vm.runInContext(coreSource, context, { filename: 'core.js' });
  vm.runInContext(appSource, context, { filename: 'app.js' });

  return Promise.resolve(context.document.listeners.DOMContentLoaded[0]()).then(() => {
    assert.equal(elements.supportStatus.textContent, '本地启动器已连接，可直接编辑当前 Rime 配置目录。');
    assert.equal(elements.chooseFolderButton.textContent, '已连接本地启动器');
    assert.equal(elements.chooseFolderButton.disabled, true);
    assert.equal(elements.folderName.textContent, 'Rime');
    assert.equal(elements.workspace.classList.removed.includes('hidden'), true);
    assert.equal(fetchCalls[0].options.headers['x-rime-editor-token'], 'abc123');
  });
});

function createElementMap(ids) {
  const elements = {};
  for (const id of ids) {
    elements[id] = createFakeElement('div');
    elements[id].id = id;
  }
  return elements;
}

function createFakeElement(tagName) {
  return {
    tagName,
    id: '',
    type: '',
    value: '',
    textContent: '',
    innerHTML: '',
    className: '',
    disabled: false,
    style: {},
    options: [],
    children: [],
    classList: {
      added: [],
      removed: [],
      toggled: [],
      add(name) {
        this.added.push(name);
      },
      remove(name) {
        this.removed.push(name);
      },
      toggle(name, active) {
        this.toggled.push([name, active]);
      },
    },
    addEventListener() {},
    append(...items) {
      this.children.push(...items);
      if (this.tagName === 'select') this.options.push(...items);
    },
    prepend(...items) {
      this.children.unshift(...items);
      if (this.tagName === 'select') this.options.unshift(...items);
    },
    replaceChildren(...items) {
      this.children = [...items];
      if (this.tagName === 'select') this.options = [...items];
    },
    querySelector() {
      return createFakeElement('span');
    },
    querySelectorAll() {
      return [];
    },
  };
}

function addSelectShim(element) {
  element.tagName = 'select';
  element.options = [];
}

function jsonResponse(value) {
  return {
    ok: true,
    status: 200,
    json: () => Promise.resolve(value),
  };
}
