/**
 * Google Sheets <- banking_accounts_data GraphQL API (sql/015, docs/graphql.md).
 *
 * Setup: Extensions > Apps Script, paste this file, save, reload the sheet.
 *   Bank data > Set API URL    (the graphql-url of your environment, ends in /graphql)
 *   Bank data > Set API token  (create it in the app: API tokens; kept in Script Properties)
 *   Bank data > Create config tab (optional: pick tabs, months and columns per tab)
 *   Bank data > Refresh all    (ONE API call for every tab, so a weekly quota is enough)
 */

var CONFIG_SHEET = 'API config';
var USAGE_KEY = 'BANK_API_LAST_USAGE';

var FIELDS = [
  'row_hash', 'table', 'layer', 'kind', 'row_id', 'account_id', 'account_number', 'bank_id', 'bank_name',
  'period_start', 'period_end', 'txn_date', 'concept', 'concept_sk', 'abonos', 'cargos', 'amount',
  'occurrence', 'file_name', 'source_profile', 'balance', 'entry_source', 'cutoff_id',
  'attribute_1', 'attribute_2', 'attribute_3',
  'is_internal_transfer', 'transfer_link_hash', 'transfer_role', 'transfer_type', 'transfer_source',
  'transfer_counterpart_account'
];

var COMMON = 'account_number,bank_name,txn_date,concept_sk,abonos,cargos';
var ATTRIBUTES = 'attribute_1,attribute_2,attribute_3';

// tab name | kind | layer | months (closed: blank = last 12; open/future: blank = all) | columns
// ASSET / CLOSED is the investments and assets table (sql/017); balance = account balance after
// each row, counted over the full history even when months is set (every tab since sql/018).
// Debit cargos are negative. Credit and asset cargos are positive. amount is abonos + cargos
// on a debit tab and abonos - cargos on credit and asset tabs (money in is positive; on a
// card a purchase is negative). entry_source: upload / manual / opening / adjustment.
// | exclude_transfers (config tab only, optional: yes = leave out movements linked as
//   transfers between your accounts, sql/016)
var DEFAULT_TABS = [
  ['master_credit_closed_f', 'CREDIT', 'CLOSED', 3, COMMON + ',' + ATTRIBUTES],
  ['master_credit_open_f', 'CREDIT', 'OPEN', '', COMMON + ',' + ATTRIBUTES],
  ['master_debit_closed_f', 'DEBIT', 'CLOSED', 3, COMMON + ',' + ATTRIBUTES],
  ['master_debit_open_f', 'DEBIT', 'OPEN', '', COMMON + ',' + ATTRIBUTES],
  ['master_credit_future_f', 'CREDIT', 'FUTURE', '', COMMON + ',' + ATTRIBUTES],
  ['master_closed_aaccandass_f', 'ASSET', 'CLOSED', 12, COMMON + ',balance,source_profile,' + ATTRIBUTES],
  ['master_open_aaccandass_f', 'ASSET', 'OPEN', '', COMMON + ',balance,source_profile,' + ATTRIBUTES]
];

function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu('Bank data')
    .addItem('Refresh all', 'refreshAll')
    .addSeparator()
    .addItem('Set API URL', 'setApiUrl')
    .addItem('Set API token', 'setApiToken')
    .addItem('Create config tab', 'createConfigTab')
    .addItem('Show last usage', 'showUsage')
    .addToUi();
}

function setApiUrl() {
  var ui = SpreadsheetApp.getUi();
  var answer = ui.prompt('API URL', 'Paste the GraphQL URL (ends in /graphql):', ui.ButtonSet.OK_CANCEL);
  if (answer.getSelectedButton() !== ui.Button.OK) return;
  var url = String(answer.getResponseText()).trim();
  if (!/^https:\/\/.+\/graphql$/.test(url)) {
    ui.alert('The URL must start with https:// and end in /graphql.');
    return;
  }
  PropertiesService.getScriptProperties().setProperty('BANK_API_URL', url);
}

function setApiToken() {
  var ui = SpreadsheetApp.getUi();
  var answer = ui.prompt('API token', 'Paste the token from the app (starts with bst_):', ui.ButtonSet.OK_CANCEL);
  if (answer.getSelectedButton() !== ui.Button.OK) return;
  var token = String(answer.getResponseText()).trim();
  if (!/^bst_[0-9a-f]{48}$/.test(token)) {
    ui.alert('That does not look like an API token (bst_ followed by 48 characters).');
    return;
  }
  PropertiesService.getScriptProperties().setProperty('BANK_API_TOKEN', token);
}

function createConfigTab() {
  var book = SpreadsheetApp.getActiveSpreadsheet();
  var sheet = book.getSheetByName(CONFIG_SHEET) || book.insertSheet(CONFIG_SHEET);
  sheet.clearContents();
  var rows = [['tab', 'kind', 'layer', 'months', 'columns', 'exclude_transfers']].concat(
    DEFAULT_TABS.map(function (tab) { return tab.slice(0, 5).concat(['']); })
  );
  sheet.getRange(1, 1, rows.length, 6).setValues(rows);
  sheet.setFrozenRows(1);
}

function readTabs_() {
  var sheet = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(CONFIG_SHEET);
  if (!sheet) return DEFAULT_TABS;
  var values = sheet.getDataRange().getValues().slice(1);
  var tabs = values.filter(function (row) { return String(row[0]).trim() !== ''; });
  return tabs.length ? tabs : DEFAULT_TABS;
}

