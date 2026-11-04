// node --test tests/site
// Pure-function tests for site/assets/js/policy-generator.js against the real catalog.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';

import {
  PRESETS,
  COMMON_SETTING_IDS,
  indexCatalog,
  validateValue,
  buildChanges,
  toPowerShell,
  toRegFile,
  toGpmcText,
  gpmcRows,
  psQuote,
  regQuote
} from '../../site/assets/js/policy-generator.js';

const catalogPath = fileURLToPath(new URL('../../site/data/settings.json', import.meta.url));
const catalog = JSON.parse(readFileSync(catalogPath, 'utf8'));
const byId = indexCatalog(catalog);
const ids = (changes) => changes.map((c) => c.setting.id).sort();
const ascii = (text) => /^[\x00-\x7F]*$/.test(text);

test('catalog has settings and every preset and common id exists in it', () => {
  assert.ok(catalog.settings.length > 50);
  for (const preset of Object.values(PRESETS)) {
    for (const id of Object.keys(preset.values)) assert.ok(byId.has(id), `${preset.id}: ${id}`);
  }
  for (const id of COMMON_SETTING_IDS) assert.ok(byId.has(id), id);
});

test('every shipped default passes its own validation', () => {
  for (const setting of catalog.settings) {
    const result = validateValue(setting, setting.default);
    assert.equal(result.ok, true, `${setting.id}: ${result.error}`);
  }
});

test('Pilot preset emits report only and completion notifications, nothing else', () => {
  const { changes, errors } = buildChanges(catalog, { preset: 'pilot' });
  assert.deepEqual(errors, []);
  assert.deepEqual(ids(changes), ['General_ReportOnly', 'Tray_NotifyOnCompletion']);
  for (const change of changes) assert.equal(change.value, 1);
});

test('Recommended preset emits report only off explicitly, nothing else', () => {
  const { changes } = buildChanges(catalog, { preset: 'recommended' });
  assert.deepEqual(ids(changes), ['General_ReportOnly']);
  assert.equal(changes[0].value, 0);
  assert.equal(changes[0].reason, 'preset');
});

test('no preset and no values: nothing to set in every output', () => {
  const { changes } = buildChanges(catalog, {});
  assert.equal(changes.length, 0);
  assert.match(toPowerShell(changes), /Nothing to set: the defaults apply\./);
  assert.match(toRegFile(changes), /Nothing to set: the defaults apply\./);
  assert.equal(toGpmcText(changes), 'Nothing to set: the defaults apply.\n');
});

test('only values that differ from the default are emitted', () => {
  const values = {
    Schedule_MaintenanceTime: '03:00', // the default
    Pressure_FloorGB: '30', // the default
    Schedule_MaintenanceDays: 'saturday', // differs; normalized
    Tray_SupportShare: '' // the default (empty)
  };
  const { changes, errors } = buildChanges(catalog, { values });
  assert.deepEqual(errors, []);
  assert.deepEqual(ids(changes), ['Schedule_MaintenanceDays']);
  assert.equal(changes[0].value, 'Saturday');
});

test('a form value overrides the preset; not configured removes a preset value', () => {
  let result = buildChanges(catalog, { preset: 'pilot', values: { General_ReportOnly: '0' } });
  assert.equal(result.changes.find((c) => c.setting.id === 'General_ReportOnly').value, 0);
  result = buildChanges(catalog, { preset: 'pilot', values: { General_ReportOnly: '' } });
  assert.deepEqual(ids(result.changes), ['Tray_NotifyOnCompletion']);
});

