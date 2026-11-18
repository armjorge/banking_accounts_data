"""Local statements API for the preview page. Not deployed and not a substitute for the Lambda."""

from __future__ import annotations

import json
import os
import re
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

import psycopg

from statements import graphql_api

PREVIEW_TOKEN = "preview"
PREVIEW_SUB = "preview-local"
PREVIEW_EMAIL = "preview@example.com"


def _json(value: Any) -> Any:
    if isinstance(value, str):
        return json.loads(value)
    return value


def seed_preview(conn: psycopg.Connection[Any]) -> None:
    with conn.cursor() as cur:
        cur.execute(
            """
            INSERT INTO cognito_users.users (cognito_sub, email)
            VALUES (%s, %s)
            ON CONFLICT (cognito_sub) DO UPDATE SET email = EXCLUDED.email
            RETURNING user_id
            """,
            (PREVIEW_SUB, PREVIEW_EMAIL),
        )
        user_id = cur.fetchone()[0]
        cur.execute("SELECT public.ensure_personal_tenant(%s)", (user_id,))
        cur.execute("SELECT COUNT(*) FROM public.banks_d")
        if cur.fetchone()[0] == 0:
            cur.execute("INSERT INTO public.banks_d (bank_name) VALUES ('Sample bank')")
    conn.commit()