/** Builds the single GraphQL request for every configured tab. Pure: no API call. */
function buildQuery(tabs) {
  if (tabs.length > 7) throw new Error('At most 7 tabs per refresh');
  var parts = [];
  var plan = [];
  tabs.forEach(function (tab, index) {
    var name = String(tab[0]).trim();
    var kind = String(tab[1]).trim().toUpperCase();
    var layer = String(tab[2]).trim().toUpperCase();
    var months = String(tab[3]).trim();
    var columns = String(tab[4]).split(',').map(function (item) { return item.trim(); })
      .filter(function (item) { return item !== ''; });
    if (['DEBIT', 'CREDIT', 'ASSET'].indexOf(kind) < 0) throw new Error(name + ': kind must be DEBIT, CREDIT or ASSET');
    if (['CLOSED', 'OPEN', 'FUTURE'].indexOf(layer) < 0) throw new Error(name + ': layer must be CLOSED, OPEN or FUTURE');
    if (kind === 'DEBIT' && layer === 'FUTURE') throw new Error(name + ': there is no debit future table');
    if (kind === 'ASSET' && layer === 'FUTURE') throw new Error(name + ': investments and assets have no future table');
    if (months !== '' && !/^\d+$/.test(months)) throw new Error(name + ': months must be a whole number');
    if (!columns.length) throw new Error(name + ': list at least one column');
    columns.forEach(function (column) {
      if (FIELDS.indexOf(column) < 0) throw new Error(name + ': unknown column ' + column);
    });
    var exclude = /^(yes|y|true|si|sí|1)$/i.test(String(tab[5] === undefined ? '' : tab[5]).trim());
    var alias = 't' + index;
    var args = 'kind: ' + kind + ', layer: ' + layer + (months !== '' ? ', months: ' + Number(months) : '') + (layer === 'FUTURE' ? ', upcomingOnly: true' : '') + (exclude ? ', excludeTransfers: true' : '');
    parts.push(alias + ': movements(' + args + ') { ' + columns.join(' ') + ' }');
    plan.push({ alias: alias, name: name, columns: columns });
  });
  parts.push('usage { used limit remaining window resets_at }');
  return { query: 'query RefreshAll { ' + parts.join(' ') + ' }', plan: plan };
}

function writeTab_(book, name, columns, rows) {
  var sheet = book.getSheetByName(name) || book.insertSheet(name);
  sheet.clearContents();
  var values = [columns].concat(rows.map(function (row) {
    return columns.map(function (column) { return row[column] === null || row[column] === undefined ? '' : row[column]; });
  }));
  sheet.getRange(1, 1, values.length, columns.length).setValues(values);
  sheet.setFrozenRows(1);
}

function usageText_(usage) {
  if (!usage) return 'No API usage recorded yet.';
  return 'API calls: ' + usage.used + ' of ' + usage.limit + ' this ' + usage.window + '. Resets at ' + usage.resets_at + '.';
}

/** Bank data > Refresh all: one request, then every tab is rewritten. */
function refreshAll() {
  var props = PropertiesService.getScriptProperties();
  var url = props.getProperty('BANK_API_URL');
  var token = props.getProperty('BANK_API_TOKEN');
  var ui = SpreadsheetApp.getUi();
  if (!url || !token) {
    ui.alert('Set the API URL and token first (Bank data menu).');
    return;
  }
  var built = buildQuery(readTabs_());
  var response = UrlFetchApp.fetch(url, {
    method: 'post',
    contentType: 'application/json',
    headers: { Authorization: 'Bearer ' + token },
    payload: JSON.stringify({ query: built.query, operationName: 'RefreshAll' }),
    muteHttpExceptions: true
  });
  var status = response.getResponseCode();
  var body = {};
  try { body = JSON.parse(response.getContentText() || '{}'); } catch (error) { body = {}; }
  if (status === 429) {
    ui.alert('API limit reached', body.error || 'Try again after the quota resets.', ui.ButtonSet.OK);
    return;
  }
  if (status !== 200) {
    ui.alert('The API answered ' + status + ': ' + (body.error || 'unknown error'));
    return;
  }
  if (!body.data) {
    ui.alert('The API returned no data: ' + JSON.stringify(body.errors || []));
    return;
  }
  var book = SpreadsheetApp.getActiveSpreadsheet();
  built.plan.forEach(function (tab) {
    writeTab_(book, tab.name, tab.columns, body.data[tab.alias] || []);
  });
  var usage = body.data.usage || (body.extensions && body.extensions.usage);
  if (usage) PropertiesService.getDocumentProperties().setProperty(USAGE_KEY, JSON.stringify(usage));
  var notes = [];
  if (body.errors && body.errors.length) notes.push('Some tabs failed: ' + body.errors.map(function (e) { return e.message; }).join('; '));
  var truncated = body.extensions && body.extensions.truncated;
  if (truncated && truncated.length) notes.push('Row limit reached; cut tabs: ' + truncated.join(', '));
  book.toast(usageText_(usage) + (notes.length ? ' ' + notes.join(' ') : ''), 'Bank data refreshed', 10);
}

/** Shows the usage saved by the last refresh. Does not call the API. */
function showUsage() {
  var saved = PropertiesService.getDocumentProperties().getProperty(USAGE_KEY);
  SpreadsheetApp.getUi().alert(usageText_(saved ? JSON.parse(saved) : null));
}