test('integer bounds come from the catalog', () => {
  for (const setting of catalog.settings.filter((s) => s.type === 'Int')) {
    assert.equal(validateValue(setting, String(setting.min)).ok, true, setting.id);
    assert.equal(validateValue(setting, String(setting.max)).ok, true, setting.id);
    assert.equal(validateValue(setting, String(setting.min - 1)).ok, false, setting.id);
    assert.equal(validateValue(setting, String(setting.max + 1)).ok, false, setting.id);
  }
  const budget = byId.get('General_TimeBudgetMinutes');
  assert.equal(validateValue(budget, '1.5').ok, false);
  assert.equal(validateValue(budget, 'ten').ok, false);
  const { errors } = buildChanges(catalog, { values: { General_TimeBudgetMinutes: '601' } });
  assert.equal(errors.length, 1);
  assert.match(errors[0].error, /maximum 600/);
});

test('enum, time, days and bool validation follow the engine', () => {
  const mode = byId.get('General_OnDemandMode');
  assert.deepEqual(validateValue(mode, 'pressurecheck'), { ok: true, value: 'PressureCheck', error: null, warning: null });
  assert.equal(validateValue(mode, 'Weekly').ok, false);
  const time = byId.get('Schedule_MaintenanceTime');
  for (const good of ['00:00', '03:00', '23:59']) assert.equal(validateValue(time, good).ok, true, good);
  for (const bad of ['24:00', '3:00', '03:60', '0300', '']) assert.equal(validateValue(time, bad).ok, false, bad);
  const days = byId.get('Schedule_MaintenanceDays');
  assert.equal(validateValue(days, 'Monday, thursday').value, 'Monday,Thursday');
  assert.equal(validateValue(days, 'Mon').ok, false);
  assert.equal(validateValue(days, ' , ').ok, false);
  const bool = byId.get('General_ReportOnly');
  assert.equal(validateValue(bool, '2').ok, false);
  assert.equal(validateValue(bool, 1).value, 1);
});

test('strings: length limit, ASCII only, UNC warning for the support share', () => {
  const share = byId.get('Tray_SupportShare');
  assert.equal(validateValue(share, 'x'.repeat(share.maxLength)).ok, true);
  assert.equal(validateValue(share, 'x'.repeat(share.maxLength + 1)).ok, false);
  assert.equal(validateValue(share, '\\\\server\\caf\u00e9').ok, false);
  assert.equal(validateValue(share, 'line\nbreak').ok, false);
  assert.ok(validateValue(share, 'C:\\Logs').warning);
  assert.equal(validateValue(share, '\\\\server\\share').warning, null);
});

test('PowerShell escaping: single quotes doubled, backslashes literal', () => {
  assert.equal(psQuote("it's"), "'it''s'");
  assert.equal(psQuote('\\\\server\\share'), "'\\\\server\\share'");
  const value = "\\\\server\\it's \"logs\"";
  const { changes } = buildChanges(catalog, { values: { Tray_SupportShare: value } });
  const ps = toPowerShell(changes, { gpoName: "Bob's GPO" });
  assert.ok(ps.includes("-ValueName 'SupportShare' -Type String -Value '\\\\server\\it''s \"logs\"'"), ps);
  assert.ok(ps.includes("[string]$GpoName = 'Bob''s GPO'"));
  assert.ok(ascii(ps));
  assert.ok(!ps.includes('&&') && !ps.includes('||'));
  assert.ok(ps.includes('\r\n'));
});

test('.reg escaping: backslashes doubled, double quotes escaped, dwords in hex', () => {
  assert.equal(regQuote('\\\\server\\share'), '"\\\\\\\\server\\\\share"');
  assert.equal(regQuote('say "hi"'), '"say \\"hi\\""');
  const { changes } = buildChanges(catalog, {
    values: { Tray_SupportShare: '\\\\server\\share "x"', General_MaxDeleteMBPerRun: '10000000' }
  });
  const reg = toRegFile(changes);
  assert.ok(reg.startsWith('Windows Registry Editor Version 5.00\r\n'));
  assert.ok(reg.includes('[HKEY_LOCAL_MACHINE\\Software\\Policies\\DeadLoad]\r\n"MaxDeleteMBPerRun"=dword:00989680'), reg);
  assert.ok(reg.includes('[HKEY_LOCAL_MACHINE\\Software\\Policies\\DeadLoad\\Tray]\r\n"SupportShare"="\\\\\\\\server\\\\share \\"x\\""'), reg);
  assert.ok(ascii(reg));
});

