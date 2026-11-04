// DeadLoad policy generator page: wires the form to the pure functions in policy-generator.js.
// Reads data/settings.json and data/product-groups.json from this site; sends nothing anywhere.
// One source of truth: state.values, keyed by setting id. Every control showing a setting
// (common settings, Autodesk products, All settings) reads and writes that same entry.
import {
  PRESETS,
  COMMON_SETTING_IDS,
  buildChanges,
  toPowerShell,
  toRegFile,
  toGpmcText,
  gpmcRows,
  resolveProductGroups,
  productLabels,
  isCategoryOn,
  switchValue
} from './policy-generator.js';

const $ = (selector, root = document) => root.querySelector(selector);

const state = {
  catalog: null,
  products: null,
  labels: null,
  preset: 'pilot',
  values: {},
  gpoName: '',
  trayScope: 'Machine',
  outputs: { ps: '', reg: '', gpmc: '' }
};

const RISK_ICONS = {
  Routine: '<path d="M3.5 8.5l3 3 6-7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/>',
  Review: '<path d="M1.5 8s2.4-4.5 6.5-4.5S14.5 8 14.5 8 12.1 12.5 8 12.5 1.5 8 1.5 8z" fill="none" stroke="currentColor" stroke-width="1.5"/><circle cx="8" cy="8" r="2" fill="none" stroke="currentColor" stroke-width="1.5"/>',
  Restricted: '<rect x="3" y="7" width="10" height="7" rx="1.5" fill="none" stroke="currentColor" stroke-width="1.5"/><path d="M5.5 7V5a2.5 2.5 0 015 0v2" fill="none" stroke="currentColor" stroke-width="1.5"/>'
};

function el(tag, attributes = {}, children = []) {
  const node = document.createElement(tag);
  for (const [name, value] of Object.entries(attributes)) {
    if (value === null || value === undefined || value === false) continue;
    if (name === 'text') node.textContent = value;
    else node.setAttribute(name, value === true ? '' : value);
  }
  for (const child of [].concat(children)) {
    if (child === null || child === undefined) continue;
    node.append(child);
  }
  return node;
}

function riskBadge(risk) {
  const badge = el('span', { class: `risk risk-${risk.toLowerCase()}` });
  badge.innerHTML = `<svg viewBox="0 0 16 16" aria-hidden="true" focusable="false">${RISK_ICONS[risk] || ''}</svg>`;
  badge.append(risk);
  return badge;
}

function describeDefault(setting) {
  if (setting.type === 'Bool') return setting.default === 1 ? 'Enabled' : 'Disabled';
  if (setting.default === '') return 'empty';
  return String(setting.default);
}

function helpText(setting) {
  const paragraphs = setting.explain.split('\n\n');
  const meaning = paragraphs.find((p) => !/^Category /.test(p) && !/^(Allowed values|Enabled sets|Format|Up to|Not configured|Registry)/.test(p)) || '';
  const allowed = paragraphs.find((p) => /^(Allowed values|Format|Up to)/.test(p)) || '';
  return [meaning, allowed.replace(/ Shipped default: .*$/, '')].filter(Boolean).join(' ');
}

function fieldId(setting) {
  return 'f-' + setting.id.replace(/[^A-Za-z0-9_-]/g, '_');
}

function renderField(setting) {
  const id = fieldId(setting);
  const hintId = id + '-hint';
  const errorId = id + '-error';
  const current = Object.prototype.hasOwnProperty.call(state.values, setting.id) ? state.values[setting.id] : '';
  let control;
  if (setting.type === 'Bool' || setting.type === 'Enum') {
    control = el('select', { id, 'aria-describedby': `${hintId} ${errorId}` });
    control.append(el('option', { value: '', text: `Not configured (default: ${describeDefault(setting)})` }));
    if (setting.type === 'Bool') {
      control.append(el('option', { value: '1', text: 'Enabled (1)' }));
      control.append(el('option', { value: '0', text: 'Disabled (0)' }));
    } else {
      for (const value of setting.values) control.append(el('option', { value, text: value }));
    }
    control.value = current === undefined || current === null ? '' : String(current);
  } else {
    control = el('input', {
      id,
      type: 'text',
      autocomplete: 'off',
      spellcheck: 'false',
      inputmode: setting.type === 'Int' ? 'numeric' : null,
      placeholder: setting.type === 'String' ? '(empty)' : String(setting.default),
      'aria-describedby': `${hintId} ${errorId}`
    });
    control.value = current === undefined || current === null ? '' : String(current);
  }
  control.dataset.setting = setting.id;
  const label = el('label', { for: id, text: setting.display });
  const hint = el('p', { class: 'hint', id: hintId, text: `${helpText(setting)} Default: ${describeDefault(setting)}.` });
  const error = el('p', { class: 'error', id: errorId, hidden: true });
  return el('div', { class: 'field' }, [label, control, hint, error]);
}

