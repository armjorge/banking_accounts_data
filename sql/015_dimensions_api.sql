-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- Movement attributes (dimensions page), read-only API tokens, API quotas and the data
-- function behind the GraphQL API (see docs/dimensions.md and docs/graphql.md).
--
--   * debit_d / credit_d: one row per movement key (row_hash) with attribute_1..3, owned
--     by tenant and user like the masters (row level security). debit_d covers
--     master_debit_closed_f + master_debit_open_f; credit_d covers master_credit_closed_f +
--     master_credit_open_f + master_credit_future_f. A trigger on each master adds the
--     row when a movement is stored; the row stays when the movement moves from the open
--     to the closed book (same row_hash), so the attributes follow it.
--   * movement_dimensions_d (key registry since 006) is kept and still written by the
--     ingest; its rows seed debit_d / credit_d (created_at kept). Nothing new reads it.
--   * Dimensions page: dimension_summary, dimension_rows, save_dimension.
--   * API tokens (read-only, hashed): create_api_token, list_api_tokens, revoke_api_token.
--   * API quotas per plan in plans_d (api_calls_limit per api_window 'day' or 'week'),
--     call log api_usage_f, atomic api_consume_call before every GraphQL request.
--   * graphql_rows: rows of one master joined with its attributes, with the filters the
--     GraphQL API exposes.
--
-- Safe to run more than once. Requires 014. Apply on Neon by hand after 014.

-- =============================================================================
-- 1. Attribute tables
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.debit_d (
    row_hash TEXT NOT NULL,
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    attribute_1 TEXT,
    attribute_2 TEXT,
    attribute_3 TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    updated_at TIMESTAMPTZ,
    updated_by UUID,
    CONSTRAINT debit_d_pkey PRIMARY KEY (row_hash),
    CONSTRAINT debit_d_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT debit_d_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id) ON DELETE CASCADE,
    CONSTRAINT debit_d_hash_check CHECK (LENGTH(row_hash) = 64),
    CONSTRAINT debit_d_attribute_check CHECK (
        COALESCE(LENGTH(attribute_1), 0) <= 500
        AND COALESCE(LENGTH(attribute_2), 0) <= 500
        AND COALESCE(LENGTH(attribute_3), 0) <= 500
    )
);

CREATE TABLE IF NOT EXISTS public.credit_d (
    row_hash TEXT NOT NULL,
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    attribute_1 TEXT,
    attribute_2 TEXT,
    attribute_3 TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    updated_at TIMESTAMPTZ,
    updated_by UUID,
    CONSTRAINT credit_d_pkey PRIMARY KEY (row_hash),
    CONSTRAINT credit_d_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT credit_d_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id) ON DELETE CASCADE,
    CONSTRAINT credit_d_hash_check CHECK (LENGTH(row_hash) = 64),
    CONSTRAINT credit_d_attribute_check CHECK (
        COALESCE(LENGTH(attribute_1), 0) <= 500
        AND COALESCE(LENGTH(attribute_2), 0) <= 500
        AND COALESCE(LENGTH(attribute_3), 0) <= 500
    )
);

CREATE INDEX IF NOT EXISTS debit_d_tenant_idx ON public.debit_d (tenant_id, user_id);
CREATE INDEX IF NOT EXISTS credit_d_tenant_idx ON public.credit_d (tenant_id, user_id);
CREATE INDEX IF NOT EXISTS debit_d_account_idx ON public.debit_d (account_id);
CREATE INDEX IF NOT EXISTS credit_d_account_idx ON public.credit_d (account_id);

COMMENT ON TABLE public.debit_d IS
'User attributes of debit movements (master_debit_closed_f, master_debit_open_f), one row per row_hash.';
COMMENT ON TABLE public.credit_d IS
'User attributes of credit-card movements (master_credit_closed_f, master_credit_open_f, '
'master_credit_future_f), one row per row_hash.';

-- New movements get their attribute row (empty) as they are stored.
CREATE OR REPLACE FUNCTION public.add_movement_attribute_rows()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
    EXECUTE FORMAT(
        'INSERT INTO public.%I (row_hash, tenant_id, user_id, account_id, created_by)
        SELECT added.row_hash, added.tenant_id, added.user_id, added.account_id, added.user_id
        FROM added_rows AS added
        ON CONFLICT (row_hash) DO NOTHING',
        TG_ARGV[0]
    );
    RETURN NULL;
END
$fn$;

DO $do$
DECLARE
    v_spec TEXT [];
