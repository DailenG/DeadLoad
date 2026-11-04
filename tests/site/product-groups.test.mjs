// node --test tests/site/*.test.mjs
// The Autodesk products panel: site/data/product-groups.json against the real catalog, and the
// pure helpers in site/assets/js/policy-generator.js that the panel uses.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  buildChanges,
  toPowerShell,
  toGpmcText,
  gpmcRows,
  findCategorySetting,
  resolveProductGroups,
  productLabels,
  isCategoryOn,
  switchValue
} from '../../site/assets/js/policy-generator.js';

const load = (relative) => readFileSync(fileURLToPath(new URL(relative, import.meta.url)), 'utf8');
const catalog = JSON.parse(load('../../site/data/settings.json'));
const groupsText = load('../../site/data/product-groups.json');
const groups = JSON.parse(groupsText);
const resolved = resolveProductGroups(catalog, groups);
const allCategories = resolved.products.flatMap((p) => p.categories);
const allKnobs = allCategories.flatMap((c) => c.knobs.map((k) => ({ category: c, ...k })));

// Settings that only feed the routine phase; useless where the shipped RoutineAction is None.
const ROUTINE_ONLY = ['AgeDays', 'AgeBasis', 'KeepNewest', 'MaxTotalMB', 'MaxSharePercent', 'ShareBase', 'LimitScope', 'ActivateBelowGB', 'ActivateBelowPercent'];
const PRESSURE_ONLY = ['PressureTier', 'PressureAction', 'PressureAgeDays', 'PressureKeepNewest'];

test('product-groups.json is 7-bit ASCII', () => {
  assert.ok(/^[\x00-\x7F]*$/.test(groupsText));
});

test('every curated category and knob exists in the catalog with the stated type', () => {
  assert.deepEqual(resolved.problems, []);
  for (const product of groups.products) {
    for (const entry of product.categories) {
      assert.ok(findCategorySetting(catalog, entry.id, 'Enabled'), `${entry.id}: Enabled`);
      assert.ok(entry.knobs.length >= 1 && entry.knobs.length <= 4, `${entry.id}: 1 to 4 knobs`);
      for (const knob of entry.knobs) {
        const setting = findCategorySetting(catalog, entry.id, knob.setting);
        assert.ok(setting, `${entry.id}: ${knob.setting}`);
        assert.equal(setting.type, knob.type, `${entry.id}: ${knob.setting} type`);
        assert.equal(setting.categoryId, entry.id);
        assert.ok(knob.label && knob.unit && knob.help, `${entry.id}: ${knob.setting} needs label, unit and help`);
        assert.notEqual(knob.setting, 'Enabled', 'Enabled is the switch, not a knob');
      }
    }
  }
});

test('every catalog category is in exactly one product group, or deliberately excluded', () => {
  const curated = groups.products.flatMap((p) => p.categories.map((c) => c.id));
  assert.equal(new Set(curated).size, curated.length, 'no category twice');
  const excluded = groups.excluded.map((e) => e.id);
  for (const category of catalog.categories) {
    assert.ok(curated.includes(category.id) || excluded.includes(category.id), `${category.id} is neither curated nor excluded`);
  }
  for (const id of excluded) assert.ok(!catalog.categories.some((c) => c.id === id), `${id} is excluded but also a catalog category`);
  assert.deepEqual(groups.products.map((p) => p.name), ['Revit', 'AutoCAD', 'Shared Autodesk components', 'Temporary files']);
});

test('no knob is one the category rule does not use', () => {
  for (const { category, setting } of allKnobs) {
    const routine = findCategorySetting(catalog, category.info.id, 'RoutineAction');
    const pressure = findCategorySetting(catalog, category.info.id, 'PressureEnabled');
    if (routine && routine.default === 'None') {
      assert.ok(!ROUTINE_ONLY.includes(setting.valueName), `${category.info.id}: ${setting.valueName} does nothing without a routine action`);
    }
    if (pressure && pressure.default === 0) {
      assert.ok(!PRESSURE_ONLY.includes(setting.valueName), `${category.info.id}: ${setting.valueName} does nothing without pressure`);
    }
  }
  // The journal shelf is a Revit.ini setting, not a file cleanup: only its shelf values.
  const shelf = allCategories.find((c) => c.info.id === 'revit.ini.journalshelf');
  assert.deepEqual(shelf.knobs.map((k) => k.setting.valueName).sort(), ['ShelfCapacity', 'ShelfLifeDays']);
});

