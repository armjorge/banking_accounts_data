-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- Investments and assets (Infonavit, Afore, CETES, GBM, cash, a car...): accounts, the
-- master_closed_aaccandass_f movements with their attributes (master_closed_aaccandass_d),
-- file upload with a column map, manual rows, reconciliation against the balance the
-- institution shows, and the balance at any date (see docs/investments_assets.md).
--
--   * Account types 'investment' and 'asset' (ledger_kind 'asset', no cutoff day). An
--     asset account belongs to a bank or an institution (banks_d.is_institution); the
--     user can name a new institution. Asset accounts have their own plan limit
--     (plans_d.max_asset_accounts) and do not count toward the bank account limits.
--     Statements, upload completeness and the statement bank picker leave them out.
--   * master_closed_aaccandass_f: four core columns (txn_date, concept -> concept_sk,
--     abonos = money in or gain, cargos = money out or loss, both >= 0), plus the keys
--     of the other masters (row_hash as in 014, occurrence, calendar-month period, file
--     reference). entry_source: 'upload', 'manual' or 'adjustment'. Rows are never
--     updated; an uploaded row goes away only with its file.
--   * aaccandass_templates_d: a saved column map per account (which header is the date,
--     abono, cargo and concept). aaccandass_uploads_f keeps each uploaded file (as CSV),
--     its map and counts; the vault copy is {YYYY-MM}_{account}_{Bank}_inv.csv.
--   * Reconciliation: the user types the balance an institution shows at a date; the
--     difference becomes one 'adjustment' row (aaccandass_checks_f keeps every check).
--   * Balance: master_closed_aaccandass_balance_v (running balance per row),
--     aaccandass_balance (one account at a date) and aaccandass_balances (month ends).
--   * master_closed_aaccandass_d: attribute_1..3 with list support like debit_d /
--     credit_d. movement_keys_v, movement_attributes_v, the Dimensions page functions,
--     list binding and graphql_rows include the new table as kind 'asset', layer 'closed'.
--
-- Safe to run more than once. Requires 016. Apply on Neon by hand after 016.

-- =============================================================================
-- 1. Asset accounts: account types, institutions, plan limit
-- =============================================================================
ALTER TABLE public.account_types_d
DROP CONSTRAINT IF EXISTS account_types_d_ledger_kind_check;

ALTER TABLE public.account_types_d
ADD CONSTRAINT account_types_d_ledger_kind_check CHECK (
    (ledger_kind = 'credit' AND allows_cutoff)
    OR (ledger_kind IN ('debit', 'asset') AND NOT allows_cutoff)
);

-- Identity sequences can trail rows inserted with explicit ids; never hand out a used id.
SELECT SETVAL(
    PG_GET_SERIAL_SEQUENCE('public.account_types_d', 'a_type_id'),
    GREATEST((SELECT COALESCE(MAX(a_type_id), 1) FROM public.account_types_d), 1)
);
SELECT SETVAL(
    PG_GET_SERIAL_SEQUENCE('public.banks_d', 'bank_id'),
    GREATEST((SELECT COALESCE(MAX(bank_id), 1) FROM public.banks_d), 1)
);

INSERT INTO public.account_types_d (type_name, ledger_kind, allows_cutoff)
SELECT
    seed.type_name,
    'asset' AS ledger_kind,
    FALSE AS allows_cutoff
FROM (VALUES ('investment'), ('asset')) AS seed (type_name)
WHERE NOT EXISTS (
    SELECT 1 FROM public.account_types_d AS existing
    WHERE LOWER(existing.type_name) = LOWER(seed.type_name)
);

ALTER TABLE public.banks_d
ADD COLUMN IF NOT EXISTS is_institution BOOLEAN NOT NULL DEFAULT FALSE;

COMMENT ON COLUMN public.banks_d.is_institution IS
'TRUE for investment / asset institutions (Infonavit, Afore, CETES, GBM...) that have no '
'statement profile (sql/017). They are offered only for investment and asset accounts.';

INSERT INTO public.banks_d (bank_name, is_institution)
SELECT
    seed.bank_name,
    TRUE AS is_institution
FROM (
    VALUES ('Infonavit'), ('Afore'), ('Cetesdirecto'), ('GBM'), ('Efectivo'), ('Bienes personales')
) AS seed (bank_name)
WHERE NOT EXISTS (
    SELECT 1 FROM public.banks_d AS existing
    WHERE LOWER(existing.bank_name) = LOWER(seed.bank_name)
);

-- Plan limit for investment and asset accounts. Defaults are written only when the
-- column is first added, so a later edit (NULL = no limit) survives re-running 017.
DO $plan$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'plans_d' AND column_name = 'max_asset_accounts'
    ) THEN
        ALTER TABLE public.plans_d ADD COLUMN max_asset_accounts INTEGER;
        UPDATE public.plans_d
        SET max_asset_accounts = CASE plan_code
            WHEN 'free' THEN 2
            WHEN 'entry' THEN 3
            WHEN 'plus' THEN 10
            WHEN 'premium' THEN 20
            ELSE 2
        END;
    END IF;
END
$plan$;

ALTER TABLE public.plans_d
DROP CONSTRAINT IF EXISTS plans_d_asset_accounts_check;
ALTER TABLE public.plans_d
ADD CONSTRAINT plans_d_asset_accounts_check CHECK (max_asset_accounts IS NULL OR max_asset_accounts BETWEEN 0 AND 100);

COMMENT ON COLUMN public.plans_d.max_asset_accounts IS
'Investment and asset accounts allowed per tenant (sql/017); NULL = no limit. They do not '
'count toward max_credit_accounts, max_debit_accounts or max_total_accounts.';

-- 007 rules for bank accounts, plus asset accounts: any bank or institution (no
-- statement profile needed), no cutoff day, own plan limit.
CREATE OR REPLACE FUNCTION public.enforce_bank_account()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_kind TEXT;
    v_allows BOOLEAN;
    v_plan_name TEXT;
    v_max_credit INTEGER;
    v_max_debit INTEGER;
    v_max_total INTEGER;
    v_max_asset INTEGER;
    v_credit INTEGER;
    v_debit INTEGER;
    v_total INTEGER;
    v_asset INTEGER;
BEGIN
    SELECT kind.ledger_kind, kind.allows_cutoff
    INTO v_kind, v_allows
    FROM public.account_types_d AS kind
    WHERE kind.a_type_id = NEW.a_type_id;

    IF v_kind IS NULL THEN
        RAISE EXCEPTION 'account type not found' USING ERRCODE = '23503';
    END IF;

    IF v_kind = 'asset' THEN
        IF NOT EXISTS (SELECT 1 FROM public.banks_d AS bank WHERE bank.bank_id = NEW.bank_id) THEN
            RAISE EXCEPTION 'institution not found' USING ERRCODE = '23503';
        END IF;
    ELSIF NOT EXISTS (
        SELECT 1
        FROM public.banks_d AS bank
        INNER JOIN public.file_profiles_d AS fp
            ON LOWER(fp.bank_name) = LOWER(bank.bank_name)
        WHERE
            bank.bank_id = NEW.bank_id
            AND fp.active IS TRUE
    ) THEN
        RAISE EXCEPTION 'This bank has no active statement profile' USING ERRCODE = '23514';
    END IF;

    IF NEW.account_number IS NULL OR NEW.account_number !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'Account number must be digits so leading zeros can be kept'
            USING ERRCODE = '23514';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM public.bank_accounts_d AS account
        WHERE
            account.tenant_id = NEW.tenant_id
            AND account.account_number = NEW.account_number
            AND account.account_id IS DISTINCT FROM NEW.account_id
    ) THEN
        RAISE EXCEPTION 'That account number is already open' USING ERRCODE = '23505';
    END IF;

    IF v_allows THEN
        IF NEW.account_cutoff_day IS NULL OR NEW.account_cutoff_day < 1 OR NEW.account_cutoff_day > 31 THEN
            RAISE EXCEPTION 'Credit card accounts require a cutoff day from 1 to 31'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.credit_days IS NULL OR NEW.credit_days < 1 OR NEW.credit_days > 90 THEN
            RAISE EXCEPTION 'Credit card accounts require a payment window from 1 to 90 days'
                USING ERRCODE = '23514';
        END IF;
    ELSIF NEW.account_cutoff_day IS NOT NULL OR NEW.credit_days IS NOT NULL THEN
        IF v_kind = 'asset' THEN
            RAISE EXCEPTION 'Investment and asset accounts do not have a cutoff day or payment window'
                USING ERRCODE = '23514';
        END IF;
        RAISE EXCEPTION 'Debit accounts do not have a cutoff day or payment window'
            USING ERRCODE = '23514';
    END IF;

    SELECT
        plan.display_name,
        plan.max_credit_accounts,
        plan.max_debit_accounts,
        plan.max_total_accounts,
        plan.max_asset_accounts
    INTO v_plan_name, v_max_credit, v_max_debit, v_max_total, v_max_asset
    FROM public.tenants_d AS tenant
    INNER JOIN public.plans_d AS plan ON plan.plan_code = tenant.plan_code
    WHERE tenant.tenant_id = NEW.tenant_id;

    SELECT
        COUNT(*) FILTER (WHERE kind.ledger_kind = 'credit'),
        COUNT(*) FILTER (WHERE kind.ledger_kind = 'debit'),
        COUNT(*) FILTER (WHERE kind.ledger_kind <> 'asset'),
        COUNT(*) FILTER (WHERE kind.ledger_kind = 'asset')
    INTO v_credit, v_debit, v_total, v_asset
    FROM public.bank_accounts_d AS account
    INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
    WHERE
        account.tenant_id = NEW.tenant_id
        AND account.account_id IS DISTINCT FROM NEW.account_id;

    IF v_kind = 'asset' THEN
        IF v_max_asset IS NOT NULL AND v_asset >= v_max_asset THEN
            RAISE EXCEPTION 'The % plan allows at most % investment or asset account(s)', v_plan_name, v_max_asset
                USING ERRCODE = '23514';
        END IF;
        RETURN NEW;
    END IF;

    IF v_kind = 'credit' AND v_max_credit IS NOT NULL AND v_credit >= v_max_credit THEN
        RAISE EXCEPTION 'The % plan allows at most % credit account(s)', v_plan_name, v_max_credit
            USING ERRCODE = '23514';
    END IF;

    IF v_kind = 'debit' AND v_max_debit IS NOT NULL AND v_debit >= v_max_debit THEN
        RAISE EXCEPTION 'The % plan allows at most % debit account(s)', v_plan_name, v_max_debit
            USING ERRCODE = '23514';
    END IF;

    IF v_max_total IS NOT NULL AND v_total >= v_max_total THEN
        RAISE EXCEPTION 'The % plan allows at most % account(s) in total', v_plan_name, v_max_total
            USING ERRCODE = '23514';
    END IF;

    RETURN NEW;
END
$fn$;

-- Internal: the session user's investment / asset account (raises when it is not one).
CREATE OR REPLACE FUNCTION public.aaccandass_account(p_tenant UUID, p_user UUID, p_account_id INTEGER)
RETURNS TABLE (
    account_id INTEGER,
    account_name TEXT,
    account_number TEXT,
    bank_id INTEGER,
    bank_name TEXT,
    type_name TEXT
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
    RETURN QUERY
    SELECT account.account_id, account.account_name, account.account_number, bank.bank_id, bank.bank_name, kind.type_name
    FROM public.bank_accounts_d AS account
    INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
    INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
    WHERE
        account.account_id = p_account_id
        AND account.tenant_id = p_tenant
        AND account.user_id = p_user
        AND kind.ledger_kind = 'asset';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'investment or asset account not found' USING ERRCODE = 'P0002';
    END IF;
END
$fn$;

-- Page: open an investment or asset account. p_bank_id picks a bank or institution;
-- without it p_institution names one (created when missing). A blank account number
-- gets a generated one (digits, unique for the tenant).
CREATE OR REPLACE FUNCTION public.create_asset_account(
    p_bank_id INTEGER,
    p_institution TEXT,
    p_a_type_id INTEGER,
    p_account_name TEXT,
    p_account_number TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_name TEXT := public.list_clean_name(p_account_name);
    v_institution TEXT := public.list_clean_name(p_institution);
    v_number TEXT := REGEXP_REPLACE(COALESCE(p_account_number, ''), '\s+', '', 'g');
    v_type INTEGER := p_a_type_id;
    v_bank INTEGER := p_bank_id;
    v_next INTEGER;
    v_account INTEGER;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    IF v_name IS NULL OR LENGTH(v_name) > 100 THEN
        RAISE EXCEPTION 'An account name needs 1 to 100 characters' USING ERRCODE = '22023';
    END IF;
    IF v_type IS NULL THEN
        SELECT kind.a_type_id INTO v_type
        FROM public.account_types_d AS kind
        WHERE LOWER(kind.type_name) = 'investment';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.account_types_d AS kind
        WHERE kind.a_type_id = v_type AND kind.ledger_kind = 'asset'
    ) THEN
        RAISE EXCEPTION 'Pick an investment or asset account type' USING ERRCODE = '22023';
    END IF;
    IF v_bank IS NULL THEN
        IF v_institution IS NULL OR LENGTH(v_institution) > 60 THEN
            RAISE EXCEPTION 'Pick an institution or type its name (up to 60 characters)' USING ERRCODE = '22023';
        END IF;
        INSERT INTO public.banks_d (bank_name, is_institution)
        VALUES (v_institution, TRUE)
        ON CONFLICT ((LOWER(bank_name))) DO NOTHING;
        SELECT bank.bank_id INTO v_bank
        FROM public.banks_d AS bank
        WHERE LOWER(bank.bank_name) = LOWER(v_institution);
    END IF;
    IF v_number = '' THEN
        SELECT COALESCE(MAX(SUBSTR(account.account_number, 2)::INTEGER), 0) + 1
        INTO v_next
        FROM public.bank_accounts_d AS account
        WHERE account.tenant_id = v_tenant AND account.account_number ~ '^9[0-9]{5}$';
        v_number := '9' || LPAD(v_next::TEXT, 5, '0');
    ELSIF v_number !~ '^[0-9]{1,30}$' THEN
        RAISE EXCEPTION 'Use digits only for the account number, or leave it blank' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.bank_accounts_d (bank_id, user_id, tenant_id, a_type_id, account_name, account_number)
    VALUES (v_bank, v_user, v_tenant, v_type, v_name, v_number)
    RETURNING bank_accounts_d.account_id INTO v_account;

    RETURN (
        SELECT JSONB_BUILD_OBJECT(
            'account_id', picked.account_id,
            'account_name', picked.account_name,
            'account_number', picked.account_number,
            'bank_id', picked.bank_id,
            'bank_name', picked.bank_name,
            'type_name', picked.type_name
        )
        FROM public.aaccandass_account(v_tenant, v_user, v_account) AS picked
    );
END
$fn$;

-- =============================================================================
-- 2. Tables: column-map templates, uploads, movements, attributes, balance checks
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.aaccandass_templates_d (
    template_id BIGINT GENERATED BY DEFAULT AS IDENTITY,
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    template_name TEXT NOT NULL,
    mapping JSONB NOT NULL,
    headers TEXT [],
    last_used_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    updated_at TIMESTAMPTZ,
    updated_by UUID,
    CONSTRAINT aaccandass_templates_d_pkey PRIMARY KEY (template_id),
    CONSTRAINT aaccandass_templates_d_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT aaccandass_templates_d_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id) ON DELETE CASCADE,
    CONSTRAINT aaccandass_templates_d_name_check CHECK (
        LENGTH(template_name) BETWEEN 1 AND 60 AND template_name = BTRIM(template_name)
    ),
    CONSTRAINT aaccandass_templates_d_mapping_check CHECK (JSONB_TYPEOF(mapping) = 'object')
);

CREATE UNIQUE INDEX IF NOT EXISTS aaccandass_templates_d_name_idx
ON public.aaccandass_templates_d (account_id, LOWER(template_name));
CREATE INDEX IF NOT EXISTS aaccandass_templates_d_tenant_idx
ON public.aaccandass_templates_d (tenant_id, user_id);

COMMENT ON TABLE public.aaccandass_templates_d IS
'Saved column maps of an investment / asset account (sql/017): which file header is '
'txn_date, abono, cargo and concept. See aaccandass_clean_mapping for the keys.';

CREATE TABLE IF NOT EXISTS public.aaccandass_uploads_f (
    upload_id UUID NOT NULL DEFAULT GEN_RANDOM_UUID(),
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    template_id BIGINT,
    original_filename TEXT NOT NULL,
    chosen_filename TEXT NOT NULL,
    source_format TEXT NOT NULL DEFAULT 'csv',
    content_sha256 TEXT NOT NULL,
    byte_size INTEGER NOT NULL,
    body_text TEXT NOT NULL,
    mapping JSONB NOT NULL,
    headers TEXT [] NOT NULL,
    row_count INTEGER NOT NULL DEFAULT 0,
    inserted_count INTEGER NOT NULL DEFAULT 0,
    duplicate_count INTEGER NOT NULL DEFAULT 0,
    skipped_count INTEGER NOT NULL DEFAULT 0,
    first_txn_date DATE,
    last_txn_date DATE,
    total_abonos NUMERIC(18, 2),
    total_cargos NUMERIC(18, 2),
    storage_mode TEXT NOT NULL DEFAULT 'database',
    curated_s3_key TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT aaccandass_uploads_f_pkey PRIMARY KEY (upload_id),
    CONSTRAINT aaccandass_uploads_f_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT aaccandass_uploads_f_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id),
    CONSTRAINT aaccandass_uploads_f_template_fkey
    FOREIGN KEY (template_id) REFERENCES public.aaccandass_templates_d (template_id) ON DELETE SET NULL,
    CONSTRAINT aaccandass_uploads_f_format_check CHECK (source_format IN ('csv', 'xlsx')),
    CONSTRAINT aaccandass_uploads_f_storage_check CHECK (storage_mode IN ('database', 'curated')),
    CONSTRAINT aaccandass_uploads_f_sha_check CHECK (content_sha256 ~ '^[0-9a-f]{64}$')
);