function renderCommon() {
  const root = $('#common-fields');
  root.replaceChildren();
  const byId = new Map(state.catalog.settings.map((s) => [s.id, s]));
  for (const id of COMMON_SETTING_IDS) {
    const setting = byId.get(id);
    if (setting) root.append(renderField(setting));
  }
}

function renderAll() {
  const root = $('#all-fields');
  root.replaceChildren();
  const settings = state.catalog.settings.filter((s) => !COMMON_SETTING_IDS.includes(s.id));
  $('#all-count').textContent = `(${settings.length})`;
  const categories = new Map((state.catalog.categories || []).map((c) => [c.id, c]));
  const groups = new Map();
  for (const setting of settings) {
    const key = setting.categoryId ? `cat:${setting.categoryId}` : `sec:${setting.sectionName}`;
    if (!groups.has(key)) groups.set(key, { setting, items: [] });
    groups.get(key).items.push(setting);
  }
  let lastSection = null;
  for (const [key, group] of groups) {
    const first = group.setting;
    if (first.categoryId && lastSection !== 'categories') {
      root.append(el('h3', { class: 'group-heading', text: first.sectionName }));
      lastSection = 'categories';
    }
    const details = el('details', { class: 'group' });
    const summary = el('summary');
    if (first.categoryId) {
      const info = categories.get(first.categoryId) || {};
      const title = info.displayName ? `${info.displayName} (${first.categoryId})` : (first.categoryFolder || first.categoryId);
      summary.append(el('span', { class: 'group-title', text: title }));
      if (info.risk) summary.append(riskBadge(info.risk));
      summary.append(el('span', { class: 'group-meta', text: info.enabledByDefault ? 'On by default' : 'Off by default' }));
    } else {
      summary.append(el('span', { class: 'group-title', text: first.sectionName }));
    }
    details.append(summary);
    if (first.categoryId) {
      const info = categories.get(first.categoryId) || {};
      if (info.description) details.append(el('p', { class: 'note', text: info.description }));
    }
    const fields = el('div', { class: 'fields' });
    for (const setting of group.items) fields.append(renderField(setting));
    details.append(fields);
    root.append(details);
    if (!first.categoryId) lastSection = key;
  }
}

function syncFieldErrors(result) {
  const errorsById = new Map(result.errors.map((e) => [e.setting.id, e.error]));
  const warningsById = new Map(result.warnings.map((w) => [w.setting.id, w.warning]));
  for (const control of document.querySelectorAll('[data-setting]')) {
    const id = control.dataset.setting;
    const error = document.getElementById(control.id + '-error');
    const message = errorsById.get(id) || warningsById.get(id) || '';
    error.textContent = message;
    error.hidden = message === '';
    error.classList.toggle('is-warning', !errorsById.has(id) && message !== '');
    if (errorsById.has(id)) control.setAttribute('aria-invalid', 'true');
    else control.removeAttribute('aria-invalid');
  }
}