BEGIN
    FOREACH v_spec SLICE 1 IN ARRAY ARRAY[
        ['master_debit_closed_f', 'debit_d'],
        ['master_debit_open_f', 'debit_d'],
        ['master_credit_closed_f', 'credit_d'],
        ['master_credit_open_f', 'credit_d'],
        ['master_credit_future_f', 'credit_d']
    ]
    LOOP
        EXECUTE FORMAT('DROP TRIGGER IF EXISTS %I ON public.%I', v_spec[1] || '_attribute_rows', v_spec[1]);
        EXECUTE FORMAT(
            'CREATE TRIGGER %I AFTER INSERT ON public.%I
            REFERENCING NEW TABLE AS added_rows
            FOR EACH STATEMENT EXECUTE FUNCTION public.add_movement_attribute_rows(%L)',
            v_spec[1] || '_attribute_rows', v_spec[1], v_spec[2]
        );
        -- Seed: every stored movement, keeping the registry's created_at when present.
        EXECUTE FORMAT(
            'INSERT INTO public.%I (row_hash, tenant_id, user_id, account_id, created_at, created_by)
            SELECT movement.row_hash, movement.tenant_id, movement.user_id, movement.account_id,
                COALESCE(registry.created_at, NOW()), movement.user_id
            FROM public.%I AS movement
            LEFT JOIN public.movement_dimensions_d AS registry
                ON registry.tenant_id = movement.tenant_id AND registry.row_hash = movement.row_hash
            ON CONFLICT (row_hash) DO NOTHING',
            v_spec[2], v_spec[1]
        );
    END LOOP;
END
$do$;

-- =============================================================================
-- 2. Dimensions page
-- =============================================================================
-- Share of stored movements with at least one attribute, per kind and layer.
CREATE OR REPLACE FUNCTION public.dimension_summary()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_result JSONB;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    WITH movement AS (
        SELECT
            keys.kind,
            keys.layer,
            (
                NULLIF(BTRIM(COALESCE(debit.attribute_1, credit.attribute_1, '')), '') IS NOT NULL
                OR NULLIF(BTRIM(COALESCE(debit.attribute_2, credit.attribute_2, '')), '') IS NOT NULL
                OR NULLIF(BTRIM(COALESCE(debit.attribute_3, credit.attribute_3, '')), '') IS NOT NULL
            ) AS filled
        FROM public.movement_keys_v AS keys
        LEFT JOIN public.debit_d AS debit ON keys.kind = 'debit' AND debit.row_hash = keys.row_hash
        LEFT JOIN public.credit_d AS credit ON keys.kind = 'credit' AND credit.row_hash = keys.row_hash
        WHERE keys.tenant_id = v_tenant AND keys.user_id = v_user
    ),
    levels AS (
        SELECT
            spec.kind,
            spec.layer,
            COUNT(movement.kind) AS total,
            COUNT(movement.kind) FILTER (WHERE movement.filled) AS filled
        FROM (
            VALUES
                ('debit', 'open'), ('debit', 'closed'),
                ('credit', 'open'), ('credit', 'closed'), ('credit', 'future')
        ) AS spec (kind, layer)
        LEFT JOIN movement ON movement.kind = spec.kind AND movement.layer = spec.layer
        GROUP BY spec.kind, spec.layer
    ),
    kinds AS (
        SELECT
            levels.kind,
            SUM(levels.total)::BIGINT AS total,
            SUM(levels.filled)::BIGINT AS filled,
            JSONB_OBJECT_AGG(
                levels.layer,
                JSONB_BUILD_OBJECT(
                    'total', levels.total,
                    'filled', levels.filled,
                    'pct', CASE WHEN levels.total = 0 THEN 0 ELSE ROUND(100.0 * levels.filled / levels.total, 1) END
                )
            ) AS layers
        FROM levels
        GROUP BY levels.kind
    )
    SELECT JSONB_OBJECT_AGG(
        kinds.kind,
        JSONB_BUILD_OBJECT(
            'total', kinds.total,
            'filled', kinds.filled,
            'pct', CASE WHEN kinds.total = 0 THEN 0 ELSE ROUND(100.0 * kinds.filled / kinds.total, 1) END,
            'layers', kinds.layers
        )
    )
    INTO v_result
    FROM kinds;
    RETURN v_result;
END
$fn$;