class StatementHandler(BaseHTTPRequestHandler):
    database_url = os.environ.get("DATABASE_URL", "dbname=strm_preview")

    def log_message(self, fmt: str, *args: object) -> None:
        print(f"[statements] {self.address_string()} {fmt % args}")

    def _send(self, status: int, payload: Any, headers: dict[str, str] | None = None) -> None:
        body = json.dumps(payload, default=str).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.send_header("content-length", str(len(body)))
        self._cors()
        self.end_headers()
        self.wfile.write(body)

    def _cors(self) -> None:
        self.send_header("access-control-allow-origin", "*")
        self.send_header("access-control-allow-headers", "authorization, content-type")
        self.send_header("access-control-allow-methods", "GET, POST, DELETE, OPTIONS")

    def do_OPTIONS(self) -> None:  # noqa: N802
        self.send_response(204)
        self._cors()
        self.end_headers()

    def do_GET(self) -> None:  # noqa: N802
        self._route("GET")

    def do_POST(self) -> None:  # noqa: N802
        self._route("POST")

    def do_DELETE(self) -> None:  # noqa: N802
        self._route("DELETE")

    def _authorized(self) -> bool:
        header = self.headers.get("authorization", "")
        return header == f"Bearer {PREVIEW_TOKEN}"

    def _graphql(self) -> None:
        # sql/015: Google Sheets API. Its own read-only token, not the preview sign-in.
        length = int(self.headers.get("content-length") or 0)
        if length > graphql_api.MAX_BODY_BYTES:
            self._send(413, {"error": f"The request is larger than {graphql_api.MAX_BODY_BYTES} bytes"})
            return
        raw = self.rfile.read(length) if length > 0 else b""
        try:
            with psycopg.connect(self.database_url) as conn:
                status, payload, headers = graphql_api.handle(conn, self.headers.get("authorization"), raw)
        except psycopg.Error as exc:
            status, payload = _map_error(exc)
            headers = {}
        self._send(status, payload, headers)

    def _route(self, method: str) -> None:
        if method == "POST" and urlparse(self.path).path.rstrip("/") == "/graphql":
            self._graphql()
            return
        if not self._authorized():
            self._send(401, {"error": "Sign in required"})
            return
        parsed = urlparse(self.path)
        path = parsed.path.rstrip("/") or "/"
        try:
            with psycopg.connect(self.database_url) as conn:
                seed_preview(conn)
                with conn.cursor() as cur:
                    cur.execute(
                        "SELECT user_id::text FROM cognito_users.users WHERE cognito_sub = %s",
                        (PREVIEW_SUB,),
                    )
                    user_id = cur.fetchone()[0]
                    cur.execute("SELECT public.ensure_personal_tenant(%s::uuid)", (user_id,))
                    tenant_id = str(cur.fetchone()[0])
                    cur.execute("SELECT set_config('app.user_id', %s, true)", (user_id,))
                    cur.execute("SELECT set_config('app.tenant_id', %s, true)", (tenant_id,))
                    cur.execute("SET LOCAL ROLE strm_app")
                    status, payload = self._dispatch(cur, method, path, parsed.query)
        except psycopg.Error as exc:
            status, payload = _map_error(exc)
        self._send(status, payload)

    def _dispatch(self, cur: psycopg.Cursor[Any], method: str, path: str, query: str) -> tuple[int, dict[str, Any]]:
        if method == "GET" and path == "/statements":
            as_of = parse_qs(query).get("as_of", [None])[0]
            if as_of:
                cur.execute("SELECT public.statement_home(%s::date)", (as_of,))
            else:
                cur.execute("SELECT public.statement_home(CURRENT_DATE)")
            home = _json(cur.fetchone()[0]) or {}
            # sql/016: upload completeness for the same day as the home.
            cur.execute("SELECT public.upload_completeness(COALESCE(%s::date, CURRENT_DATE))", (as_of,))
            return 200, {**home, "completeness": _json(cur.fetchone()[0])}
        params = parse_qs(query)
        routed = dispatch_016(cur, method, path, params, self._body)
        if routed is not None:
            return routed
        routed = dispatch_017(cur, method, path, params, self._body)
        if routed is not None:
            return routed
        routed = dispatch_018(cur, method, path, params, self._body)
        if routed is not None:
            return routed
        if method == "GET" and path == "/dimensions":
            cur.execute("SELECT public.dimension_summary()")
            return 200, _json(cur.fetchone()[0]) or {}
        if method == "GET" and path == "/dimensions/rows":
            cur.execute(
                "SELECT public.dimension_rows(%s, %s, %s::date, %s::date, %s, %s, %s)",
                (
                    params.get("kind", [None])[0],
                    params.get("layer", [None])[0],
                    params.get("from", [None])[0] or None,
                    params.get("to", [None])[0] or None,
                    params.get("q", [None])[0],
                    int(params.get("limit", ["200"])[0]),
                    int(params.get("offset", ["0"])[0]),
                ),
            )
            return 200, _json(cur.fetchone()[0])
        if method == "GET" and path == "/api-tokens":
            cur.execute("SELECT public.list_api_tokens(), public.api_usage_summary()")
            tokens, usage = cur.fetchone()
            return 200, {"tokens": _json(tokens), "usage": _json(usage)}
        body = self._body()
        if method == "POST" and path == "/dimensions" and isinstance(body.get("values"), dict):
            cur.execute(
                "SELECT public.save_dimension_values(%s, %s::jsonb)", (body.get("row_hash"), json.dumps(body["values"]))
            )
            return 200, _json(cur.fetchone()[0])
        if method == "POST" and path == "/dimensions":
            cur.execute(
                "SELECT public.save_dimension(%s, %s, %s, %s)",
                (body.get("row_hash"), body.get("attribute_1"), body.get("attribute_2"), body.get("attribute_3")),
            )
            return 200, _json(cur.fetchone()[0])
        if method == "POST" and path == "/api-tokens":
            cur.execute("SELECT public.create_api_token(%s)", (body.get("token_name"),))
            return 200, _json(cur.fetchone()[0])
        if method == "DELETE" and path.startswith("/api-tokens/"):
            cur.execute("SELECT public.revoke_api_token(%s::uuid)", (path.removeprefix("/api-tokens/"),))
            return 200, _json(cur.fetchone()[0])
        if method == "POST" and path == "/accounts":
            cutoff = body.get("account_cutoff_day")
            credit_days = body.get("credit_days")
            if cutoff == "":
                cutoff = None
            if credit_days == "":
                credit_days = None
            cur.execute(
                """
                SELECT public.create_bank_account(
                    %s, %s, %s, %s, %s, %s, COALESCE(%s::date, CURRENT_DATE)
                )
                """,
                (
                    body.get("bank_id"),
                    body.get("a_type_id"),
                    body.get("account_name"),
                    body.get("account_number"),
                    cutoff,
                    credit_days,
                    body.get("as_of"),
                ),
            )
            return 200, {"account_id": cur.fetchone()[0]}
        cutoff_edit = re.fullmatch(r"/accounts/(\d+)/cutoff", path)
        if method == "POST" and cutoff_edit:
            # sql/012: change a credit card's cutoff day and payment window.
            cur.execute(
                """
                SELECT public.update_bank_account_cutoff(
                    %s, %s, %s, COALESCE(%s::date, CURRENT_DATE)
                )
                """,
                (
                    int(cutoff_edit.group(1)),
                    body.get("account_cutoff_day"),
                    body.get("credit_days"),
                    body.get("as_of"),
                ),
            )
            return 200, _json(cur.fetchone()[0])
        if method == "POST" and path == "/periods":
            cur.execute(
                "SELECT public.add_earlier_period(%s, COALESCE(%s::date, CURRENT_DATE))",
                (body.get("account_id"), body.get("as_of")),
            )
            return 200, {"cutoff_id": cur.fetchone()[0]}
        if method == "DELETE" and path.startswith("/periods/"):
            cutoff_id = path.removeprefix("/periods/")
            as_of = parse_qs(query).get("as_of", [None])[0]
            cur.execute(
                "SELECT public.remove_statement_period(%s, COALESCE(%s::date, CURRENT_DATE))",
                (cutoff_id, as_of),
            )
            return 200, {"ok": True}
        if method == "POST" and path == "/uploads":
            if body.get("slot") == "pdf":
                cur.execute(
                    """
                    SELECT public.ingest_period_pdf_upload(
                        %s, %s, %s, %s, %s, COALESCE(%s::date, CURRENT_DATE)
                    )
                    """,
                    (
                        body.get("account_id"),
                        body.get("cutoff_id"),
                        body.get("filename"),
                        body.get("chosen_filename") or body.get("filename"),
                        body.get("pdf_base64"),
                        body.get("as_of"),
                    ),
                )
            else:
                cur.execute(
                    """
                    SELECT public.ingest_statement_upload(
                        %s, %s, %s, %s, %s, %s, COALESCE(%s::date, CURRENT_DATE), %s, %s, %s::jsonb, %s
                    )
                    """,
                    (
                        body.get("account_id"),
                        body.get("cutoff_id"),
                        body.get("slot"),
                        body.get("filename"),
                        body.get("chosen_filename") or body.get("filename"),
                        body.get("csv"),
                        body.get("as_of"),
                        body.get("encoding"),
                        body.get("delimiter"),
                        # sql/018 column map wizard: sent only when the file matched no profile.
                        json.dumps(body["mapping"]) if isinstance(body.get("mapping"), dict) else None,
                        body.get("template_name") if isinstance(body.get("template_name"), str) else None,
                    ),
                )
            return 200, _json(cur.fetchone()[0])
        if method == "POST" and path == "/profiles":
            # User-configurable bank mapping -> file_profiles_d
            cur.execute(
                "SELECT public.upsert_user_file_profile(%s::jsonb)",
                (json.dumps(body.get("profile") or body),),
            )
            return 200, {"profile_code": cur.fetchone()[0]}
        # Open (current period) movements now go through POST /uploads like closed
        # statements; sql/011 routes them to master_*_open_f (the JSON reload is gone).
        if method == "DELETE" and path.startswith("/uploads/"):
            upload_id = path.removeprefix("/uploads/")
            cur.execute("SELECT public.delete_statement_upload(%s::uuid)", (upload_id,))
            return 200, {"ok": True}
        return 404, {"error": "Not found"}

    def _body(self) -> dict[str, Any]:
        cached = getattr(self, "_cached_body", None)
        if cached is not None:
            return cached
        length = int(self.headers.get("content-length") or 0)
        parsed: Any = {}
        if length > 0:
            parsed = json.loads(self.rfile.read(length).decode("utf-8"))
        self._cached_body = parsed if isinstance(parsed, dict) else {}
        return self._cached_body


