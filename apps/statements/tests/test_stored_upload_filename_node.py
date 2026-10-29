"""Node checks for strmStoredUploadFilename (BBVA XLSX → CSV naming)."""

from pathlib import Path
import subprocess
import textwrap

ROOT = Path(__file__).resolve().parents[3]
JS = ROOT / "web" / "xlsx_to_csv.js"


def test_stored_upload_filename_bbva_xlsx_gets_bank_account_period():
    script = textwrap.dedent(
        f"""
        const fs = require('fs');
        const vm = require('vm');
        const ctx = {{ globalThis: {{}}, console }};
        ctx.window = ctx;
        ctx.global = ctx;
        vm.createContext(ctx);
        vm.runInContext(fs.readFileSync({str(JS)!r}, 'utf8'), ctx);
        const fn = ctx.strmStoredUploadFilename;
        if (typeof fn !== 'function') throw new Error('missing strmStoredUploadFilename');
        const meta = {{ bank: 'BBVA', accountNumber: '415231', period: '2026-09' }};
        const a = fn('movimientos.xlsx', meta);
        if (a !== 'BBVA_415231_2026-09.csv') throw new Error('xlsx canonical: ' + a);
        const b = fn('bbva_credit_2026-09.xlsx', meta);
        if (b !== 'BBVA_415231_2026-09.csv') throw new Error('xlsx with bank still canonical: ' + b);
        const c = fn('4598 08 HSBC TransactionHistory.csv', {{
          bank: 'HSBC', accountNumber: '45981234', period: '2026-08'
        }});
        if (!c.toLowerCase().endsWith('.csv')) throw new Error('hsbc ext: ' + c);
        if (!c.includes('HSBC') && !c.includes('4598')) throw new Error('hsbc kept: ' + c);
        const d = fn('plain.csv', {{ bank: 'Banorte', accountNumber: '999', period: '2026-10' }});
        if (d !== 'Banorte_999_2026-10.csv') throw new Error('plain csv: ' + d);
        console.log('ok');
        """
    )
    proc = subprocess.run(["node", "-e", script], capture_output=True, text=True, check=False)
    assert proc.returncode == 0, proc.stderr or proc.stdout
    assert "ok" in proc.stdout