CREATE INDEX IF NOT EXISTS aaccandass_uploads_f_account_idx
ON public.aaccandass_uploads_f (account_id, created_at);
CREATE INDEX IF NOT EXISTS aaccandass_uploads_f_tenant_idx
ON public.aaccandass_uploads_f (tenant_id, user_id);

COMMENT ON TABLE public.aaccandass_uploads_f IS
'Files uploaded to an investment / asset account (sql/017), kept as CSV with the column '
'map used. Spreadsheets are converted to CSV in the browser, like statement uploads.';

CREATE TABLE IF NOT EXISTS public.master_closed_aaccandass_f (
    row_id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    row_hash TEXT NOT NULL,
    file_id UUID,
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    bank_id INTEGER NOT NULL,
    account_number TEXT NOT NULL,
    bank_name TEXT NOT NULL,
    file_name TEXT,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    txn_date DATE NOT NULL,
    concept TEXT NOT NULL,
    concept_sk TEXT NOT NULL,
    abonos NUMERIC(18, 2) NOT NULL DEFAULT 0,
    cargos NUMERIC(18, 2) NOT NULL DEFAULT 0,
    amount NUMERIC(18, 2) NOT NULL,
    occurrence INTEGER NOT NULL,
    entry_source TEXT NOT NULL,
    source_line INTEGER,
    reported_balance NUMERIC(18, 2),
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    CONSTRAINT master_closed_aaccandass_f_pkey PRIMARY KEY (row_id),
    CONSTRAINT master_closed_aaccandass_f_hash_key UNIQUE (row_hash),
    CONSTRAINT master_closed_aaccandass_f_file_fkey
    FOREIGN KEY (file_id) REFERENCES public.aaccandass_uploads_f (upload_id),
    CONSTRAINT master_closed_aaccandass_f_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT master_closed_aaccandass_f_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id),
    CONSTRAINT master_closed_aaccandass_f_bank_fkey
    FOREIGN KEY (bank_id) REFERENCES public.banks_d (bank_id),
    CONSTRAINT master_closed_aaccandass_f_account_number_check CHECK (account_number ~ '^[0-9]+$'),
    CONSTRAINT master_closed_aaccandass_f_concept_sk_check CHECK (LENGTH(concept_sk) > 0),
    CONSTRAINT master_closed_aaccandass_f_occurrence_check CHECK (occurrence >= 1),
    CONSTRAINT master_closed_aaccandass_f_hash_check CHECK (LENGTH(row_hash) = 64),
    CONSTRAINT master_closed_aaccandass_f_sign_check CHECK (abonos >= 0 AND cargos >= 0 AND (abonos > 0 OR cargos > 0)),
    CONSTRAINT master_closed_aaccandass_f_amount_check CHECK (amount = abonos - cargos),
    CONSTRAINT master_closed_aaccandass_f_source_check CHECK (
        entry_source IN ('upload', 'manual', 'adjustment')
        AND (entry_source = 'upload') = (file_id IS NOT NULL)
    ),
    CONSTRAINT master_closed_aaccandass_f_period_check CHECK (txn_date BETWEEN period_start AND period_end),
    CONSTRAINT master_closed_aaccandass_f_note_check CHECK (COALESCE(LENGTH(note), 0) <= 500)
);

CREATE INDEX IF NOT EXISTS master_closed_aaccandass_f_account_idx
ON public.master_closed_aaccandass_f (account_id, txn_date, row_id);
CREATE INDEX IF NOT EXISTS master_closed_aaccandass_f_file_idx
ON public.master_closed_aaccandass_f (file_id);
CREATE INDEX IF NOT EXISTS master_closed_aaccandass_f_tenant_idx
ON public.master_closed_aaccandass_f (tenant_id, user_id);

COMMENT ON TABLE public.master_closed_aaccandass_f IS
'Investment and asset movements (sql/017). abonos = money in or gain, cargos = money out '
'or loss, both stored positive; amount = abonos - cargos. The balance of an account at a '
'date is the sum of amount up to that date (master_closed_aaccandass_balance_v).';
COMMENT ON COLUMN public.master_closed_aaccandass_f.row_hash IS
'movement_row_hash_v2(user_id, account_id, bank_id, txn_date, concept_sk, abonos, cargos, '
'occurrence), as in the other masters (sql/014). occurrence numbers identical rows within '
'one upload; manual and adjustment rows take the next free occurrence.';
COMMENT ON COLUMN public.master_closed_aaccandass_f.entry_source IS
'upload = from a file (file_id), manual = typed by the user, adjustment = difference '
'against the balance the institution shows (reconcile_aaccandass).';
COMMENT ON COLUMN public.master_closed_aaccandass_f.period_start IS
'Calendar month of txn_date (investment accounts have no cutoff day).';

DROP TRIGGER IF EXISTS master_closed_aaccandass_f_no_update ON public.master_closed_aaccandass_f;
CREATE TRIGGER master_closed_aaccandass_f_no_update
BEFORE UPDATE ON public.master_closed_aaccandass_f
FOR EACH ROW
EXECUTE FUNCTION public.reject_closed_row_update();

CREATE TABLE IF NOT EXISTS public.master_closed_aaccandass_d (
    row_hash TEXT NOT NULL,
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    attribute_1 TEXT,
    attribute_2 TEXT,
    attribute_3 TEXT,
    attribute_1_item_id BIGINT,
    attribute_2_item_id BIGINT,
    attribute_3_item_id BIGINT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    updated_at TIMESTAMPTZ,
    updated_by UUID,
    CONSTRAINT master_closed_aaccandass_d_pkey PRIMARY KEY (row_hash),
    CONSTRAINT master_closed_aaccandass_d_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT master_closed_aaccandass_d_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id) ON DELETE CASCADE,
    CONSTRAINT master_closed_aaccandass_d_attribute_1_item_fkey
    FOREIGN KEY (attribute_1_item_id) REFERENCES public.list_d (item_id),
    CONSTRAINT master_closed_aaccandass_d_attribute_2_item_fkey
    FOREIGN KEY (attribute_2_item_id) REFERENCES public.list_d (item_id),
    CONSTRAINT master_closed_aaccandass_d_attribute_3_item_fkey
    FOREIGN KEY (attribute_3_item_id) REFERENCES public.list_d (item_id),
    CONSTRAINT master_closed_aaccandass_d_hash_check CHECK (LENGTH(row_hash) = 64),
    CONSTRAINT master_closed_aaccandass_d_attribute_check CHECK (
        COALESCE(LENGTH(attribute_1), 0) <= 500
        AND COALESCE(LENGTH(attribute_2), 0) <= 500
        AND COALESCE(LENGTH(attribute_3), 0) <= 500
    )
);

CREATE INDEX IF NOT EXISTS master_closed_aaccandass_d_tenant_idx
ON public.master_closed_aaccandass_d (tenant_id, user_id);
CREATE INDEX IF NOT EXISTS master_closed_aaccandass_d_account_idx
ON public.master_closed_aaccandass_d (account_id);
CREATE INDEX IF NOT EXISTS master_closed_aaccandass_d_attribute_1_item_idx
ON public.master_closed_aaccandass_d (attribute_1_item_id) WHERE attribute_1_item_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS master_closed_aaccandass_d_attribute_2_item_idx
ON public.master_closed_aaccandass_d (attribute_2_item_id) WHERE attribute_2_item_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS master_closed_aaccandass_d_attribute_3_item_idx
ON public.master_closed_aaccandass_d (attribute_3_item_id) WHERE attribute_3_item_id IS NOT NULL;

COMMENT ON TABLE public.master_closed_aaccandass_d IS
'User attributes of investment / asset movements (master_closed_aaccandass_f), one row per '
'row_hash, with list-bound slots like debit_d / credit_d (sql/016, sql/017).';

DROP TRIGGER IF EXISTS master_closed_aaccandass_f_attribute_rows ON public.master_closed_aaccandass_f;
CREATE TRIGGER master_closed_aaccandass_f_attribute_rows
AFTER INSERT ON public.master_closed_aaccandass_f
REFERENCING NEW TABLE AS added_rows
FOR EACH STATEMENT EXECUTE FUNCTION public.add_movement_attribute_rows('master_closed_aaccandass_d');

CREATE TABLE IF NOT EXISTS public.aaccandass_checks_f (
    check_id BIGINT GENERATED BY DEFAULT AS IDENTITY,
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    as_of DATE NOT NULL,
    reported_balance NUMERIC(18, 2) NOT NULL,
    tracked_balance NUMERIC(18, 2) NOT NULL,
    difference NUMERIC(18, 2) NOT NULL,
    adjustment_hash TEXT,
    adjustment_date DATE,
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    CONSTRAINT aaccandass_checks_f_pkey PRIMARY KEY (check_id),
    CONSTRAINT aaccandass_checks_f_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT aaccandass_checks_f_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id) ON DELETE CASCADE,
    CONSTRAINT aaccandass_checks_f_difference_check CHECK (difference = reported_balance - tracked_balance)
);

CREATE INDEX IF NOT EXISTS aaccandass_checks_f_account_idx ON public.aaccandass_checks_f (account_id, as_of);
CREATE INDEX IF NOT EXISTS aaccandass_checks_f_tenant_idx ON public.aaccandass_checks_f (tenant_id, user_id);

COMMENT ON TABLE public.aaccandass_checks_f IS
'Every balance the user typed for an investment / asset account (sql/017): what the '
'institution showed, what the rows added up to, and the adjustment row (if any).';

-- Running balance per row: cumulative abonos - cargos per account, by date then row_id
-- (an adjustment stored later on the same date comes after the rows of that day).
CREATE OR REPLACE VIEW public.master_closed_aaccandass_balance_v
WITH (security_invoker = TRUE) AS
SELECT
    movement.row_hash,
    movement.row_id,
    movement.tenant_id,
    movement.user_id,
    movement.account_id,
    movement.txn_date,
    movement.abonos,
    movement.cargos,
    movement.amount,
    movement.entry_source,
    SUM(movement.amount) OVER (
        PARTITION BY movement.account_id
        ORDER BY movement.txn_date, movement.row_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    )::NUMERIC(18, 2) AS balance
FROM public.master_closed_aaccandass_f AS movement;

COMMENT ON VIEW public.master_closed_aaccandass_balance_v IS
'master_closed_aaccandass_f with the account balance after each row (sql/017).';

-- =============================================================================
-- 3. Column map: dates, concept expression, mapped rows
-- =============================================================================
-- Dates as investment files write them: YYYY-MM-DD (optionally with a time), D/M/Y (or
-- M/D/Y, Y/M/D by p_format) with '/', '-' or '.', two-digit years (20xx), Spanish month
-- names (14-sep-2026), and Excel serial numbers (46279). NULL for blank text; raises
-- 22007 for anything else.
CREATE OR REPLACE FUNCTION public.aaccandass_parse_date(p_text TEXT, p_format TEXT DEFAULT 'DMY')
RETURNS DATE
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_text TEXT := BTRIM(REPLACE(COALESCE(p_text, ''), CHR(160), ' '));
    v_parts TEXT [];
    v_a INTEGER;
    v_b INTEGER;
    v_year INTEGER;
    v_format TEXT := UPPER(COALESCE(NULLIF(BTRIM(p_format), ''), 'DMY'));
    v_spanish DATE;
BEGIN
    IF v_text = '' THEN
        RETURN NULL;
    END IF;
    v_parts := REGEXP_MATCH(v_text, '^(\d{4})[-/.](\d{1,2})[-/.](\d{1,2})([ T]\d{1,2}:\d{2}(:\d{2}(\.\d+)?)?)?$');
    IF v_parts IS NOT NULL THEN
        RETURN MAKE_DATE(v_parts[1]::INTEGER, v_parts[2]::INTEGER, v_parts[3]::INTEGER);
    END IF;
    v_parts := REGEXP_MATCH(v_text, '^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2}|\d{4})( \d{1,2}:\d{2}(:\d{2})?)?$');
    IF v_parts IS NOT NULL THEN
        v_a := v_parts[1]::INTEGER;
        v_b := v_parts[2]::INTEGER;
        v_year := v_parts[3]::INTEGER;
        IF v_year < 100 THEN
            v_year := 2000 + v_year;
        END IF;
        IF v_format = 'MDY' THEN
            RETURN MAKE_DATE(v_year, v_a, v_b);
        END IF;
        RETURN MAKE_DATE(v_year, v_b, v_a);
    END IF;
    IF v_text ~ '^\d{5}(\.\d+)?$' AND FLOOR(v_text::NUMERIC) BETWEEN 20000 AND 80000 THEN
        RETURN DATE '1899-12-30' + FLOOR(v_text::NUMERIC)::INTEGER;
    END IF;
    v_spanish := public.spanish_short_date(v_text);
    IF v_spanish IS NOT NULL THEN
        RETURN v_spanish;
    END IF;
    RAISE EXCEPTION 'unreadable date: %', v_text USING ERRCODE = '22007';
EXCEPTION
    WHEN datetime_field_overflow OR invalid_datetime_format OR numeric_value_out_of_range THEN
        RAISE EXCEPTION 'unreadable date: %', v_text USING ERRCODE = '22007';
END
$fn$;

-- Concept parts of a map: an expression like
--   Num. De Registro Patronal || ' - ' || Nombre de la empresa
-- (single-quoted text is literal, anything else is a column name; "quoted" names too),
-- or a JSON array of column names joined with p_separator. Returns
-- [{"column": name} | {"text": literal}, ...].
CREATE OR REPLACE FUNCTION public.aaccandass_concept_parts(p_concept JSONB, p_separator TEXT DEFAULT ' - ')
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_parts JSONB := '[]'::JSONB;
    v_token TEXT;
    v_index INTEGER := 0;
    v_item JSONB;