function renderGpmcTable(changes) {
  const root = $('#out-gpmc');
  root.replaceChildren();
  const rows = gpmcRows(changes, { trayScope: state.trayScope, labels: state.labels });
  if (rows.length === 0) {
    root.append(el('p', { class: 'empty', text: 'Nothing to set: the defaults apply.' }));
    return;
  }
  const table = el('table');
  table.append(el('caption', { class: 'visually-hidden', text: 'Policies to set in the Group Policy Management Editor' }));
  const head = el('thead', {}, el('tr', {}, [
    el('th', { scope: 'col', text: 'Folder' }),
    el('th', { scope: 'col', text: 'Policy' }),
    el('th', { scope: 'col', text: 'Set to' })
  ]));
  const body = el('tbody');
  for (const row of rows) {
    const policy = el('td', { text: row.policy });
    if (row.meaning) policy.append(el('span', { class: 'meaning', text: row.meaning }));
    body.append(el('tr', {}, [el('td', { text: row.path }), policy, el('td', { text: row.state })]));
  }
  table.append(head, body);
  root.append(el('div', { class: 'table-wrap' }, table));
}

// ---------------------------------------------------------------- Autodesk products panel
function switchId(category) {
  return 'p-' + category.enabled.id;
}

function knobField(knob) {
  const setting = knob.setting;
  const id = 'p-' + setting.id;
  const hintId = id + '-hint';
  const errorId = id + '-error';
  const unit = knob.unit ? ` (${knob.unit})` : '';
  const input = el('input', {
    id,
    type: 'text',
    inputmode: 'numeric',
    autocomplete: 'off',
    spellcheck: 'false',
    placeholder: String(setting.default),
    'aria-describedby': `${hintId} ${errorId}`
  });
  input.dataset.setting = setting.id;
  input.value = Object.prototype.hasOwnProperty.call(state.values, setting.id) ? String(state.values[setting.id]) : '';
  const range = typeof setting.min === 'number' ? ` Allowed: ${setting.min} to ${setting.max}.` : '';
  // The label carries the unit, so the hint states the bare number.
  const hint = `${knob.help} Default: ${setting.default}.${range}`.trim();
  return el('div', { class: 'field knob' }, [
    el('label', { for: id, text: knob.label + unit }),
    input,
    el('p', { class: 'hint', id: hintId, text: hint }),
    el('p', { class: 'error', id: errorId, hidden: true })
  ]);
}

function renderProducts() {
  const root = $('#product-fields');
  root.replaceChildren();
  for (const product of state.products.products) {
    const fieldset = el('fieldset', { class: 'product' }, el('legend', { text: product.name }));
    for (const category of product.categories) {
      const info = category.info;
      const id = switchId(category);
      const defaultOn = Number(category.enabled.default) === 1;
      const toggle = el('input', { type: 'checkbox', id, role: 'switch', 'aria-describedby': `${id}-desc ${id}-default` });
      toggle.dataset.switch = category.enabled.id;
      const head = el('div', { class: 'category-head' }, [
        el('span', { class: 'switch' }, [toggle, el('label', { for: id, text: info.displayName || info.id })]),
        el('span', { class: 'category-meta' }, [
          info.risk ? riskBadge(info.risk) : null,
          el('span', { class: 'category-default', id: `${id}-default`, text: `Default: ${defaultOn ? 'on' : 'off'}` })
        ])
      ]);
      const row = el('div', { class: 'category', 'data-category': info.id }, [
        head,
        el('p', { class: 'category-desc', id: `${id}-desc`, text: info.description || '' })
      ]);
      if (category.offReason) row.append(el('p', { class: 'category-reason', 'data-off-reason': '', text: category.offReason }));
      row.append(el('p', { class: 'category-warning', 'data-warning': '', 'aria-live': 'polite' }));
      const knobs = el('div', { class: 'knobs fields', 'data-knobs': '' });
      for (const knob of category.knobs) knobs.append(knobField(knob));
      row.append(knobs);
      fieldset.append(row);
    }
    root.append(fieldset);
  }
  refreshProducts();
}

// Switch state, knob visibility and warnings follow state.values (they may change from All settings).
function refreshProducts() {
  if (!state.products) return;
  for (const product of state.products.products) {
    for (const category of product.categories) {
      const row = document.querySelector(`[data-category="${category.info.id}"]`);
      if (!row) continue;
      const on = isCategoryOn(category.enabled, state.values);
      const defaultOn = Number(category.enabled.default) === 1;
      row.querySelector('[data-switch]').checked = on;
      row.classList.toggle('is-off', !on);
      row.querySelector('[data-knobs]').hidden = !on || category.knobs.length === 0;
      const reason = row.querySelector('[data-off-reason]');
      if (reason) reason.hidden = on;
      let warning = '';
      if (on && !defaultOn) warning = category.onWarning;
      if (!on && defaultOn) warning = category.offWarning || 'Off: DeadLoad no longer acts on this category.';
      const box = row.querySelector('[data-warning]');
      if (box.textContent !== warning) box.textContent = warning;
      box.hidden = warning === '';
    }
  }
}