HASH_RE = re.compile(r"^[0-9a-f]{64}$")
ID_RE = re.compile(r"^\d{1,18}$")


def dispatch_016(
    cur: psycopg.Cursor[Any],
    method: str,
    path: str,
    params: dict[str, list[str]],
    read_body: Callable[[], dict[str, Any]],
) -> tuple[int, Any] | None:
    """sql/016 routes (same paths as infra/lambda/statements.ts): lists and transfers."""

    def call(sql: str, args: tuple[Any, ...] = ()) -> tuple[int, Any]:
        cur.execute(f"SELECT {sql}", args)
        return 200, _json(cur.fetchone()[0])

    def text(value: Any) -> str | None:
        return value if isinstance(value, str) else None

    def first(name: str) -> str | None:
        return params.get(name, [None])[0]

    if path == "/lists" and method == "GET":
        return call("public.list_catalog()")
    if path == "/transfers" and method == "GET":
        return call("public.transfer_links()")
    if path == "/transfers/partners" and method == "GET":
        return call(
            "public.transfer_partners(%s, %s, %s)",
            (first("row_hash"), (first("q") or "")[:100] or None, int(first("limit") or 30)),
        )
    if method not in {"POST", "DELETE"}:
        return None
    match = re.fullmatch(r"/transfers/([^/]+)", path)
    if match and method == "DELETE" and match.group(1) not in {"detect", "settings", "partners"}:
        if not HASH_RE.fullmatch(match.group(1)):
            return 400, {"error": "link id is not valid"}
        return call("public.unlink_transfer(%s)", (match.group(1),))
    if method != "POST":
        return None
    body = read_body()
    if path == "/lists":
        return call("public.create_list(%s)", (text(body.get("list_name")),))
    for pattern, sql, field in (
        (r"/lists/([^/]+)/items", "public.add_list_item(%s::bigint, %s)", "item_name"),
        (r"/lists/([^/]+)", "public.rename_list(%s::bigint, %s)", "list_name"),
        (r"/list-items/([^/]+)", "public.rename_list_item(%s::bigint, %s)", "item_name"),
    ):
        match = re.fullmatch(pattern, path)
        if match:
            if not ID_RE.fullmatch(match.group(1)):
                return 400, {"error": "id is not valid"}
            return call(sql, (match.group(1), text(body.get(field))))
    if path == "/attribute-settings":
        list_id = body.get("list_id")
        list_id = None if list_id in (None, "") else str(list_id)
        if list_id is not None and not ID_RE.fullmatch(list_id):
            return 400, {"error": "list id is not valid"}
        slot = body.get("slot")
        return call(
            "public.set_attribute_setting(%s::int, %s, %s::bigint)",
            (int(slot) if str(slot or "").isdigit() else None, text(body.get("label")), list_id),
        )
    if path == "/transfers":
        return call("public.link_transfer(%s, %s)", (text(body.get("row_a")), text(body.get("row_b"))))
    if path == "/transfers/detect":
        create = body.get("create")
        return call("public.detect_transfers(%s::boolean)", (create if isinstance(create, bool) else None,))
    if path == "/transfers/settings":
        enabled = body.get("auto_link_transfers")
        return call("public.set_transfer_auto(%s::boolean)", (enabled if isinstance(enabled, bool) else None,))
    match = re.fullmatch(r"/transfers/([^/]+)/confirm", path)
    if match:
        if not HASH_RE.fullmatch(match.group(1)):
            return 400, {"error": "link id is not valid"}
        return call("public.confirm_transfer(%s)", (match.group(1),))
    return None


UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.IGNORECASE)
AMOUNT_RE = re.compile(r"^-?\d+(\.\d+)?$")


def dispatch_017(
    cur: psycopg.Cursor[Any],
    method: str,
    path: str,
    params: dict[str, list[str]],
    read_body: Callable[[], dict[str, Any]],
) -> tuple[int, Any] | None:
    """sql/017 routes (same paths as infra/lambda/statements.ts): Investments & Assets.

    The local preview never writes the vault: the upload reply keeps the vault name only.
    """
    if not path.startswith("/assets"):
        return None

    def call(sql: str, args: tuple[Any, ...] = ()) -> tuple[int, Any]:
        cur.execute(f"SELECT {sql}", args)
        return 200, _json(cur.fetchone()[0])

    def text(value: Any) -> str | None:
        return value if isinstance(value, str) else None

    def first(name: str) -> str | None:
        return params.get(name, [None])[0] or None

    def integer(value: Any) -> int | None:
        try:
            return int(value)
        except (TypeError, ValueError):
            return None

    def amount(value: Any) -> str | None:
        if value is None or value == "":
            return None
        raw = str(value).replace(",", "").strip()
        return raw if AMOUNT_RE.fullmatch(raw) else "invalid"

    def mapping(value: Any) -> str:
        return json.dumps(value if isinstance(value, dict) else {})

    if method == "GET":
        if path == "/assets":
            return call("public.aaccandass_home(%s::date)", (first("as_of"),))
        if path == "/assets/balances":
            return call(
                "public.aaccandass_balances(%s::date, %s::int)", (first("as_of"), integer(first("months")) or 12)
            )
        if path == "/assets/rows":
            return call(
                "public.aaccandass_rows(%s::int, %s::date, %s::date, %s, %s::int, %s::int)",
                (
                    integer(first("account_id")),
                    first("from"),
                    first("to"),
                    (first("q") or "")[:100] or None,
                    integer(first("limit")) or 200,
                    integer(first("offset")) or 0,
                ),
            )
        return None
    if method == "DELETE":
        for pattern, check, sql in (
            (r"/assets/rows/([^/]+)", HASH_RE, "public.delete_aaccandass_row(%s)"),
            (r"/assets/uploads/([^/]+)", UUID_RE, "public.delete_aaccandass_upload(%s::uuid)"),
            (r"/assets/templates/([^/]+)", ID_RE, "public.delete_aaccandass_template(%s::bigint)"),
        ):
            match = re.fullmatch(pattern, path)
            if match:
                if not check.fullmatch(match.group(1)):
                    return 400, {"error": "id is not valid"}
                status, payload = call(sql, (match.group(1),))
                if isinstance(payload, dict):
                    payload.pop("vault_delete_marker", None)
                return status, payload
        return None
    if method != "POST":
        return None
    body = read_body()
    if path == "/assets/accounts":
        return call(
            "public.create_asset_account(%s::int, %s, %s::int, %s, %s)",
            (
                integer(body.get("bank_id")),
                text(body.get("institution")),
                integer(body.get("a_type_id")),
                text(body.get("account_name")),
                text(body.get("account_number")),
            ),
        )
    if path == "/assets/rows":
        abonos, cargos = amount(body.get("abonos")), amount(body.get("cargos"))
        if "invalid" in (abonos, cargos):
            return 400, {"error": "Type amounts as numbers"}
        return call(
            "public.add_aaccandass_row(%s::int, %s::date, %s, %s::numeric, %s::numeric, %s)",
            (
                integer(body.get("account_id")),
                text(body.get("txn_date")),
                text(body.get("concept")),
                abonos or "0",
                cargos or "0",
                text(body.get("note")),
            ),
        )
    if path == "/assets/reconcile":
        reported = amount(body.get("reported_balance"))
        if reported in (None, "invalid"):
            return 400, {"error": "Type the balance the institution shows"}
        return call(
            "public.reconcile_aaccandass(%s::int, %s::date, %s::numeric, %s::date, %s, %s)",
            (
                integer(body.get("account_id")),
                text(body.get("as_of")),
                reported,
                text(body.get("adjust_date")) or None,
                text(body.get("concept")),
                text(body.get("note")),
            ),
        )
    if path in {"/assets/preview", "/assets/uploads"}:
        csv_text = body.get("csv") if isinstance(body.get("csv"), str) else ""
        if not csv_text or len(csv_text) > 2_000_000:
            return 400, {"error": "The file is empty or larger than 2 MB"}
        if path == "/assets/preview":
            return call(
                "public.aaccandass_preview(%s::int, %s, %s::jsonb)",
                (integer(body.get("account_id")), csv_text, mapping(body.get("mapping"))),
            )
        filename = text(body.get("filename")) or "upload.csv"
        status, payload = call(
            "public.ingest_aaccandass_upload(%s::int, %s, %s, %s, %s::jsonb, %s, %s)",
            (
                integer(body.get("account_id")),
                filename,
                text(body.get("chosen_filename")) or filename,
                csv_text,
                mapping(body.get("mapping")),
                text(body.get("template_name")),
                "xlsx" if body.get("source_format") == "xlsx" else "csv",
            ),
        )
        if isinstance(payload, dict):
            for key in ("vault_metadata", "vault_manifest", "vault_manifest_key", "vault_key"):
                payload.pop(key, None)
        return status, payload
    return None