BEGIN
    IF p_concept IS NULL OR JSONB_TYPEOF(p_concept) = 'null' THEN
        RETURN '[]'::JSONB;
    END IF;
    IF JSONB_TYPEOF(p_concept) = 'array' THEN
        FOR v_item IN SELECT value FROM JSONB_ARRAY_ELEMENTS(p_concept) LOOP
            CONTINUE WHEN JSONB_TYPEOF(v_item) <> 'string' OR BTRIM(v_item #>> '{}') = '';
            IF v_index > 0 AND COALESCE(p_separator, '') <> '' THEN
                v_parts := v_parts || JSONB_BUILD_ARRAY(JSONB_BUILD_OBJECT('text', p_separator));
            END IF;
            v_parts := v_parts || JSONB_BUILD_ARRAY(JSONB_BUILD_OBJECT('column', BTRIM(v_item #>> '{}')));
            v_index := v_index + 1;
        END LOOP;
        RETURN v_parts;
    END IF;
    IF JSONB_TYPEOF(p_concept) <> 'string' THEN
        RAISE EXCEPTION 'concept must be text or a list of columns' USING ERRCODE = '22023';
    END IF;
    FOREACH v_token IN ARRAY REGEXP_SPLIT_TO_ARRAY(p_concept #>> '{}', '\|\|') LOOP
        IF v_token ~ '^\s*''.*''\s*$' THEN
            v_parts := v_parts || JSONB_BUILD_ARRAY(JSONB_BUILD_OBJECT(
                'text', REPLACE(SUBSTRING(v_token FROM '^\s*''(.*)''\s*$'), '''''', '''')
            ));
        ELSIF BTRIM(v_token) ~ '^".*"$' THEN
            v_parts := v_parts || JSONB_BUILD_ARRAY(JSONB_BUILD_OBJECT(
                'column', BTRIM(SUBSTRING(BTRIM(v_token) FROM '^"(.*)"$'))
            ));
        ELSIF BTRIM(v_token) <> '' THEN
            v_parts := v_parts || JSONB_BUILD_ARRAY(JSONB_BUILD_OBJECT('column', BTRIM(v_token)));
        END IF;
    END LOOP;
    RETURN v_parts;
END
$fn$;

-- Checks a column map and fills defaults. Keys:
--   header_row        1-based line of the headers (default 1)
--   txn_date          column with the date (required)
--   date_format       DMY (default), MDY or YMD, for dates like 05/09/2026
--   abono             column with money in / gains (optional)
--   cargo             column with money out / losses; null, "" or {"constant": 0} = none
--   amount            one signed column instead of abono/cargo: > 0 abono, < 0 cargo
--   concept           expression (A || ' - ' || B) or a list of columns
--   concept_separator joins a list of concept columns (default ' - ')
--   concept_default   concept when the mapped one is blank (default 'Movimiento')
--   delimiter         CSV delimiter (default ',')
-- Signs: a negative abono is stored as a cargo; cargos are stored as their absolute value.
CREATE OR REPLACE FUNCTION public.aaccandass_clean_mapping(p_mapping JSONB)
RETURNS JSONB
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_map JSONB := COALESCE(p_mapping, '{}'::JSONB);
    v_text TEXT;
    v_header INTEGER := 1;
    v_cargo JSONB;
    v_out JSONB;
    v_key TEXT;
BEGIN
    IF JSONB_TYPEOF(v_map) <> 'object' THEN
        RAISE EXCEPTION 'The column map must be an object' USING ERRCODE = '22023';
    END IF;
    IF v_map ? 'header_row' AND JSONB_TYPEOF(v_map -> 'header_row') <> 'null' THEN
        BEGIN
            v_header := (v_map ->> 'header_row')::INTEGER;
        EXCEPTION WHEN invalid_text_representation THEN
            RAISE EXCEPTION 'header_row must be a whole number' USING ERRCODE = '22023';
        END;
        IF v_header < 1 OR v_header > 50 THEN
            RAISE EXCEPTION 'header_row must be between 1 and 50' USING ERRCODE = '22023';
        END IF;
    END IF;
    v_cargo := v_map -> 'cargo';
    IF v_cargo IS NOT NULL AND JSONB_TYPEOF(v_cargo) = 'object' THEN
        IF COALESCE((v_cargo ->> 'constant')::NUMERIC, 0) <> 0 THEN
            RAISE EXCEPTION 'A constant cargo can only be 0' USING ERRCODE = '22023';
        END IF;
        v_cargo := NULL;
    END IF;
    v_out := JSONB_BUILD_OBJECT(
        'header_row', v_header,
        'txn_date', NULLIF(BTRIM(COALESCE(v_map ->> 'txn_date', '')), ''),
        'date_format', UPPER(COALESCE(NULLIF(BTRIM(v_map ->> 'date_format'), ''), 'DMY')),
        'abono', NULLIF(BTRIM(COALESCE(v_map ->> 'abono', '')), ''),
        'cargo', NULLIF(BTRIM(COALESCE(v_cargo #>> '{}', '')), ''),
        'amount', NULLIF(BTRIM(COALESCE(v_map ->> 'amount', '')), ''),
        'concept', COALESCE(v_map -> 'concept', 'null'::JSONB),
        'concept_separator', COALESCE(v_map ->> 'concept_separator', ' - '),
        'concept_default', COALESCE(NULLIF(BTRIM(v_map ->> 'concept_default'), ''), 'Movimiento'),
        'delimiter', COALESCE(NULLIF(v_map ->> 'delimiter', ''), ',')
    );
    IF v_out ->> 'date_format' NOT IN ('DMY', 'MDY', 'YMD') THEN
        RAISE EXCEPTION 'date_format must be DMY, MDY or YMD' USING ERRCODE = '22023';
    END IF;
    IF LENGTH(v_out ->> 'delimiter') <> 1 THEN
        RAISE EXCEPTION 'The delimiter must be one character' USING ERRCODE = '22023';
    END IF;
    IF v_out ->> 'amount' IS NOT NULL AND (v_out ->> 'abono' IS NOT NULL OR v_out ->> 'cargo' IS NOT NULL) THEN
        RAISE EXCEPTION 'Map either one signed amount column or abono / cargo columns, not both' USING ERRCODE = '22023';
    END IF;
    FOREACH v_key IN ARRAY ARRAY['concept_separator', 'concept_default'] LOOP
        v_text := v_out ->> v_key;
        IF LENGTH(v_text) > 100 THEN
            RAISE EXCEPTION '% can have at most 100 characters', v_key USING ERRCODE = '22023';
        END IF;
    END LOOP;
    -- Validates the concept shape now (raises on a number or an object).
    PERFORM public.aaccandass_concept_parts(v_out -> 'concept', v_out ->> 'concept_separator');
    RETURN v_out;
END
$fn$;

-- True when the map has what a row needs: a date column and at least one amount column.
CREATE OR REPLACE FUNCTION public.aaccandass_mapping_ready(p_mapping JSONB)
RETURNS BOOLEAN
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT p_mapping ->> 'txn_date' IS NOT NULL
        AND COALESCE(p_mapping ->> 'abono', p_mapping ->> 'cargo', p_mapping ->> 'amount') IS NOT NULL
$fn$;

-- Index (1-based) of a header, matched like statement headers (case, accents and spaces
-- ignored). Raises when the file has no such column.
CREATE OR REPLACE FUNCTION public.aaccandass_column_index(p_headers TEXT [], p_name TEXT)
RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_index INTEGER;
BEGIN
    IF p_name IS NULL THEN
        RETURN NULL;
    END IF;
    SELECT header.ordinality INTO v_index
    FROM UNNEST(p_headers) WITH ORDINALITY AS header (name, ordinality)
    WHERE public.normalize_header(header.name) = public.normalize_header(p_name)
    ORDER BY header.ordinality
    LIMIT 1;
    IF v_index IS NULL THEN
        RAISE EXCEPTION 'Column "%" is not in the file', p_name USING ERRCODE = '22023';
    END IF;
    RETURN v_index;
END
$fn$;

-- Header row of a CSV for a map (no session; pure).
CREATE OR REPLACE FUNCTION public.aaccandass_headers(p_csv TEXT, p_mapping JSONB)
RETURNS TEXT []
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT COALESCE(
        (
            SELECT ARRAY(SELECT BTRIM(field) FROM UNNEST(record.fields) AS field)
            FROM public.parse_csv(p_csv, COALESCE(p_mapping ->> 'delimiter', ',')) AS record
            WHERE record.record_no = COALESCE((p_mapping ->> 'header_row')::INTEGER, 1)
        ),
        ARRAY[]::TEXT []
    )
$fn$;

-- Every data line of a CSV under a (clean) map: status 'ok' with the four core values,
-- or 'skipped' with the reason. Blank lines are not returned.
CREATE OR REPLACE FUNCTION public.aaccandass_map_rows(p_csv TEXT, p_mapping JSONB)
RETURNS TABLE (
    line_no INTEGER,
    txn_date DATE,
    concept TEXT,
    abonos NUMERIC(18, 2),
    cargos NUMERIC(18, 2),
    status TEXT,
    reason TEXT,
    fields TEXT []
)
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_map JSONB := public.aaccandass_clean_mapping(p_mapping);
    v_header_row INTEGER := (v_map ->> 'header_row')::INTEGER;
    v_headers TEXT [];
    v_date_col INTEGER;
    v_abono_col INTEGER;
    v_cargo_col INTEGER;
    v_amount_col INTEGER;
    v_parts JSONB;
    v_part JSONB;
    v_concept_cols INTEGER [] := ARRAY[]::INTEGER [];
    v_record RECORD;
    v_value NUMERIC;
    v_text TEXT;
    v_index INTEGER;
BEGIN
    IF NOT public.aaccandass_mapping_ready(v_map) THEN
        RAISE EXCEPTION 'Map the date column and at least one amount column (abono, cargo or amount)'
        USING ERRCODE = '22023';
    END IF;
    v_headers := public.aaccandass_headers(p_csv, v_map);
    IF CARDINALITY(v_headers) = 0 THEN
        RAISE EXCEPTION 'The file has no line %', v_header_row USING ERRCODE = '22023';
    END IF;
    v_date_col := public.aaccandass_column_index(v_headers, v_map ->> 'txn_date');
    v_abono_col := public.aaccandass_column_index(v_headers, v_map ->> 'abono');
    v_cargo_col := public.aaccandass_column_index(v_headers, v_map ->> 'cargo');
    v_amount_col := public.aaccandass_column_index(v_headers, v_map ->> 'amount');
    v_parts := public.aaccandass_concept_parts(v_map -> 'concept', v_map ->> 'concept_separator');
    FOR v_part IN SELECT value FROM JSONB_ARRAY_ELEMENTS(v_parts) LOOP
        v_concept_cols := v_concept_cols || COALESCE(public.aaccandass_column_index(v_headers, v_part ->> 'column'), 0);
    END LOOP;

    FOR v_record IN
        SELECT record.record_no, record.fields
        FROM public.parse_csv(p_csv, v_map ->> 'delimiter') AS record
        WHERE record.record_no > v_header_row
        ORDER BY record.record_no
    LOOP
        CONTINUE WHEN NOT EXISTS (SELECT 1 FROM UNNEST(v_record.fields) AS field WHERE BTRIM(field) <> '');
        line_no := v_record.record_no;
        fields := v_record.fields;
        txn_date := NULL;
        abonos := 0;
        cargos := 0;
        status := 'ok';
        reason := NULL;

        -- Concept: the parts in order; a blank result takes concept_default.
        concept := '';
        v_index := 0;
        FOR v_part IN SELECT value FROM JSONB_ARRAY_ELEMENTS(v_parts) LOOP
            v_index := v_index + 1;
            IF v_part ? 'text' THEN
                concept := concept || (v_part ->> 'text');
            ELSE
                concept := concept || BTRIM(COALESCE(v_record.fields[v_concept_cols[v_index]], ''));
            END IF;
        END LOOP;
        concept := BTRIM(REGEXP_REPLACE(concept, '\s+', ' ', 'g'));
        IF public.concept_sk(concept) = '' THEN
            concept := v_map ->> 'concept_default';
        END IF;
        concept := LEFT(concept, 500);

        BEGIN
            v_text := BTRIM(COALESCE(v_record.fields[v_date_col], ''));
            IF v_text = '' THEN
                status := 'skipped';
                reason := 'no date';
            ELSE
                txn_date := public.aaccandass_parse_date(v_text, v_map ->> 'date_format');
            END IF;
        EXCEPTION WHEN invalid_datetime_format THEN
            status := 'skipped';
            reason := FORMAT('unreadable date "%s"', LEFT(v_text, 40));
        END;

        IF status = 'ok' THEN
            BEGIN
                IF v_amount_col IS NOT NULL THEN
                    v_value := COALESCE(public.parse_amount(v_record.fields[v_amount_col]), 0);
                    IF v_value >= 0 THEN
                        abonos := v_value;
                    ELSE
                        cargos := -v_value;
                    END IF;
                ELSE
                    IF v_abono_col IS NOT NULL THEN
                        v_value := COALESCE(public.parse_amount(v_record.fields[v_abono_col]), 0);
                        IF v_value >= 0 THEN
                            abonos := abonos + v_value;
                        ELSE
                            cargos := cargos - v_value;
                        END IF;
                    END IF;
                    IF v_cargo_col IS NOT NULL THEN
                        cargos := cargos + ABS(COALESCE(public.parse_amount(v_record.fields[v_cargo_col]), 0));
                    END IF;
                END IF;
                abonos := ROUND(abonos, 2);
                cargos := ROUND(cargos, 2);
                IF abonos = 0 AND cargos = 0 THEN
                    status := 'skipped';
                    reason := 'amount is zero';
                END IF;
            EXCEPTION WHEN invalid_text_representation OR numeric_value_out_of_range THEN
                status := 'skipped';
                reason := 'unreadable amount';
                abonos := 0;
                cargos := 0;
            END;
        END IF;
        RETURN NEXT;
    END LOOP;
END
$fn$;

-- First guess of a map from the headers (the page shows it; the user can change it).
CREATE OR REPLACE FUNCTION public.aaccandass_guess_mapping(p_headers TEXT [])
RETURNS JSONB
LANGUAGE sql
IMMUTABLE
AS $fn$
    WITH header AS (
        SELECT name, public.normalize_header(name) AS norm, ordinality
        FROM UNNEST(p_headers) WITH ORDINALITY AS item (name, ordinality)
        WHERE BTRIM(COALESCE(name, '')) <> ''
    )
    SELECT JSONB_STRIP_NULLS(JSONB_BUILD_OBJECT(
        'header_row', 1,
        'txn_date', (SELECT name FROM header WHERE norm ~ 'fecha|date' ORDER BY (norm ~ 'pago|operacion|liquidacion') DESC, ordinality LIMIT 1),
        'abono', (SELECT name FROM header WHERE norm ~ 'abono|aportacion|deposito|ingreso|rendimiento|credit' ORDER BY ordinality LIMIT 1),
        'cargo', (SELECT name FROM header WHERE norm ~ 'cargo|retiro|egreso|debit|comision' ORDER BY ordinality LIMIT 1),
        'concept', (SELECT TO_JSONB(name) FROM header WHERE norm ~ 'concepto|descripcion|detalle|description|emisora|empresa' ORDER BY ordinality LIMIT 1),
        'date_format', 'DMY'
    ))
$fn$;

-- =============================================================================
-- 4. Rows: one place that stores a manual or adjustment row
-- =============================================================================
CREATE OR REPLACE FUNCTION public.aaccandass_store_row(
    p_tenant UUID,
    p_user UUID,
    p_account_id INTEGER,
    p_txn_date DATE,
    p_concept TEXT,
    p_abonos NUMERIC,
    p_cargos NUMERIC,
    p_source TEXT,
    p_note TEXT,
    p_reported NUMERIC
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_account RECORD;
    v_concept TEXT := LEFT(BTRIM(REGEXP_REPLACE(COALESCE(p_concept, ''), '\s+', ' ', 'g')), 500);
    v_sk TEXT;
    v_abonos NUMERIC(18, 2) := ROUND(COALESCE(p_abonos, 0), 2);
    v_cargos NUMERIC(18, 2) := ROUND(COALESCE(p_cargos, 0), 2);
    v_occurrence INTEGER;
    v_hash TEXT;
BEGIN
    SELECT * INTO v_account FROM public.aaccandass_account(p_tenant, p_user, p_account_id);
    IF p_txn_date IS NULL THEN
        RAISE EXCEPTION 'A date is required' USING ERRCODE = '22023';
    END IF;
    IF p_txn_date < DATE '1950-01-01' OR p_txn_date > (NOW() AT TIME ZONE 'America/Mexico_City')::DATE + 366 THEN
        RAISE EXCEPTION 'The date % is out of range', p_txn_date USING ERRCODE = '22023';
    END IF;
    IF v_abonos < 0 OR v_cargos < 0 THEN
        RAISE EXCEPTION 'Type abono and cargo as positive amounts' USING ERRCODE = '22023';
    END IF;
    IF v_abonos = 0 AND v_cargos = 0 THEN
        RAISE EXCEPTION 'Type an abono or a cargo' USING ERRCODE = '22023';
    END IF;
    IF COALESCE(LENGTH(p_note), 0) > 500 THEN
        RAISE EXCEPTION 'A note can have at most 500 characters' USING ERRCODE = '22023';
    END IF;
    IF public.concept_sk(v_concept) = '' THEN
        v_concept := CASE p_source WHEN 'adjustment' THEN 'Ajuste de saldo' ELSE 'Movimiento' END;
    END IF;
    v_sk := public.concept_sk(v_concept);

    PERFORM PG_ADVISORY_XACT_LOCK(HASHTEXTEXTENDED('aaccandass:' || p_account_id::TEXT, 0));
    SELECT COALESCE(MAX(movement.occurrence), 0) + 1
    INTO v_occurrence
    FROM public.master_closed_aaccandass_f AS movement
    WHERE
        movement.account_id = p_account_id
        AND movement.txn_date = p_txn_date
        AND movement.concept_sk = v_sk
        AND movement.abonos = v_abonos
        AND movement.cargos = v_cargos;
    v_hash := public.movement_row_hash_v2(
        p_user, p_account_id, v_account.bank_id, p_txn_date, v_sk, v_abonos, v_cargos, v_occurrence
    );
    INSERT INTO public.master_closed_aaccandass_f (
        row_hash, file_id, tenant_id, user_id, account_id, bank_id, account_number, bank_name, file_name,
        period_start, period_end, txn_date, concept, concept_sk, abonos, cargos, amount, occurrence,
        entry_source, reported_balance, note, created_by
    )
    VALUES (
        v_hash, NULL, p_tenant, p_user, p_account_id, v_account.bank_id, v_account.account_number,
        v_account.bank_name, NULL, DATE_TRUNC('month', p_txn_date)::DATE,
        (DATE_TRUNC('month', p_txn_date) + INTERVAL '1 month - 1 day')::DATE, p_txn_date, v_concept, v_sk,
        v_abonos, v_cargos, v_abonos - v_cargos, v_occurrence, p_source, ROUND(p_reported, 2),
        NULLIF(BTRIM(COALESCE(p_note, '')), ''), p_user
    );
    RETURN v_hash;
END
$fn$;

-- Internal: balance of an account at the end of a date (no session check).
CREATE OR REPLACE FUNCTION public.aaccandass_balance_at(p_account_id INTEGER, p_date DATE)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
    SELECT COALESCE(SUM(movement.amount), 0)::NUMERIC(18, 2)
    FROM public.master_closed_aaccandass_f AS movement
    WHERE movement.account_id = p_account_id AND movement.txn_date <= p_date
$fn$;

-- Page: one row typed by hand (PDF-only sources such as CETES: opening balance, cash in
-- or out, the gain of the period).
CREATE OR REPLACE FUNCTION public.add_aaccandass_row(
    p_account_id INTEGER,
    p_txn_date DATE,
    p_concept TEXT,
    p_abonos NUMERIC,
    p_cargos NUMERIC,
    p_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_hash TEXT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    v_hash := public.aaccandass_store_row(
        v_tenant, v_user, p_account_id, p_txn_date, p_concept, p_abonos, p_cargos, 'manual', p_note, NULL
    );
    RETURN JSONB_BUILD_OBJECT(
        'row_hash', v_hash,
        'account_id', p_account_id,
        'txn_date', p_txn_date,
        'balance', public.aaccandass_balance_at(p_account_id, p_txn_date)
    );
END
$fn$;

-- Page: delete a manual or adjustment row (uploaded rows go away with their file).
CREATE OR REPLACE FUNCTION public.delete_aaccandass_row(p_row_hash TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_source TEXT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    SELECT movement.entry_source INTO v_source
    FROM public.master_closed_aaccandass_f AS movement
    WHERE movement.row_hash = p_row_hash AND movement.tenant_id = v_tenant AND movement.user_id = v_user;
    IF v_source IS NULL THEN
        RAISE EXCEPTION 'row not found' USING ERRCODE = 'P0002';
    END IF;
    IF v_source = 'upload' THEN
        RAISE EXCEPTION 'Uploaded rows are removed by deleting their file' USING ERRCODE = '22023';
    END IF;
    DELETE FROM public.master_closed_aaccandass_d WHERE row_hash = p_row_hash AND tenant_id = v_tenant;
    DELETE FROM public.master_closed_aaccandass_f WHERE row_hash = p_row_hash AND tenant_id = v_tenant;
    RETURN JSONB_BUILD_OBJECT('row_hash', p_row_hash, 'deleted', TRUE);
END
$fn$;

-- Page: the balance the institution shows at p_as_of. The difference with the rows up
-- to that date becomes one 'adjustment' row dated p_adjust_date (default p_as_of; an
-- earlier date, e.g. the day before the first row, makes it an opening balance). A zero
-- difference stores no row; every check is kept in aaccandass_checks_f.
CREATE OR REPLACE FUNCTION public.reconcile_aaccandass(
    p_account_id INTEGER,
    p_as_of DATE,
    p_reported_balance NUMERIC,
    p_adjust_date DATE DEFAULT NULL,
    p_concept TEXT DEFAULT NULL,
    p_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_reported NUMERIC(18, 2) := ROUND(p_reported_balance, 2);
    v_tracked NUMERIC(18, 2);
    v_difference NUMERIC(18, 2);
    v_date DATE := COALESCE(p_adjust_date, p_as_of);
    v_hash TEXT;
    v_check BIGINT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    PERFORM 1 FROM public.aaccandass_account(v_tenant, v_user, p_account_id);
    IF p_as_of IS NULL OR v_reported IS NULL THEN
        RAISE EXCEPTION 'Type the date and the balance the institution shows' USING ERRCODE = '22023';
    END IF;
    IF v_date > p_as_of THEN
        RAISE EXCEPTION 'The adjustment date must be on or before the balance date' USING ERRCODE = '22023';
    END IF;
    PERFORM PG_ADVISORY_XACT_LOCK(HASHTEXTEXTENDED('aaccandass:' || p_account_id::TEXT, 0));
    v_tracked := public.aaccandass_balance_at(p_account_id, p_as_of);
    v_difference := v_reported - v_tracked;
    IF v_difference <> 0 THEN
        v_hash := public.aaccandass_store_row(
            v_tenant, v_user, p_account_id, v_date, COALESCE(NULLIF(BTRIM(p_concept), ''), 'Ajuste de saldo'),
            GREATEST(v_difference, 0), GREATEST(-v_difference, 0), 'adjustment', p_note, v_reported
        );
    END IF;
    INSERT INTO public.aaccandass_checks_f (
        tenant_id, user_id, account_id, as_of, reported_balance, tracked_balance, difference,
        adjustment_hash, adjustment_date, note, created_by
    )
    VALUES (
        v_tenant, v_user, p_account_id, p_as_of, v_reported, v_tracked, v_difference,
        v_hash, CASE WHEN v_hash IS NULL THEN NULL ELSE v_date END, NULLIF(BTRIM(COALESCE(p_note, '')), ''), v_user
    )
    RETURNING check_id INTO v_check;
    RETURN JSONB_BUILD_OBJECT(
        'check_id', v_check,
        'account_id', p_account_id,
        'as_of', p_as_of,
        'reported_balance', v_reported,
        'tracked_balance', v_tracked,
        'difference', v_difference,
        'adjustment', CASE WHEN v_hash IS NULL THEN NULL ELSE JSONB_BUILD_OBJECT(
            'row_hash', v_hash,
            'txn_date', v_date,
            'abonos', GREATEST(v_difference, 0),
            'cargos', GREATEST(-v_difference, 0)
        ) END,
        'balance', public.aaccandass_balance_at(p_account_id, p_as_of)
    );
END
$fn$;

-- =============================================================================
-- 5. Upload: preview, store, vault name and manifest, delete
-- =============================================================================
-- Page: what a file gives under a map, without storing anything. With an incomplete map
-- it returns the headers, the first lines and a guessed map.
CREATE OR REPLACE FUNCTION public.aaccandass_preview(p_account_id INTEGER, p_csv TEXT, p_mapping JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_account RECORD;
    v_map JSONB;
    v_headers TEXT [];
    v_lines JSONB;
    v_rows JSONB;
    v_totals JSONB;
    v_balance NUMERIC(18, 2);
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    SELECT * INTO v_account FROM public.aaccandass_account(v_tenant, v_user, p_account_id);
    IF p_csv IS NULL OR BTRIM(p_csv) = '' THEN
        RAISE EXCEPTION 'The file is empty' USING ERRCODE = '22023';
    END IF;
    v_map := public.aaccandass_clean_mapping(p_mapping);
    v_headers := public.aaccandass_headers(p_csv, v_map);
    SELECT COALESCE(JSONB_AGG(JSONB_BUILD_OBJECT('line_no', record.record_no, 'fields', TO_JSONB(record.fields))
        ORDER BY record.record_no), '[]'::JSONB)
    INTO v_lines
    FROM public.parse_csv(p_csv, v_map ->> 'delimiter') AS record
    WHERE record.record_no <= (v_map ->> 'header_row')::INTEGER + 8;
    v_balance := public.aaccandass_balance_at(p_account_id, '9999-12-31');

    IF NOT public.aaccandass_mapping_ready(v_map) THEN
        RETURN JSONB_BUILD_OBJECT(
            'ready', FALSE,
            'headers', TO_JSONB(v_headers),
            'lines', v_lines,
            'mapping', v_map,
            'suggested_mapping', public.aaccandass_guess_mapping(v_headers),
            'balance_before', v_balance
        );
    END IF;

    DROP TABLE IF EXISTS pg_temp.aaccandass_preview_tmp;
    CREATE TEMP TABLE aaccandass_preview_tmp ON COMMIT DROP AS
    SELECT
        mapped.*,
        public.concept_sk(mapped.concept) AS concept_sk,
        CASE WHEN mapped.status = 'ok' THEN ROW_NUMBER() OVER (
            PARTITION BY mapped.status, mapped.txn_date, public.concept_sk(mapped.concept), mapped.abonos, mapped.cargos
            ORDER BY mapped.line_no
        ) END::INTEGER AS occurrence
    FROM public.aaccandass_map_rows(p_csv, v_map) AS mapped;
    ALTER TABLE pg_temp.aaccandass_preview_tmp ADD COLUMN row_hash TEXT;
    UPDATE pg_temp.aaccandass_preview_tmp AS tmp
    SET row_hash = public.movement_row_hash_v2(
        v_user, p_account_id, v_account.bank_id, tmp.txn_date, tmp.concept_sk, tmp.abonos, tmp.cargos, tmp.occurrence
    )
    WHERE tmp.status = 'ok';

    SELECT JSONB_BUILD_OBJECT(
        'lines', COUNT(*),
        'ok', COUNT(*) FILTER (WHERE tmp.status = 'ok'),
        'skipped', COUNT(*) FILTER (WHERE tmp.status = 'skipped'),
        'already_stored', COUNT(*) FILTER (WHERE stored.row_hash IS NOT NULL),
        'new', COUNT(*) FILTER (WHERE tmp.status = 'ok' AND stored.row_hash IS NULL),
        'abonos', COALESCE(SUM(tmp.abonos) FILTER (WHERE tmp.status = 'ok'), 0),
        'cargos', COALESCE(SUM(tmp.cargos) FILTER (WHERE tmp.status = 'ok'), 0),
        'new_net', COALESCE(SUM(tmp.abonos - tmp.cargos) FILTER (WHERE tmp.status = 'ok' AND stored.row_hash IS NULL), 0),
        'first_txn_date', MIN(tmp.txn_date) FILTER (WHERE tmp.status = 'ok'),
        'last_txn_date', MAX(tmp.txn_date) FILTER (WHERE tmp.status = 'ok')
    )
    INTO v_totals
    FROM pg_temp.aaccandass_preview_tmp AS tmp
    LEFT JOIN public.master_closed_aaccandass_f AS stored ON stored.row_hash = tmp.row_hash;

    SELECT COALESCE(JSONB_AGG(JSONB_BUILD_OBJECT(
        'line_no', page.line_no,
        'status', page.status,
        'reason', page.reason,
        'txn_date', page.txn_date,
        'concept', page.concept,
        'concept_sk', page.concept_sk,
        'abonos', page.abonos,
        'cargos', page.cargos,
        'occurrence', page.occurrence,
        'row_hash', page.row_hash,
        'already_stored', page.stored
    ) ORDER BY page.line_no), '[]'::JSONB)
    INTO v_rows
    FROM (
        SELECT tmp.*, stored.row_hash IS NOT NULL AS stored
        FROM pg_temp.aaccandass_preview_tmp AS tmp
        LEFT JOIN public.master_closed_aaccandass_f AS stored ON stored.row_hash = tmp.row_hash
        ORDER BY tmp.line_no
        LIMIT 200
    ) AS page;
    DROP TABLE IF EXISTS pg_temp.aaccandass_preview_tmp;

    RETURN JSONB_BUILD_OBJECT(
        'ready', TRUE,
        'headers', TO_JSONB(v_headers),
        'lines', v_lines,
        'mapping', v_map,
        'rows', v_rows,
        'totals', v_totals,
        'balance_before', v_balance,
        'balance_after', v_balance + (v_totals ->> 'new_net')::NUMERIC
    );
END
$fn$;

-- {YYYY-MM}_{account}_{Bank}_inv: the month of the last movement in the file.
CREATE OR REPLACE FUNCTION public.aaccandass_vault_parts(p_upload_id UUID)
RETURNS TABLE (tenant_id UUID, base_name TEXT, reserved_key TEXT)
LANGUAGE sql
STABLE
AS $fn$
    SELECT
        upload.tenant_id,
        FORMAT(
            '%s_%s_%s_inv',
            TO_CHAR(COALESCE(upload.last_txn_date, upload.created_at::DATE), 'YYYY-MM'),
            public.curated_name_part(account.account_number),
            public.curated_name_part(bank.bank_name)
        ),
        registry.vault_key
    FROM public.aaccandass_uploads_f AS upload
    INNER JOIN public.bank_accounts_d AS account ON account.account_id = upload.account_id
    INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
    LEFT JOIN public.curated_vault_keys_d AS registry ON registry.upload_id = upload.upload_id
    WHERE upload.upload_id = p_upload_id
$fn$;

-- Next free vault name, in the same registry as statement files (idempotent).
CREATE OR REPLACE FUNCTION public.aaccandass_reserve_vault_key(p_upload_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_parts RECORD;
    v_version INTEGER;
    v_key TEXT;
BEGIN
    SELECT * INTO v_parts FROM public.aaccandass_vault_parts(p_upload_id);
    IF v_parts.tenant_id IS NULL THEN
        RAISE EXCEPTION 'file not found' USING ERRCODE = 'P0002';
    END IF;
    IF v_parts.reserved_key IS NOT NULL THEN
        RETURN v_parts.reserved_key;
    END IF;
    PERFORM PG_ADVISORY_XACT_LOCK(HASHTEXT(v_parts.tenant_id::TEXT || '/' || v_parts.base_name || '.csv'));
    SELECT COALESCE(MAX(registry.version), 0) + 1
    INTO v_version
    FROM public.curated_vault_keys_d AS registry
    WHERE
        registry.tenant_id = v_parts.tenant_id
        AND registry.base_name = v_parts.base_name
        AND registry.extension = 'csv';
    v_key := FORMAT(
        'curated/%s/%s%s.csv',
        v_parts.tenant_id,
        v_parts.base_name,
        CASE WHEN v_version > 1 THEN '_v' || v_version ELSE '' END
    );
    INSERT INTO public.curated_vault_keys_d (vault_key, tenant_id, upload_id, base_name, extension, version)
    VALUES (v_key, v_parts.tenant_id, p_upload_id, v_parts.base_name, 'csv', v_version);
    RETURN v_key;
END
$fn$;

-- Sidecar manifest: enough to rebuild the account, the map and the upload row.
CREATE OR REPLACE FUNCTION public.aaccandass_vault_manifest(p_upload_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $fn$
    SELECT JSONB_BUILD_OBJECT(
        'schema', 'bankstream-vault-manifest/1',
        'vault_key', parts.reserved_key,
        'tenant_id', upload.tenant_id,
        'upload_id', upload.upload_id,
        'uploaded_at', upload.created_at,
        'chosen_filename', upload.chosen_filename,
        'stored_filename', upload.original_filename,
        'source_format', upload.source_format,
        'dataset', 'aaccandass',
        'slot', 'investment',
        'table', 'master_closed_aaccandass_f',
        'content_sha256', upload.content_sha256,
        'byte_size', upload.byte_size,
        'row_count', upload.row_count,
        'inserted_count', upload.inserted_count,
        'duplicate_count', upload.duplicate_count,
        'skipped_count', upload.skipped_count,
        'mapping', upload.mapping,
        'headers', TO_JSONB(upload.headers),
        'template_name', template.template_name,
        'bank_name', bank.bank_name,
        'account', JSONB_BUILD_OBJECT(
            'account_number', account.account_number,
            'account_name', account.account_name,
            'account_type', kind.type_name,
            'ledger_kind', kind.ledger_kind
        ),
        'period', JSONB_BUILD_OBJECT(
            'period', TO_CHAR(COALESCE(upload.last_txn_date, upload.created_at::DATE), 'YYYY-MM'),
            'first_txn_date', upload.first_txn_date,
            'last_txn_date', upload.last_txn_date
        )
    )
    FROM public.aaccandass_uploads_f AS upload
    CROSS JOIN LATERAL public.aaccandass_vault_parts(upload.upload_id) AS parts
    INNER JOIN public.bank_accounts_d AS account ON account.account_id = upload.account_id
    INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
    INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
    LEFT JOIN public.aaccandass_templates_d AS template ON template.template_id = upload.template_id
    WHERE upload.upload_id = p_upload_id
$fn$;

CREATE OR REPLACE FUNCTION public.aaccandass_vault_metadata(p_upload_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $fn$
    SELECT JSONB_BUILD_OBJECT(
        'original-filename', public.curated_meta_value(manifest ->> 'chosen_filename'),
        'value-encoding', 'percent-utf8',
        'bank', public.curated_meta_value(manifest ->> 'bank_name'),
        'account', public.curated_meta_value(manifest #>> '{account,account_number}'),
        'period', manifest #>> '{period,period}',
        'period-start', manifest #>> '{period,first_txn_date}',
        'period-end', manifest #>> '{period,last_txn_date}',
        'dataset', 'aaccandass',
        'upload-id', manifest ->> 'upload_id',
        'content-sha256', manifest ->> 'content_sha256'
    )
    FROM (SELECT public.aaccandass_vault_manifest(p_upload_id) AS manifest) AS built
$fn$;

-- Page: store a file under a map. Rows whose row_hash is already stored (an overlapping
-- export) are skipped as duplicates. p_template_name saves the map for the account
-- (updated when the name exists). Returns the vault name and manifest when the plan
-- keeps a curated backup; the API writes the objects and calls attach_aaccandass_backup.
CREATE OR REPLACE FUNCTION public.ingest_aaccandass_upload(
    p_account_id INTEGER,
    p_filename TEXT,
    p_chosen_filename TEXT,
    p_csv TEXT,
    p_mapping JSONB,
    p_template_name TEXT DEFAULT NULL,
    p_source_format TEXT DEFAULT 'csv'
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_account RECORD;
    v_map JSONB;
    v_headers TEXT [];
    v_sha TEXT;
    v_upload UUID;
    v_template BIGINT;
    v_template_name TEXT := public.list_clean_name(p_template_name);
    v_chosen TEXT := LEFT(COALESCE(NULLIF(BTRIM(p_chosen_filename), ''), NULLIF(BTRIM(p_filename), ''), 'upload.csv'), 255);
    v_stored TEXT := LEFT(COALESCE(NULLIF(BTRIM(p_filename), ''), v_chosen), 255);
    v_stats RECORD;
    v_inserted INTEGER;
    v_backup BOOLEAN;
    v_key TEXT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    SELECT * INTO v_account FROM public.aaccandass_account(v_tenant, v_user, p_account_id);
    IF p_csv IS NULL OR BTRIM(p_csv) = '' THEN
        RAISE EXCEPTION 'The file is empty' USING ERRCODE = '22023';
    END IF;
    IF COALESCE(p_source_format, 'csv') NOT IN ('csv', 'xlsx') THEN
        RAISE EXCEPTION 'source format must be csv or xlsx' USING ERRCODE = '22023';
    END IF;
    IF v_template_name IS NOT NULL AND LENGTH(v_template_name) > 60 THEN
        RAISE EXCEPTION 'A template name can have at most 60 characters' USING ERRCODE = '22023';
    END IF;
    v_map := public.aaccandass_clean_mapping(p_mapping);
    v_headers := public.aaccandass_headers(p_csv, v_map);
    v_sha := ENCODE(SHA256(CONVERT_TO(p_csv, 'UTF8')), 'hex');
    IF EXISTS (
        SELECT 1 FROM public.aaccandass_uploads_f AS upload
        WHERE upload.account_id = p_account_id AND upload.content_sha256 = v_sha
    ) THEN
        RAISE EXCEPTION 'This file was already uploaded to this account' USING ERRCODE = '23505';
    END IF;

    DROP TABLE IF EXISTS pg_temp.aaccandass_ingest_tmp;
    CREATE TEMP TABLE aaccandass_ingest_tmp ON COMMIT DROP AS
    SELECT
        mapped.*,
        public.concept_sk(mapped.concept) AS concept_sk,
        ROW_NUMBER() OVER (
            PARTITION BY mapped.txn_date, public.concept_sk(mapped.concept), mapped.abonos, mapped.cargos
            ORDER BY mapped.line_no
        )::INTEGER AS occurrence
    FROM public.aaccandass_map_rows(p_csv, v_map) AS mapped
    WHERE mapped.status = 'ok';

    SELECT
        COUNT(*)::INTEGER AS ok_rows,
        MIN(tmp.txn_date) AS first_date,
        MAX(tmp.txn_date) AS last_date,
        COALESCE(SUM(tmp.abonos), 0) AS abonos,
        COALESCE(SUM(tmp.cargos), 0) AS cargos
    INTO v_stats
    FROM pg_temp.aaccandass_ingest_tmp AS tmp;
    IF v_stats.ok_rows = 0 THEN
        RAISE EXCEPTION 'No row could be read with this column map' USING ERRCODE = '22023';
    END IF;

    IF v_template_name IS NOT NULL THEN
        INSERT INTO public.aaccandass_templates_d AS template (
            tenant_id, user_id, account_id, template_name, mapping, headers, last_used_at, created_by
        )
        VALUES (v_tenant, v_user, p_account_id, v_template_name, v_map, v_headers, NOW(), v_user)
        ON CONFLICT (account_id, (LOWER(template_name))) DO UPDATE
        SET
            mapping = EXCLUDED.mapping,
            headers = EXCLUDED.headers,
            last_used_at = NOW(),
            updated_at = NOW(),
            updated_by = v_user
        WHERE template.tenant_id = v_tenant AND template.user_id = v_user
        RETURNING template.template_id INTO v_template;
    END IF;

    INSERT INTO public.aaccandass_uploads_f (
        tenant_id, user_id, account_id, template_id, original_filename, chosen_filename, source_format,
        content_sha256, byte_size, body_text, mapping, headers, row_count, skipped_count,
        first_txn_date, last_txn_date, total_abonos, total_cargos
    )
    VALUES (
        v_tenant, v_user, p_account_id, v_template, v_stored, v_chosen, COALESCE(p_source_format, 'csv'),
        v_sha, OCTET_LENGTH(CONVERT_TO(p_csv, 'UTF8')), p_csv, v_map, v_headers, v_stats.ok_rows,
        (SELECT COUNT(*) FROM public.aaccandass_map_rows(p_csv, v_map) AS mapped WHERE mapped.status = 'skipped'),
        v_stats.first_date, v_stats.last_date, v_stats.abonos, v_stats.cargos
    )
    RETURNING upload_id INTO v_upload;

    PERFORM PG_ADVISORY_XACT_LOCK(HASHTEXTEXTENDED('aaccandass:' || p_account_id::TEXT, 0));
    INSERT INTO public.master_closed_aaccandass_f (
        row_hash, file_id, tenant_id, user_id, account_id, bank_id, account_number, bank_name, file_name,
        period_start, period_end, txn_date, concept, concept_sk, abonos, cargos, amount, occurrence,
        entry_source, source_line, created_by
    )
    SELECT
        public.movement_row_hash_v2(
            v_user, p_account_id, v_account.bank_id, tmp.txn_date, tmp.concept_sk, tmp.abonos, tmp.cargos,
            tmp.occurrence
        ),
        v_upload, v_tenant, v_user, p_account_id, v_account.bank_id, v_account.account_number,
        v_account.bank_name, v_chosen, DATE_TRUNC('month', tmp.txn_date)::DATE,
        (DATE_TRUNC('month', tmp.txn_date) + INTERVAL '1 month - 1 day')::DATE, tmp.txn_date, tmp.concept,
        tmp.concept_sk, tmp.abonos, tmp.cargos, tmp.abonos - tmp.cargos, tmp.occurrence, 'upload',
        tmp.line_no, v_user
    FROM pg_temp.aaccandass_ingest_tmp AS tmp
    ORDER BY tmp.txn_date, tmp.line_no
    ON CONFLICT (row_hash) DO NOTHING;
    GET DIAGNOSTICS v_inserted = ROW_COUNT;
    DROP TABLE IF EXISTS pg_temp.aaccandass_ingest_tmp;

    UPDATE public.aaccandass_uploads_f
    SET inserted_count = v_inserted, duplicate_count = v_stats.ok_rows - v_inserted
    WHERE upload_id = v_upload;

    SELECT COALESCE(plan.curated_csv_backup, FALSE)
    INTO v_backup
    FROM public.tenants_d AS tenant
    INNER JOIN public.plans_d AS plan ON plan.plan_code = tenant.plan_code
    WHERE tenant.tenant_id = v_tenant;
    IF COALESCE(v_backup, FALSE) THEN
        v_key := public.aaccandass_reserve_vault_key(v_upload);
    END IF;

    RETURN JSONB_BUILD_OBJECT(
        'upload_id', v_upload,
        'tenant_id', v_tenant,
        'account_id', p_account_id,
        'template_id', v_template,
        'chosen_filename', v_chosen,
        'stored_filename', v_stored,
        'row_count', v_stats.ok_rows,
        'inserted', v_inserted,
        'duplicates', v_stats.ok_rows - v_inserted,
        'skipped', (SELECT upload.skipped_count FROM public.aaccandass_uploads_f AS upload WHERE upload.upload_id = v_upload),
        'first_txn_date', v_stats.first_date,
        'last_txn_date', v_stats.last_date,
        'abonos', v_stats.abonos,
        'cargos', v_stats.cargos,
        'balance', public.aaccandass_balance_at(p_account_id, '9999-12-31'),
        'curated_csv_backup', COALESCE(v_backup, FALSE),
        'file_suffix', 'csv',
        'vault_key', v_key,
        'vault_metadata', CASE WHEN v_key IS NULL THEN NULL ELSE public.aaccandass_vault_metadata(v_upload) END,
        'vault_manifest_key', CASE WHEN v_key IS NULL THEN NULL ELSE public.vault_manifest_key(v_key) END,
        'vault_manifest', CASE WHEN v_key IS NULL THEN NULL ELSE public.aaccandass_vault_manifest(v_upload) END
    );
END
$fn$;

-- After the API wrote the vault object: records it (the key must be the reserved one).
CREATE OR REPLACE FUNCTION public.attach_aaccandass_backup(p_upload_id UUID, p_key TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_parts RECORD;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    IF NOT EXISTS (
        SELECT 1 FROM public.aaccandass_uploads_f AS upload
        WHERE upload.upload_id = p_upload_id AND upload.tenant_id = v_tenant AND upload.user_id = v_user
    ) THEN
        RAISE EXCEPTION 'file not found' USING ERRCODE = 'P0002';
    END IF;
    SELECT * INTO v_parts FROM public.aaccandass_vault_parts(p_upload_id);
    IF p_key IS NULL OR p_key IS DISTINCT FROM v_parts.reserved_key THEN
        RAISE EXCEPTION 'curated key does not match the vault name of this file' USING ERRCODE = '22023';
    END IF;
    UPDATE public.aaccandass_uploads_f
    SET curated_s3_key = p_key, storage_mode = 'curated'
    WHERE upload_id = p_upload_id AND tenant_id = v_tenant AND user_id = v_user;
END
$fn$;

-- Page: delete a file and its rows (their attributes too). Returns the vault delete
-- marker for the API to write (the vault object itself stays), or NULL.
CREATE OR REPLACE FUNCTION public.delete_aaccandass_upload(p_upload_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_key TEXT;
    v_rows INTEGER;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    SELECT upload.curated_s3_key INTO v_key
    FROM public.aaccandass_uploads_f AS upload
    WHERE upload.upload_id = p_upload_id AND upload.tenant_id = v_tenant AND upload.user_id = v_user;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'file not found' USING ERRCODE = 'P0002';
    END IF;
    DELETE FROM public.master_closed_aaccandass_d AS dim
    USING public.master_closed_aaccandass_f AS movement
    WHERE movement.file_id = p_upload_id AND dim.row_hash = movement.row_hash;
    DELETE FROM public.master_closed_aaccandass_f WHERE file_id = p_upload_id AND tenant_id = v_tenant;
    GET DIAGNOSTICS v_rows = ROW_COUNT;
    DELETE FROM public.aaccandass_uploads_f WHERE upload_id = p_upload_id AND tenant_id = v_tenant;
    RETURN JSONB_BUILD_OBJECT(
        'upload_id', p_upload_id,
        'deleted_rows', v_rows,
        'vault_delete_marker', CASE WHEN v_key IS NULL THEN NULL ELSE JSONB_BUILD_OBJECT(
            'key', public.vault_manifest_key(v_key, 'deleted.json'),
            'body', JSONB_BUILD_OBJECT(
                'schema', 'bankstream-vault-delete/1',
                'vault_key', v_key,
                'upload_id', p_upload_id,
                'tenant_id', v_tenant,
                'deleted_at', NOW()
            )
        ) END
    );
END
$fn$;

-- Page: delete a saved column map.
CREATE OR REPLACE FUNCTION public.delete_aaccandass_template(p_template_id BIGINT)
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
    DELETE FROM public.aaccandass_templates_d
    WHERE template_id = p_template_id AND tenant_id = v_tenant AND user_id = v_user;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'template not found' USING ERRCODE = 'P0002';
    END IF;
    RETURN JSONB_BUILD_OBJECT('template_id', p_template_id, 'deleted', TRUE);
END
$fn$;

-- =============================================================================
-- 6. Balances, page data, rows
-- =============================================================================
-- Page / API: balance of one account at the end of a date (default today).
CREATE OR REPLACE FUNCTION public.aaccandass_balance(p_account_id INTEGER, p_as_of DATE DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_account RECORD;
    v_as_of DATE := COALESCE(p_as_of, (NOW() AT TIME ZONE 'America/Mexico_City')::DATE);
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    SELECT * INTO v_account FROM public.aaccandass_account(v_tenant, v_user, p_account_id);
    RETURN JSONB_BUILD_OBJECT(
        'account_id', p_account_id,
        'account_name', v_account.account_name,
        'bank_name', v_account.bank_name,
        'as_of', v_as_of,
        'balance', public.aaccandass_balance_at(p_account_id, v_as_of),
        'rows', (
            SELECT COUNT(*) FROM public.master_closed_aaccandass_f AS movement
            WHERE movement.account_id = p_account_id AND movement.txn_date <= v_as_of
        )
    );
END
$fn$;

-- Page: month by month per account (abonos, cargos, balance at the month end) for the
-- p_months months that end with the month of p_as_of, plus the total of all accounts.
CREATE OR REPLACE FUNCTION public.aaccandass_balances(p_as_of DATE DEFAULT NULL, p_months INTEGER DEFAULT 12)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_as_of DATE := COALESCE(p_as_of, (NOW() AT TIME ZONE 'America/Mexico_City')::DATE);
    v_months INTEGER := COALESCE(p_months, 12);
    v_result JSONB;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    IF v_months < 1 OR v_months > 120 THEN
        RAISE EXCEPTION 'months must be between 1 and 120' USING ERRCODE = '22023';
    END IF;

    WITH month AS (
        SELECT
            GENERATE_SERIES(
                DATE_TRUNC('month', v_as_of) - MAKE_INTERVAL(months => v_months - 1),
                DATE_TRUNC('month', v_as_of),
                INTERVAL '1 month'
            )::DATE AS month_start
    ),
    account AS (
        SELECT account.account_id, account.account_name, account.account_number, bank.bank_name, kind.type_name
        FROM public.bank_accounts_d AS account
        INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
        INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
        WHERE account.tenant_id = v_tenant AND account.user_id = v_user AND kind.ledger_kind = 'asset'
    ),
    cell AS (
        SELECT
            account.account_id,
            month.month_start,
            LEAST((month.month_start + INTERVAL '1 month - 1 day')::DATE, v_as_of) AS month_end,
            COALESCE(SUM(movement.abonos) FILTER (
                WHERE movement.txn_date >= month.month_start
            ), 0)::NUMERIC(18, 2) AS abonos,
            COALESCE(SUM(movement.cargos) FILTER (
                WHERE movement.txn_date >= month.month_start
            ), 0)::NUMERIC(18, 2) AS cargos,
            COALESCE(SUM(movement.amount), 0)::NUMERIC(18, 2) AS balance
        FROM account
        CROSS JOIN month
        LEFT JOIN public.master_closed_aaccandass_f AS movement
            ON movement.account_id = account.account_id
            AND movement.txn_date <= LEAST((month.month_start + INTERVAL '1 month - 1 day')::DATE, v_as_of)
        GROUP BY account.account_id, month.month_start
    )
    SELECT JSONB_BUILD_OBJECT(
        'as_of', v_as_of,
        'months', (SELECT JSONB_AGG(TO_CHAR(month.month_start, 'YYYY-MM') ORDER BY month.month_start) FROM month),
        'accounts', COALESCE((
            SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
                'account_id', account.account_id,
                'account_name', account.account_name,
                'account_number', account.account_number,
                'bank_name', account.bank_name,
                'type_name', account.type_name,
                'months', (
                    SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
                        'month', TO_CHAR(cell.month_start, 'YYYY-MM'),
                        'month_end', cell.month_end,
                        'abonos', cell.abonos,
                        'cargos', cell.cargos,
                        'balance', cell.balance
                    ) ORDER BY cell.month_start)
                    FROM cell WHERE cell.account_id = account.account_id
                ),
                'balance', public.aaccandass_balance_at(account.account_id, v_as_of)
            ) ORDER BY account.bank_name, account.account_name)
            FROM account
        ), '[]'::JSONB),
        'total', COALESCE((
            SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
                'month', TO_CHAR(total.month_start, 'YYYY-MM'),
                'abonos', total.abonos,
                'cargos', total.cargos,
                'balance', total.balance
            ) ORDER BY total.month_start)
            FROM (
                SELECT month.month_start,
                    COALESCE(SUM(cell.abonos), 0) AS abonos,
                    COALESCE(SUM(cell.cargos), 0) AS cargos,
                    COALESCE(SUM(cell.balance), 0) AS balance
                FROM month
                LEFT JOIN cell ON cell.month_start = month.month_start
                GROUP BY month.month_start
            ) AS total
        ), '[]'::JSONB),
        'total_balance', COALESCE((
            SELECT SUM(public.aaccandass_balance_at(account.account_id, v_as_of)) FROM account
        ), 0)
    )
    INTO v_result;
    RETURN v_result;
END
$fn$;

-- Page: everything the Investments & Assets page opens with.
CREATE OR REPLACE FUNCTION public.aaccandass_home(p_as_of DATE DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_as_of DATE := COALESCE(p_as_of, (NOW() AT TIME ZONE 'America/Mexico_City')::DATE);
    v_result JSONB;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    SELECT JSONB_BUILD_OBJECT(
        'as_of', v_as_of,
        'plan_code', plan.plan_code,
        'max_asset_accounts', plan.max_asset_accounts,
        'curated_csv_backup', plan.curated_csv_backup,
        'institutions', COALESCE((
            SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
                'bank_id', bank.bank_id,
                'bank_name', bank.bank_name,
                'is_institution', bank.is_institution
            ) ORDER BY bank.is_institution DESC, bank.bank_name)
            FROM public.banks_d AS bank
        ), '[]'::JSONB),
        'account_types', COALESCE((
            SELECT JSONB_AGG(JSONB_BUILD_OBJECT('a_type_id', kind.a_type_id, 'type_name', kind.type_name)
                ORDER BY kind.type_name)
            FROM public.account_types_d AS kind
            WHERE kind.ledger_kind = 'asset'
        ), '[]'::JSONB),
        'accounts', COALESCE((
            SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
                'account_id', account.account_id,
                'account_name', account.account_name,
                'account_number', account.account_number,
                'bank_id', account.bank_id,
                'bank_name', bank.bank_name,
                'a_type_id', account.a_type_id,
                'type_name', kind.type_name,
                'balance', public.aaccandass_balance_at(account.account_id, v_as_of),
                'row_count', (
                    SELECT COUNT(*) FROM public.master_closed_aaccandass_f AS movement
                    WHERE movement.account_id = account.account_id
                ),
                'first_txn_date', (
                    SELECT MIN(movement.txn_date) FROM public.master_closed_aaccandass_f AS movement
                    WHERE movement.account_id = account.account_id
                ),
                'last_txn_date', (
                    SELECT MAX(movement.txn_date) FROM public.master_closed_aaccandass_f AS movement
                    WHERE movement.account_id = account.account_id
                ),
                'last_check', (
                    SELECT JSONB_BUILD_OBJECT(
                        'check_id', checked.check_id,
                        'as_of', checked.as_of,
                        'reported_balance', checked.reported_balance,
                        'tracked_balance', checked.tracked_balance,
                        'difference', checked.difference,
                        'adjustment_hash', checked.adjustment_hash,
                        'created_at', checked.created_at
                    )
                    FROM public.aaccandass_checks_f AS checked
                    WHERE checked.account_id = account.account_id
                    ORDER BY checked.as_of DESC, checked.check_id DESC
                    LIMIT 1
                ),
                'templates', COALESCE((
                    SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
                        'template_id', template.template_id,
                        'template_name', template.template_name,
                        'mapping', template.mapping,
                        'headers', TO_JSONB(template.headers),
                        'last_used_at', template.last_used_at
                    ) ORDER BY template.last_used_at DESC NULLS LAST, template.template_name)
                    FROM public.aaccandass_templates_d AS template
                    WHERE template.account_id = account.account_id
                ), '[]'::JSONB),
                'uploads', COALESCE((
                    SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
                        'upload_id', upload.upload_id,
                        'chosen_filename', upload.chosen_filename,
                        'source_format', upload.source_format,
                        'created_at', upload.created_at,
                        'row_count', upload.row_count,
                        'inserted_count', upload.inserted_count,
                        'duplicate_count', upload.duplicate_count,
                        'skipped_count', upload.skipped_count,
                        'first_txn_date', upload.first_txn_date,
                        'last_txn_date', upload.last_txn_date,
                        'total_abonos', upload.total_abonos,
                        'total_cargos', upload.total_cargos,
                        'storage_mode', upload.storage_mode
                    ) ORDER BY upload.created_at DESC)
                    FROM public.aaccandass_uploads_f AS upload
                    WHERE upload.account_id = account.account_id
                ), '[]'::JSONB)
            ) ORDER BY bank.bank_name, account.account_name)
            FROM public.bank_accounts_d AS account
            INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
            INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
            WHERE account.tenant_id = v_tenant AND account.user_id = v_user AND kind.ledger_kind = 'asset'
        ), '[]'::JSONB),
        'asset_account_count', (
            SELECT COUNT(*)
            FROM public.bank_accounts_d AS account
            INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
            WHERE account.tenant_id = v_tenant AND account.user_id = v_user AND kind.ledger_kind = 'asset'
        )
    )
    INTO v_result
    FROM public.tenants_d AS tenant
    INNER JOIN public.plans_d AS plan ON plan.plan_code = tenant.plan_code
    WHERE tenant.tenant_id = v_tenant;
    v_result := v_result || JSONB_BUILD_OBJECT(
        'total_balance', COALESCE((
            SELECT SUM((item ->> 'balance')::NUMERIC) FROM JSONB_ARRAY_ELEMENTS(v_result -> 'accounts') AS item
        ), 0)
    );
    RETURN v_result;
END
$fn$;

-- Page: rows of one account (or all asset accounts when p_account_id is NULL), newest
-- first, each with the balance after it and its attributes.
CREATE OR REPLACE FUNCTION public.aaccandass_rows(
    p_account_id INTEGER DEFAULT NULL,
    p_from DATE DEFAULT NULL,
    p_to DATE DEFAULT NULL,
    p_search TEXT DEFAULT NULL,
    p_limit INTEGER DEFAULT 200,
    p_offset INTEGER DEFAULT 0
) RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_search TEXT := NULLIF(BTRIM(COALESCE(p_search, '')), '');
    v_limit INTEGER := LEAST(GREATEST(COALESCE(p_limit, 200), 1), 1000);
    v_offset INTEGER := GREATEST(COALESCE(p_offset, 0), 0);
    v_total BIGINT;
    v_rows JSONB;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    IF p_account_id IS NOT NULL THEN
        PERFORM 1 FROM public.aaccandass_account(v_tenant, v_user, p_account_id);
    END IF;

    WITH picked AS (
        SELECT
            movement.row_hash,
            movement.row_id,
            movement.account_id,
            movement.account_number,
            movement.bank_name,
            movement.txn_date,
            movement.concept,
            movement.concept_sk,
            movement.abonos,
            movement.cargos,
            movement.amount,
            movement.occurrence,
            movement.entry_source,
            movement.file_id,
            movement.file_name,
            movement.source_line,
            movement.reported_balance,
            movement.note,
            movement.period_start,
            running.balance,
            attrs.attribute_1,
            attrs.attribute_2,
            attrs.attribute_3,
            attrs.attribute_1_item_id,
            attrs.attribute_2_item_id,
            attrs.attribute_3_item_id
        FROM public.master_closed_aaccandass_f AS movement
        INNER JOIN public.master_closed_aaccandass_balance_v AS running ON running.row_hash = movement.row_hash
        LEFT JOIN public.movement_attributes_v AS attrs
            ON attrs.kind = 'asset' AND attrs.row_hash = movement.row_hash
        WHERE
            movement.tenant_id = v_tenant
            AND movement.user_id = v_user
            AND (p_account_id IS NULL OR movement.account_id = p_account_id)
            AND (p_from IS NULL OR movement.txn_date >= p_from)
            AND (p_to IS NULL OR movement.txn_date <= p_to)
            AND (
                v_search IS NULL
                OR movement.concept ILIKE '%' || v_search || '%'
                OR movement.bank_name ILIKE '%' || v_search || '%'
                OR COALESCE(movement.note, '') ILIKE '%' || v_search || '%'
                OR COALESCE(attrs.attribute_1, '') ILIKE '%' || v_search || '%'
                OR COALESCE(attrs.attribute_2, '') ILIKE '%' || v_search || '%'
                OR COALESCE(attrs.attribute_3, '') ILIKE '%' || v_search || '%'
            )
    )
    SELECT
        (SELECT COUNT(*) FROM picked),
        COALESCE((
            SELECT JSONB_AGG(TO_JSONB(page) ORDER BY page.txn_date DESC, page.row_id DESC)
            FROM (
                SELECT * FROM picked
                ORDER BY picked.txn_date DESC, picked.row_id DESC
                LIMIT v_limit OFFSET v_offset
            ) AS page
        ), '[]'::JSONB)
    INTO v_total, v_rows;

    RETURN JSONB_BUILD_OBJECT(
        'account_id', p_account_id,
        'total', v_total,
        'limit', v_limit,
        'offset', v_offset,
        'rows', v_rows
    );
END
$fn$;

-- =============================================================================
-- 7. Shared views and dimension functions: the asset dataset joins debit and credit
-- =============================================================================
-- movement_keys_v (sql/014) gains kind 'asset', layer 'closed'. Transfer detection only
-- reads kinds debit and credit (transfer_pool), so asset rows are never auto-linked.
CREATE OR REPLACE VIEW public.movement_keys_v
WITH (security_invoker = TRUE) AS
SELECT
    movement.row_hash,
    'closed'::TEXT AS layer,
    'debit'::TEXT AS kind,
    'master_debit_closed_f'::TEXT AS source_table,
    movement.row_id,
    movement.file_id,
    movement.tenant_id,
    movement.user_id,
    movement.account_id,
    movement.bank_id,
    movement.txn_date,
    movement.concept_sk,
    movement.abonos,
    movement.cargos,
    movement.amount,
    movement.occurrence,
    movement.account_number,
    movement.bank_name,
    movement.concept,
    movement.period_start,
    movement.period_end,
    movement.saldos,
    NULL::TEXT AS tarjeta,
    movement.file_name,
    movement.source_profile
FROM public.master_debit_closed_f AS movement
UNION ALL
SELECT
    movement.row_hash,
    'open'::TEXT AS layer,
    'debit'::TEXT AS kind,
    'master_debit_open_f'::TEXT AS source_table,
    movement.row_id,
    movement.file_id,
    movement.tenant_id,
    movement.user_id,
    movement.account_id,
    movement.bank_id,
    movement.txn_date,
    movement.concept_sk,
    movement.abonos,
    movement.cargos,
    movement.amount,
    movement.occurrence,
    movement.account_number,
    movement.bank_name,
    movement.concept,
    movement.period_start,
    movement.period_end,
    movement.saldos,
    NULL::TEXT AS tarjeta,
    movement.file_name,
    movement.source_profile
FROM public.master_debit_open_f AS movement
UNION ALL
SELECT
    movement.row_hash,
    'closed'::TEXT AS layer,
    'credit'::TEXT AS kind,
    'master_credit_closed_f'::TEXT AS source_table,
    movement.row_id,
    movement.file_id,
    movement.tenant_id,
    movement.user_id,
    movement.account_id,
    movement.bank_id,
    movement.txn_date,
    movement.concept_sk,
    movement.abonos,
    movement.cargos,
    movement.amount,
    movement.occurrence,
    movement.account_number,
    movement.bank_name,
    movement.concept,
    movement.period_start,
    movement.period_end,
    NULL::NUMERIC(18, 2) AS saldos,
    movement.tarjeta,
    movement.file_name,
    movement.source_profile
FROM public.master_credit_closed_f AS movement
UNION ALL
SELECT
    movement.row_hash,
    'open'::TEXT AS layer,
    'credit'::TEXT AS kind,
    'master_credit_open_f'::TEXT AS source_table,
    movement.row_id,
    movement.file_id,
    movement.tenant_id,
    movement.user_id,
    movement.account_id,
    movement.bank_id,
    movement.txn_date,
    movement.concept_sk,
    movement.abonos,
    movement.cargos,
    movement.amount,
    movement.occurrence,
    movement.account_number,
    movement.bank_name,
    movement.concept,
    movement.period_start,
    movement.period_end,
    NULL::NUMERIC(18, 2) AS saldos,
    movement.tarjeta,
    movement.file_name,
    movement.source_profile
FROM public.master_credit_open_f AS movement
UNION ALL
SELECT
    movement.row_hash,
    'future'::TEXT AS layer,
    'credit'::TEXT AS kind,
    'master_credit_future_f'::TEXT AS source_table,
    movement.row_id,
    movement.file_id,
    movement.tenant_id,
    movement.user_id,
    movement.account_id,
    movement.bank_id,
    movement.txn_date,
    movement.concept_sk,
    movement.abonos,
    movement.cargos,
    movement.amount,
    movement.occurrence,
    movement.account_number,
    movement.bank_name,
    movement.concept,
    movement.period_start,
    movement.period_end,
    NULL::NUMERIC(18, 2) AS saldos,
    movement.tarjeta,
    movement.file_name,
    movement.source_profile
FROM public.master_credit_future_f AS movement
UNION ALL
SELECT
    movement.row_hash,
    'closed'::TEXT AS layer,
    'asset'::TEXT AS kind,
    'master_closed_aaccandass_f'::TEXT AS source_table,
    movement.row_id,
    movement.file_id,
    movement.tenant_id,
    movement.user_id,
    movement.account_id,
    movement.bank_id,
    movement.txn_date,
    movement.concept_sk,
    movement.abonos,
    movement.cargos,
    movement.amount,
    movement.occurrence,
    movement.account_number,
    movement.bank_name,
    movement.concept,
    movement.period_start,
    movement.period_end,
    NULL::NUMERIC(18, 2) AS saldos,
    NULL::TEXT AS tarjeta,
    movement.file_name,
    movement.entry_source AS source_profile
FROM public.master_closed_aaccandass_f AS movement;

COMMENT ON VIEW public.movement_keys_v IS
'One row per stored movement across the five statement masters and the investment / asset '
'master (sql/017): row_hash with its layer (closed, open, future), kind (debit, credit, asset), '
'key inputs and readable columns (saldos is debit only, tarjeta credit only). Future installments '
'are credit-card rows. For asset rows source_profile is the entry source (upload, manual, '
'adjustment).';

CREATE OR REPLACE VIEW public.movement_attributes_v
WITH (security_invoker = TRUE) AS
SELECT
    'debit'::TEXT AS kind,
    dim.row_hash,
    dim.tenant_id,
    dim.user_id,
    dim.account_id,
    COALESCE(item_1.item_name, dim.attribute_1) AS attribute_1,
    COALESCE(item_2.item_name, dim.attribute_2) AS attribute_2,
    COALESCE(item_3.item_name, dim.attribute_3) AS attribute_3,
    dim.attribute_1_item_id,
    dim.attribute_2_item_id,
    dim.attribute_3_item_id,
    dim.updated_at
FROM public.debit_d AS dim
LEFT JOIN public.list_d AS item_1 ON dim.attribute_1_item_id = item_1.item_id
LEFT JOIN public.list_d AS item_2 ON dim.attribute_2_item_id = item_2.item_id
LEFT JOIN public.list_d AS item_3 ON dim.attribute_3_item_id = item_3.item_id
UNION ALL
SELECT
    'credit'::TEXT AS kind,
    dim.row_hash,
    dim.tenant_id,
    dim.user_id,
    dim.account_id,
    COALESCE(item_1.item_name, dim.attribute_1) AS attribute_1,
    COALESCE(item_2.item_name, dim.attribute_2) AS attribute_2,
    COALESCE(item_3.item_name, dim.attribute_3) AS attribute_3,
    dim.attribute_1_item_id,
    dim.attribute_2_item_id,
    dim.attribute_3_item_id,
    dim.updated_at
FROM public.credit_d AS dim
LEFT JOIN public.list_d AS item_1 ON dim.attribute_1_item_id = item_1.item_id
LEFT JOIN public.list_d AS item_2 ON dim.attribute_2_item_id = item_2.item_id
LEFT JOIN public.list_d AS item_3 ON dim.attribute_3_item_id = item_3.item_id
UNION ALL
SELECT
    'asset'::TEXT AS kind,
    dim.row_hash,
    dim.tenant_id,
    dim.user_id,
    dim.account_id,
    COALESCE(item_1.item_name, dim.attribute_1) AS attribute_1,
    COALESCE(item_2.item_name, dim.attribute_2) AS attribute_2,
    COALESCE(item_3.item_name, dim.attribute_3) AS attribute_3,
    dim.attribute_1_item_id,
    dim.attribute_2_item_id,
    dim.attribute_3_item_id,
    dim.updated_at
FROM public.master_closed_aaccandass_d AS dim
LEFT JOIN public.list_d AS item_1 ON dim.attribute_1_item_id = item_1.item_id
LEFT JOIN public.list_d AS item_2 ON dim.attribute_2_item_id = item_2.item_id
LEFT JOIN public.list_d AS item_3 ON dim.attribute_3_item_id = item_3.item_id;

COMMENT ON VIEW public.movement_attributes_v IS
'debit_d + credit_d + master_closed_aaccandass_d with list-bound attributes resolved to the '
'item name (sql/016, sql/017).';

-- Binding a slot to a list (or back to text) converts asset attributes too.
CREATE OR REPLACE FUNCTION public.set_attribute_setting(
    p_slot INTEGER,
    p_label TEXT,
    p_list_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_label TEXT := public.list_clean_name(p_label);
    v_old BIGINT;
    v_table TEXT;
    v_converted BIGINT := 0;
    v_count BIGINT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    IF p_slot IS NULL OR p_slot NOT BETWEEN 1 AND 3 THEN
        RAISE EXCEPTION 'slot must be 1, 2 or 3' USING ERRCODE = '22023';
    END IF;
    IF COALESCE(LENGTH(v_label), 0) > 60 THEN
        RAISE EXCEPTION 'A label can have at most 60 characters' USING ERRCODE = '22023';
    END IF;
    IF p_list_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.list_f AS list
        WHERE list.list_id = p_list_id AND list.tenant_id = v_tenant AND list.user_id = v_user
    ) THEN
        RAISE EXCEPTION 'list not found' USING ERRCODE = 'P0002';
    END IF;

    SELECT setting.list_id INTO v_old
    FROM public.attribute_settings_d AS setting
    WHERE setting.tenant_id = v_tenant AND setting.user_id = v_user AND setting.slot = p_slot;

    INSERT INTO public.attribute_settings_d AS setting (tenant_id, user_id, slot, label, list_id, created_by)
    VALUES (v_tenant, v_user, p_slot, v_label, p_list_id, v_user)
    ON CONFLICT (tenant_id, user_id, slot) DO UPDATE
    SET label = EXCLUDED.label, list_id = EXCLUDED.list_id, updated_at = NOW(), updated_by = v_user;

    FOREACH v_table IN ARRAY ARRAY['debit_d', 'credit_d', 'master_closed_aaccandass_d']
    LOOP
        IF p_list_id IS NOT NULL THEN
            -- Values to move into the list: free text, or items of another list.
            EXECUTE FORMAT(
                'INSERT INTO public.list_d (list_id, tenant_id, user_id, item_name, created_by)
                SELECT DISTINCT ON (LOWER(source.name)) $1, $2, $3, source.name, $3
                FROM (
                    SELECT public.list_clean_name(COALESCE(item.item_name, dim.attribute_%1$s)) AS name
                    FROM public.%2$I AS dim
                    LEFT JOIN public.list_d AS item ON item.item_id = dim.attribute_%1$s_item_id
                    WHERE
                        dim.tenant_id = $2 AND dim.user_id = $3
                        AND (
                            (dim.attribute_%1$s_item_id IS NULL AND dim.attribute_%1$s IS NOT NULL)
                            OR item.list_id <> $1
                        )
                ) AS source
                WHERE source.name IS NOT NULL
                ORDER BY LOWER(source.name), source.name COLLATE "C"
                ON CONFLICT (list_id, (LOWER(item_name))) DO NOTHING',
                p_slot, v_table
            )
            USING p_list_id, v_tenant, v_user;
            EXECUTE FORMAT(
                'UPDATE public.%2$I AS dim
                SET
                    attribute_%1$s_item_id = target.item_id,
                    attribute_%1$s = NULL,
                    updated_at = NOW(),
                    updated_by = $3
                FROM public.%2$I AS old_dim
                LEFT JOIN public.list_d AS old_item ON old_item.item_id = old_dim.attribute_%1$s_item_id
                INNER JOIN public.list_d AS target
                    ON target.list_id = $1
                    AND LOWER(target.item_name) = LOWER(
                        public.list_clean_name(COALESCE(old_item.item_name, old_dim.attribute_%1$s))
                    )
                WHERE
                    old_dim.row_hash = dim.row_hash
                    AND dim.tenant_id = $2 AND dim.user_id = $3
                    AND (
                        (dim.attribute_%1$s_item_id IS NULL AND dim.attribute_%1$s IS NOT NULL)
                        OR old_item.list_id <> $1
                    )',
                p_slot, v_table
            )
            USING p_list_id, v_tenant, v_user;
            GET DIAGNOSTICS v_count = ROW_COUNT;
            v_converted := v_converted + v_count;
        ELSIF v_old IS NOT NULL THEN
            EXECUTE FORMAT(
                'UPDATE public.%2$I AS dim
                SET
                    attribute_%1$s = item.item_name,
                    attribute_%1$s_item_id = NULL,
                    updated_at = NOW(),
                    updated_by = $2
                FROM public.list_d AS item
                WHERE
                    item.item_id = dim.attribute_%1$s_item_id
                    AND dim.tenant_id = $1 AND dim.user_id = $2',
                p_slot, v_table
            )
            USING v_tenant, v_user;
            GET DIAGNOSTICS v_count = ROW_COUNT;
            v_converted := v_converted + v_count;
        END IF;
    END LOOP;

    RETURN JSONB_BUILD_OBJECT(
        'slot', p_slot,
        'label', v_label,
        'list_id', p_list_id,
        'mode', CASE WHEN p_list_id IS NULL THEN 'text' ELSE 'list' END,
        'converted', v_converted
    );
END
$fn$;

-- Attribute values of an asset row go to master_closed_aaccandass_d.
CREATE OR REPLACE FUNCTION public.dimension_store(
    p_tenant UUID,
    p_user UUID,
    p_row_hash TEXT,
    p_values JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_kind TEXT;
    v_account INTEGER;
    v_table TEXT;
    v_slot INTEGER;
    v_key TEXT;
    v_value JSONB;
    v_list BIGINT;
    v_name TEXT;
    v_item BIGINT;
    v_keep BOOLEAN [] := ARRAY[TRUE, TRUE, TRUE];
    v_text TEXT [] := ARRAY[NULL, NULL, NULL]::TEXT [];
    v_items BIGINT [] := ARRAY[NULL, NULL, NULL]::BIGINT [];
    v_saved JSONB;
BEGIN
    IF p_values IS NULL OR JSONB_TYPEOF(p_values) <> 'object' THEN
        RAISE EXCEPTION 'values must be an object' USING ERRCODE = '22023';
    END IF;
    SELECT keys.kind, keys.account_id
    INTO v_kind, v_account
    FROM public.movement_keys_v AS keys
    WHERE keys.row_hash = p_row_hash AND keys.tenant_id = p_tenant AND keys.user_id = p_user
    LIMIT 1;
    IF v_kind IS NULL THEN
        RAISE EXCEPTION 'movement not found' USING ERRCODE = 'P0002';
    END IF;
    v_table := CASE v_kind
        WHEN 'debit' THEN 'debit_d'
        WHEN 'asset' THEN 'master_closed_aaccandass_d'
        ELSE 'credit_d'
    END;

    FOR v_slot IN 1..3 LOOP
        v_key := 'attribute_' || v_slot;
        CONTINUE WHEN NOT p_values ? v_key;
        v_keep[v_slot] := FALSE;
        v_value := p_values -> v_key;
        SELECT setting.list_id INTO v_list
        FROM public.attribute_settings_d AS setting
        WHERE setting.tenant_id = p_tenant AND setting.user_id = p_user AND setting.slot = v_slot;

        v_item := NULL;
        v_name := NULL;
        IF v_value IS NULL OR JSONB_TYPEOF(v_value) = 'null' THEN
            CONTINUE;
        ELSIF JSONB_TYPEOF(v_value) = 'string' THEN
            v_name := v_value #>> '{}';
        ELSIF JSONB_TYPEOF(v_value) = 'object' THEN
            IF v_value ? 'item_id' AND JSONB_TYPEOF(v_value -> 'item_id') <> 'null' THEN
                IF v_list IS NULL THEN
                    RAISE EXCEPTION 'Attribute % is free text; bind it to a list first', v_slot
                    USING ERRCODE = '22023';
                END IF;
                BEGIN
                    v_item := (v_value ->> 'item_id')::BIGINT;
                EXCEPTION WHEN invalid_text_representation THEN
                    RAISE EXCEPTION 'item_id must be a number' USING ERRCODE = '22023';
                END;
                IF NOT EXISTS (
                    SELECT 1 FROM public.list_d AS item
                    WHERE item.item_id = v_item AND item.list_id = v_list
                        AND item.tenant_id = p_tenant AND item.user_id = p_user
                ) THEN
                    RAISE EXCEPTION 'That item is not in the list of attribute %', v_slot USING ERRCODE = '22023';
                END IF;
                v_items[v_slot] := v_item;
                CONTINUE;
            END IF;
            v_name := COALESCE(v_value ->> 'new_item', v_value ->> 'text');
        ELSE
            RAISE EXCEPTION 'attribute % must be text, null or an object', v_slot USING ERRCODE = '22023';
        END IF;

        IF v_list IS NULL THEN
            v_name := NULLIF(BTRIM(COALESCE(v_name, '')), '');
            IF LENGTH(v_name) > 500 THEN
                RAISE EXCEPTION 'Each attribute can have at most 500 characters' USING ERRCODE = '22023';
            END IF;
            v_text[v_slot] := v_name;
        ELSE
            v_items[v_slot] := public.list_item_ensure(p_tenant, p_user, v_list, v_name);
        END IF;
    END LOOP;

    EXECUTE FORMAT(
        'INSERT INTO public.%I (row_hash, tenant_id, user_id, account_id, created_by)
        VALUES ($1, $2, $3, $4, $3)
        ON CONFLICT (row_hash) DO NOTHING',
        v_table
    )
    USING p_row_hash, p_tenant, p_user, v_account;

    EXECUTE FORMAT(
        'UPDATE public.%I AS target
        SET
            attribute_1 = CASE WHEN $4[1] THEN target.attribute_1 ELSE $5[1] END,
            attribute_2 = CASE WHEN $4[2] THEN target.attribute_2 ELSE $5[2] END,
            attribute_3 = CASE WHEN $4[3] THEN target.attribute_3 ELSE $5[3] END,
            attribute_1_item_id = CASE WHEN $4[1] THEN target.attribute_1_item_id ELSE $6[1] END,
            attribute_2_item_id = CASE WHEN $4[2] THEN target.attribute_2_item_id ELSE $6[2] END,
            attribute_3_item_id = CASE WHEN $4[3] THEN target.attribute_3_item_id ELSE $6[3] END,
            updated_at = NOW(),
            updated_by = $3
        WHERE target.row_hash = $1 AND target.tenant_id = $2 AND target.user_id = $3',
        v_table
    )
    USING p_row_hash, p_tenant, p_user, v_keep, v_text, v_items;

    SELECT JSONB_BUILD_OBJECT(
        'row_hash', attrs.row_hash,
        'kind', attrs.kind,
        'attribute_1', attrs.attribute_1,
        'attribute_2', attrs.attribute_2,
        'attribute_3', attrs.attribute_3,
        'attribute_1_item_id', attrs.attribute_1_item_id,
        'attribute_2_item_id', attrs.attribute_2_item_id,
        'attribute_3_item_id', attrs.attribute_3_item_id,
        'updated_at', attrs.updated_at
    )
    INTO v_saved
    FROM public.movement_attributes_v AS attrs
    WHERE attrs.kind = v_kind AND attrs.row_hash = p_row_hash AND attrs.tenant_id = p_tenant;
    IF v_saved IS NULL THEN
        RAISE EXCEPTION 'tenant isolation' USING ERRCODE = '42501';
    END IF;
    RETURN v_saved;
END
$fn$;

-- Dimensions page: a third group, asset (layer closed).
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
                NULLIF(BTRIM(COALESCE(attrs.attribute_1, '')), '') IS NOT NULL
                OR NULLIF(BTRIM(COALESCE(attrs.attribute_2, '')), '') IS NOT NULL
                OR NULLIF(BTRIM(COALESCE(attrs.attribute_3, '')), '') IS NOT NULL
            ) AS filled,
            side.row_hash IS NOT NULL AS is_transfer
        FROM public.movement_keys_v AS keys
        LEFT JOIN public.movement_attributes_v AS attrs
            ON attrs.kind = keys.kind AND attrs.row_hash = keys.row_hash
        LEFT JOIN public.movement_transfers_v AS side
            ON side.row_hash = keys.row_hash AND side.tenant_id = keys.tenant_id
        WHERE keys.tenant_id = v_tenant AND keys.user_id = v_user
    ),
    levels AS (
        SELECT
            spec.kind,
            spec.layer,
            COUNT(movement.kind) AS total,
            COUNT(movement.kind) FILTER (WHERE movement.filled) AS filled,
            COUNT(movement.kind) FILTER (WHERE movement.is_transfer) AS transfers
        FROM (
            VALUES
                ('debit', 'open'), ('debit', 'closed'),
                ('credit', 'open'), ('credit', 'closed'), ('credit', 'future'),
                ('asset', 'closed')
        ) AS spec (kind, layer)
        LEFT JOIN movement ON movement.kind = spec.kind AND movement.layer = spec.layer
        GROUP BY spec.kind, spec.layer
    ),
    kinds AS (
        SELECT
            levels.kind,
            SUM(levels.total)::BIGINT AS total,
            SUM(levels.filled)::BIGINT AS filled,
            SUM(levels.transfers)::BIGINT AS transfers,
            JSONB_OBJECT_AGG(
                levels.layer,
                JSONB_BUILD_OBJECT(
                    'total', levels.total,
                    'filled', levels.filled,
                    'transfers', levels.transfers,
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
            'transfers', kinds.transfers,
            'pct', CASE WHEN kinds.total = 0 THEN 0 ELSE ROUND(100.0 * kinds.filled / kinds.total, 1) END,
            'layers', kinds.layers
        )
    )
    INTO v_result
    FROM kinds;
    RETURN v_result;
END
$fn$;

-- Rows of the asset group, with the running balance and entry source.
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
        ('debit', 'open'), ('debit', 'closed'), ('credit', 'open'), ('credit', 'closed'), ('credit', 'future'),
        ('asset', 'closed')
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
            keys.source_profile,
            running.balance,
            attrs.attribute_1,
            attrs.attribute_2,
            attrs.attribute_3,
            attrs.attribute_1_item_id,
            attrs.attribute_2_item_id,
            attrs.attribute_3_item_id,
            side.row_hash IS NOT NULL AS is_internal_transfer,
            side.link_hash AS transfer_link_hash,
            side.transfer_role,
            side.transfer_type,
            side.source AS transfer_source,
            side.reviewed_at IS NOT NULL AS transfer_reviewed,
            side.counterpart_hash AS transfer_counterpart_hash,
            counterpart.account_number AS transfer_counterpart_account
        FROM public.movement_keys_v AS keys
        LEFT JOIN public.movement_attributes_v AS attrs
            ON attrs.kind = keys.kind AND attrs.row_hash = keys.row_hash
        LEFT JOIN public.movement_transfers_v AS side
            ON side.row_hash = keys.row_hash AND side.tenant_id = keys.tenant_id
        LEFT JOIN public.bank_accounts_d AS counterpart
            ON counterpart.account_id = side.counterpart_account_id
        LEFT JOIN public.master_closed_aaccandass_balance_v AS running
            ON keys.kind = 'asset' AND running.row_hash = keys.row_hash
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
                OR COALESCE(attrs.attribute_1, '') ILIKE '%' || v_search || '%'
                OR COALESCE(attrs.attribute_2, '') ILIKE '%' || v_search || '%'
                OR COALESCE(attrs.attribute_3, '') ILIKE '%' || v_search || '%'
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

-- GraphQL / Sheets: master_closed_aaccandass_f is a sixth table. balance is the account
-- balance after the row, over the full history (not only the months returned); it is
-- NULL on the statement tables. source_profile is the statement profile (debit/credit)
-- or the entry source (asset).
CREATE OR REPLACE FUNCTION public.graphql_rows(
    p_table TEXT,
    p_months INTEGER DEFAULT NULL,
    p_after DATE DEFAULT NULL,
    p_as_of DATE DEFAULT NULL,
    p_limit INTEGER DEFAULT 20000,
    p_exclude_transfers BOOLEAN DEFAULT FALSE
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
        'master_credit_closed_f', 'master_credit_open_f', 'master_credit_future_f',
        'master_closed_aaccandass_f'
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
                    keys.source_profile,
                    running.balance,
                    attrs.attribute_1,
                    attrs.attribute_2,
                    attrs.attribute_3,
                    side.row_hash IS NOT NULL AS is_internal_transfer,
                    side.link_hash AS transfer_link_hash,
                    side.transfer_role,
                    side.transfer_type,
                    side.source AS transfer_source,
                    counterpart.account_number AS transfer_counterpart_account
                FROM public.movement_keys_v AS keys
                LEFT JOIN public.movement_attributes_v AS attrs
                    ON attrs.kind = keys.kind AND attrs.row_hash = keys.row_hash
                LEFT JOIN public.movement_transfers_v AS side
                    ON side.row_hash = keys.row_hash AND side.tenant_id = keys.tenant_id
                LEFT JOIN public.bank_accounts_d AS counterpart
                    ON counterpart.account_id = side.counterpart_account_id
                LEFT JOIN public.master_closed_aaccandass_balance_v AS running
                    ON keys.kind = 'asset' AND running.row_hash = keys.row_hash
                WHERE
                    keys.tenant_id = v_tenant
                    AND keys.user_id = v_user
                    AND keys.source_table = p_table
                    AND (v_from IS NULL OR keys.txn_date >= v_from)
                    AND (p_after IS NULL OR keys.txn_date > p_after)
                    AND NOT (COALESCE(p_exclude_transfers, FALSE) AND side.row_hash IS NOT NULL)
                ORDER BY keys.txn_date DESC, keys.row_id DESC
                LIMIT LEAST(GREATEST(COALESCE(p_limit, 20000), 1), 100000)
            ) AS picked
        ),
        '[]'::JSONB
    );
END
$fn$;

-- =============================================================================
-- 8. Statements page and completeness skip investment / asset accounts
-- =============================================================================
-- statement_home (sql/014) without asset accounts and asset account types: those have no
-- statement periods and live on the Investments & Assets page.
CREATE OR REPLACE FUNCTION public.statement_home(p_as_of DATE)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_accounts JSONB := '[]'::JSONB;
    v_account RECORD;
    v_periods JSONB;
    v_current RECORD;
    v_home JSONB;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    FOR v_account IN
        SELECT
            account.account_id,
            account.account_name,
            account.account_number,
            account.account_cutoff_day,
            account.credit_days,
            bank.bank_name,
            kind.type_name,
            kind.ledger_kind,
            kind.allows_cutoff
        FROM public.bank_accounts_d AS account
        INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
        INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
        WHERE
            account.tenant_id = v_tenant
            AND account.user_id = v_user
            AND kind.ledger_kind <> 'asset'
        ORDER BY account.account_number
    LOOP
        PERFORM public.refresh_statement_periods(v_account.account_id, p_as_of);
        -- Current period = the stored period that contains p_as_of (it can be a loaded
        -- period planned on an earlier cutoff day); the calendar is only a fallback.
        SELECT cutoff.period_start, cutoff.period_end
        INTO v_current
        FROM public.cutoff_date_f AS cutoff
        WHERE
            cutoff.account_id = v_account.account_id
            AND cutoff.user_id = v_user
            AND cutoff.period_start <= p_as_of
            AND cutoff.period_end >= p_as_of
        ORDER BY cutoff.period_end
        LIMIT 1;
        IF v_current.period_end IS NULL THEN
            SELECT current_row.period_start, current_row.period_end
            INTO v_current
            FROM public.current_period(
                v_account.allows_cutoff,
                v_account.account_cutoff_day,
                p_as_of
            ) AS current_row;
        END IF;

        SELECT COALESCE(JSONB_AGG(period.payload ORDER BY period.period_end), '[]'::JSONB)
        INTO v_periods
        FROM (
            SELECT
                cutoff.period_end,
                JSONB_BUILD_OBJECT(
                    'cutoff_id', cutoff.cutoff_id,
                    'period_start', cutoff.period_start,
                    'period_end', cutoff.period_end,
                    'period_label', TO_CHAR(cutoff.period_end, 'YYYY-MM'),
                    'is_current', cutoff.period_end = v_current.period_end,
                    'ledger_state', CASE
                        WHEN p_as_of > cutoff.period_end THEN 'closed'
                        WHEN cutoff.period_end = v_current.period_end THEN 'open'
                        ELSE 'upcoming'
                    END,
                    'payment_due', CASE
                        WHEN v_account.allows_cutoff THEN cutoff.period_end + v_account.credit_days
                        ELSE NULL
                    END,
                    'in_window', EXISTS (
                        SELECT 1
                        FROM public.catcher_periods(
                            v_account.allows_cutoff,
                            v_account.account_cutoff_day,
                            p_as_of
                        ) AS window_period
                        WHERE window_period.period_end = cutoff.period_end
                    ),
                    'pending', statement_file.upload_id IS NULL,
                    'statement_upload_id', statement_file.upload_id,
                    'statement_filename', statement_file.chosen_filename,
                    'statement_stored_filename', statement_file.original_filename,
                    'statement_vault_key', statement_file.curated_s3_key,
                    'statement_row_count', statement_file.row_count,
                    'statement_source_profile', statement_file.source_profile,
                    'statement_ledger_state', statement_file.ledger_state,
                    'installment_upload_id', installment_file.upload_id,
                    'installment_filename', installment_file.chosen_filename,
                    'installment_stored_filename', installment_file.original_filename,
                    'installment_vault_key', installment_file.curated_s3_key,
                    'installment_row_count', installment_file.row_count,
                    'installment_source_profile', installment_file.source_profile,
                    'installment_ledger_state', installment_file.ledger_state,
                    'pdf_upload_id', pdf_file.upload_id,
                    'pdf_filename', pdf_file.chosen_filename,
                    'pdf_stored_filename', pdf_file.original_filename,
                    'pdf_vault_key', pdf_file.curated_s3_key,
                    -- Closed: one file per period (a stale open file can be replaced).
                    -- Current: always open; a new file replaces the account's open rows.
                    'show_statement_slot',
                    (
                        p_as_of > cutoff.period_end
                        AND (
                            statement_file.upload_id IS NULL
                            OR statement_file.ledger_state = 'open'
                        )
                    )
                    OR cutoff.period_end = v_current.period_end,
                    'show_installment_slot',
                    v_account.allows_cutoff
                    AND (
                        (
                            p_as_of > cutoff.period_end
                            AND (
                                installment_file.upload_id IS NULL
                                OR installment_file.ledger_state = 'future'
                            )
                        )
                        OR cutoff.period_end = v_current.period_end
                    ),
                    'show_pdf_slot',
                    plan.curated_csv_backup
                    AND pdf_file.upload_id IS NULL
                    AND p_as_of > cutoff.period_end,
                    'removable',
                    p_as_of > cutoff.period_end
                    AND statement_file.upload_id IS NULL
                    AND installment_file.upload_id IS NULL
                    AND pdf_file.upload_id IS NULL
                    AND NOT EXISTS (
                        SELECT 1
                        FROM public.catcher_periods(
                            v_account.allows_cutoff,
                            v_account.account_cutoff_day,
                            p_as_of
                        ) AS window_period
                        WHERE window_period.period_end = cutoff.period_end
                    )
                ) AS payload
            FROM public.cutoff_date_f AS cutoff
            INNER JOIN public.tenants_d AS tenant ON tenant.tenant_id = cutoff.tenant_id
            INNER JOIN public.plans_d AS plan ON plan.plan_code = tenant.plan_code
            LEFT JOIN public.statement_uploads_f AS statement_file
                ON statement_file.cutoff_id = cutoff.cutoff_id
                AND statement_file.dataset = CASE
                    WHEN v_account.ledger_kind = 'credit' THEN 'credit_monthly'
                    ELSE 'debit'
                END
            LEFT JOIN public.statement_uploads_f AS installment_file
                ON installment_file.cutoff_id = cutoff.cutoff_id
                AND installment_file.dataset = 'credit_plan'
            LEFT JOIN public.statement_uploads_f AS pdf_file
                ON pdf_file.cutoff_id = cutoff.cutoff_id
                AND pdf_file.dataset = 'pdf'
            WHERE
                cutoff.account_id = v_account.account_id
                AND cutoff.user_id = v_user
                AND cutoff.period_end <= v_current.period_end
        ) AS period;

        v_accounts := v_accounts || JSONB_BUILD_ARRAY(JSONB_BUILD_OBJECT(
            'account_id', v_account.account_id,
            'account_name', v_account.account_name,
            'account_number', v_account.account_number,
            'account_cutoff_day', v_account.account_cutoff_day,
            'credit_days', v_account.credit_days,
            'bank_name', v_account.bank_name,
            'type_name', v_account.type_name,
            'ledger_kind', v_account.ledger_kind,
            'allows_cutoff', v_account.allows_cutoff,
            'current_period_start', v_current.period_start,
            'current_period_end', v_current.period_end,
            'open_row_count', (
                SELECT COUNT(*)
                FROM public.master_debit_open_f AS open_row
                WHERE
                    open_row.account_id = v_account.account_id
                    AND open_row.user_id = v_user
            ) + (
                SELECT COUNT(*)
                FROM public.master_credit_open_f AS open_row
                WHERE
                    open_row.account_id = v_account.account_id
                    AND open_row.user_id = v_user
            ),
            'future_row_count', (
                SELECT COUNT(*)
                FROM public.master_credit_future_f AS future_row
                WHERE
                    future_row.account_id = v_account.account_id
                    AND future_row.user_id = v_user
            ),
            'future_total', (
                SELECT COALESCE(SUM(future_row.amount), 0)
                FROM public.master_credit_future_f AS future_row
                WHERE
                    future_row.account_id = v_account.account_id
                    AND future_row.user_id = v_user
            ),
            'periods', v_periods
        ));
    END LOOP;

    SELECT JSONB_BUILD_OBJECT(
        'as_of', p_as_of,
        'plan_code', plan.plan_code,
        'plan_name', plan.display_name,
        'max_credit_accounts', plan.max_credit_accounts,
        'max_debit_accounts', plan.max_debit_accounts,
        'max_total_accounts', plan.max_total_accounts,
        'curated_csv_backup', plan.curated_csv_backup,
        'banks', (
            SELECT COALESCE(
                JSONB_AGG(
                    JSONB_BUILD_OBJECT('bank_id', bank.bank_id, 'bank_name', bank.bank_name)
                    ORDER BY bank.bank_name
                ),
                '[]'::JSONB
            )
            FROM public.banks_d AS bank
            WHERE EXISTS (
                SELECT 1
                FROM public.file_profiles_d AS fp
                WHERE LOWER(fp.bank_name) = LOWER(bank.bank_name)
                  AND fp.active IS TRUE
            )
        ),
        'account_types', (
            SELECT COALESCE(
                JSONB_AGG(
                    JSONB_BUILD_OBJECT(
                        'a_type_id', kind.a_type_id,
                        'type_name', kind.type_name,
                        'ledger_kind', kind.ledger_kind,
                        'allows_cutoff', kind.allows_cutoff
                    )
                    ORDER BY kind.type_name
                ),
                '[]'::JSONB
            )
            FROM public.account_types_d AS kind
            WHERE kind.ledger_kind <> 'asset'
        ),
        'accounts', v_accounts
    )
    INTO v_home
    FROM public.tenants_d AS tenant
    INNER JOIN public.plans_d AS plan ON plan.plan_code = tenant.plan_code
    WHERE tenant.tenant_id = v_tenant;
    RETURN v_home;
END
$fn$;

-- upload_completeness (sql/016) without asset accounts.
CREATE OR REPLACE FUNCTION public.upload_completeness(p_as_of DATE DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_as_of DATE := COALESCE(p_as_of, (NOW() AT TIME ZONE 'America/Mexico_City')::DATE);
    v_pdf BOOLEAN;
    v_account RECORD;
    v_current RECORD;
    v_periods JSONB;
    v_missing INTEGER;
    v_index INTEGER;
    v_accounts JSONB := '[]'::JSONB;
    v_pct NUMERIC;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    SELECT COALESCE(plan.curated_csv_backup, FALSE)
    INTO v_pdf
    FROM public.tenants_d AS tenant
    INNER JOIN public.plans_d AS plan ON plan.plan_code = tenant.plan_code
    WHERE tenant.tenant_id = v_tenant;
    v_pdf := COALESCE(v_pdf, FALSE);

    FOR v_account IN
        SELECT
            account.account_id,
            account.account_name,
            account.account_number,
            account.account_cutoff_day,
            bank.bank_name,
            kind.ledger_kind,
            kind.allows_cutoff
        FROM public.bank_accounts_d AS account
        INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
        INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
        WHERE account.tenant_id = v_tenant AND account.user_id = v_user AND kind.ledger_kind <> 'asset'
        ORDER BY bank.bank_name, account.account_number
    LOOP
        PERFORM public.refresh_statement_periods(v_account.account_id, v_as_of);
        v_current := NULL;
        SELECT cutoff.cutoff_id, cutoff.period_start, cutoff.period_end
        INTO v_current
        FROM public.cutoff_date_f AS cutoff
        WHERE
            cutoff.account_id = v_account.account_id
            AND cutoff.user_id = v_user
            AND cutoff.period_start <= v_as_of
            AND cutoff.period_end >= v_as_of
        ORDER BY cutoff.period_end
        LIMIT 1;
        IF v_current.period_end IS NULL THEN
            SELECT NULL::INTEGER AS cutoff_id, current_row.period_start, current_row.period_end
            INTO v_current
            FROM public.current_period(v_account.allows_cutoff, v_account.account_cutoff_day, v_as_of) AS current_row;
        END IF;

        WITH target AS (
            SELECT
                v_current.cutoff_id AS cutoff_id,
                v_current.period_start AS period_start,
                v_current.period_end AS period_end,
                'open'::TEXT AS state
            UNION ALL
            SELECT closed.cutoff_id, closed.period_start, closed.period_end, 'closed'::TEXT
            FROM (
                SELECT cutoff.cutoff_id, cutoff.period_start, cutoff.period_end
                FROM public.cutoff_date_f AS cutoff
                WHERE
                    cutoff.account_id = v_account.account_id
                    AND cutoff.user_id = v_user
                    AND cutoff.period_end < v_current.period_start
                ORDER BY cutoff.period_end DESC
                LIMIT 2
            ) AS closed
        ),
        files AS (
            SELECT
                target.*,
                csv.upload_id IS NOT NULL AS has_csv,
                csv.ledger_state AS csv_state,
                csv.chosen_filename AS csv_filename,
                pdf.upload_id IS NOT NULL AS has_pdf
            FROM target
            LEFT JOIN public.statement_uploads_f AS csv
                ON csv.cutoff_id = target.cutoff_id
                AND csv.dataset = CASE WHEN v_account.ledger_kind = 'credit' THEN 'credit_monthly' ELSE 'debit' END
            LEFT JOIN public.statement_uploads_f AS pdf
                ON pdf.cutoff_id = target.cutoff_id AND pdf.dataset = 'pdf'
        ),
        scored AS (
            SELECT
                files.*,
                CASE
                    WHEN files.state = 'open' THEN CASE WHEN files.has_csv THEN 100 ELSE 0 END
                    WHEN v_pdf THEN
                        CASE
                            WHEN files.has_csv AND files.csv_state = 'open' THEN 40
                            WHEN files.has_csv THEN 75
                            ELSE 0
                        END + CASE WHEN files.has_pdf THEN 25 ELSE 0 END
                    ELSE
                        CASE
                            WHEN files.has_csv AND files.csv_state = 'open' THEN 50
                            WHEN files.has_csv THEN 100
                            ELSE 0
                        END
                END AS score
            FROM files
        )
        SELECT JSONB_AGG(
            JSONB_BUILD_OBJECT(
                'state', scored.state,
                'cutoff_id', scored.cutoff_id,
                'period_start', scored.period_start,
                'period_end', scored.period_end,
                'period_label', TO_CHAR(scored.period_end, 'YYYY-MM'),
                'has_csv', scored.has_csv,
                'csv_state', scored.csv_state,
                'csv_filename', scored.csv_filename,
                'has_pdf', scored.has_pdf,
                'pdf_expected', v_pdf AND scored.state = 'closed',
                'score', scored.score,
                'band', public.completeness_band(scored.score),
                'missing', CASE
                    WHEN scored.state = 'open' AND NOT scored.has_csv THEN 'Upload the open-period CSV'
                    WHEN scored.state = 'open' THEN NULL
                    WHEN NOT scored.has_csv THEN 'Upload the statement CSV'
                    WHEN scored.csv_state = 'open' THEN 'Upload the closed statement CSV (only the open snapshot is here)'
                    WHEN v_pdf AND NOT scored.has_pdf THEN 'Add the PDF to certify it'
                END
            )
            ORDER BY scored.period_end DESC
        )
        INTO v_periods
        FROM scored;

        v_periods := COALESCE(v_periods, '[]'::JSONB);
        v_missing := 3 - JSONB_ARRAY_LENGTH(v_periods);
        IF v_missing > 0 THEN
            FOR v_index IN 1..v_missing LOOP
                v_periods := v_periods || JSONB_BUILD_ARRAY(JSONB_BUILD_OBJECT(
                    'state', 'closed', 'period_label', NULL, 'has_csv', FALSE, 'has_pdf', FALSE,
                    'pdf_expected', v_pdf, 'score', 0, 'band', 'empty', 'missing', 'No period stored yet'
                ));
            END LOOP;
        END IF;
        SELECT ROUND(AVG((item.value ->> 'score')::NUMERIC), 1)
        INTO v_pct
        FROM JSONB_ARRAY_ELEMENTS(v_periods) AS item;

        v_accounts := v_accounts || JSONB_BUILD_ARRAY(JSONB_BUILD_OBJECT(
            'account_id', v_account.account_id,
            'account_name', v_account.account_name,
            'account_number', v_account.account_number,
            'bank_name', v_account.bank_name,
            'ledger_kind', v_account.ledger_kind,
            'pct', v_pct,
            'band', public.completeness_band(v_pct),
            'periods', v_periods
        ));
    END LOOP;

    RETURN JSONB_BUILD_OBJECT(
        'as_of', v_as_of,
        'pdf_counts', v_pdf,
        'pct', (
            SELECT ROUND(AVG((account.value ->> 'pct')::NUMERIC), 1)
            FROM JSONB_ARRAY_ELEMENTS(v_accounts) AS account
        ),
        'band', public.completeness_band(COALESCE((
            SELECT ROUND(AVG((account.value ->> 'pct')::NUMERIC), 1)
            FROM JSONB_ARRAY_ELEMENTS(v_accounts) AS account
        ), 0)),
        'kinds', COALESCE((
            WITH flat AS (
                SELECT
                    account.value ->> 'ledger_kind' AS kind,
                    account.value ->> 'bank_name' AS bank_name,
                    (account.value ->> 'pct')::NUMERIC AS pct,
                    account.value AS payload
                FROM JSONB_ARRAY_ELEMENTS(v_accounts) AS account
            ),
            banks AS (
                SELECT
                    flat.kind,
                    flat.bank_name,
                    JSONB_BUILD_OBJECT(
                        'bank_name', flat.bank_name,
                        'pct', ROUND(AVG(flat.pct), 1),
                        'band', public.completeness_band(ROUND(AVG(flat.pct), 1)),
                        'accounts', JSONB_AGG(flat.payload ORDER BY flat.payload ->> 'account_number')
                    ) AS payload
                FROM flat
                GROUP BY flat.kind, flat.bank_name
            ),
            kinds AS (
                SELECT flat.kind, ROUND(AVG(flat.pct), 1) AS pct, COUNT(*) AS accounts
                FROM flat
                GROUP BY flat.kind
            )
            SELECT JSONB_AGG(
                JSONB_BUILD_OBJECT(
                    'kind', kinds.kind,
                    'title', CASE kinds.kind WHEN 'credit' THEN 'Credit' ELSE 'Debit' END,
                    'pct', kinds.pct,
                    'band', public.completeness_band(kinds.pct),
                    'accounts', kinds.accounts,
                    'banks', (
                        SELECT JSONB_AGG(banks.payload ORDER BY banks.bank_name)
                        FROM banks
                        WHERE banks.kind = kinds.kind
                    )
                )
                ORDER BY CASE kinds.kind WHEN 'credit' THEN 0 ELSE 1 END
            )
            FROM kinds
        ), '[]'::JSONB)
    );
END
$fn$;

-- =============================================================================
-- 9. Row level security and grants
-- =============================================================================
ALTER TABLE public.aaccandass_templates_d ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.aaccandass_uploads_f ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.master_closed_aaccandass_f ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.master_closed_aaccandass_d ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.aaccandass_checks_f ENABLE ROW LEVEL SECURITY;

DO $policies$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY[
        'aaccandass_templates_d', 'aaccandass_uploads_f', 'master_closed_aaccandass_f',
        'master_closed_aaccandass_d', 'aaccandass_checks_f'
    ]
    LOOP
        EXECUTE FORMAT('DROP POLICY IF EXISTS %I ON public.%I', v_table || '_tenant', v_table);
        EXECUTE FORMAT(
            'CREATE POLICY %I ON public.%I
            FOR ALL
            TO strm_app
            USING (tenant_id = public.session_tenant() AND user_id = public.session_user())
            WITH CHECK (tenant_id = public.session_tenant() AND user_id = public.session_user())',
            v_table || '_tenant', v_table
        );
    END LOOP;
END
$policies$;

REVOKE ALL ON public.aaccandass_templates_d, public.aaccandass_uploads_f, public.master_closed_aaccandass_f,
public.master_closed_aaccandass_d, public.aaccandass_checks_f FROM PUBLIC;
REVOKE ALL ON public.master_closed_aaccandass_balance_v, public.movement_keys_v, public.movement_attributes_v
FROM PUBLIC;
GRANT SELECT ON public.aaccandass_templates_d, public.master_closed_aaccandass_f,
public.master_closed_aaccandass_d, public.aaccandass_checks_f TO strm_app;
-- The file body stays behind the functions (like statement_uploads_f.body_text).
GRANT SELECT (
    upload_id, tenant_id, user_id, account_id, template_id, original_filename, chosen_filename, source_format,
    content_sha256, byte_size, mapping, headers, row_count, inserted_count, duplicate_count, skipped_count,
    first_txn_date, last_txn_date, total_abonos, total_cargos, storage_mode, curated_s3_key, created_at
) ON public.aaccandass_uploads_f TO strm_app;
GRANT SELECT ON public.master_closed_aaccandass_balance_v, public.movement_keys_v, public.movement_attributes_v
TO strm_app;

-- Internal helpers: no direct calls from the app role.
REVOKE ALL ON FUNCTION public.aaccandass_account(UUID, UUID, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aaccandass_store_row(
    UUID, UUID, INTEGER, DATE, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, NUMERIC
)
FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aaccandass_balance_at(INTEGER, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aaccandass_vault_parts(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aaccandass_reserve_vault_key(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aaccandass_vault_manifest(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aaccandass_vault_metadata(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dimension_store(UUID, UUID, TEXT, JSONB) FROM PUBLIC;

-- Pure helpers (no data access).
GRANT EXECUTE ON FUNCTION public.aaccandass_parse_date(TEXT, TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.aaccandass_concept_parts(JSONB, TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.aaccandass_clean_mapping(JSONB) TO strm_app;
GRANT EXECUTE ON FUNCTION public.aaccandass_mapping_ready(JSONB) TO strm_app;
GRANT EXECUTE ON FUNCTION public.aaccandass_column_index(TEXT [], TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.aaccandass_headers(TEXT, JSONB) TO strm_app;
GRANT EXECUTE ON FUNCTION public.aaccandass_map_rows(TEXT, JSONB) TO strm_app;
GRANT EXECUTE ON FUNCTION public.aaccandass_guess_mapping(TEXT []) TO strm_app;

-- Page and API entry points (each checks the session).
REVOKE ALL ON FUNCTION public.create_asset_account(INTEGER, TEXT, INTEGER, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.add_aaccandass_row(INTEGER, DATE, TEXT, NUMERIC, NUMERIC, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_aaccandass_row(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reconcile_aaccandass(INTEGER, DATE, NUMERIC, DATE, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aaccandass_preview(INTEGER, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ingest_aaccandass_upload(INTEGER, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.attach_aaccandass_backup(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_aaccandass_upload(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_aaccandass_template(BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aaccandass_balance(INTEGER, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aaccandass_balances(DATE, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aaccandass_home(DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.aaccandass_rows(INTEGER, DATE, DATE, TEXT, INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_attribute_setting(INTEGER, TEXT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dimension_summary() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dimension_rows(TEXT, TEXT, DATE, DATE, TEXT, INTEGER, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.graphql_rows(TEXT, INTEGER, DATE, DATE, INTEGER, BOOLEAN) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.statement_home(DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upload_completeness(DATE) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_asset_account(INTEGER, TEXT, INTEGER, TEXT, TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.add_aaccandass_row(INTEGER, DATE, TEXT, NUMERIC, NUMERIC, TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.delete_aaccandass_row(TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.reconcile_aaccandass(INTEGER, DATE, NUMERIC, DATE, TEXT, TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.aaccandass_preview(INTEGER, TEXT, JSONB) TO strm_app;
GRANT EXECUTE ON FUNCTION public.ingest_aaccandass_upload(INTEGER, TEXT, TEXT, TEXT, JSONB, TEXT, TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.attach_aaccandass_backup(UUID, TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.delete_aaccandass_upload(UUID) TO strm_app;
GRANT EXECUTE ON FUNCTION public.delete_aaccandass_template(BIGINT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.aaccandass_balance(INTEGER, DATE) TO strm_app;
GRANT EXECUTE ON FUNCTION public.aaccandass_balances(DATE, INTEGER) TO strm_app;
GRANT EXECUTE ON FUNCTION public.aaccandass_home(DATE) TO strm_app;
GRANT EXECUTE ON FUNCTION public.aaccandass_rows(INTEGER, DATE, DATE, TEXT, INTEGER, INTEGER) TO strm_app;
GRANT EXECUTE ON FUNCTION public.set_attribute_setting(INTEGER, TEXT, BIGINT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.dimension_summary() TO strm_app;
GRANT EXECUTE ON FUNCTION public.dimension_rows(TEXT, TEXT, DATE, DATE, TEXT, INTEGER, INTEGER) TO strm_app;
GRANT EXECUTE ON FUNCTION public.graphql_rows(TEXT, INTEGER, DATE, DATE, INTEGER, BOOLEAN) TO strm_app;
GRANT EXECUTE ON FUNCTION public.statement_home(DATE) TO strm_app;
GRANT EXECUTE ON FUNCTION public.upload_completeness(DATE) TO strm_app;
