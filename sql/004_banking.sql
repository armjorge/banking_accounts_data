CREATE TABLE IF NOT EXISTS {{NEON_DB_SCHEMA}}.financial_providers (
    provider_code TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    template_enabled_on_entry BOOLEAN NOT NULL DEFAULT TRUE
);

INSERT INTO {{NEON_DB_SCHEMA}}.financial_providers (provider_code, display_name, template_enabled_on_entry)
VALUES
    ('generic_csv', 'Generic CSV', TRUE)
ON CONFLICT (provider_code) DO NOTHING;

CREATE TABLE IF NOT EXISTS {{NEON_DB_SCHEMA}}.bank_accounts (
    account_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES {{NEON_DB_SCHEMA}}.tenants (tenant_id),
    user_id UUID NOT NULL REFERENCES {{NEON_USERS_SCHEMA}}.users (user_id),
    provider_code TEXT NOT NULL REFERENCES {{NEON_DB_SCHEMA}}.financial_providers (provider_code),
    display_name TEXT NOT NULL,
    currency_code CHAR(3) NOT NULL DEFAULT 'USD',
    external_account_ref TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS {{NEON_DB_SCHEMA}}.import_jobs (
    import_job_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES {{NEON_DB_SCHEMA}}.tenants (tenant_id),
    user_id UUID NOT NULL REFERENCES {{NEON_USERS_SCHEMA}}.users (user_id),
    account_id UUID REFERENCES {{NEON_DB_SCHEMA}}.bank_accounts (account_id),
    source_filename TEXT NOT NULL,
    source_object_key TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    row_count INTEGER,
    error_message TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS {{NEON_DB_SCHEMA}}.transactions (
    transaction_id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id UUID NOT NULL REFERENCES {{NEON_DB_SCHEMA}}.tenants (tenant_id),
    user_id UUID NOT NULL REFERENCES {{NEON_USERS_SCHEMA}}.users (user_id),
    account_id UUID NOT NULL REFERENCES {{NEON_DB_SCHEMA}}.bank_accounts (account_id),
    import_job_id UUID REFERENCES {{NEON_DB_SCHEMA}}.import_jobs (import_job_id),
    booked_on DATE NOT NULL,
    amount NUMERIC(18, 2) NOT NULL,
    description TEXT,
    raw_payload JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS transactions_user_booked_idx
    ON {{NEON_DB_SCHEMA}}.transactions (user_id, booked_on DESC);