-- Rows of one kind and layer for the page: date range, text search, paging.
CREATE OR REPLACE FUNCTION public.dimension_rows(
    p_kind TEXT,
    p_layer TEXT,
    p_from DATE DEFAULT NULL,
    p_to DATE DEFAULT NULL,
    p_search TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 200,
    p_offset INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_search TEXT := NULLIF(BTRIM(COALESCE(p_search, '')), '');
    v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 200), 1), 500);
    v_offset INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
    v_total BIGINT;
    v_rows JSONB;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    IF NOT (p_kind, p_layer) IN (
        ('debit', 'open'), ('debit', 'closed'), ('credit', 'open'), ('credit', 'closed'), ('credit', 'future')
    ) THEN
        RAISE EXCEPTION 'unknown kind/layer %/%', p_kind, p_layer USING ERRCODE = '22023';
    END IF;

    WITH picked AS (
        SELECT
            keys.row_hash,
            keys.row_id,
            keys.account_id,
            keys.account_number,
            keys.bank_name,
            keys.txn_date,
            keys.concept,
            keys.concept_sk,
            keys.abonos,
            keys.cargos,
            COALESCE(debit.attribute_1, credit.attribute_1) AS attribute_1,
            COALESCE(debit.attribute_2, credit.attribute_2) AS attribute_2,
            COALESCE(debit.attribute_3, credit.attribute_3) AS attribute_3
        FROM public.movement_keys_v AS keys
        LEFT JOIN public.debit_d AS debit ON keys.kind = 'debit' AND debit.row_hash = keys.row_hash
        LEFT JOIN public.credit_d AS credit ON keys.kind = 'credit' AND credit.row_hash = keys.row_hash
        WHERE
            keys.tenant_id = v_tenant
            AND keys.user_id = v_user
            AND keys.kind = p_kind
            AND keys.layer = p_layer
            AND (p_from IS NULL OR keys.txn_date >= p_from)
            AND (p_to IS NULL OR keys.txn_date <= p_to)
            AND (
                v_search IS NULL
                OR keys.concept ILIKE '%' || v_search || '%'
                OR keys.concept_sk ILIKE '%' || v_search || '%'
                OR keys.bank_name ILIKE '%' || v_search || '%'
                OR keys.account_number ILIKE '%' || v_search || '%'
                OR COALESCE(debit.attribute_1, credit.attribute_1, '') ILIKE '%' || v_search || '%'
                OR COALESCE(debit.attribute_2, credit.attribute_2, '') ILIKE '%' || v_search || '%'
                OR COALESCE(debit.attribute_3, credit.attribute_3, '') ILIKE '%' || v_search || '%'
            )
    )
    SELECT
        (SELECT COUNT(*) FROM picked),
        COALESCE(
            (
                SELECT JSONB_AGG(TO_JSONB(page) ORDER BY page.txn_date DESC, page.row_id DESC)
                FROM (
                    SELECT *
                    FROM picked
                    ORDER BY picked.txn_date DESC, picked.row_id DESC
                    LIMIT v_limit OFFSET v_offset
                ) AS page
            ),
            '[]'::JSONB
        )
    INTO v_total, v_rows;

    RETURN JSONB_BUILD_OBJECT(
        'kind', p_kind,
        'layer', p_layer,
        'total', v_total,
        'limit', v_limit,
        'offset', v_offset,
        'rows', v_rows
    );
END
$fn$;

