// DeadLoad policy generator: pure functions only (no DOM, no network).
// Input is the catalog in data/settings.json (build/Export-DeadLoadSettingsCatalog.ps1) and
// the values an administrator chose; output is PowerShell for a GPO, a .reg file for one test
// machine, and a table for setting the same values by hand in the Group Policy editor.
// Validation follows the engine's own rules (src/engine/DeadLoad/Private/Config.ps1).

export const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];

// Presets name only the values they set; everything else stays at the shipped default.
// docs/RECOMMENDED-POLICY.md explains both.
export const PRESETS = {
  pilot: {
    id: 'pilot',
    label: 'Pilot',
    summary: 'Report only: DeadLoad scans, plans and logs what it would do, and changes nothing. Users are told when a run completes.',
    values: { General_ReportOnly: '1', Tray_NotifyOnCompletion: '1' }
  },
  recommended: {
    id: 'recommended',
    label: 'Recommended',
    summary: 'The shipped defaults, with report only explicitly off so a local report-only value left from a pilot no longer applies.',
    values: { General_ReportOnly: '0' }
  }
};

// The handful of settings most administrators set (RECOMMENDED-POLICY.md).
export const COMMON_SETTING_IDS = [
  'Schedule_MaintenanceTime',
  'General_ReportOnly',
  'Tray_SupportShare',
  'Tray_NotifyOnCompletion',
  'Tray_LowDiskNotifications'
];

export function indexCatalog(catalog) {
  const map = new Map();
  for (const setting of catalog.settings) map.set(setting.id, setting);
  return map;
}

function isPrintableAscii(text) {
  return /^[\x20-\x7E]*$/.test(text);
}

// One raw value (string from a form, or a number) against its setting.
// Returns { ok, value, error, warning }. value is a number for Bool/Int, else a string.
export function validateValue(setting, raw) {
  const text = raw === null || raw === undefined ? '' : String(raw).trim();
  const fail = (error) => ({ ok: false, value: null, error, warning: null });
  const pass = (value, warning = null) => ({ ok: true, value, error: null, warning });
  switch (setting.type) {
    case 'Bool': {
      if (text === '1' || /^(true|enabled|on)$/i.test(text)) return pass(1);
      if (text === '0' || /^(false|disabled|off)$/i.test(text)) return pass(0);
      return fail('Expected 0 or 1.');
    }
    case 'Int': {
      if (!/^-?\d+$/.test(text)) return fail('Expected a whole number.');
      const number = Number(text);
      if (!Number.isSafeInteger(number)) return fail('Number too large.');
      if (typeof setting.min === 'number' && number < setting.min) return fail(`Below the minimum ${setting.min}.`);
      if (typeof setting.max === 'number' && number > setting.max) return fail(`Above the maximum ${setting.max}.`);
      return pass(number);
    }
    case 'Enum': {
      // The engine compares case-insensitively and keeps its own spelling.
      const match = (setting.values || []).find((v) => v.toLowerCase() === text.toLowerCase());
      if (match === undefined) return fail(`Expected one of ${(setting.values || []).join(', ')}.`);
      return pass(match);
    }
    case 'Time': {
      if (!/^([01]\d|2[0-3]):[0-5]\d$/.test(text)) return fail('Expected HH:mm, 24-hour, for example 03:00.');
      return pass(text);
    }
    case 'Days': {
      const parts = text.split(',').map((d) => d.trim()).filter((d) => d.length > 0);
      if (parts.length === 0) return fail('Expected at least one day name.');
      const days = [];
      for (const part of parts) {
        const day = DAY_NAMES.find((d) => d.toLowerCase() === part.toLowerCase());
        if (!day) return fail(`Not a day name: ${part}. Use Sunday to Saturday.`);
        days.push(day);
      }
      return pass(days.join(','));
    }
    default: {
      const value = raw === null || raw === undefined ? '' : String(raw);
      const max = typeof setting.maxLength === 'number' ? setting.maxLength : 1024;
      if (value.length > max) return fail(`Longer than ${max} characters.`);
      // The generated script and .reg file are 7-bit ASCII; other text belongs in the editor.
      if (!isPrintableAscii(value)) return fail('Use printable ASCII characters only (set other text in the Group Policy editor).');
      if (setting.valueName === 'SupportShare' && value !== '' && !value.startsWith('\\\\')) {
        return pass(value, 'Expected a UNC folder such as \\\\server\\share.');
      }
      return pass(value);
    }
  }
}