test('every emitted key and value name matches the catalog, for every setting', () => {
  const values = {};
  for (const setting of catalog.settings) {
    if (setting.type === 'Bool') values[setting.id] = setting.default === 1 ? '0' : '1';
    else if (setting.type === 'Int') values[setting.id] = String(setting.default === setting.max ? setting.min : setting.default + 1);
    else if (setting.type === 'Enum') values[setting.id] = setting.values.find((v) => v !== setting.default);
    else if (setting.type === 'Time') values[setting.id] = setting.default === '01:00' ? '02:00' : '01:00';
    else if (setting.type === 'Days') values[setting.id] = setting.default === 'Monday' ? 'Tuesday' : 'Monday';
    else values[setting.id] = '\\\\server\\share';
  }
  const { changes, errors } = buildChanges(catalog, { values });
  assert.deepEqual(errors, []);
  assert.equal(changes.length, catalog.settings.length);

  const ps = toPowerShell(changes);
  const lines = ps.split('\r\n').filter((l) => l.startsWith('Set-GPRegistryValue'));
  assert.equal(lines.length, catalog.settings.length);
  lines.forEach((line, i) => {
    const setting = changes[i].setting;
    const match = /-Key '([^']+)' -ValueName '([^']+)' -Type (DWord|String) -Value /.exec(line);
    assert.ok(match, line);
    assert.equal(match[1], `HKLM\\${setting.key}`);
    assert.equal(match[2], setting.valueName);
    assert.equal(match[3], setting.registryType === 'REG_DWORD' ? 'DWord' : 'String');
    assert.ok(match[1].startsWith('HKLM\\Software\\Policies\\DeadLoad'));
  });

  const reg = toRegFile(changes);
  for (const setting of catalog.settings) {
    assert.ok(reg.includes(`[HKEY_LOCAL_MACHINE\\${setting.key}]`), setting.key);
  }
  assert.equal(gpmcRows(changes).length, catalog.settings.length);
});

test('tray settings go to user policy only when asked, and only tray settings', () => {
  const { changes } = buildChanges(catalog, { values: { Tray_NotifyOnCompletion: '1', General_ReportOnly: '1' } });
  const ps = toPowerShell(changes, { trayScope: 'User' });
  assert.ok(ps.includes("-Key 'HKCU\\Software\\Policies\\DeadLoad\\Tray' -ValueName 'NotifyOnCompletion'"));
  assert.ok(ps.includes("-Key 'HKLM\\Software\\Policies\\DeadLoad' -ValueName 'ReportOnly'"));
  const rows = gpmcRows(changes, { trayScope: 'User' });
  assert.ok(rows.some((r) => r.path.startsWith('User Configuration > Policies > Administrative Templates > DeadLoad > Tray app')));
  assert.ok(rows.some((r) => r.path.startsWith('Computer Configuration') && r.id === 'General_ReportOnly' && r.state === 'Enabled'));
});

test('GPMC table names category folders and value states', () => {
  const { changes } = buildChanges(catalog, { values: { 'Category_revit_collabcache_Enabled': '1', Pressure_FloorGB: '40' } });
  const rows = gpmcRows(changes);
  const collab = rows.find((r) => r.id === 'Category_revit_collabcache_Enabled');
  const folder = byId.get('Category_revit_collabcache_Enabled').categoryFolder;
  assert.ok(folder.includes('revit.collabcache'));
  assert.equal(collab.path, `Computer Configuration > Policies > Administrative Templates > DeadLoad > Categories > ${folder}`);
  assert.equal(collab.state, 'Enabled');
  const floor = rows.find((r) => r.id === 'Pressure_FloorGB');
  assert.equal(floor.state, 'Enabled, 40');
});
