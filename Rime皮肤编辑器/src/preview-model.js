(function (root) {
'use strict';

const DEFAULT_PREVIEW_CANDIDATES = [
  { label: '1', text: '你好', comment: '常用' },
  { label: '2', text: '你', comment: '单字' },
  { label: '3', text: '年', comment: '' },
  { label: '4', text: '候选文本比较长', comment: '长词' },
  { label: '5', text: '候選', comment: '异体' },
];
const DEFAULT_PREVIEW_CODE = 'nihao';
const DEFAULT_PREVIEW_CANDIDATES_TEXT = '你好\t常用\n你\t单字\n拟\n候选文本比较长\t长词\n候選\t异体';

function colorIsVisible(color) {
  return Boolean(color && (color.a ?? 255) > 0);
}

function markerBehavior(platform, layout = {}, colors = {}, active = false) {
  if (platform !== 'weasel') {
    return {
      type: 'none',
      hasSlot: false,
      visible: false,
      text: '',
    };
  }

  const text = String(layout.markText || '');
  const hasVisibleColor = colorIsVisible(colors.hilitedMark);
  if (text) {
    return {
      type: hasVisibleColor ? 'text' : 'none',
      hasSlot: hasVisibleColor,
      visible: Boolean(active && hasVisibleColor),
      text: hasVisibleColor ? text : '',
    };
  }
  if (hasVisibleColor) {
    return {
      type: 'win11',
      hasSlot: true,
      visible: Boolean(active),
      text: '',
    };
  }
  return {
    type: 'none',
    hasSlot: false,
    visible: false,
    text: '',
  };
}

function parsePreviewCandidateLine(line) {
  const text = String(line || '').trim();
  if (!text) return { text: '', comment: '' };
  const tabParts = text.split('\t');
  if (tabParts.length >= 2) {
    return { text: tabParts[0].trim(), comment: tabParts.slice(1).join('\t').trim() };
  }
  const pipeIndex = text.indexOf('|');
  if (pipeIndex >= 0) {
    return { text: text.slice(0, pipeIndex).trim(), comment: text.slice(pipeIndex + 1).trim() };
  }
  const commaIndex = text.indexOf(',');
  if (commaIndex >= 0) {
    return { text: text.slice(0, commaIndex).trim(), comment: text.slice(commaIndex + 1).trim() };
  }
  const spaced = text.match(/^(.+?)\s{2,}(.+)$/);
  if (spaced) return { text: spaced[1].trim(), comment: spaced[2].trim() };
  return { text, comment: '' };
}

function previewCandidateItems(source, fallback = DEFAULT_PREVIEW_CANDIDATES) {
  const raw = String(source || '').trim();
  const lines = raw ? raw.split(/\r?\n/) : [];
  const items = lines
    .map((line) => parsePreviewCandidateLine(line))
    .filter((item) => item.text);
  return items.length ? items : fallback;
}

function applyAlpha(color, alpha) {
  return {
    ...(color || { r: 0, g: 0, b: 0 }),
    a: Math.max(0, Math.min(255, Math.round(Number(alpha) || 0))),
  };
}

const api = {
  DEFAULT_PREVIEW_CANDIDATES,
  DEFAULT_PREVIEW_CODE,
  DEFAULT_PREVIEW_CANDIDATES_TEXT,
  applyAlpha,
  colorIsVisible,
  markerBehavior,
  parsePreviewCandidateLine,
  previewCandidateItems,
};

if (typeof module !== 'undefined' && module.exports) {
  module.exports = api;
}
root.RimeSkinPreviewModel = api;
})(typeof globalThis !== 'undefined' ? globalThis : window);
