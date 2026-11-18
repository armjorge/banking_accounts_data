"""The Lambda GraphQL core (TypeScript) and the Apps Script, run with Node, against the
Python twin. Skips when node or infra/node_modules (esbuild, graphql) are missing."""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from pathlib import Path

import pytest
from statements import graphql_api

ROOT = Path(__file__).resolve().parents[3]
CORE_TS = ROOT / "infra" / "lambda" / "graphql-core.ts"
APPS_SCRIPT = ROOT / "integrations" / "google_sheets" / "Code.gs"
ESBUILD = ROOT / "infra" / "node_modules" / ".bin" / "esbuild"
GRAPHQL_JS = ROOT / "infra" / "node_modules" / "graphql" / "package.json"
NODE = shutil.which("node")

needs_node = pytest.mark.skipif(NODE is None, reason="node not installed")
needs_bundle = pytest.mark.skipif(
    NODE is None or not ESBUILD.exists() or not GRAPHQL_JS.exists(),
    reason="node, esbuild or graphql missing in infra/node_modules (run npm ci in infra)",
)

GUARD_CASES = [
    "not json",
    json.dumps({"query": "{ movements(kind: DEBIT, layer: OPEN) { nope } }"}),
    json.dumps({"query": "mutation { x }"}),
    json.dumps({"query": "{ __schema { types { name } } }"}),
    json.dumps({"query": "{ " + " ".join(f"a{i}: usage {{ used }}" for i in range(9)) + " }"}),
    json.dumps({"query": "{ usage { used } }", "pad": "x" * 20000}),
    json.dumps({"query": "{ a: usage { used } } { b: usage { used } }"}),
    json.dumps({"query": "{ usage { used " + "used " * 300 + "} }"}),
    json.dumps({"query": "fragment F on Usage { used } { usage { ...F limit } }"}),
    json.dumps({"query": "{ movements(kind: CREDIT, layer: FUTURE) { txn_date cargos } }"}),
]


def _python_outcome(body: str) -> list:
    try:
        prepared = graphql_api.prepare(body)
    except graphql_api.ApiError as exc:
        return [exc.status, exc.message]
    return [200, prepared.root_fields]


def test_sdl_and_limits_match_python():
    ts = CORE_TS.read_text(encoding="utf-8")
    sdl = re.search(r"export const SDL = `(.*?)`;", ts, re.DOTALL).group(1)
    assert sdl == graphql_api.SDL
    for name in ("MAX_BODY_BYTES", "MAX_QUERY_CHARS", "MAX_DEPTH", "MAX_ROOT_FIELDS", "MAX_FIELDS",
                 "MAX_RESPONSE_BYTES", "DEFAULT_CLOSED_MONTHS"):
        value = re.search(rf"export const {name} = ([\d_]+);", ts).group(1)
        assert int(value.replace("_", "")) == getattr(graphql_api, name), name
    assert re.search(r"TOKEN_RE = /(.*?)/;", ts).group(1) == graphql_api.TOKEN_RE.pattern.replace("\\", "\\")


