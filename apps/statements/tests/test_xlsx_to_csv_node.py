"""Run web/xlsx_to_csv.js against BBVA fixtures via Node (no browser)."""

import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[3]
FIX = Path(__file__).parent / "fixtures"
JS = ROOT / "web" / "xlsx_to_csv.js"

NODE = shutil.which("node")


@pytest.mark.skipif(NODE is None, reason="node not installed")
def test_bbva_xlsx_to_csv_skips_sections_and_keeps_movements():
    script = f"""
const fs = require('fs');
eval(fs.readFileSync({str(JS)!r}, 'utf8'));
(async () => {{
  const debit = fs.readFileSync({str(FIX / 'bbva_debit_2026-09.xlsx')!r});
  const credit = fs.readFileSync({str(FIX / 'bbva_credit_2026-09.xlsx')!r});
  const d = await strmXlsxToCsv(debit.buffer.slice(debit.byteOffset, debit.byteOffset + debit.byteLength));
  const c = await strmXlsxToCsv(credit.buffer.slice(credit.byteOffset, credit.byteOffset + credit.byteLength));
  if (!d.includes('FECHA') || !d.includes('PAGO TARJETA')) throw new Error('debit csv bad');
  if (/Digital|Titular/i.test(d+c)) throw new Error('section leaked');
  if (!c.includes('FIESTA REWARDS') || !c.includes('BMOVIL')) throw new Error('credit csv bad');
  if (!c.includes('-6157.93')) throw new Error('credit payment sign missing');
  console.log('ok');
}})().catch((e) => {{ console.error(e); process.exit(1); }});
"""
    result = subprocess.run([NODE, "-e", script], check=False, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert "ok" in result.stdout