def dispatch_018(
    cur: psycopg.Cursor[Any],
    method: str,
    path: str,
    params: dict[str, list[str]],
    read_body: Callable[[], dict[str, Any]],
) -> tuple[int, Any] | None:
    """sql/018 routes (same paths as infra/lambda/statements.ts): balances (opening balance,
    monthly reconciliation), banks, moving an account to another bank, column map preview."""
    if not path.startswith(("/balances", "/banks", "/accounts/", "/statements/preview")):
        return None

    def call(sql: str, args: tuple[Any, ...] = ()) -> tuple[int, Any]:
        cur.execute(f"SELECT {sql}", args)
        return 200, _json(cur.fetchone()[0])

    def text(value: Any) -> str | None:
        return value if isinstance(value, str) and value.strip() else None

    def integer(value: Any) -> int | None:
        try:
            return int(value)
        except (TypeError, ValueError):
            return None

    def amount(value: Any) -> str | None:
        if value is None or value == "":
            return None
        raw = str(value).replace(",", "").strip()
        return raw if AMOUNT_RE.fullmatch(raw) else "invalid"

    balance_home = re.fullmatch(r"/balances/(\d+)", path)
    if method == "GET" and balance_home:
        return call(
            "public.account_balance_home(%s::int, %s::date)",
            (int(balance_home.group(1)), params.get("as_of", [None])[0] or None),
        )
    if method == "GET" and path == "/banks":
        return call("public.bank_catalog()")
    balance_row = re.fullmatch(r"/balances/rows/([^/]+)", path)
    if method == "POST" and balance_row:
        if not HASH_RE.fullmatch(balance_row.group(1)):
            return 400, {"error": "id is not valid"}
        edit = read_body()
        edited = amount(edit.get("amount"))
        if edited in (None, "invalid"):
            return 400, {"error": "Type the amount"}
        return call(
            "public.update_balance_row(%s, %s::date, %s::numeric)",
            (balance_row.group(1), text(edit.get("txn_date")), edited),
        )
    if method == "DELETE" and balance_row:
        if not HASH_RE.fullmatch(balance_row.group(1)):
            return 400, {"error": "id is not valid"}
        return call("public.delete_balance_row(%s)", (balance_row.group(1),))
    bank_delete = re.fullmatch(r"/banks/(\d+)", path)
    if method == "DELETE" and bank_delete:
        return call("public.delete_bank(%s::int)", (int(bank_delete.group(1)),))
    account_delete = re.fullmatch(r"/accounts/(\d+)", path)
    if method == "DELETE" and account_delete:
        return call("public.delete_bank_account(%s::int)", (int(account_delete.group(1)),))
    if method != "POST":
        return None
    body = read_body()
    if method == "POST" and path == "/balances/opening":
        balance = amount(body.get("balance"))
        if balance in (None, "invalid"):
            return 400, {"error": "Type the opening balance"}
        return call(
            "public.add_opening_balance(%s::int, %s::numeric, %s::date, %s, %s)",
            (integer(body.get("account_id")), balance, text(body.get("txn_date")),
             text(body.get("concept")), text(body.get("note"))),
        )
    if method == "POST" and path == "/balances/reconcile":
        reported = amount(body.get("reported_balance"))
        if reported in (None, "invalid"):
            return 400, {"error": "Type the balance the institution shows"}
        return call(
            "public.reconcile_account(%s::int, %s::date, %s::numeric, %s::date, %s, %s)",
            (integer(body.get("account_id")), text(body.get("as_of")), reported, text(body.get("adjust_date")),
             text(body.get("concept")), text(body.get("note"))),
        )
    if method == "POST" and path == "/banks":
        return call("public.create_bank(%s, %s)", (text(body.get("bank_name")), body.get("is_institution") is True))
    bank = re.fullmatch(r"/banks/(\d+)", path)
    if method == "POST" and bank:
        return call("public.rename_bank(%s::int, %s)", (int(bank.group(1)), text(body.get("bank_name"))))
    account_bank = re.fullmatch(r"/accounts/(\d+)/bank", path)
    if method == "POST" and account_bank:
        return call(
            "public.set_account_bank(%s::int, %s::int)", (int(account_bank.group(1)), integer(body.get("bank_id")))
        )
    if method == "POST" and path == "/statements/preview":
        csv_text = body.get("csv") if isinstance(body.get("csv"), str) else ""
        if not csv_text or len(csv_text) > 2_000_000:
            return 400, {"error": "The file is empty or larger than 2 MB"}
        mapping = body.get("mapping")
        return call(
            "public.column_map_preview(%s::int, %s, %s::jsonb)",
            (integer(body.get("account_id")), csv_text, json.dumps(mapping) if isinstance(mapping, dict) else None),
        )
    return None


def _map_error(exc: psycopg.Error) -> tuple[int, dict[str, str]]:
    code = exc.sqlstate or ""
    message = str(exc).splitlines()[0]
    if code == "23505":
        if "already uploaded" in message.lower():
            return 409, {"error": "already uploaded"}
        return 409, {"error": message}
    if code in {"23514", "22023", "22P02", "22007", "P0002", "42501", "28000"}:
        return 400, {"error": message}
    return 500, {"error": "Could not update the statements."}


def main() -> None:
    port = int(os.environ.get("PORT", "8765"))
    server = ThreadingHTTPServer(("127.0.0.1", port), StatementHandler)
    print(f"statements preview API on http://127.0.0.1:{port}")
    server.serve_forever()


if __name__ == "__main__":
    main()
