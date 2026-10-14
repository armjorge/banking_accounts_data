from site_publish import cognito_hosted_domain
from catalog import (
    compose_database_url,
    connectable_url,
    neon_database_from_url,
    neon_user_from_url,
    object_prefix,
    render_sql,
    validate_environment_name,
    validate_schema_name,
)


def test_prefix_and_name():
    assert validate_environment_name("dev") == "dev"
    assert object_prefix("prd") == "strm_bank_prd"
    try:
        validate_environment_name("Prod")
        raise AssertionError("expected failure")
    except ValueError:
        pass


def test_schema():
    assert validate_schema_name("core") == "core"
    try:
        validate_schema_name("pg_catalog")
        raise AssertionError("expected failure")
    except ValueError:
        pass


def test_compose_url():
    url = compose_database_url(
        host="ep-example.neon.tech",
        user="app",
        password="p@ss:word",
        database="bank",
    )
    assert url.startswith("postgresql://app:p%40ss%3Aword@ep-example.neon.tech/bank")
    assert "sslmode=require" in url


def test_parse_neon_uri():
    raw = (
        "postgresql://neondb_owner:pass@ep-royal-meadow.neon.tech/neondb"
        "?sslmode=require&channel_binding=require"
    )
    assert neon_user_from_url(raw) == "neondb_owner"
    assert neon_database_from_url(raw) == "neondb"
    cleaned = connectable_url(raw)
    assert "sslmode=require" in cleaned
    assert "channel_binding" not in cleaned


def test_sql_placeholders():
    rendered = render_sql(
        "{{NEON_USERS_SCHEMA}}.users {{NEON_DB_SCHEMA}}.tx -- {{NEON_DATABASE}}",
        app_schema="core",
        users_schema="cognito_users",
        database="neondb",
    )
    assert rendered == "cognito_users.users core.tx -- neondb"


def test_cognito_domain():
    assert (
        cognito_hosted_domain("strm_bank_dev", "us-east-1")
        == "https://strmbankdevauth.auth.us-east-1.amazoncognito.com"
    )