-- Save the three attributes of one movement (blank text clears an attribute).
CREATE OR REPLACE FUNCTION public.save_dimension(
    p_row_hash TEXT,
    p_attribute_1 TEXT,
    p_attribute_2 TEXT,
    p_attribute_3 TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_kind TEXT;
    v_account INTEGER;
    v_table TEXT;
    v_values TEXT [] := ARRAY[
        NULLIF(BTRIM(COALESCE(p_attribute_1, '')), ''),
        NULLIF(BTRIM(COALESCE(p_attribute_2, '')), ''),
        NULLIF(BTRIM(COALESCE(p_attribute_3, '')), '')
    ];
    v_saved JSONB;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    IF EXISTS (SELECT 1 FROM UNNEST(v_values) AS item WHERE LENGTH(item) > 500) THEN
        RAISE EXCEPTION 'Each attribute can have at most 500 characters' USING ERRCODE = '22023';
    END IF;

    SELECT keys.kind, keys.account_id
    INTO v_kind, v_account
    FROM public.movement_keys_v AS keys
    WHERE keys.row_hash = p_row_hash AND keys.tenant_id = v_tenant AND keys.user_id = v_user
    LIMIT 1;
    IF v_kind IS NULL THEN
        RAISE EXCEPTION 'movement not found' USING ERRCODE = 'P0002';
    END IF;
    v_table := CASE WHEN v_kind = 'debit' THEN 'debit_d' ELSE 'credit_d' END;

    EXECUTE FORMAT(
        'INSERT INTO public.%I AS target (
            row_hash, tenant_id, user_id, account_id, attribute_1, attribute_2, attribute_3,
            created_by, updated_at, updated_by
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $3, NOW(), $3)
        ON CONFLICT (row_hash) DO UPDATE
        SET
            attribute_1 = EXCLUDED.attribute_1,
            attribute_2 = EXCLUDED.attribute_2,
            attribute_3 = EXCLUDED.attribute_3,
            updated_at = NOW(),
            updated_by = EXCLUDED.updated_by
        WHERE target.tenant_id = EXCLUDED.tenant_id AND target.user_id = EXCLUDED.user_id
        RETURNING JSONB_BUILD_OBJECT(
            ''row_hash'', target.row_hash, ''kind'', %L,
            ''attribute_1'', target.attribute_1, ''attribute_2'', target.attribute_2,
            ''attribute_3'', target.attribute_3, ''updated_at'', target.updated_at
        )',
        v_table, v_kind
    )
    INTO v_saved
    USING p_row_hash, v_tenant, v_user, v_account, v_values[1], v_values[2], v_values[3];
    IF v_saved IS NULL THEN
        RAISE EXCEPTION 'tenant isolation' USING ERRCODE = '42501';
    END IF;
    RETURN v_saved;
END
$fn$;

-- =============================================================================
-- 3. Read-only API tokens (hashed) and API quotas
-- =============================================================================
ALTER TABLE public.plans_d
ADD COLUMN IF NOT EXISTS api_calls_limit INTEGER;
ALTER TABLE public.plans_d
ADD COLUMN IF NOT EXISTS api_window TEXT;
ALTER TABLE public.plans_d
ADD COLUMN IF NOT EXISTS api_max_rows INTEGER;

-- Defaults only where empty: edits in plans_d survive re-running 015 (and 006, whose
-- plan upsert does not list these columns). Entry and Plus are placeholders to confirm.
UPDATE public.plans_d
SET
    api_calls_limit = COALESCE(
        api_calls_limit,
        CASE plan_code WHEN 'free' THEN 1 WHEN 'entry' THEN 1 WHEN 'plus' THEN 3 WHEN 'premium' THEN 3 ELSE 1 END
    ),
    api_window = COALESCE(
        api_window,
        CASE plan_code WHEN 'free' THEN 'week' WHEN 'entry' THEN 'week' ELSE 'day' END
    ),
    api_max_rows = COALESCE(api_max_rows, 5000)
WHERE api_calls_limit IS NULL OR api_window IS NULL OR api_max_rows IS NULL;

ALTER TABLE public.plans_d
DROP CONSTRAINT IF EXISTS plans_d_api_quota_check;
ALTER TABLE public.plans_d
ADD CONSTRAINT plans_d_api_quota_check CHECK (
    api_calls_limit >= 0 AND api_window IN ('day', 'week') AND api_max_rows BETWEEN 1 AND 100000
);

COMMENT ON COLUMN public.plans_d.api_calls_limit IS
'GraphQL API calls allowed per user per api_window (sql/015). 0 turns the API off for the plan.';
COMMENT ON COLUMN public.plans_d.api_window IS
'Quota window: day or week, calendar windows in America/Mexico_City (weeks start on Monday).';
COMMENT ON COLUMN public.plans_d.api_max_rows IS
'Most rows one GraphQL response may return (all root fields together).';
COMMENT ON COLUMN public.plans_d.monthly_api_quota IS
'Unused. The GraphQL API quota is api_calls_limit per api_window (sql/015).';

CREATE TABLE IF NOT EXISTS public.api_tokens_d (
    token_id UUID NOT NULL DEFAULT GEN_RANDOM_UUID(),
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    token_name TEXT NOT NULL,
    token_prefix TEXT NOT NULL,
    token_sha256 TEXT NOT NULL,
    scope TEXT NOT NULL DEFAULT 'read',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_used_at TIMESTAMPTZ,
    revoked_at TIMESTAMPTZ,
    CONSTRAINT api_tokens_d_pkey PRIMARY KEY (token_id),
    CONSTRAINT api_tokens_d_sha_key UNIQUE (token_sha256),
    CONSTRAINT api_tokens_d_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT api_tokens_d_scope_check CHECK (scope = 'read'),
    CONSTRAINT api_tokens_d_sha_check CHECK (token_sha256 ~ '^[0-9a-f]{64}$'),
    CONSTRAINT api_tokens_d_name_check CHECK (LENGTH(token_name) BETWEEN 1 AND 60)
);

