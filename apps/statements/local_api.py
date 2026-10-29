"""Local statements API for the preview page. Not deployed and not a substitute for the Lambda."""

from __future__ import annotations

import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import parse_qs, urlparse

import psycopg

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

    def _send(self, status: int, payload: dict[str, Any]) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("content-type", "application/json")
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

    def _route(self, method: str) -> None:
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
            return 200, _json(cur.fetchone()[0])
        body = self._body()
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
                    SELECT public.ingest_period_pdf(
                        %s, %s, %s, %s, COALESCE(%s::date, CURRENT_DATE)
                    )
                    """,
                    (
                        body.get("account_id"),
                        body.get("cutoff_id"),
                        body.get("filename"),
                        body.get("pdf_base64"),
                        body.get("as_of"),
                    ),
                )
            else:
                cur.execute(
                    """
                    SELECT public.ingest_statement_csv(
                        %s, %s, %s, %s, %s, COALESCE(%s::date, CURRENT_DATE), %s, %s
                    )
                    """,
                    (
                        body.get("account_id"),
                        body.get("cutoff_id"),
                        body.get("slot"),
                        body.get("filename"),
                        body.get("csv"),
                        body.get("as_of"),
                        body.get("encoding"),
                        body.get("delimiter"),
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
        if method == "POST" and path == "/open-reload":
            # Open period: replace only accounts present in payload
            cur.execute(
                "SELECT public.reload_open_movements(%s::jsonb)",
                (json.dumps(body),),
            )
            return 200, _json(cur.fetchone()[0])
        if method == "POST" and path == "/open-replace":
            cur.execute(
                "SELECT public.replace_open_account_movements(%s, %s::jsonb)",
                (body.get("account_id"), json.dumps(body.get("rows") or [])),
            )
            return 200, _json(cur.fetchone()[0])
                if method == "DELETE" and path.startswith("/uploads/"):
            upload_id = path.removeprefix("/uploads/")
            cur.execute("SELECT public.delete_statement_upload(%s::uuid)", (upload_id,))
            return 200, {"ok": True}
        return 404, {"error": "Not found"}

    def _body(self) -> dict[str, Any]:
        length = int(self.headers.get("content-length") or 0)
        if length <= 0:
            return {}
        raw = self.rfile.read(length)
        parsed = json.loads(raw.decode("utf-8"))
        if not isinstance(parsed, dict):
            return {}
        return parsed


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