function sameValue(setting, a, b) {
  if (setting.type === 'Bool' || setting.type === 'Int') return Number(a) === Number(b);
  return String(a) === String(b);
}

// values: { [settingId]: raw } from the form. A setting missing from values takes the preset's
// value, if the preset names it. null, undefined, or '' (except for String settings) means
// "not configured": nothing is emitted for it, even when the preset names it.
// A configured setting is emitted when the preset names it, or when it differs from the default.
// Returns { changes: [{ setting, value, reason }], errors: [{ setting, error }], warnings: [...] }.
export function buildChanges(catalog, { preset = null, values = {} } = {}) {
  const presetValues = preset && PRESETS[preset] ? PRESETS[preset].values : {};
  const changes = [];
  const errors = [];
  const warnings = [];
  for (const setting of catalog.settings) {
    const inForm = Object.prototype.hasOwnProperty.call(values, setting.id);
    const inPreset = Object.prototype.hasOwnProperty.call(presetValues, setting.id);
    const raw = inForm ? values[setting.id] : presetValues[setting.id];
    if (raw === undefined || raw === null) continue;
    if (setting.type !== 'String' && String(raw).trim() === '') continue;
    const result = validateValue(setting, raw);
    if (!result.ok) {
      errors.push({ setting, error: result.error });
      continue;
    }
    if (result.warning) warnings.push({ setting, warning: result.warning });
    if (inPreset || !sameValue(setting, result.value, setting.default)) {
      changes.push({ setting, value: result.value, reason: inPreset ? 'preset' : 'changed' });
    }
  }
  return { changes, errors, warnings };
}

// Machine or user policy: settings of class Both (the tray) may go to either.
export function policyHive(setting, { trayScope = 'Machine' } = {}) {
  if (setting.class === 'Both' && trayScope === 'User') return 'HKCU';
  return 'HKLM';
}