@needs_bundle
def test_typescript_core_matches_python(tmp_path):
    bundle = tmp_path / "core.cjs"
    subprocess.run(
        [str(ESBUILD), str(CORE_TS), "--bundle", "--platform=node", "--format=cjs", f"--outfile={bundle}"],
        check=True, capture_output=True, cwd=ROOT / "infra",
    )
    cases = tmp_path / "cases.json"
    cases.write_text(json.dumps(GUARD_CASES), encoding="utf-8")
    script = f"""
const core = require({str(bundle)!r});
const cases = JSON.parse(require('fs').readFileSync({str(cases)!r}, 'utf8'));
(async () => {{
  const outcomes = cases.map((body) => {{
    try {{ return [200, core.prepare(body).rootFields]; }}
    catch (error) {{ return [error.status, error.message]; }}
  }});
  const query = `query R {{
    debitClosed: movements(kind: DEBIT, layer: CLOSED) {{ txn_date }}
    debitOpen: movements(kind: DEBIT, layer: OPEN) {{ txn_date }}
    bad: movements(kind: DEBIT, layer: FUTURE) {{ txn_date }}
    creditFuture: movements(kind: CREDIT, layer: FUTURE, upcomingOnly: true) {{ txn_date }}
    usage {{ used limit window resets_at }}
  }}`;
  const calls = [];
  const fake = async (table, months, upcoming, limit) => {{
    calls.push([table, months, upcoming, limit]);
    return Array.from({{ length: 3 }}, (_, i) => ({{ txn_date: `2026-11-0${{i + 1}}`, extra: 'hidden' }}));
  }};
  const usage = {{ used: 1, limit: 3, window: 'day', resets_at: '2026-11-13T00:00:00-06:00', max_rows: 5 }};
  const result = await core.run(core.prepare(JSON.stringify({{ query }})), fake, usage);
  const over = core.overQuotaBody({{ plan_name: 'Free', limit: 1, used: 1, window: 'week', resets_at: '2026-11-16T00:00:00-06:00' }});
  console.log(JSON.stringify({{ outcomes, calls, result, over }}));
}})().catch((error) => {{ console.error(error); process.exit(1); }});
"""
    done = subprocess.run([NODE, "-e", script], check=False, capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    out = json.loads(done.stdout)
    # graphql-js and graphql-core quote names differently in validation messages.
    def same_quotes(items):
        return [[status, str(text).replace("'", '"')] for status, text in items]

    assert same_quotes(out["outcomes"]) == same_quotes([_python_outcome(body) for body in GUARD_CASES])
    assert out["calls"] == [
        ["master_debit_closed_f", 12, False, 6],
        ["master_debit_open_f", None, False, 3],
    ]  # creditFuture: the row budget is spent, so no query at all
    data = out["result"]["body"]["data"]
    assert data["debitClosed"] == [{"txn_date": "2026-11-01"}, {"txn_date": "2026-11-02"}, {"txn_date": "2026-11-03"}]
    assert data["debitOpen"] == [{"txn_date": "2026-11-02"}, {"txn_date": "2026-11-03"}]
    assert data["creditFuture"] == []
    assert data["bad"] is None
    assert out["result"]["body"]["errors"][0]["message"] == "bad: there is no debit future table"
    assert out["result"]["truncated"] == ["debitOpen", "creditFuture"]
    assert out["result"]["rowCount"] == 5
    assert data["usage"] == {"used": 1, "limit": 3, "window": "day", "resets_at": "2026-11-13T00:00:00-06:00"}
    python_over = graphql_api.over_quota_body(
        {"plan_name": "Free", "limit": 1, "used": 1, "window": "week", "resets_at": "2026-11-16T00:00:00-06:00"}
    )
    assert out["over"] == python_over
    assert python_over["error"] == (
        "API limit reached: your Free plan allows 1 call per week. It resets at 2026-11-16T00:00:00-06:00."
    )


APPS_STUBS = """
const fs = require('fs');
const vm = require('vm');
const fetches = [];
const sheets = {};
const alerts = [];
const toasts = [];
const props = { BANK_API_URL: 'https://example.test/graphql', BANK_API_TOKEN: 'bst_' + 'a'.repeat(48) };
const docProps = {};
function makeSheet(name) {
  const sheet = { name, values: [['old']], frozen: 0,
    clearContents() { this.values = []; },
    getRange(r, c, nr, nc) { const self = this; return { setValues(v) {
      if (v.length !== nr || v.some((row) => row.length !== nc)) throw new Error('range size');
      self.values = v; } }; },
    setFrozenRows(n) { this.frozen = n; },
    getDataRange() { const self = this; return { getValues() { return self.values; } }; } };
  sheets[name] = sheet; return sheet;
}
const context = {
  SpreadsheetApp: {
    getActiveSpreadsheet: () => ({ getSheetByName: (n) => sheets[n] || null, insertSheet: makeSheet,
      toast: (text) => toasts.push(text) }),
    getUi: () => ({ alert: (...args) => alerts.push(args.join(' | ')), ButtonSet: { OK: 'OK' } }),
  },
  PropertiesService: {
    getScriptProperties: () => ({ getProperty: (k) => props[k] || null, setProperty: (k, v) => { props[k] = v; } }),
    getDocumentProperties: () => ({ getProperty: (k) => docProps[k] || null, setProperty: (k, v) => { docProps[k] = v; } }),
  },
  UrlFetchApp: { fetch: (url, options) => { fetches.push([url, options]); return RESPONSE; } },
  JSON, console,
};
vm.createContext(context);
vm.runInContext(fs.readFileSync(SCRIPT, 'utf8'), context);
"""


def _apps_script(response: dict, status: int, tail: str) -> dict:
    script = (
        f"const SCRIPT = {str(APPS_SCRIPT)!r};\n"
        f"const RESPONSE = {{ getResponseCode: () => {status}, getContentText: () => {json.dumps(json.dumps(response))} }};\n"
        + APPS_STUBS
        + tail
    )
    done = subprocess.run([NODE, "-e", script], check=False, capture_output=True, text=True)
    assert done.returncode == 0, done.stderr
    return json.loads(done.stdout)


@needs_node
def test_apps_script_default_query_is_one_valid_request():
    out = _apps_script({}, 200, "console.log(JSON.stringify(vm.runInContext('buildQuery(DEFAULT_TABS)', context)));")
    prepared = graphql_api.prepare(json.dumps({"query": out["query"], "operationName": "RefreshAll"}))
    # Seven default tabs (sql/019 adds the open asset table) plus usage.
    assert prepared.root_fields == 8
    assert [tab["alias"] for tab in out["plan"]] == ["t0", "t1", "t2", "t3", "t4", "t5", "t6"]
    assert "t0: movements(kind: CREDIT, layer: CLOSED, months: 3)" in out["query"]
    assert "t4: movements(kind: CREDIT, layer: FUTURE, upcomingOnly: true)" in out["query"]
    assert "t5: movements(kind: ASSET, layer: CLOSED, months: 12)" in out["query"]
    assert "t6: movements(kind: ASSET, layer: OPEN)" in out["query"]


@needs_node
def test_apps_script_refresh_all_fetches_once_and_rewrites_tabs():
    rows = {f"t{i}": [{"txn_date": f"2026-11-0{i + 1}", "concept_sk": "X", "cargos": 1.5, "abonos": None}]
            for i in range(7)}
    usage = {"used": 1, "limit": 1, "remaining": 0, "window": "week", "resets_at": "2026-11-16T00:00:00-06:00"}
    tail = """
makeSheet('master_debit_closed_f');
vm.runInContext('refreshAll()', context);
console.log(JSON.stringify({ fetches, sheets, alerts, toasts, docProps }));
"""
    out = _apps_script({"data": {**rows, "usage": usage}, "extensions": {"truncated": []}}, 200, tail)
    assert len(out["fetches"]) == 1
    url, options = out["fetches"][0]
    assert url == "https://example.test/graphql"
    assert options["headers"]["Authorization"].startswith("Bearer bst_")
    assert options["muteHttpExceptions"] is True
    assert json.loads(options["payload"])["query"].count("movements(") == 7
    debit_closed = out["sheets"]["master_debit_closed_f"]["values"]
    assert debit_closed[0] == ["account_number", "bank_name", "txn_date", "concept_sk", "abonos", "cargos", "attribute_1", "attribute_2", "attribute_3"]
    assert len(debit_closed) == 2 and debit_closed[1][2] == "2026-11-03" and debit_closed[1][4] == ""
    assert set(out["sheets"]) == {
        "master_debit_closed_f", "master_debit_open_f", "master_credit_closed_f", "master_credit_open_f",
        "master_credit_future_f", "master_closed_aaccandass_f", "master_open_aaccandass_f",
    }
    assert "1 of 1 this week" in out["toasts"][0]
    assert json.loads(out["docProps"]["BANK_API_LAST_USAGE"])["resets_at"] == usage["resets_at"]


@needs_node
def test_apps_script_shows_429_and_keeps_tabs():
    body = graphql_api.over_quota_body(
        {"plan_name": "Free", "limit": 1, "used": 1, "window": "week", "resets_at": "2026-11-16T00:00:00-06:00"}
    )
    tail = """
makeSheet('master_debit_closed_f');
vm.runInContext('refreshAll()', context);
console.log(JSON.stringify({ fetches, sheets, alerts }));
"""
    out = _apps_script(body, 429, tail)
    assert len(out["fetches"]) == 1
    assert out["sheets"]["master_debit_closed_f"]["values"] == [["old"]]
    assert "1 call per week" in out["alerts"][0] and "2026-11-16" in out["alerts"][0]