// Writes one setting and shows it in every other control bound to it.
function setValue(id, value, source) {
  state.values[id] = value;
  for (const control of document.querySelectorAll(`[data-setting="${id}"]`)) {
    if (control !== source) control.value = value;
  }
  update();
}

function update() {
  if (!state.catalog) return;
  const result = buildChanges(state.catalog, { preset: state.preset || null, values: state.values });
  syncFieldErrors(result);

  const gpoValid = /^[\x20-\x7E]*$/.test(state.gpoName);
  const gpoError = $('#gpo-name-error');
  gpoError.textContent = gpoValid ? '' : 'Use printable ASCII characters only.';
  gpoError.hidden = gpoValid;
  const options = { gpoName: gpoValid ? state.gpoName.trim() : '', trayScope: state.trayScope, preset: state.preset || null, labels: state.labels };

  const changes = result.changes;
  state.outputs.ps = toPowerShell(changes, options);
  state.outputs.reg = toRegFile(changes, options);
  state.outputs.gpmc = toGpmcText(changes, options);
  $('#out-ps').textContent = state.outputs.ps;
  $('#out-reg').textContent = state.outputs.reg;
  renderGpmcTable(changes);

  refreshProducts();

  const summary = $('#summary');
  if (changes.length === 0) summary.textContent = 'Nothing to set: the defaults apply.';
  else summary.textContent = `${changes.length} value${changes.length === 1 ? '' : 's'} to set.`;
  const errors = $('#errors');
  errors.replaceChildren();
  for (const { setting, error } of result.errors) {
    const link = el('a', { href: '#' + fieldId(setting), text: setting.display });
    link.addEventListener('click', (event) => {
      event.preventDefault();
      const target = document.getElementById(fieldId(setting));
      const details = target.closest('details');
      if (details) details.open = true;
      const outer = details ? details.parentElement.closest('details') : null;
      if (outer) outer.open = true;
      target.focus();
    });
    errors.append(el('li', {}, [link, ` is not used: ${error}`]));
  }
  errors.hidden = result.errors.length === 0;
  if (result.errors.length === 1) summary.textContent += ' 1 value needs fixing and is left out.';
  else if (result.errors.length > 1) summary.textContent += ` ${result.errors.length} values need fixing and are left out.`;
}

function applyPreset(preset) {
  const previous = state.preset && PRESETS[state.preset] ? PRESETS[state.preset].values : {};
  for (const id of Object.keys(previous)) delete state.values[id];
  state.preset = preset;
  const next = preset && PRESETS[preset] ? PRESETS[preset].values : {};
  for (const [id, value] of Object.entries(next)) state.values[id] = value;
  for (const control of document.querySelectorAll('[data-setting]')) {
    const id = control.dataset.setting;
    control.value = Object.prototype.hasOwnProperty.call(state.values, id) ? String(state.values[id]) : '';
  }
  update();
}

function setupTabs() {
  const tabs = Array.from(document.querySelectorAll('[role="tab"]'));
  const select = (tab, focus) => {
    for (const other of tabs) {
      const selected = other === tab;
      other.setAttribute('aria-selected', String(selected));
      other.tabIndex = selected ? 0 : -1;
      document.getElementById(other.getAttribute('aria-controls')).hidden = !selected;
    }
    if (focus) tab.focus();
  };
  tabs.forEach((tab, index) => {
    tab.addEventListener('click', () => select(tab, false));
    tab.addEventListener('keydown', (event) => {
      let next = null;
      if (event.key === 'ArrowRight') next = tabs[(index + 1) % tabs.length];
      else if (event.key === 'ArrowLeft') next = tabs[(index - 1 + tabs.length) % tabs.length];
      else if (event.key === 'Home') next = tabs[0];
      else if (event.key === 'End') next = tabs[tabs.length - 1];
      if (next) {
        event.preventDefault();
        select(next, true);
      }
    });
  });
}

