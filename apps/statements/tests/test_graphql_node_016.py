"""sql/016 in the GraphQL twins and the Sheets add-on: transfer fields, excludeTransfers."""

from __future__ import annotations

import json
import subprocess

from statements import graphql_api
from test_graphql_node import (
    CORE_TS,
    ESBUILD,
    NODE,
    ROOT,
    _apps_script,
    needs_bundle,
    needs_node,
)


def test_python_schema_has_transfer_fields_and_argument():
    prepared = graphql_api.prepare(
        json.dumps(
            {
                "query": "{ movements(kind: DEBIT, layer: OPEN, excludeTransfers: true) "
                "{ is_internal_transfer transfer_link_hash transfer_role transfer_type transfer_source "
                "transfer_counterpart_account } }"
            }
        )
    )
    assert prepared.root_fields == 1


@needs_bundle
def test_typescript_passes_exclude_transfers_and_defaults_the_flag(tmp_path):
    bundle = tmp_path / "core.cjs"
    subprocess.run(
        [
            str(ESBUILD),
            str(CORE_TS),
            "--bundle",
            "--platform=node",
            "--format=cjs",
            f"--outfile={bundle}",
        ],
        check=True,
        capture_output=True,
        cwd=ROOT / "infra",
    )
    script = f"""
const core = require({str(bundle)!r});
(async () => {{
  const query = `{{
    a: movements(kind: DEBIT, layer: OPEN, excludeTransfers: true) {{ txn_date is_internal_transfer }}
    b: movements(kind: CREDIT, layer: OPEN) {{ txn_date is_internal_transfer transfer_type }}
  }}`;
  const calls = [];
  const fake = async (table, months, upcoming, limit, exclude) => {{
    calls.push([table, exclude]);
    return table === 'master_debit_open_f'
      ? [{{ txn_date: '2026-11-01' }}]
      : [{{ txn_date: '2026-11-02', is_internal_transfer: true, transfer_type: 'same_bank' }}];
  }};
  const usage = {{ used: 1, limit: 3, window: 'day', resets_at: 'x', max_rows: 50 }};
  const result = await core.run(core.prepare(JSON.stringify({{ query }})), fake, usage);
  console.log(JSON.stringify({{ calls, data: result.body.data }}));
}})().catch((error) => {{ console.error(error); process.exit(1); }});
"""
    done = subprocess.run(
        [NODE, "-e", script], check=False, capture_output=True, text=True
    )
    assert done.returncode == 0, done.stderr
    out = json.loads(done.stdout)
    assert out["calls"] == [
        ["master_debit_open_f", True],
        ["master_credit_open_f", False],
    ]
    assert out["data"]["a"] == [
        {"txn_date": "2026-11-01", "is_internal_transfer": False}
    ]
    assert out["data"]["b"] == [
        {
            "txn_date": "2026-11-02",
            "is_internal_transfer": True,
            "transfer_type": "same_bank",
        }
    ]


@needs_node
def test_apps_script_exclude_transfers_column():
    tail = """
const tabs = [
  ['debit', 'DEBIT', 'CLOSED', 3, 'txn_date,cargos,is_internal_transfer', 'yes'],
  ['debit_all', 'DEBIT', 'OPEN', '', 'txn_date,transfer_type', ''],
];
vm.runInContext('createConfigTab()', context);
const built = vm.runInContext('buildQuery(' + JSON.stringify(tabs) + ')', context);
console.log(JSON.stringify({ built, config: sheets['API config'].values }));
"""
    out = _apps_script({}, 200, tail)
    query = out["built"]["query"]
    assert (
        "t0: movements(kind: DEBIT, layer: CLOSED, months: 3, excludeTransfers: true)"
        in query
    )
    assert "t1: movements(kind: DEBIT, layer: OPEN) {" in query
    assert graphql_api.prepare(json.dumps({"query": query})).root_fields == 3
    assert out["config"][0] == [
        "tab",
        "kind",
        "layer",
        "months",
        "columns",
        "exclude_transfers",
    ]
    assert all(len(row) == 6 for row in out["config"])
