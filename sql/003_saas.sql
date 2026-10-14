-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
CREATE SCHEMA IF NOT EXISTS {{NEON_DB_SCHEMA}};

CREATE TABLE IF NOT EXISTS {{NEON_DB_SCHEMA}}.plans (
    plan_code TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    local_storage_only BOOLEAN NOT NULL DEFAULT TRUE,
    snowflake_backup BOOLEAN NOT NULL DEFAULT FALSE,
    monthly_api_quota INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

INSERT INTO {{NEON_DB_SCHEMA}}.plans (plan_code, display_name, local_storage_only, snowflake_backup, monthly_api_quota)
VALUES
    ('entry', 'Entry', TRUE, FALSE, 0),
    ('plus', 'Plus', FALSE, TRUE, 1000),
    ('premium', 'Premium', FALSE, TRUE, 10000)
ON CONFLICT (plan_code) DO UPDATE
SET
    display_name = EXCLUDED.display_name,
    local_storage_only = EXCLUDED.local_storage_only,
    snowflake_backup = EXCLUDED.snowflake_backup,
    monthly_api_quota = EXCLUDED.monthly_api_quota;

CREATE TABLE IF NOT EXISTS {{NEON_DB_SCHEMA}}.tenants (
    tenant_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name TEXT NOT NULL,
    plan_code TEXT NOT NULL REFERENCES {{NEON_DB_SCHEMA}}.plans (plan_code),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS {{NEON_DB_SCHEMA}}.tenant_users (
    tenant_id UUID NOT NULL REFERENCES {{NEON_DB_SCHEMA}}.tenants (tenant_id),
    user_id UUID NOT NULL REFERENCES {{NEON_USERS_SCHEMA}}.users (user_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    PRIMARY KEY (tenant_id, user_id)
);