const FILES = {
  ps: { name: 'Set-DeadLoadPolicy.ps1', label: 'PowerShell script' },
  reg: { name: 'DeadLoad-policy.reg', label: '.reg file' },
  gpmc: { name: 'DeadLoad-policy-gpmc.txt', label: 'GPMC table' }
};

async function copy(kind) {
  const status = $('#copy-status');
  const text = state.outputs[kind];
  try {
    await navigator.clipboard.writeText(text);
    status.textContent = `${FILES[kind].label} copied.`;
  } catch {
    const area = el('textarea', { 'aria-hidden': 'true', readonly: true });
    area.value = text;
    area.style.position = 'fixed';
    area.style.opacity = '0';
    document.body.append(area);
    area.select();
    const ok = document.execCommand && document.execCommand('copy');
    area.remove();
    status.textContent = ok ? `${FILES[kind].label} copied.` : 'Copy is not available here: select the text and copy it.';
  }
}

function download(kind) {
  const blob = new Blob([state.outputs[kind]], { type: 'text/plain' });
  const url = URL.createObjectURL(blob);
  const link = el('a', { href: url, download: FILES[kind].name });
  document.body.append(link);
  link.click();
  link.remove();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  $('#copy-status').textContent = `${FILES[kind].name} saved by your browser.`;
}

function wire() {
  const form = $('#generator');
  form.addEventListener('submit', (event) => event.preventDefault());
  form.addEventListener('input', (event) => {
    const target = event.target;
    if (target.dataset && target.dataset.setting) {
      setValue(target.dataset.setting, target.value, target);
    } else if (target.id === 'gpo-name') {
      state.gpoName = target.value;
      update();
    }
  });
  form.addEventListener('change', (event) => {
    const target = event.target;
    if (target.name === 'preset') applyPreset(target.value);
    else if (target.name === 'tray-scope') {
      state.trayScope = target.value;
      update();
    } else if (target.dataset && target.dataset.switch) {
      const enabled = state.catalog.settings.find((s) => s.id === target.dataset.switch);
      setValue(enabled.id, switchValue(enabled, target.checked), null);
    } else if (target.dataset && target.dataset.setting) {
      setValue(target.dataset.setting, target.value, target);
    }
  });
  $('#reset').addEventListener('click', () => {
    state.values = {};
    const preset = state.preset;
    state.preset = null;
    applyPreset(preset);
  });
  for (const button of document.querySelectorAll('[data-copy]')) button.addEventListener('click', () => copy(button.dataset.copy));
  for (const button of document.querySelectorAll('[data-download]')) button.addEventListener('click', () => download(button.dataset.download));
  setupTabs();
}

async function start() {
  for (const node of document.querySelectorAll('[data-preset-summary]')) {
    const preset = PRESETS[node.dataset.presetSummary];
    if (preset) node.textContent = preset.summary;
  }
  wire();
  try {
    const response = await fetch('data/settings.json', { cache: 'no-cache' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    state.catalog = await response.json();
  } catch (error) {
    const box = $('#load-error');
    box.textContent = 'The settings catalog (data/settings.json) could not be loaded. Open this page from a web server (GitHub Pages, or a local one such as "python -m http.server" in the site folder), not as a file. Detail: ' + error.message;
    box.hidden = false;
    return;
  }
  try {
    const response = await fetch('data/product-groups.json', { cache: 'no-cache' });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    state.products = resolveProductGroups(state.catalog, await response.json());
    state.labels = productLabels(state.products);
  } catch (error) {
    // The rest of the generator works without the curated panel; All settings has every value.
    state.products = null;
    $('#products-panel').hidden = true;
  }
  const checked = document.querySelector('input[name="preset"]:checked');
  state.preset = checked ? checked.value : 'pilot';
  for (const [id, value] of Object.entries(PRESETS[state.preset] ? PRESETS[state.preset].values : {})) state.values[id] = value;
  renderCommon();
  if (state.products) renderProducts();
  renderAll();
  update();
}

start();