test('default-off categories say why; risky ones warn when switched on', () => {
  for (const category of allCategories) {
    if (Number(category.enabled.default) === 0) {
      assert.ok(category.offReason, `${category.info.id}: offReason`);
      if (category.info.risk === 'Restricted') assert.ok(category.onWarning, `${category.info.id}: onWarning`);
    }
  }
  const collab = allCategories.find((c) => c.info.id === 'revit.collabcache');
  assert.equal(collab.info.risk, 'Restricted');
  assert.match(collab.onWarning, /saved but not synchronized/);
  assert.match(collab.onWarning, /synchronize/);
});

test('switching a default-on category off emits Enabled=0 under its own key', () => {
  const journals = findCategorySetting(catalog, 'revit.journals', 'Enabled');
  assert.equal(isCategoryOn(journals, {}), true);
  const value = switchValue(journals, false);
  assert.equal(value, '0');
  assert.equal(isCategoryOn(journals, { [journals.id]: value }), false);
  const { changes } = buildChanges(catalog, { values: { [journals.id]: value } });
  assert.equal(changes.length, 1);
  const ps = toPowerShell(changes);
  assert.ok(ps.includes("-Key 'HKLM\\Software\\Policies\\DeadLoad\\Categories\\revit.journals' -ValueName 'Enabled' -Type DWord -Value 0"), ps);
});

test('switching an opt-in category on emits Enabled=1; switching back emits nothing', () => {
  const collab = findCategorySetting(catalog, 'revit.collabcache', 'Enabled');
  assert.equal(isCategoryOn(collab, {}), false);
  const on = switchValue(collab, true);
  let { changes } = buildChanges(catalog, { values: { [collab.id]: on } });
  assert.equal(changes.length, 1);
  assert.equal(changes[0].value, 1);
  assert.equal(changes[0].setting.key, 'Software\\Policies\\DeadLoad\\Categories\\revit.collabcache');
  assert.equal(switchValue(collab, false), '');
  ({ changes } = buildChanges(catalog, { values: { [collab.id]: switchValue(collab, false) } }));
  assert.equal(changes.length, 0);
});

test('a knob value equal to its default emits nothing', () => {
  const values = {};
  for (const { setting } of allKnobs) values[setting.id] = String(setting.default);
  const { changes, errors } = buildChanges(catalog, { values });
  assert.deepEqual(errors, []);
  assert.equal(changes.length, 0);
});

test('out-of-range knob values are rejected and not emitted', () => {
  for (const { setting } of allKnobs) {
    const { changes, errors } = buildChanges(catalog, { values: { [setting.id]: String(setting.max + 1) } });
    assert.equal(changes.length, 0, setting.id);
    assert.equal(errors.length, 1, setting.id);
    const below = buildChanges(catalog, { values: { [setting.id]: String(setting.min - 1) } });
    assert.equal(below.errors.length, 1, setting.id);
    assert.equal(buildChanges(catalog, { values: { [setting.id]: 'seven' } }).errors.length, 1, setting.id);
  }
});

test('curated values are labeled in plain English in every output, emitted once', () => {
  const labels = productLabels(resolved);
  const temp = findCategorySetting(catalog, 'user.temp', 'AgeDays');
  const collab = findCategorySetting(catalog, 'revit.collabcache', 'Enabled');
  const values = { [temp.id]: '14', [collab.id]: '1' };
  const { changes } = buildChanges(catalog, { values });
  assert.equal(changes.length, 2);
  const ps = toPowerShell(changes, { labels });
  assert.equal(ps.split('-ValueName \'AgeDays\'').length - 1, 1, 'AgeDays emitted once');
  assert.ok(ps.includes('(Temporary files: Delete files older than N days)'), ps);
  assert.ok(ps.includes('(Revit collaboration cache: on or off)'), ps);
  const rows = gpmcRows(changes, { labels });
  assert.equal(rows.find((r) => r.id === temp.id).meaning, 'Temporary files: Delete files older than N days');
  assert.match(toGpmcText(changes, { labels }), /\(Temporary files: Delete files older than N days\)/);
  for (const label of labels.values()) assert.ok(/^[\x20-\x7E]+$/.test(label), label);
});
