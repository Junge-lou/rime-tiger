const assert = require('assert');
const {
  applyAlpha,
  markerBehavior,
  parsePreviewCandidateLine,
  previewCandidateItems,
  resolvePreviewComment,
} = require('../Rime皮肤编辑器/src/preview-model.js');

function test(name, fn) {
  try {
    fn();
    console.log(`ok - ${name}`);
  } catch (error) {
    console.error(`not ok - ${name}`);
    throw error;
  }
}

const visibleMark = { r: 48, g: 48, b: 48, a: 255 };
const transparentMark = { r: 48, g: 48, b: 48, a: 0 };

test('weasel empty mark text and visible hilited mark uses win11 marker', () => {
  assert.deepStrictEqual(
    markerBehavior('weasel', { markText: '' }, { hilitedMark: visibleMark }, true),
    { type: 'win11', hasSlot: true, visible: true, text: '' },
  );
});

test('weasel non-empty mark text uses text marker', () => {
  assert.deepStrictEqual(
    markerBehavior('weasel', { markText: '▌' }, { hilitedMark: visibleMark }, true),
    { type: 'text', hasSlot: true, visible: true, text: '▌' },
  );
});

test('weasel transparent hilited mark suppresses marker', () => {
  assert.deepStrictEqual(
    markerBehavior('weasel', { markText: '' }, { hilitedMark: transparentMark }, true),
    { type: 'none', hasSlot: false, visible: false, text: '' },
  );
});

test('squirrel ignores weasel marker settings', () => {
  assert.deepStrictEqual(
    markerBehavior('squirrel', { markText: '▌' }, { hilitedMark: visibleMark }, true),
    { type: 'none', hasSlot: false, visible: false, text: '' },
  );
});

test('candidate line parser accepts common separators', () => {
  assert.deepStrictEqual(parsePreviewCandidateLine('你好\t常用'), { text: '你好', comment: '常用' });
  assert.deepStrictEqual(parsePreviewCandidateLine('你好|常用'), { text: '你好', comment: '常用' });
  assert.deepStrictEqual(parsePreviewCandidateLine('你好,常用'), { text: '你好', comment: '常用' });
  assert.deepStrictEqual(parsePreviewCandidateLine('你好  常用'), { text: '你好', comment: '常用' });
  assert.deepStrictEqual(parsePreviewCandidateLine('你好'), { text: '你好', comment: '' });
});

test('preview candidate parser falls back when input is empty', () => {
  const fallback = [{ label: '1', text: 'fallback', comment: '' }];
  assert.deepStrictEqual(previewCandidateItems('', fallback), fallback);
});

test('preview quick-code placeholder uses the selected schema indicator', () => {
  assert.strictEqual(resolvePreviewComment('{{quick_code}}', { quickCodeIndicator: '⚡' }), '⚡');
  assert.strictEqual(resolvePreviewComment('简码 {{quick_code}}', { quickCodeIndicator: '·' }), '简码 ·');
});

test('alpha update preserves rgb and clamps alpha', () => {
  assert.deepStrictEqual(applyAlpha({ r: 1, g: 2, b: 3, a: 255 }, 128), { r: 1, g: 2, b: 3, a: 128 });
  assert.deepStrictEqual(applyAlpha({ r: 1, g: 2, b: 3, a: 255 }, 999), { r: 1, g: 2, b: 3, a: 255 });
  assert.deepStrictEqual(applyAlpha({ r: 1, g: 2, b: 3, a: 255 }, -1), { r: 1, g: 2, b: 3, a: 0 });
});