CREATE INDEX IF NOT EXISTS api_tokens_d_user_idx ON public.api_tokens_d (tenant_id, user_id);

COMMENT ON TABLE public.api_tokens_d IS
'Read-only API tokens. Only the sha256 of the token is stored; the token is shown once.';

CREATE TABLE IF NOT EXISTS public.api_usage_f (
    call_id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    token_id UUID,
    called_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    operation TEXT NOT NULL,
    status TEXT NOT NULL,
    rows_returned INTEGER,
    CONSTRAINT api_usage_f_pkey PRIMARY KEY (call_id),
    CONSTRAINT api_usage_f_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT api_usage_f_status_check CHECK (status IN ('accepted', 'ok', 'error', 'rejected'))
);

CREATE INDEX IF NOT EXISTS api_usage_f_user_idx ON public.api_usage_f (user_id, called_at);

COMMENT ON TABLE public.api_usage_f IS
'GraphQL API call log. accepted/ok/error count toward the quota; rejected (over quota) does not.';

CREATE OR REPLACE FUNCTION public.api_token_sha(p_token TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT ENCODE(SHA256(CONVERT_TO(COALESCE(p_token, ''), 'UTF8')), 'hex')
$fn$;

CREATE OR REPLACE FUNCTION public.create_api_token(p_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_name TEXT := LEFT(NULLIF(BTRIM(COALESCE(p_name, '')), ''), 60);
    v_token TEXT;
    v_row public.api_tokens_d;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    IF v_name IS NULL THEN
        v_name := 'Google Sheets';
    END IF;
    IF (
        SELECT COUNT(*) FROM public.api_tokens_d AS token
        WHERE token.tenant_id = v_tenant AND token.user_id = v_user AND token.revoked_at IS NULL
    ) >= 5 THEN
        RAISE EXCEPTION 'At most 5 active tokens; revoke one first' USING ERRCODE = '23514';
    END IF;
    -- 48 hex characters from two random (v4) UUIDs: about 180 random bits.
    v_token := 'bst_' || LEFT(
        REPLACE(GEN_RANDOM_UUID()::TEXT, '-', '') || REPLACE(GEN_RANDOM_UUID()::TEXT, '-', ''), 48
    );
    INSERT INTO public.api_tokens_d (tenant_id, user_id, token_name, token_prefix, token_sha256)
    VALUES (v_tenant, v_user, v_name, LEFT(v_token, 10), public.api_token_sha(v_token))
    RETURNING * INTO v_row;
    RETURN JSONB_BUILD_OBJECT(
        'token_id', v_row.token_id,
        'token_name', v_row.token_name,
        'token_prefix', v_row.token_prefix,
        'created_at', v_row.created_at,
        'token', v_token
    );
END
$fn$;

CREATE OR REPLACE FUNCTION public.list_api_tokens()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    RETURN COALESCE(
        (
            SELECT JSONB_AGG(
                JSONB_BUILD_OBJECT(
                    'token_id', token.token_id,
                    'token_name', token.token_name,
                    'token_prefix', token.token_prefix,
                    'scope', token.scope,
                    'created_at', token.created_at,
                    'last_used_at', token.last_used_at,
                    'revoked_at', token.revoked_at
                )
                ORDER BY token.created_at DESC
            )
            FROM public.api_tokens_d AS token
            WHERE token.tenant_id = v_tenant AND token.user_id = v_user
        ),
        '[]'::JSONB
    );
END
$fn$;

CREATE OR REPLACE FUNCTION public.revoke_api_token(p_token_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_revoked TIMESTAMPTZ;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    UPDATE public.api_tokens_d AS token
    SET revoked_at = COALESCE(token.revoked_at, NOW())
    WHERE token.token_id = p_token_id AND token.tenant_id = v_tenant AND token.user_id = v_user
    RETURNING token.revoked_at INTO v_revoked;
    IF v_revoked IS NULL THEN
        RAISE EXCEPTION 'token not found' USING ERRCODE = 'P0002';
    END IF;
    RETURN JSONB_BUILD_OBJECT('token_id', p_token_id, 'revoked_at', v_revoked);
END
$fn$;

-- Current quota window of a plan at a moment, in America/Mexico_City calendar terms.
CREATE OR REPLACE FUNCTION public.api_window_bounds(
    p_window TEXT,
    p_at TIMESTAMPTZ,
    OUT window_start TIMESTAMPTZ,
    OUT window_end TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $fn$
    SELECT
        DATE_TRUNC(p_window, p_at AT TIME ZONE 'America/Mexico_City') AT TIME ZONE 'America/Mexico_City',
        (
            DATE_TRUNC(p_window, p_at AT TIME ZONE 'America/Mexico_City')
            + CASE WHEN p_window = 'week' THEN INTERVAL '7 days' ELSE INTERVAL '1 day' END
        ) AT TIME ZONE 'America/Mexico_City'
$fn$;

CREATE OR REPLACE FUNCTION public.api_usage_state(p_tenant UUID, p_user UUID, p_at TIMESTAMPTZ)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
SET timezone = 'America/Mexico_City'
AS $fn$
DECLARE
    v_plan RECORD;
    v_bounds RECORD;
    v_used BIGINT;
BEGIN
    SELECT plan.plan_code, plan.display_name, plan.api_calls_limit, plan.api_window, plan.api_max_rows
    INTO v_plan
    FROM public.tenants_d AS tenant
    INNER JOIN public.plans_d AS plan ON plan.plan_code = tenant.plan_code
    WHERE tenant.tenant_id = p_tenant;
    SELECT * INTO v_bounds FROM public.api_window_bounds(COALESCE(v_plan.api_window, 'week'), p_at);
    SELECT COUNT(*)
    INTO v_used
    FROM public.api_usage_f AS usage
    WHERE
        usage.user_id = p_user
        AND usage.tenant_id = p_tenant
        AND usage.status IN ('accepted', 'ok', 'error')
        AND usage.called_at >= v_bounds.window_start
        AND usage.called_at < v_bounds.window_end;
    RETURN JSONB_BUILD_OBJECT(
        'plan_code', v_plan.plan_code,
        'plan_name', v_plan.display_name,
        'limit', COALESCE(v_plan.api_calls_limit, 0),
        'window', COALESCE(v_plan.api_window, 'week'),
        'max_rows', COALESCE(v_plan.api_max_rows, 5000),
        'used', v_used,
        'remaining', GREATEST(COALESCE(v_plan.api_calls_limit, 0) - v_used, 0),
        'window_start', v_bounds.window_start,
        'resets_at', v_bounds.window_end
    );
END
$fn$;

-- One GraphQL request = one call. Resolves the token, locks the user, counts the calls
-- in the current window and either logs an accepted call or a rejected one. The token
-- check and the count run under the same per-user advisory lock, so concurrent requests
-- cannot pass the limit. Not granted to strm_app (it takes the clock as a parameter).
CREATE OR REPLACE FUNCTION public.api_consume_call_at(p_token TEXT, p_operation TEXT, p_at TIMESTAMPTZ)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'America/Mexico_City'
AS $fn$
DECLARE
    v_token public.api_tokens_d;
    v_state JSONB;
    v_call BIGINT;
BEGIN
    SELECT *
    INTO v_token
    FROM public.api_tokens_d AS token
    WHERE token.token_sha256 = public.api_token_sha(p_token) AND token.revoked_at IS NULL;
    IF v_token.token_id IS NULL OR NOT EXISTS (
        SELECT 1 FROM public.tenant_users AS membership
        WHERE membership.tenant_id = v_token.tenant_id AND membership.user_id = v_token.user_id
    ) THEN
        RAISE EXCEPTION 'invalid or revoked API token' USING ERRCODE = '28000';
    END IF;

    PERFORM PG_ADVISORY_XACT_LOCK(HASHTEXTEXTENDED('api_quota:' || v_token.user_id::TEXT, 0));
    v_state := public.api_usage_state(v_token.tenant_id, v_token.user_id, p_at);

    IF (v_state ->> 'used')::BIGINT >= (v_state ->> 'limit')::BIGINT THEN
        INSERT INTO public.api_usage_f (tenant_id, user_id, token_id, called_at, operation, status)
        VALUES (v_token.tenant_id, v_token.user_id, v_token.token_id, p_at, LEFT(p_operation, 40), 'rejected');
        RETURN v_state || JSONB_BUILD_OBJECT('ok', FALSE);
    END IF;

    INSERT INTO public.api_usage_f (tenant_id, user_id, token_id, called_at, operation, status)
    VALUES (v_token.tenant_id, v_token.user_id, v_token.token_id, p_at, LEFT(p_operation, 40), 'accepted')
    RETURNING call_id INTO v_call;
    UPDATE public.api_tokens_d SET last_used_at = p_at WHERE token_id = v_token.token_id;

    RETURN v_state || JSONB_BUILD_OBJECT(
        'ok', TRUE,
        'call_id', v_call,
        'tenant_id', v_token.tenant_id,
        'user_id', v_token.user_id,
        'token_id', v_token.token_id,
        'used', (v_state ->> 'used')::BIGINT + 1,
        'remaining', GREATEST((v_state ->> 'remaining')::BIGINT - 1, 0)
    );
END
$fn$;

CREATE OR REPLACE FUNCTION public.api_consume_call(p_token TEXT, p_operation TEXT)
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
    SELECT public.api_consume_call_at(p_token, p_operation, NOW())
$fn$;

-- After the request: how it ended and how many rows it returned.
CREATE OR REPLACE FUNCTION public.api_finish_call(p_call_id BIGINT, p_status TEXT, p_rows INTEGER)
RETURNS VOID
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
    UPDATE public.api_usage_f
    SET
        status = CASE WHEN p_status IN ('ok', 'error') THEN p_status ELSE 'error' END,
        rows_returned = p_rows
    WHERE call_id = p_call_id AND status = 'accepted'
$fn$;

-- For the token panel: calls used, limit and reset time for the session user.
CREATE OR REPLACE FUNCTION public.api_usage_summary()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
SET timezone = 'America/Mexico_City'
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    RETURN public.api_usage_state(v_tenant, v_user, NOW()) || JSONB_BUILD_OBJECT(
        'recent',
        COALESCE(
            (
                SELECT JSONB_AGG(TO_JSONB(recent) ORDER BY recent.called_at DESC)
                FROM (
                    SELECT usage.called_at, usage.operation, usage.status, usage.rows_returned
                    FROM public.api_usage_f AS usage
                    WHERE usage.tenant_id = v_tenant AND usage.user_id = v_user
                    ORDER BY usage.called_at DESC
                    LIMIT 10
                ) AS recent
            ),
            '[]'::JSONB
        )
    );
END
$fn$;

-- =============================================================================
-- 4. Data behind the GraphQL API
-- =============================================================================
-- Rows of one master for the session user, joined with the attributes.
--   p_months: txn_date on or after (as-of date - p_months months); NULL = no lower bound.
--   p_after:  txn_date strictly after this date (future tabs use today); NULL = none.
--   p_limit:  at most this many rows (newest first are kept), capped at 100000.
CREATE OR REPLACE FUNCTION public.graphql_rows(
    p_table TEXT,
    p_months INTEGER DEFAULT NULL,
    p_after DATE DEFAULT NULL,
    p_as_of DATE DEFAULT NULL,
    p_limit INTEGER DEFAULT 20000
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_as_of DATE := COALESCE(p_as_of, (NOW() AT TIME ZONE 'America/Mexico_City')::DATE);
    v_from DATE;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    IF p_table NOT IN (
        'master_debit_closed_f', 'master_debit_open_f',
        'master_credit_closed_f', 'master_credit_open_f', 'master_credit_future_f'
    ) THEN
        RAISE EXCEPTION 'unknown table %', p_table USING ERRCODE = '22023';
    END IF;
    IF p_months IS NOT NULL AND (p_months < 1 OR p_months > 120) THEN
        RAISE EXCEPTION 'months must be between 1 and 120' USING ERRCODE = '22023';
    END IF;
    IF p_months IS NOT NULL THEN
        v_from := (v_as_of - MAKE_INTERVAL(months => p_months))::DATE;
    END IF;

    RETURN COALESCE(
        (
            SELECT JSONB_AGG(TO_JSONB(picked) ORDER BY picked.txn_date, picked.row_id)
            FROM (
                SELECT
                    keys.row_hash,
                    keys.source_table AS "table",
                    keys.layer,
                    keys.kind,
                    keys.row_id,
                    keys.account_id,
                    keys.account_number,
                    keys.bank_id,
                    keys.bank_name,
                    keys.period_start,
                    keys.period_end,
                    keys.txn_date,
                    keys.concept,
                    keys.concept_sk,
                    keys.abonos,
                    keys.cargos,
                    keys.amount,
                    keys.saldos,
                    keys.tarjeta,
                    keys.occurrence,
                    keys.file_name,
                    COALESCE(debit.attribute_1, credit.attribute_1) AS attribute_1,
                    COALESCE(debit.attribute_2, credit.attribute_2) AS attribute_2,
                    COALESCE(debit.attribute_3, credit.attribute_3) AS attribute_3
                FROM public.movement_keys_v AS keys
                LEFT JOIN public.debit_d AS debit ON keys.kind = 'debit' AND debit.row_hash = keys.row_hash
                LEFT JOIN public.credit_d AS credit ON keys.kind = 'credit' AND credit.row_hash = keys.row_hash
                WHERE
                    keys.tenant_id = v_tenant
                    AND keys.user_id = v_user
                    AND keys.source_table = p_table
                    AND (v_from IS NULL OR keys.txn_date >= v_from)
                    AND (p_after IS NULL OR keys.txn_date > p_after)
                ORDER BY keys.txn_date DESC, keys.row_id DESC
                LIMIT LEAST(GREATEST(COALESCE(p_limit, 20000), 1), 100000)
            ) AS picked
        ),
        '[]'::JSONB
    );
END
$fn$;

-- =============================================================================
-- 5. Row level security and grants
-- =============================================================================
ALTER TABLE public.debit_d ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_d ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.api_tokens_d ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.api_usage_f ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS debit_d_tenant ON public.debit_d;
CREATE POLICY debit_d_tenant ON public.debit_d
FOR ALL
TO strm_app
USING (tenant_id = public.session_tenant() AND user_id = public.session_user())
WITH CHECK (tenant_id = public.session_tenant() AND user_id = public.session_user());

DROP POLICY IF EXISTS credit_d_tenant ON public.credit_d;
CREATE POLICY credit_d_tenant ON public.credit_d
FOR ALL
TO strm_app
USING (tenant_id = public.session_tenant() AND user_id = public.session_user())
WITH CHECK (tenant_id = public.session_tenant() AND user_id = public.session_user());

DROP POLICY IF EXISTS api_tokens_d_tenant ON public.api_tokens_d;
CREATE POLICY api_tokens_d_tenant ON public.api_tokens_d
FOR SELECT
TO strm_app
USING (tenant_id = public.session_tenant() AND user_id = public.session_user());

DROP POLICY IF EXISTS api_usage_f_tenant ON public.api_usage_f;
CREATE POLICY api_usage_f_tenant ON public.api_usage_f
FOR SELECT
TO strm_app
USING (tenant_id = public.session_tenant() AND user_id = public.session_user());

REVOKE ALL ON public.debit_d, public.credit_d, public.api_tokens_d, public.api_usage_f FROM PUBLIC;
GRANT SELECT ON public.debit_d, public.credit_d, public.api_usage_f TO strm_app;
GRANT SELECT (token_id, tenant_id, user_id, token_name, token_prefix, scope, created_at, last_used_at, revoked_at)
ON public.api_tokens_d TO strm_app;

REVOKE ALL ON FUNCTION public.add_movement_attribute_rows() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dimension_summary() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dimension_rows(TEXT, TEXT, DATE, DATE, TEXT, INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.save_dimension(TEXT, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_token_sha(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_api_token(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_api_tokens() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.revoke_api_token(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_window_bounds(TEXT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_usage_state(UUID, UUID, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_consume_call_at(TEXT, TEXT, TIMESTAMPTZ) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_consume_call(TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_finish_call(BIGINT, TEXT, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.api_usage_summary() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.graphql_rows(TEXT, INTEGER, DATE, DATE, INTEGER) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.dimension_summary() TO strm_app;
GRANT EXECUTE ON FUNCTION public.dimension_rows(TEXT, TEXT, DATE, DATE, TEXT, INTEGER, INTEGER) TO strm_app;
GRANT EXECUTE ON FUNCTION public.save_dimension(TEXT, TEXT, TEXT, TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.create_api_token(TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.list_api_tokens() TO strm_app;
GRANT EXECUTE ON FUNCTION public.revoke_api_token(UUID) TO strm_app;
GRANT EXECUTE ON FUNCTION public.api_usage_summary() TO strm_app;
GRANT EXECUTE ON FUNCTION public.graphql_rows(TEXT, INTEGER, DATE, DATE, INTEGER) TO strm_app;
