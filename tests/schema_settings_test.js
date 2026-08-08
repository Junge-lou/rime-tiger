const assert = require('assert');

function test(name, fn) {
  try {
    fn();
    console.log(`ok - ${name}`);
  } catch (error) {
    console.error(`not ok - ${name}`);
    throw error;
  }
}

const settings = require('../Rime皮肤编辑器/src/schema-settings.js');

const schemaFiles = [
  {
    name: 'tiger.schema.yaml',
    text: [
      'schema:',
      '  schema_id: tiger',
      '  name: 虎码',
      '__include: tiger_base.schema:/',
    ].join('\n'),
  },
  {
    name: 'tigress.schema.yaml',
    text: [
      'schema:',
      '  schema_id: tigress',
      '  name: 虎码单字',
      '__include: tiger_base.schema:/',
    ].join('\n'),
  },
  {
    name: 'tiger_base.schema.yaml',
    text: [
      'translator:',
      '  quick_code_indicator: "⚡"',
      'pin:',
      '  indicator: "📌"',
    ].join('\n'),
  },
];

test('catalog only marks schemas listed under schema_list as enabled', () => {
  const custom = [
    '# schema: commented_out',
    'patch:',
    '  schema_list:',
    '    - {schema: tiger}',
    '  unrelated:',
    '    schema: tigress',
  ].join('\n');
  const catalog = settings.buildSchemaCatalog(schemaFiles, custom);
  assert.deepStrictEqual(
    catalog.filter((item) => item.enabled).map((item) => item.id),
    ['tiger'],
  );
});

test('catalog accepts block-style schema list entries and preserves their order', () => {
  const custom = [
    'patch:',
    '  schema_list:',
    '    - schema: tigress',
    '    - schema: tiger',
  ].join('\n');
  const catalog = settings.buildSchemaCatalog(schemaFiles, custom);
  assert.deepStrictEqual(catalog.slice(0, 2).map((item) => item.id), ['tigress', 'tiger']);
});

test('settings are discovered through schema inheritance', () => {
  const schema = settings.buildSchemaCatalog(schemaFiles)[0];
  const discovered = settings.discoverSchemaSettings(schema, schemaFiles);
  assert.deepStrictEqual(
    discovered.map(({ id, value, source }) => ({ id, value, source })),
    [
      { id: 'quickCodeIndicator', value: '⚡', source: 'tiger_base.schema.yaml' },
      { id: 'pinIndicator', value: '📌', source: 'tiger_base.schema.yaml' },
    ],
  );
});

test('schema custom inheritance stays scoped to the selected schema', () => {
  const files = [
    { name: 'tiger.custom.yaml', text: 'patch:\n  __include: shared_tiger.custom:/' },
    { name: 'shared_tiger.custom.yaml', text: 'patch:\n  menu/alternative_select_labels: [一, 二]' },
    { name: 'tigress.custom.yaml', text: 'patch:\n  menu/alternative_select_labels: [壹, 贰]' },
  ];
  assert.deepStrictEqual(
    settings.customFilesForSchema('tiger', files).map((item) => item.name),
    ['tiger.custom.yaml', 'shared_tiger.custom.yaml'],
  );
});

test('schema setting writer stores a scalar patch path', () => {
  const updated = settings.updateSchemaSetting('patch:\n', 'translator/quick_code_indicator', '⚡');
  assert.ok(updated.includes('translator/quick_code_indicator:'), updated);
  assert.ok(updated.includes('⚡'), updated);
});