export function psQuote(text) {
  return "'" + String(text).replace(/'/g, "''") + "'";
}

export function regQuote(text) {
  return '"' + String(text).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

function dword(value) {
  return 'dword:' + (Number(value) >>> 0).toString(16).padStart(8, '0');
}

function describe(preset) {
  return preset && PRESETS[preset] ? `Preset: ${PRESETS[preset].label}.` : 'Preset: none.';
}

const CRLF = '\r\n';

// labels: optional Map of setting id -> plain-English label (from the products panel), shown
// beside the policy's own name so a curated value is easy to recognize in every output.
function labelFor(labels, setting) {
  return labels && labels.has(setting.id) ? labels.get(setting.id) : '';
}

export function toPowerShell(changes, { gpoName = '', trayScope = 'Machine', preset = null, labels = null } = {}) {
  const lines = [];
  lines.push('# DeadLoad Group Policy values, from the DeadLoad policy generator.');
  lines.push(`# ${describe(preset)} ${changes.length} value(s). Review before running.`);
  lines.push('# Needs the GroupPolicy module (Group Policy Management tools) and edit rights on the GPO.');
  lines.push('# Run: powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\\Set-DeadLoadPolicy.ps1 -GpoName <name>');
  lines.push('[CmdletBinding()]');
  lines.push('param');
  lines.push('(');
  if (gpoName) {
    lines.push(`    [string]$GpoName = ${psQuote(gpoName)}`);
  } else {
    lines.push('    [Parameter(Mandatory = $true)]');
    lines.push('    [string]$GpoName');
  }
  lines.push(')');
  lines.push('');
  lines.push("$ErrorActionPreference = 'Stop'");
  lines.push('Import-Module GroupPolicy');
  lines.push('');
  lines.push('$gpo = Get-GPO -Name $GpoName -ErrorAction SilentlyContinue');
  lines.push('if (-not $gpo)');
  lines.push('{');
  lines.push('    # The GPO does not exist yet. Create it, then link it where the workstations are, for example:');
  lines.push('    #   New-GPO -Name $GpoName');
  lines.push("    #   New-GPLink -Name $GpoName -Target 'OU=Workstations,DC=example,DC=com'");
  lines.push("    throw ('GPO not found: ' + $GpoName)");
  lines.push('}');
  lines.push('');
  if (changes.length === 0) {
    lines.push('# Nothing to set: the defaults apply.');
  }
  for (const { setting, value } of changes) {
    const key = `${policyHive(setting, { trayScope })}\\${setting.key}`;
    const type = setting.registryType === 'REG_DWORD' ? 'DWord' : 'String';
    const data = setting.registryType === 'REG_DWORD' ? String(Number(value)) : psQuote(value);
    const label = labelFor(labels, setting);
    lines.push(`# ${setting.display}${label ? ` (${label})` : ''}`);
    lines.push(`Set-GPRegistryValue -Name $GpoName -Key ${psQuote(key)} -ValueName ${psQuote(setting.valueName)} -Type ${type} -Value ${data} | Out-Null`);
  }
  lines.push('');
  lines.push("Write-Output ('DeadLoad: {0} value(s) written to GPO {1}.' -f " + changes.length + ', $GpoName)');
  return lines.join(CRLF) + CRLF;
}

const HIVE_NAMES = { HKLM: 'HKEY_LOCAL_MACHINE', HKCU: 'HKEY_CURRENT_USER' };

export function toRegFile(changes, { trayScope = 'Machine', preset = null } = {}) {
  const lines = ['Windows Registry Editor Version 5.00', ''];
  lines.push('; DeadLoad policy values for ONE test machine, from the DeadLoad policy generator.');
  lines.push(`; ${describe(preset)} ${changes.length} value(s).`);
  lines.push('; Use a GPO for a fleet: a Group Policy refresh can replace or remove these values.');
  if (changes.length === 0) {
    lines.push('; Nothing to set: the defaults apply.');
    return lines.join(CRLF) + CRLF;
  }
  const groups = new Map();
  for (const change of changes) {
    const path = `${HIVE_NAMES[policyHive(change.setting, { trayScope })]}\\${change.setting.key}`;
    if (!groups.has(path)) groups.set(path, []);
    groups.get(path).push(change);
  }
  for (const [path, group] of groups) {
    lines.push('');
    lines.push(`[${path}]`);
    for (const { setting, value } of group) {
      const data = setting.registryType === 'REG_DWORD' ? dword(value) : regQuote(value);
      lines.push(`${regQuote(setting.valueName)}=${data}`);
    }
  }
  return lines.join(CRLF) + CRLF;
}

// What to choose in the Group Policy editor for one value.
export function gpmcState(setting, value) {
  if (setting.type === 'Bool') return Number(value) === 1 ? 'Enabled' : 'Disabled';
  const shown = value === '' ? '(empty)' : String(value);
  return `Enabled, ${shown}`;
}

export function gpmcRows(changes, { trayScope = 'Machine', labels = null } = {}) {
  return changes.map(({ setting, value }) => {
    const root = policyHive(setting, { trayScope }) === 'HKCU' ? 'User Configuration' : 'Computer Configuration';
    const folders = [root, 'Policies', 'Administrative Templates', 'DeadLoad', setting.sectionName];
    if (setting.categoryId) folders.push(setting.categoryFolder || setting.categoryId);
    return {
      id: setting.id,
      path: folders.join(' > '),
      policy: setting.display,
      meaning: labelFor(labels, setting),
      state: gpmcState(setting, value)
    };
  });
}

export function toGpmcText(changes, options = {}) {
  const rows = gpmcRows(changes, options);
  if (rows.length === 0) return 'Nothing to set: the defaults apply.\n';
  const out = [`DeadLoad: ${rows.length} policy setting(s) to set in the Group Policy Management Editor.`, ''];
  for (const row of rows) {
    out.push(row.path);
    out.push(`  ${row.policy}: ${row.state}`);
    if (row.meaning) out.push(`    (${row.meaning})`);
  }
  return out.join('\n') + '\n';
}

// ---------------------------------------------------------------- Autodesk products panel
// groups is data/product-groups.json: products -> categories -> knobs (value names of category
// settings). These helpers resolve it against the catalog; the UI only renders the result.

export function findCategorySetting(catalog, categoryId, valueName) {
  return catalog.settings.find((s) => s.categoryId === categoryId && s.valueName === valueName) || null;
}

// Returns { products, problems }. problems lists every curated id the catalog does not have,
// or a knob whose type differs; the UI shows resolved entries only.
export function resolveProductGroups(catalog, groups) {
  const problems = [];
  const infos = new Map((catalog.categories || []).map((c) => [c.id, c]));
  const products = [];
  for (const product of groups.products || []) {
    const categories = [];
    for (const entry of product.categories || []) {
      const info = infos.get(entry.id);
      const enabled = findCategorySetting(catalog, entry.id, 'Enabled');
      if (!info || !enabled) {
        problems.push(`${product.id}: category ${entry.id} is not in the catalog`);
        continue;
      }
      const knobs = [];
      for (const knob of entry.knobs || []) {
        const setting = findCategorySetting(catalog, entry.id, knob.setting);
        if (!setting) {
          problems.push(`${entry.id}: setting ${knob.setting} is not in the catalog`);
          continue;
        }
        if (knob.type && knob.type !== setting.type) {
          problems.push(`${entry.id}: setting ${knob.setting} is ${setting.type}, not ${knob.type}`);
          continue;
        }
        knobs.push({ setting, label: knob.label, unit: knob.unit || '', help: knob.help || '' });
      }
      categories.push({
        info,
        enabled,
        knobs,
        offReason: entry.offReason || '',
        onWarning: entry.onWarning || '',
        offWarning: entry.offWarning || ''
      });
    }
    products.push({ id: product.id, name: product.name, categories });
  }
  return { products, problems };
}

// Plain-English labels of every curated setting, for the outputs.
export function productLabels(resolved) {
  const labels = new Map();
  for (const product of resolved.products) {
    for (const category of product.categories) {
      const name = category.info.displayName || category.info.id;
      labels.set(category.enabled.id, `${name}: on or off`);
      for (const knob of category.knobs) {
        labels.set(knob.setting.id, `${name}: ${knob.label} N ${knob.unit}`.trim());
      }
    }
  }
  return labels;
}

// Whether a category is on, from the form value (if configured and valid) or its default.
export function isCategoryOn(enabledSetting, values) {
  const raw = Object.prototype.hasOwnProperty.call(values, enabledSetting.id) ? values[enabledSetting.id] : '';
  if (raw === undefined || raw === null || String(raw).trim() === '') return Number(enabledSetting.default) === 1;
  const result = validateValue(enabledSetting, raw);
  return result.ok ? result.value === 1 : Number(enabledSetting.default) === 1;
}

// The form value a category switch writes: '' (not configured) when it matches the shipped
// default, so switching back emits nothing; else '1' or '0'.
export function switchValue(enabledSetting, on) {
  const value = on ? 1 : 0;
  return value === Number(enabledSetting.default) ? '' : String(value);
}
