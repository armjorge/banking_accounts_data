-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- Statement file catcher on top of 004_public_banking.sql.
-- Safe to run more than once. Does not drop bank accounts.
-- The first run replaces the earlier statement tables when they lack row_hash.
-- Later runs keep uploaded files.
--
-- Assumptions recorded here and in the README:
-- * Only Banorte is loaded. The browser decodes UTF-8, or Windows-1252 when the
--   bytes are not UTF-8, then folds non-breaking spaces to spaces. Postgres
--   checks the header and casts columns. It does not rewrite the movement.
-- * concept_sk is the digits in the trimmed concept, or the letters when there
--   are no digits. row_hash is the date, account number, amount, concept_sk,
--   and an occurrence counter. Balance, period, and file are not in the hash.
-- * Debit amount is cargos + abonos. Credit statement amount is cargo - abono.
--   Installment amount is the mensualidad. Account numbers stay text.
-- * A period opens the day after its cutoff. The catcher keeps that period and
--   the two before it. Labels are derived from period_end.
-- * Closed masters are append-only. Open debit and open credit are replaced
--   for the signed-in user in one transaction. Dimensions stay when either changes.
-- * Free and Entry allow one credit and one debit account. Plus and Premium
--   allow 10. The 11th account is a private deployment, not another shared plan.
-- * End-user sessions SET ROLE strm_app and set app.tenant_id / app.user_id.
--   The table owner bypasses row level security and runs the definer functions.

CREATE SCHEMA IF NOT EXISTS cognito_users;

DO $role$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'strm_app') THEN
        CREATE ROLE strm_app NOLOGIN;
    END IF;
END
$role$;

GRANT strm_app TO CURRENT_USER;

ALTER TABLE public.plans_d
ADD COLUMN IF NOT EXISTS max_credit_accounts INTEGER;

ALTER TABLE public.plans_d
ADD COLUMN IF NOT EXISTS max_debit_accounts INTEGER;

ALTER TABLE public.plans_d
ADD COLUMN IF NOT EXISTS max_total_accounts INTEGER;

ALTER TABLE public.plans_d
ADD COLUMN IF NOT EXISTS curated_csv_backup BOOLEAN NOT NULL DEFAULT FALSE;

INSERT INTO public.plans_d (
    plan_code,
    display_name,
    local_storage_only,
    snowflake_backup,
    monthly_api_quota,
    max_credit_accounts,
    max_debit_accounts,
    max_total_accounts,
    curated_csv_backup
)
VALUES
('free', 'Free', TRUE, FALSE, 0, 1, 1, 2, FALSE),
('entry', 'Entry', TRUE, FALSE, 0, 1, 1, 2, FALSE),
('plus', 'Plus', FALSE, TRUE, 1000, NULL, NULL, 10, FALSE),
('premium', 'Premium', FALSE, TRUE, 10000, NULL, NULL, 10, TRUE)
ON CONFLICT (plan_code) DO UPDATE
SET
    display_name = EXCLUDED.display_name,
    local_storage_only = EXCLUDED.local_storage_only,
    snowflake_backup = EXCLUDED.snowflake_backup,
    monthly_api_quota = EXCLUDED.monthly_api_quota,
    max_credit_accounts = EXCLUDED.max_credit_accounts,
    max_debit_accounts = EXCLUDED.max_debit_accounts,
    max_total_accounts = EXCLUDED.max_total_accounts,
    curated_csv_backup = EXCLUDED.curated_csv_backup;

ALTER TABLE public.plans_d
DROP CONSTRAINT IF EXISTS plans_d_limits_check;

ALTER TABLE public.plans_d
ADD CONSTRAINT plans_d_limits_check CHECK (
    (max_credit_accounts IS NULL OR max_credit_accounts >= 0)
    AND (max_debit_accounts IS NULL OR max_debit_accounts >= 0)
    AND (max_total_accounts IS NULL OR max_total_accounts BETWEEN 0 AND 10)
);

ALTER TABLE public.account_types_d
ADD COLUMN IF NOT EXISTS ledger_kind TEXT NOT NULL DEFAULT 'debit';

ALTER TABLE public.account_types_d
ADD COLUMN IF NOT EXISTS allows_cutoff BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE public.account_types_d
SET
    ledger_kind = 'credit',
    allows_cutoff = TRUE
WHERE LOWER(type_name) IN ('credit', 'credit card', 'bank credit card', 'tarjeta de credito');

UPDATE public.account_types_d
SET
    ledger_kind = 'debit',
    allows_cutoff = FALSE
WHERE LOWER(type_name) IN ('debit', 'bank debit', 'savings', 'ahorro');

ALTER TABLE public.account_types_d
DROP CONSTRAINT IF EXISTS account_types_d_ledger_kind_check;

ALTER TABLE public.account_types_d
ADD CONSTRAINT account_types_d_ledger_kind_check CHECK (
    (
        ledger_kind = 'credit'
        AND allows_cutoff
    )
    OR (
        ledger_kind = 'debit'
        AND NOT allows_cutoff
    )
);

INSERT INTO public.account_types_d (type_name, ledger_kind, allows_cutoff)
SELECT
    seed.type_name,
    seed.ledger_kind,
    seed.allows_cutoff
FROM (
    VALUES
    ('bank debit', 'debit', FALSE),
    ('bank credit card', 'credit', TRUE),
    ('savings', 'debit', FALSE)
) AS seed (type_name, ledger_kind, allows_cutoff)
WHERE NOT EXISTS (
    SELECT 1
    FROM public.account_types_d AS existing
    WHERE LOWER(existing.type_name) = LOWER(seed.type_name)
);

ALTER TABLE public.tenant_users
ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

CREATE INDEX IF NOT EXISTS tenant_users_user_id_idx
ON public.tenant_users (user_id);

CREATE SEQUENCE IF NOT EXISTS public.bank_accounts_d_account_id_seq;

ALTER TABLE public.bank_accounts_d
ALTER COLUMN account_id SET DEFAULT NEXTVAL('public.bank_accounts_d_account_id_seq');

ALTER SEQUENCE public.bank_accounts_d_account_id_seq
OWNED BY public.bank_accounts_d.account_id;

SELECT SETVAL(
    'public.bank_accounts_d_account_id_seq',
    (SELECT COALESCE(MAX(account_id), 1) FROM public.bank_accounts_d),
    (SELECT EXISTS(SELECT 1 FROM public.bank_accounts_d))
);

ALTER TABLE public.bank_accounts_d
ADD COLUMN IF NOT EXISTS account_number TEXT;

ALTER TABLE public.bank_accounts_d
ADD COLUMN IF NOT EXISTS credit_days INTEGER;

UPDATE public.bank_accounts_d
SET account_number = account_id::TEXT
WHERE account_number IS NULL OR BTRIM(account_number) = '';

ALTER TABLE public.bank_accounts_d
ALTER COLUMN account_number SET NOT NULL;

ALTER TABLE public.bank_accounts_d
DROP CONSTRAINT IF EXISTS bank_accounts_d_account_number_check;

ALTER TABLE public.bank_accounts_d
ADD CONSTRAINT bank_accounts_d_account_number_check CHECK (account_number ~ '^[0-9]+$');

ALTER TABLE public.bank_accounts_d
DROP CONSTRAINT IF EXISTS bank_accounts_d_credit_days_check;

ALTER TABLE public.bank_accounts_d
ADD CONSTRAINT bank_accounts_d_credit_days_check CHECK (
    credit_days IS NULL OR credit_days BETWEEN 1 AND 90
);

CREATE UNIQUE INDEX IF NOT EXISTS bank_accounts_d_tenant_number_idx
ON public.bank_accounts_d (tenant_id, account_number);

INSERT INTO public.banks_d (bank_name)
SELECT 'Banorte'
WHERE NOT EXISTS (
    SELECT 1
    FROM public.banks_d AS bank
    WHERE LOWER(bank.bank_name) = 'banorte'
);

ALTER TABLE public.cutoff_date_f
ADD COLUMN IF NOT EXISTS tenant_id UUID;

UPDATE public.cutoff_date_f AS cutoff
SET tenant_id = account.tenant_id
FROM public.bank_accounts_d AS account
WHERE
    cutoff.tenant_id IS NULL
    AND account.account_id = cutoff.account_id
    AND account.user_id = cutoff.user_id;

DELETE FROM public.cutoff_date_f
WHERE tenant_id IS NULL;

ALTER TABLE public.cutoff_date_f
ALTER COLUMN tenant_id SET NOT NULL;

DO $fk$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE conname = 'cutoff_date_f_tenant_user_fkey'
    ) THEN
        ALTER TABLE public.cutoff_date_f
        ADD CONSTRAINT cutoff_date_f_tenant_user_fkey
        FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id);
    END IF;
END
$fk$;

CREATE SEQUENCE IF NOT EXISTS public.cutoff_date_f_cutoff_id_seq;

ALTER TABLE public.cutoff_date_f
ALTER COLUMN cutoff_id SET DEFAULT NEXTVAL('public.cutoff_date_f_cutoff_id_seq');

ALTER SEQUENCE public.cutoff_date_f_cutoff_id_seq
OWNED BY public.cutoff_date_f.cutoff_id;

SELECT SETVAL(
    'public.cutoff_date_f_cutoff_id_seq',
    (SELECT COALESCE(MAX(cutoff_id), 1) FROM public.cutoff_date_f),
    (SELECT EXISTS(SELECT 1 FROM public.cutoff_date_f))
);

CREATE UNIQUE INDEX IF NOT EXISTS cutoff_date_f_account_period_idx
ON public.cutoff_date_f (account_id, cutoff_year, cutoff_month);

CREATE UNIQUE INDEX IF NOT EXISTS cutoff_date_f_cutoff_id_idx
ON public.cutoff_date_f (cutoff_id);

ALTER TABLE public.cutoff_date_f
ADD COLUMN IF NOT EXISTS period_start DATE;

ALTER TABLE public.cutoff_date_f
ADD COLUMN IF NOT EXISTS period_end DATE;

ALTER TABLE public.cutoff_date_f
ADD COLUMN IF NOT EXISTS added_by_user BOOLEAN NOT NULL DEFAULT FALSE;

DELETE FROM public.cutoff_date_f
WHERE cutoff_date IS NULL AND period_end IS NULL;

UPDATE public.cutoff_date_f
SET
    period_end = COALESCE(period_end, cutoff_date),
    period_start = COALESCE(
        period_start,
        DATE_TRUNC('month', COALESCE(period_end, cutoff_date))::DATE
    )
WHERE period_start IS NULL OR period_end IS NULL;

ALTER TABLE public.cutoff_date_f
ALTER COLUMN period_start SET NOT NULL;

ALTER TABLE public.cutoff_date_f
ALTER COLUMN period_end SET NOT NULL;

DO $migrate$
BEGIN
    IF to_regclass('public.statement_uploads_f') IS NULL THEN
        RETURN;
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint
        WHERE
            conrelid = to_regclass('public.statement_uploads_f')
            AND conname = 'statement_uploads_f_dataset_check'
            AND pg_get_constraintdef(oid) LIKE '%credit_monthly%'
    ) THEN
        DROP TABLE IF EXISTS public.msi_closed_f;
        DROP TABLE IF EXISTS public.master_credit_closed_f;
        DROP TABLE IF EXISTS public.master_debit_closed_f;
        DROP TABLE IF EXISTS public.credit_plan_closed_f;
        DROP TABLE IF EXISTS public.open_credit_f;
        DROP TABLE IF EXISTS public.open_debit_f;
        DROP TABLE IF EXISTS public.movement_dimensions_d;
        DROP TABLE IF EXISTS public.statement_uploads_f;
    END IF;
END
$migrate$;

CREATE TABLE IF NOT EXISTS public.statement_uploads_f (
    upload_id UUID NOT NULL DEFAULT GEN_RANDOM_UUID(),
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    cutoff_id INTEGER NOT NULL,
    dataset TEXT NOT NULL,
    original_filename TEXT NOT NULL,
    content_sha256 TEXT NOT NULL,
    byte_size INTEGER NOT NULL,
    row_count INTEGER NOT NULL,
    storage_mode TEXT NOT NULL DEFAULT 'database',
    curated_s3_key TEXT,
    body_text TEXT,
    pdf_bytes BYTEA,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT statement_uploads_f_pkey PRIMARY KEY (upload_id),
    CONSTRAINT statement_uploads_f_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT statement_uploads_f_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id),
    CONSTRAINT statement_uploads_f_cutoff_fkey
    FOREIGN KEY (cutoff_id) REFERENCES public.cutoff_date_f (cutoff_id),
    CONSTRAINT statement_uploads_f_dataset_check CHECK (
        dataset IN ('debit', 'credit_monthly', 'credit_plan', 'pdf')
    ),
    CONSTRAINT statement_uploads_f_storage_check CHECK (storage_mode IN ('database', 'curated')),
    CONSTRAINT statement_uploads_f_body_check CHECK (
        (
            dataset = 'pdf'
            AND pdf_bytes IS NOT NULL
            AND body_text IS NULL
            AND row_count = 0
        )
        OR (
            dataset <> 'pdf'
            AND body_text IS NOT NULL
            AND pdf_bytes IS NULL
            AND row_count > 0
        )
    ),
    CONSTRAINT statement_uploads_f_slot_key UNIQUE (cutoff_id, dataset)
);

CREATE INDEX IF NOT EXISTS statement_uploads_f_tenant_idx
ON public.statement_uploads_f (tenant_id, user_id);

CREATE TABLE IF NOT EXISTS public.master_debit_closed_f (
    row_id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    file_id UUID NOT NULL,
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    account_number TEXT NOT NULL,
    bank_name TEXT NOT NULL,
    file_name TEXT NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    txn_date DATE NOT NULL,
    concept TEXT NOT NULL,
    concept_sk TEXT NOT NULL,
    cargos NUMERIC(18, 2) NOT NULL,
    abonos NUMERIC(18, 2) NOT NULL,
    saldos NUMERIC(18, 2) NOT NULL,
    amount NUMERIC(18, 2) NOT NULL,
    occurrence INTEGER NOT NULL,
    row_hash TEXT NOT NULL,
    CONSTRAINT master_debit_closed_f_pkey PRIMARY KEY (row_id),
    CONSTRAINT master_debit_closed_f_file_fkey
    FOREIGN KEY (file_id) REFERENCES public.statement_uploads_f (upload_id),
    CONSTRAINT master_debit_closed_f_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT master_debit_closed_f_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id),
    CONSTRAINT master_debit_closed_f_account_number_check CHECK (account_number ~ '^[0-9]+$'),
    CONSTRAINT master_debit_closed_f_concept_sk_check CHECK (LENGTH(concept_sk) > 0),
    CONSTRAINT master_debit_closed_f_occurrence_check CHECK (occurrence >= 1),
    CONSTRAINT master_debit_closed_f_hash_check CHECK (LENGTH(row_hash) = 64),
    CONSTRAINT master_debit_closed_f_amount_check CHECK (amount = cargos + abonos)
);

CREATE UNIQUE INDEX IF NOT EXISTS master_debit_closed_f_hash_idx
ON public.master_debit_closed_f (account_id, row_hash);

CREATE INDEX IF NOT EXISTS master_debit_closed_f_file_idx
ON public.master_debit_closed_f (file_id);

CREATE INDEX IF NOT EXISTS master_debit_closed_f_tenant_idx
ON public.master_debit_closed_f (tenant_id, user_id);

CREATE TABLE IF NOT EXISTS public.master_credit_closed_f (
    row_id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    file_id UUID NOT NULL,
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    account_number TEXT NOT NULL,
    bank_name TEXT NOT NULL,
    file_name TEXT NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    txn_date DATE NOT NULL,
    concept TEXT NOT NULL,
    concept_sk TEXT NOT NULL,
    abono NUMERIC(18, 2) NOT NULL,
    cargo NUMERIC(18, 2) NOT NULL,
    tarjeta TEXT NOT NULL,
    amount NUMERIC(18, 2) NOT NULL,
    occurrence INTEGER NOT NULL,
    row_hash TEXT NOT NULL,
    CONSTRAINT master_credit_closed_f_pkey PRIMARY KEY (row_id),
    CONSTRAINT master_credit_closed_f_file_fkey
    FOREIGN KEY (file_id) REFERENCES public.statement_uploads_f (upload_id),
    CONSTRAINT master_credit_closed_f_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT master_credit_closed_f_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id),
    CONSTRAINT master_credit_closed_f_account_number_check CHECK (account_number ~ '^[0-9]+$'),
    CONSTRAINT master_credit_closed_f_concept_sk_check CHECK (LENGTH(concept_sk) > 0),
    CONSTRAINT master_credit_closed_f_occurrence_check CHECK (occurrence >= 1),
    CONSTRAINT master_credit_closed_f_hash_check CHECK (LENGTH(row_hash) = 64),
    CONSTRAINT master_credit_closed_f_amount_check CHECK (amount = cargo - abono)
);

CREATE UNIQUE INDEX IF NOT EXISTS master_credit_closed_f_hash_idx
ON public.master_credit_closed_f (account_id, row_hash);

CREATE INDEX IF NOT EXISTS master_credit_closed_f_file_idx
ON public.master_credit_closed_f (file_id);

CREATE INDEX IF NOT EXISTS master_credit_closed_f_tenant_idx
ON public.master_credit_closed_f (tenant_id, user_id);

CREATE TABLE IF NOT EXISTS public.credit_plan_closed_f (
    row_id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    file_id UUID NOT NULL,
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    account_number TEXT NOT NULL,
    bank_name TEXT NOT NULL,
    file_name TEXT NOT NULL,
    period_start DATE NOT NULL,
    period_end DATE NOT NULL,
    txn_date DATE NOT NULL,
    concept TEXT NOT NULL,
    concept_sk TEXT NOT NULL,
    tasa_anual NUMERIC(18, 4) NOT NULL,
    importe_inicial NUMERIC(18, 2) NOT NULL,
    importe_pendiente NUMERIC(18, 2) NOT NULL,
    pagos_pendientes TEXT NOT NULL,
    mensualidad NUMERIC(18, 2) NOT NULL,
    amount NUMERIC(18, 2) NOT NULL,
    occurrence INTEGER NOT NULL,
    row_hash TEXT NOT NULL,
    CONSTRAINT credit_plan_closed_f_pkey PRIMARY KEY (row_id),
    CONSTRAINT credit_plan_closed_f_file_fkey
    FOREIGN KEY (file_id) REFERENCES public.statement_uploads_f (upload_id),
    CONSTRAINT credit_plan_closed_f_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT credit_plan_closed_f_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id),
    CONSTRAINT credit_plan_closed_f_account_number_check CHECK (account_number ~ '^[0-9]+$'),
    CONSTRAINT credit_plan_closed_f_concept_sk_check CHECK (LENGTH(concept_sk) > 0),
    CONSTRAINT credit_plan_closed_f_occurrence_check CHECK (occurrence >= 1),
    CONSTRAINT credit_plan_closed_f_hash_check CHECK (LENGTH(row_hash) = 64),
    CONSTRAINT credit_plan_closed_f_amount_check CHECK (amount = mensualidad)
);

CREATE UNIQUE INDEX IF NOT EXISTS credit_plan_closed_f_hash_idx
ON public.credit_plan_closed_f (account_id, row_hash);

CREATE INDEX IF NOT EXISTS credit_plan_closed_f_file_idx
ON public.credit_plan_closed_f (file_id);

CREATE INDEX IF NOT EXISTS credit_plan_closed_f_tenant_idx
ON public.credit_plan_closed_f (tenant_id, user_id);

CREATE TABLE IF NOT EXISTS public.open_debit_f (
    row_id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    account_number TEXT NOT NULL,
    bank_name TEXT NOT NULL,
    file_name TEXT NOT NULL DEFAULT 'open reload',
    txn_date DATE NOT NULL,
    concept TEXT NOT NULL,
    concept_sk TEXT NOT NULL,
    cargos NUMERIC(18, 2) NOT NULL,
    abonos NUMERIC(18, 2) NOT NULL,
    saldos NUMERIC(18, 2) NOT NULL,
    amount NUMERIC(18, 2) NOT NULL,
    occurrence INTEGER NOT NULL,
    row_hash TEXT NOT NULL,
    CONSTRAINT open_debit_f_pkey PRIMARY KEY (row_id),
    CONSTRAINT open_debit_f_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT open_debit_f_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id),
    CONSTRAINT open_debit_f_account_number_check CHECK (account_number ~ '^[0-9]+$'),
    CONSTRAINT open_debit_f_concept_sk_check CHECK (LENGTH(concept_sk) > 0),
    CONSTRAINT open_debit_f_occurrence_check CHECK (occurrence >= 1),
    CONSTRAINT open_debit_f_hash_check CHECK (LENGTH(row_hash) = 64),
    CONSTRAINT open_debit_f_amount_check CHECK (amount = cargos + abonos)
);

CREATE UNIQUE INDEX IF NOT EXISTS open_debit_f_hash_idx
ON public.open_debit_f (account_id, row_hash);

CREATE INDEX IF NOT EXISTS open_debit_f_tenant_idx
ON public.open_debit_f (tenant_id, user_id);

CREATE TABLE IF NOT EXISTS public.open_credit_f (
    row_id BIGINT GENERATED ALWAYS AS IDENTITY NOT NULL,
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    account_number TEXT NOT NULL,
    bank_name TEXT NOT NULL,
    file_name TEXT NOT NULL DEFAULT 'open reload',
    txn_date DATE NOT NULL,
    concept TEXT NOT NULL,
    concept_sk TEXT NOT NULL,
    abono NUMERIC(18, 2) NOT NULL,
    cargo NUMERIC(18, 2) NOT NULL,
    tarjeta TEXT NOT NULL,
    amount NUMERIC(18, 2) NOT NULL,
    occurrence INTEGER NOT NULL,
    row_hash TEXT NOT NULL,
    CONSTRAINT open_credit_f_pkey PRIMARY KEY (row_id),
    CONSTRAINT open_credit_f_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT open_credit_f_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id),
    CONSTRAINT open_credit_f_account_number_check CHECK (account_number ~ '^[0-9]+$'),
    CONSTRAINT open_credit_f_concept_sk_check CHECK (LENGTH(concept_sk) > 0),
    CONSTRAINT open_credit_f_occurrence_check CHECK (occurrence >= 1),
    CONSTRAINT open_credit_f_hash_check CHECK (LENGTH(row_hash) = 64),
    CONSTRAINT open_credit_f_amount_check CHECK (amount = cargo - abono)
);

CREATE UNIQUE INDEX IF NOT EXISTS open_credit_f_hash_idx
ON public.open_credit_f (account_id, row_hash);

CREATE INDEX IF NOT EXISTS open_credit_f_tenant_idx
ON public.open_credit_f (tenant_id, user_id);

CREATE TABLE IF NOT EXISTS public.movement_dimensions_d (
    tenant_id UUID NOT NULL,
    row_hash TEXT NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT movement_dimensions_d_pkey PRIMARY KEY (tenant_id, row_hash),
    CONSTRAINT movement_dimensions_d_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT movement_dimensions_d_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id),
    CONSTRAINT movement_dimensions_d_hash_check CHECK (LENGTH(row_hash) = 64)
);

CREATE INDEX IF NOT EXISTS movement_dimensions_d_account_idx
ON public.movement_dimensions_d (account_id);

CREATE TABLE IF NOT EXISTS public.upload_delete_guard (
    upload_id UUID NOT NULL,
    CONSTRAINT upload_delete_guard_pkey PRIMARY KEY (upload_id)
);

REVOKE ALL ON public.upload_delete_guard FROM PUBLIC;

CREATE OR REPLACE FUNCTION public.session_tenant()
RETURNS UUID
LANGUAGE sql
STABLE
AS $fn$
    SELECT NULLIF(CURRENT_SETTING('app.tenant_id', TRUE), '')::UUID
$fn$;

CREATE OR REPLACE FUNCTION public.session_user()
RETURNS UUID
LANGUAGE sql
STABLE
AS $fn$
    SELECT NULLIF(CURRENT_SETTING('app.user_id', TRUE), '')::UUID
$fn$;

CREATE OR REPLACE FUNCTION public.require_session()
RETURNS TABLE (tenant_id UUID, user_id UUID)
LANGUAGE plpgsql
STABLE
AS $fn$
BEGIN
    tenant_id := public.session_tenant();
    user_id := public.session_user();
    IF tenant_id IS NULL OR user_id IS NULL THEN
        RAISE EXCEPTION 'missing tenant session' USING ERRCODE = '28000';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM public.tenant_users AS membership
        WHERE
            membership.tenant_id = require_session.tenant_id
            AND membership.user_id = require_session.user_id
    ) THEN
        RAISE EXCEPTION 'tenant isolation' USING ERRCODE = '42501';
    END IF;
    RETURN NEXT;
END
$fn$;

CREATE OR REPLACE FUNCTION public.concept_sk(p_concept TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE
        WHEN trimmed.concept ~ '[0-9]' THEN REGEXP_REPLACE(trimmed.concept, '[^0-9]', '', 'g')
        ELSE REGEXP_REPLACE(trimmed.concept, '[^[:alpha:]]', '', 'g')
    END
    FROM (
        SELECT BTRIM(
            REPLACE(REPLACE(COALESCE(p_concept, ''), CHR(160), ' '), CHR(65279), '')
        ) AS concept
    ) AS trimmed
$fn$;

CREATE OR REPLACE FUNCTION public.concept_hash_key(p_concept TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT public.concept_sk(p_concept)
$fn$;

CREATE OR REPLACE FUNCTION public.normalize_header(p_header TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT REGEXP_REPLACE(
        TRANSLATE(
            LOWER(BTRIM(REPLACE(REPLACE(COALESCE(p_header, ''), CHR(160), ' '), CHR(65279), ''))),
            'áéíóúüñàèìòùâêîôûäëïöü',
            'aeiouunaeiouaeiouaeiou'
        ),
        '[[:space:]]+',
        ' ',
        'g'
    )
$fn$;

CREATE OR REPLACE FUNCTION public.banorte_profile(p_headers TEXT [])
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    WITH normalized AS (
        SELECT ARRAY_AGG(public.normalize_header(header) ORDER BY public.normalize_header(header)) AS headers
        FROM UNNEST(p_headers) AS header
    )
    SELECT CASE normalized.headers
        WHEN ARRAY['abonos', 'cargos', 'concepto', 'fecha', 'saldos'] THEN 'debit'
        WHEN ARRAY['abono', 'cargo', 'concepto', 'fecha', 'tarjeta'] THEN 'credit_monthly'
        WHEN ARRAY[
            'concepto',
            'fecha de operacion',
            'importe inicial',
            'importe pendiente',
            'mensualidad',
            'pagos pendientes',
            'tasa anual'
        ] THEN 'credit_plan'
        ELSE NULL
    END
    FROM normalized
$fn$;

CREATE OR REPLACE FUNCTION public.parse_amount(p_raw TEXT)
RETURNS NUMERIC
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_text TEXT := BTRIM(p_raw);
    v_negative BOOLEAN := FALSE;
BEGIN
    IF v_text IS NULL OR v_text = '' THEN
        RETURN NULL;
    END IF;
    v_text := REPLACE(REPLACE(REPLACE(v_text, '$', ''), ' ', ''), CHR(160), '');
    IF LEFT(v_text, 1) = '(' AND RIGHT(v_text, 1) = ')' THEN
        v_negative := TRUE;
        v_text := BTRIM(SUBSTR(v_text, 2, LENGTH(v_text) - 2));
    END IF;
    IF LEFT(v_text, 1) = '+' THEN
        v_text := SUBSTR(v_text, 2);
    END IF;
    IF LEFT(v_text, 1) = '-' THEN
        v_negative := TRUE;
        v_text := SUBSTR(v_text, 2);
    END IF;
    IF v_text ~ '\.' AND v_text ~ ',' THEN
        IF POSITION(',' IN v_text) > POSITION('.' IN v_text) THEN
            v_text := REPLACE(v_text, '.', '');
            v_text := REPLACE(v_text, ',', '.');
        ELSE
            v_text := REPLACE(v_text, ',', '');
        END IF;
    ELSIF v_text ~ ',' THEN
        IF v_text ~ '^\d{1,3}(,\d{3})+$' THEN
            v_text := REPLACE(v_text, ',', '');
        ELSE
            v_text := REPLACE(v_text, ',', '.');
        END IF;
    ELSIF v_text ~ '^\d{1,3}(\.\d{3})+$' THEN
        v_text := REPLACE(v_text, '.', '');
    END IF;
    IF v_text !~ '^\d+(\.\d+)?$' THEN
        RAISE EXCEPTION 'unreadable amount: %', p_raw USING ERRCODE = '22P02';
    END IF;
    IF v_negative THEN
        RETURN -v_text::NUMERIC;
    END IF;
    RETURN v_text::NUMERIC;
END
$fn$;

CREATE OR REPLACE FUNCTION public.parse_csv(p_csv TEXT)
RETURNS TABLE (record_no INTEGER, fields TEXT [])
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_source TEXT;
    v_index INTEGER := 1;
    v_length INTEGER;
    v_char TEXT;
    v_field TEXT := '';
    v_fields TEXT [] := ARRAY[]::TEXT [];
    v_quotes BOOLEAN := FALSE;
    v_record INTEGER := 0;
BEGIN
    IF p_csv IS NULL OR BTRIM(p_csv) = '' THEN
        RETURN;
    END IF;
    v_source := REPLACE(REPLACE(p_csv, E'\r\n', E'\n'), E'\r', E'\n');
    IF LEFT(v_source, 1) = CHR(65279) THEN
        v_source := SUBSTR(v_source, 2);
    END IF;
    v_length := CHAR_LENGTH(v_source);
    WHILE v_index <= v_length LOOP
        v_char := SUBSTR(v_source, v_index, 1);
        IF v_quotes THEN
            IF v_char = '"' THEN
                IF v_index < v_length AND SUBSTR(v_source, v_index + 1, 1) = '"' THEN
                    v_field := v_field || '"';
                    v_index := v_index + 2;
                    CONTINUE;
                END IF;
                v_quotes := FALSE;
                v_index := v_index + 1;
                CONTINUE;
            END IF;
            v_field := v_field || v_char;
            v_index := v_index + 1;
            CONTINUE;
        END IF;
        IF v_char = '"' AND v_field = '' THEN
            v_quotes := TRUE;
            v_index := v_index + 1;
            CONTINUE;
        END IF;
        IF v_char = ',' THEN
            v_fields := ARRAY_APPEND(v_fields, v_field);
            v_field := '';
            v_index := v_index + 1;
            CONTINUE;
        END IF;
        IF v_char = E'\n' THEN
            v_fields := ARRAY_APPEND(v_fields, v_field);
            v_field := '';
            IF NOT (CARDINALITY(v_fields) = 1 AND BTRIM(v_fields[1]) = '') THEN
                v_record := v_record + 1;
                record_no := v_record;
                fields := v_fields;
                RETURN NEXT;
            END IF;
            v_fields := ARRAY[]::TEXT [];
            v_index := v_index + 1;
            CONTINUE;
        END IF;
        v_field := v_field || v_char;
        v_index := v_index + 1;
    END LOOP;
    IF v_quotes THEN
        RAISE EXCEPTION 'The CSV has an unterminated quote' USING ERRCODE = '22P02';
    END IF;
    IF v_field <> '' OR CARDINALITY(v_fields) IS NOT NULL THEN
        v_fields := ARRAY_APPEND(v_fields, v_field);
        IF NOT (CARDINALITY(v_fields) = 1 AND BTRIM(v_fields[1]) = '') THEN
            v_record := v_record + 1;
            record_no := v_record;
            fields := v_fields;
            RETURN NEXT;
        END IF;
    END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION public.movement_row_hash(
    p_txn_date DATE,
    p_account_number TEXT,
    p_amount NUMERIC,
    p_concept_sk TEXT,
    p_occurrence INTEGER
) RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT ENCODE(
        PUBLIC.DIGEST(
            CONVERT_TO(
                EXTRACT(YEAR FROM p_txn_date)::INTEGER::TEXT
                || '-'
                || LPAD(EXTRACT(MONTH FROM p_txn_date)::INTEGER::TEXT, 2, '0')
                || '-'
                || LPAD(EXTRACT(DAY FROM p_txn_date)::INTEGER::TEXT, 2, '0')
                || '|'
                || p_account_number
                || '|'
                || CASE WHEN rounded.amount < 0 THEN '-' ELSE '' END
                || TRUNC(ABS(rounded.amount))::BIGINT::TEXT
                || '.'
                || LPAD(
                    ((ABS(rounded.amount) - TRUNC(ABS(rounded.amount))) * 100)::INTEGER::TEXT,
                    2,
                    '0'
                )
                || '|'
                || p_concept_sk
                || '|'
                || p_occurrence::TEXT,
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    )
    FROM (SELECT ROUND(p_amount, 2) AS amount) AS rounded
$fn$;

CREATE OR REPLACE FUNCTION public.period_bounds(
    p_allows_cutoff BOOLEAN,
    p_cutoff_day INTEGER,
    p_year INTEGER,
    p_month INTEGER,
    OUT period_start DATE,
    OUT period_end DATE
)
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_prev_year INTEGER;
    v_prev_month INTEGER;
    v_prev_last INTEGER;
    v_prev_end DATE;
    v_last INTEGER;
BEGIN
    IF p_month < 1 OR p_month > 12 THEN
        RAISE EXCEPTION 'period month must be from 1 to 12' USING ERRCODE = '22023';
    END IF;
    IF NOT p_allows_cutoff THEN
        period_start := MAKE_DATE(p_year, p_month, 1);
        period_end := (period_start + INTERVAL '1 month' - INTERVAL '1 day')::DATE;
        RETURN;
    END IF;
    IF p_cutoff_day IS NULL OR p_cutoff_day < 1 OR p_cutoff_day > 31 THEN
        RAISE EXCEPTION 'Credit card accounts require a cutoff day from 1 to 31'
            USING ERRCODE = '23514';
    END IF;
    v_last := EXTRACT(
        DAY FROM (MAKE_DATE(p_year, p_month, 1) + INTERVAL '1 month' - INTERVAL '1 day')
    )::INTEGER;
    period_end := MAKE_DATE(p_year, p_month, LEAST(p_cutoff_day, v_last));
    IF p_month = 1 THEN
        v_prev_year := p_year - 1;
        v_prev_month := 12;
    ELSE
        v_prev_year := p_year;
        v_prev_month := p_month - 1;
    END IF;
    v_prev_last := EXTRACT(
        DAY FROM (MAKE_DATE(v_prev_year, v_prev_month, 1) + INTERVAL '1 month' - INTERVAL '1 day')
    )::INTEGER;
    v_prev_end := MAKE_DATE(v_prev_year, v_prev_month, LEAST(p_cutoff_day, v_prev_last));
    period_start := v_prev_end + 1;
END
$fn$;

CREATE OR REPLACE FUNCTION public.catcher_periods(
    p_allows_cutoff BOOLEAN,
    p_cutoff_day INTEGER,
    p_as_of DATE
) RETURNS TABLE (period_start DATE, period_end DATE)
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
    v_year INTEGER;
    v_month INTEGER;
    v_bounds RECORD;
    v_found INTEGER := 0;
    v_guard INTEGER := 0;
    v_starts DATE [] := ARRAY[]::DATE [];
    v_ends DATE [] := ARRAY[]::DATE [];
    v_index INTEGER;
BEGIN
    v_year := EXTRACT(YEAR FROM p_as_of)::INTEGER;
    v_month := EXTRACT(MONTH FROM p_as_of)::INTEGER;
    WHILE v_found < 3 AND v_guard < 36 LOOP
        v_guard := v_guard + 1;
        SELECT bounds.period_start, bounds.period_end
        INTO v_bounds
        FROM public.period_bounds(p_allows_cutoff, p_cutoff_day, v_year, v_month) AS bounds;
        IF p_as_of > v_bounds.period_end THEN
            v_starts := ARRAY_PREPEND(v_bounds.period_start, v_starts);
            v_ends := ARRAY_PREPEND(v_bounds.period_end, v_ends);
            v_found := v_found + 1;
        END IF;
        IF v_month = 1 THEN
            v_month := 12;
            v_year := v_year - 1;
        ELSE
            v_month := v_month - 1;
        END IF;
    END LOOP;
    IF v_found < 3 THEN
        RAISE EXCEPTION 'Could not build the statement window' USING ERRCODE = '22023';
    END IF;
    FOR v_index IN 1..3 LOOP
        period_start := v_starts[v_index];
        period_end := v_ends[v_index];
        RETURN NEXT;
    END LOOP;
END
$fn$;

CREATE OR REPLACE FUNCTION public.account_types_d_set_kind()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF
        TG_OP = 'INSERT'
        AND NEW.ledger_kind = 'debit'
        AND NOT NEW.allows_cutoff
        AND LOWER(BTRIM(NEW.type_name)) ~ 'credit'
    THEN
        NEW.ledger_kind := 'credit';
        NEW.allows_cutoff := TRUE;
    END IF;
    RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS account_types_d_set_kind ON public.account_types_d;

CREATE TRIGGER account_types_d_set_kind
BEFORE INSERT ON public.account_types_d
FOR EACH ROW
EXECUTE FUNCTION public.account_types_d_set_kind();

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
    v_credit INTEGER;
    v_debit INTEGER;
    v_total INTEGER;
BEGIN
    SELECT kind.ledger_kind, kind.allows_cutoff
    INTO v_kind, v_allows
    FROM public.account_types_d AS kind
    WHERE kind.a_type_id = NEW.a_type_id;

    IF v_kind IS NULL THEN
        RAISE EXCEPTION 'account type not found' USING ERRCODE = '23503';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM public.banks_d AS bank
        WHERE
            bank.bank_id = NEW.bank_id
            AND LOWER(bank.bank_name) = 'banorte'
    ) THEN
        RAISE EXCEPTION 'Only Banorte is supported for now' USING ERRCODE = '23514';
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
    ELSE
        IF NEW.account_cutoff_day IS NOT NULL THEN
            RAISE EXCEPTION 'Debit and savings accounts do not have a cutoff day'
                USING ERRCODE = '23514';
        END IF;
        IF NEW.credit_days IS NOT NULL THEN
            RAISE EXCEPTION 'Debit and savings accounts do not have a payment window'
                USING ERRCODE = '23514';
        END IF;
    END IF;
    IF BTRIM(COALESCE(NEW.account_name, '')) = '' THEN
        RAISE EXCEPTION 'Account name is required' USING ERRCODE = '23514';
    END IF;

    SELECT
        plan.display_name,
        plan.max_credit_accounts,
        plan.max_debit_accounts,
        plan.max_total_accounts
    INTO v_plan_name, v_max_credit, v_max_debit, v_max_total
    FROM public.tenants_d AS tenant
    INNER JOIN public.plans_d AS plan ON plan.plan_code = tenant.plan_code
    WHERE tenant.tenant_id = NEW.tenant_id;

    SELECT
        COUNT(*) FILTER (WHERE kind.ledger_kind = 'credit'),
        COUNT(*) FILTER (WHERE kind.ledger_kind = 'debit'),
        COUNT(*)
    INTO v_credit, v_debit, v_total
    FROM public.bank_accounts_d AS account
    INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
    WHERE
        account.tenant_id = NEW.tenant_id
        AND account.account_id IS DISTINCT FROM NEW.account_id;

    IF v_kind = 'credit' THEN
        v_credit := v_credit + 1;
    ELSE
        v_debit := v_debit + 1;
    END IF;
    v_total := v_total + 1;

    IF v_max_credit IS NOT NULL AND v_credit > v_max_credit THEN
        RAISE EXCEPTION '% allows % credit account', v_plan_name, v_max_credit
            USING ERRCODE = '23514';
    END IF;
    IF v_max_debit IS NOT NULL AND v_debit > v_max_debit THEN
        RAISE EXCEPTION '% allows % debit account', v_plan_name, v_max_debit
            USING ERRCODE = '23514';
    END IF;
    IF v_max_total IS NOT NULL AND v_total > v_max_total THEN
        IF v_max_total >= 10 THEN
            RAISE EXCEPTION
                'This shared plan allows % accounts. Beyond that, the product is a private deployment in the client''s own AWS account.',
                v_max_total
                USING ERRCODE = '23514';
        END IF;
        RAISE EXCEPTION '% allows % accounts', v_plan_name, v_max_total
            USING ERRCODE = '23514';
    END IF;
    RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS bank_accounts_d_enforce ON public.bank_accounts_d;

CREATE TRIGGER bank_accounts_d_enforce
BEFORE INSERT OR UPDATE ON public.bank_accounts_d
FOR EACH ROW
EXECUTE FUNCTION public.enforce_bank_account();

CREATE OR REPLACE FUNCTION public.reject_closed_row_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM public.upload_delete_guard AS guard
        WHERE guard.upload_id = OLD.file_id
    ) THEN
        RAISE EXCEPTION 'only the whole uploaded file can be deleted'
            USING ERRCODE = '42501';
    END IF;
    RETURN OLD;
END
$fn$;

CREATE OR REPLACE FUNCTION public.reject_closed_row_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
BEGIN
    RAISE EXCEPTION 'closed statement rows are append-only' USING ERRCODE = '42501';
END
$fn$;

DROP TRIGGER IF EXISTS master_debit_closed_f_no_row_delete ON public.master_debit_closed_f;
DROP TRIGGER IF EXISTS master_credit_closed_f_no_row_delete ON public.master_credit_closed_f;
DROP TRIGGER IF EXISTS credit_plan_closed_f_no_row_delete ON public.credit_plan_closed_f;
DROP TRIGGER IF EXISTS master_debit_closed_f_no_update ON public.master_debit_closed_f;
DROP TRIGGER IF EXISTS master_credit_closed_f_no_update ON public.master_credit_closed_f;
DROP TRIGGER IF EXISTS credit_plan_closed_f_no_update ON public.credit_plan_closed_f;

CREATE TRIGGER master_debit_closed_f_no_row_delete
BEFORE DELETE ON public.master_debit_closed_f
FOR EACH ROW
EXECUTE FUNCTION public.reject_closed_row_delete();

CREATE TRIGGER master_credit_closed_f_no_row_delete
BEFORE DELETE ON public.master_credit_closed_f
FOR EACH ROW
EXECUTE FUNCTION public.reject_closed_row_delete();

CREATE TRIGGER credit_plan_closed_f_no_row_delete
BEFORE DELETE ON public.credit_plan_closed_f
FOR EACH ROW
EXECUTE FUNCTION public.reject_closed_row_delete();

CREATE TRIGGER master_debit_closed_f_no_update
BEFORE UPDATE ON public.master_debit_closed_f
FOR EACH ROW
EXECUTE FUNCTION public.reject_closed_row_update();

CREATE TRIGGER master_credit_closed_f_no_update
BEFORE UPDATE ON public.master_credit_closed_f
FOR EACH ROW
EXECUTE FUNCTION public.reject_closed_row_update();

CREATE TRIGGER credit_plan_closed_f_no_update
BEFORE UPDATE ON public.credit_plan_closed_f
FOR EACH ROW
EXECUTE FUNCTION public.reject_closed_row_update();

CREATE OR REPLACE FUNCTION public.ensure_personal_tenant(p_user_id UUID)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_existing UUID;
    v_created UUID;
    v_email TEXT;
BEGIN
    SELECT membership.tenant_id
    INTO v_existing
    FROM public.tenant_users AS membership
    WHERE membership.user_id = p_user_id
    ORDER BY membership.created_at
    LIMIT 1;
    IF v_existing IS NOT NULL THEN
        RETURN v_existing;
    END IF;
    SELECT users.email
    INTO v_email
    FROM cognito_users.users AS users
    WHERE users.user_id = p_user_id;
    IF v_email IS NULL THEN
        RAISE EXCEPTION 'cognito user not found' USING ERRCODE = 'P0002';
    END IF;
    INSERT INTO public.tenants_d (tenant_name, plan_code)
    VALUES (v_email, 'free')
    RETURNING tenant_id
    INTO v_created;
    INSERT INTO public.tenant_users (tenant_id, user_id)
    VALUES (v_created, p_user_id);
    RETURN v_created;
END
$fn$;

CREATE OR REPLACE FUNCTION public.refresh_statement_periods(
    p_account_id INTEGER,
    p_as_of DATE
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_allows BOOLEAN;
    v_cutoff_day INTEGER;
    v_period RECORD;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    SELECT kind.allows_cutoff, account.account_cutoff_day
    INTO v_allows, v_cutoff_day
    FROM public.bank_accounts_d AS account
    INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
    WHERE
        account.account_id = p_account_id
        AND account.tenant_id = v_tenant
        AND account.user_id = v_user;

    IF v_allows IS NULL THEN
        RAISE EXCEPTION 'account not found' USING ERRCODE = 'P0002';
    END IF;

    FOR v_period IN
        SELECT window_period.period_start, window_period.period_end
        FROM public.catcher_periods(v_allows, v_cutoff_day, p_as_of) AS window_period
    LOOP
        INSERT INTO public.cutoff_date_f (
            account_id,
            user_id,
            tenant_id,
            cutoff_month,
            cutoff_year,
            is_required,
            cutoff_date,
            period_start,
            period_end,
            added_by_user
        )
        VALUES (
            p_account_id,
            v_user,
            v_tenant,
            EXTRACT(MONTH FROM v_period.period_end)::INTEGER,
            EXTRACT(YEAR FROM v_period.period_end)::INTEGER,
            TRUE,
            v_period.period_end,
            v_period.period_start,
            v_period.period_end,
            FALSE
        )
        ON CONFLICT (account_id, cutoff_year, cutoff_month) DO UPDATE
        SET
            cutoff_date = EXCLUDED.cutoff_date,
            period_start = EXCLUDED.period_start,
            period_end = EXCLUDED.period_end,
            is_required = TRUE;
    END LOOP;

    UPDATE public.cutoff_date_f
    SET is_required = p_as_of > period_end
    WHERE
        account_id = p_account_id
        AND user_id = v_user;
END
$fn$;

DROP FUNCTION IF EXISTS public.create_bank_account(INTEGER, INTEGER, TEXT, INTEGER, DATE);

CREATE OR REPLACE FUNCTION public.create_bank_account(
    p_bank_id INTEGER,
    p_a_type_id INTEGER,
    p_account_name TEXT,
    p_account_number TEXT,
    p_cutoff_day INTEGER,
    p_credit_days INTEGER,
    p_as_of DATE
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_account_id INTEGER;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    INSERT INTO public.bank_accounts_d (
        bank_id,
        user_id,
        tenant_id,
        a_type_id,
        account_name,
        account_number,
        account_cutoff_day,
        credit_days
    )
    VALUES (
        p_bank_id,
        v_user,
        v_tenant,
        p_a_type_id,
        BTRIM(p_account_name),
        p_account_number,
        p_cutoff_day,
        p_credit_days
    )
    RETURNING account_id
    INTO v_account_id;

    PERFORM public.refresh_statement_periods(v_account_id, p_as_of);
    RETURN v_account_id;
END
$fn$;

CREATE OR REPLACE FUNCTION public.add_earlier_period(
    p_account_id INTEGER,
    p_as_of DATE
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_allows BOOLEAN;
    v_cutoff_day INTEGER;
    v_oldest DATE;
    v_year INTEGER;
    v_month INTEGER;
    v_bounds RECORD;
    v_cutoff_id INTEGER;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    PERFORM public.refresh_statement_periods(p_account_id, p_as_of);

    SELECT kind.allows_cutoff, account.account_cutoff_day, MIN(cutoff.period_end)
    INTO v_allows, v_cutoff_day, v_oldest
    FROM public.bank_accounts_d AS account
    INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
    INNER JOIN public.cutoff_date_f AS cutoff ON cutoff.account_id = account.account_id
    WHERE
        account.account_id = p_account_id
        AND account.tenant_id = v_tenant
        AND account.user_id = v_user
    GROUP BY kind.allows_cutoff, account.account_cutoff_day;

    IF v_oldest IS NULL THEN
        RAISE EXCEPTION 'account not found' USING ERRCODE = 'P0002';
    END IF;
    v_year := EXTRACT(YEAR FROM v_oldest)::INTEGER;
    v_month := EXTRACT(MONTH FROM v_oldest)::INTEGER;
    IF v_month = 1 THEN
        v_month := 12;
        v_year := v_year - 1;
    ELSE
        v_month := v_month - 1;
    END IF;
    SELECT bounds.period_start, bounds.period_end
    INTO v_bounds
    FROM public.period_bounds(v_allows, v_cutoff_day, v_year, v_month) AS bounds;

    INSERT INTO public.cutoff_date_f (
        account_id,
        user_id,
        tenant_id,
        cutoff_month,
        cutoff_year,
        is_required,
        cutoff_date,
        period_start,
        period_end,
        added_by_user
    )
    VALUES (
        p_account_id,
        v_user,
        v_tenant,
        EXTRACT(MONTH FROM v_bounds.period_end)::INTEGER,
        EXTRACT(YEAR FROM v_bounds.period_end)::INTEGER,
        p_as_of > v_bounds.period_end,
        v_bounds.period_end,
        v_bounds.period_start,
        v_bounds.period_end,
        TRUE
    )
    ON CONFLICT (account_id, cutoff_year, cutoff_month) DO NOTHING
    RETURNING cutoff_id
    INTO v_cutoff_id;

    IF v_cutoff_id IS NULL THEN
        RAISE EXCEPTION 'That period is already on the account' USING ERRCODE = '23505';
    END IF;
    RETURN v_cutoff_id;
END
$fn$;

CREATE OR REPLACE FUNCTION public.remove_statement_period(
    p_cutoff_id INTEGER,
    p_as_of DATE
) RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_account_id INTEGER;
    v_allows BOOLEAN;
    v_cutoff_day INTEGER;
    v_period_end DATE;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    SELECT cutoff.account_id, cutoff.period_end, kind.allows_cutoff, account.account_cutoff_day
    INTO v_account_id, v_period_end, v_allows, v_cutoff_day
    FROM public.cutoff_date_f AS cutoff
    INNER JOIN public.bank_accounts_d AS account
        ON account.account_id = cutoff.account_id
        AND account.user_id = cutoff.user_id
    INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
    WHERE
        cutoff.cutoff_id = p_cutoff_id
        AND cutoff.tenant_id = v_tenant
        AND cutoff.user_id = v_user
    FOR UPDATE OF cutoff;

    IF v_account_id IS NULL THEN
        RAISE EXCEPTION 'period not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_as_of <= v_period_end THEN
        RAISE EXCEPTION 'That period is not in the past' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.catcher_periods(v_allows, v_cutoff_day, p_as_of) AS window_period
        WHERE window_period.period_end = v_period_end
    ) THEN
        RAISE EXCEPTION 'The current download periods stay on the account' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.statement_uploads_f AS upload
        WHERE upload.cutoff_id = p_cutoff_id
    ) THEN
        RAISE EXCEPTION 'Delete the uploaded file before removing the period' USING ERRCODE = '23503';
    END IF;

    DELETE FROM public.cutoff_date_f
    WHERE cutoff_id = p_cutoff_id;
END
$fn$;

DROP FUNCTION IF EXISTS public.ingest_statement_csv(INTEGER, INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE);

CREATE OR REPLACE FUNCTION public.ingest_statement_csv(
    p_account_id INTEGER,
    p_cutoff_id INTEGER,
    p_slot TEXT,
    p_filename TEXT,
    p_csv TEXT,
    p_as_of DATE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_kind TEXT;
    v_account_number TEXT;
    v_bank_name TEXT;
    v_period_start DATE;
    v_period_end DATE;
    v_dataset TEXT;
    v_profile TEXT;
    v_filename TEXT := LEFT(BTRIM(COALESCE(p_filename, '')), 200);
    v_csv TEXT;
    v_header TEXT [];
    v_index JSONB := '{}'::JSONB;
    v_position INTEGER;
    v_record RECORD;
    v_fields TEXT [];
    v_date_text TEXT;
    v_date DATE;
    v_concept TEXT;
    v_sk TEXT;
    v_cargos NUMERIC(18, 2);
    v_abonos NUMERIC(18, 2);
    v_saldos NUMERIC(18, 2);
    v_abono NUMERIC(18, 2);
    v_cargo NUMERIC(18, 2);
    v_tarjeta TEXT;
    v_tasa NUMERIC(18, 4);
    v_inicial NUMERIC(18, 2);
    v_pendiente NUMERIC(18, 2);
    v_pagos TEXT;
    v_mensualidad NUMERIC(18, 2);
    v_amount NUMERIC(18, 2);
    v_upload_id UUID;
    v_rows INTEGER;
    v_curated BOOLEAN;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    IF p_slot NOT IN ('statement', 'installment') THEN
        RAISE EXCEPTION 'slot must be statement or installment' USING ERRCODE = '22023';
    END IF;
    IF v_filename = '' THEN
        RAISE EXCEPTION 'A file name is required' USING ERRCODE = '22023';
    END IF;
    IF p_csv IS NULL OR CHAR_LENGTH(p_csv) = 0 OR CHAR_LENGTH(p_csv) > 2000000 THEN
        RAISE EXCEPTION 'The CSV is empty or larger than 2 MB' USING ERRCODE = '22023';
    END IF;

    SELECT
        kind.ledger_kind,
        account.account_number,
        bank.bank_name,
        cutoff.period_start,
        cutoff.period_end
    INTO v_kind, v_account_number, v_bank_name, v_period_start, v_period_end
    FROM public.bank_accounts_d AS account
    INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
    INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
    INNER JOIN public.cutoff_date_f AS cutoff ON cutoff.account_id = account.account_id
    WHERE
        account.account_id = p_account_id
        AND account.tenant_id = v_tenant
        AND account.user_id = v_user
        AND cutoff.cutoff_id = p_cutoff_id
        AND cutoff.user_id = v_user
    FOR UPDATE OF cutoff;

    IF v_kind IS NULL THEN
        RAISE EXCEPTION 'period not found' USING ERRCODE = 'P0002';
    END IF;
    IF NOT (p_as_of > v_period_end) THEN
        RAISE EXCEPTION 'The period is not open for upload yet' USING ERRCODE = '22023';
    END IF;
    IF p_slot = 'installment' AND v_kind <> 'credit' THEN
        RAISE EXCEPTION 'Debit accounts do not have an installment file' USING ERRCODE = '23514';
    END IF;
    v_dataset := CASE
        WHEN p_slot = 'installment' THEN 'credit_plan'
        WHEN v_kind = 'credit' THEN 'credit_monthly'
        ELSE 'debit'
    END;
    IF EXISTS (
        SELECT 1
        FROM public.statement_uploads_f AS upload
        WHERE
            upload.cutoff_id = p_cutoff_id
            AND upload.dataset = v_dataset
    ) THEN
        RAISE EXCEPTION 'already uploaded' USING ERRCODE = '23505';
    END IF;

    v_csv := REPLACE(REPLACE(p_csv, CHR(65279), ''), CHR(160), ' ');
    SELECT parsed.fields
    INTO v_header
    FROM public.parse_csv(v_csv) AS parsed
    WHERE parsed.record_no = 1;
    IF v_header IS NULL THEN
        RAISE EXCEPTION 'The CSV needs a header row' USING ERRCODE = '22P02';
    END IF;
    v_profile := public.banorte_profile(v_header);
    IF v_profile IS NULL THEN
        RAISE EXCEPTION 'These headers do not match a Banorte debit, credit statement, or installment file'
            USING ERRCODE = '22P02';
    END IF;
    IF v_profile IS DISTINCT FROM v_dataset THEN
        RAISE EXCEPTION 'These headers belong to a different Banorte file than this slot accepts'
            USING ERRCODE = '22P02';
    END IF;

    FOR v_position IN 1..CARDINALITY(v_header) LOOP
        v_index := v_index || JSONB_BUILD_OBJECT(
            public.normalize_header(v_header[v_position]),
            v_position
        );
    END LOOP;

    DROP TABLE IF EXISTS pg_temp.banorte_catch;
    CREATE TEMP TABLE banorte_catch (
        record_no INTEGER NOT NULL,
        txn_date DATE NOT NULL,
        concept TEXT NOT NULL,
        concept_sk TEXT NOT NULL,
        cargos NUMERIC(18, 2),
        abonos NUMERIC(18, 2),
        saldos NUMERIC(18, 2),
        abono NUMERIC(18, 2),
        cargo NUMERIC(18, 2),
        tarjeta TEXT,
        tasa_anual NUMERIC(18, 4),
        importe_inicial NUMERIC(18, 2),
        importe_pendiente NUMERIC(18, 2),
        pagos_pendientes TEXT,
        mensualidad NUMERIC(18, 2),
        amount NUMERIC(18, 2) NOT NULL,
        occurrence INTEGER,
        row_hash TEXT
    ) ON COMMIT DROP;

    FOR v_record IN
        SELECT parsed.record_no, parsed.fields
        FROM public.parse_csv(v_csv) AS parsed
        WHERE parsed.record_no > 1
    LOOP
        v_fields := v_record.fields;
        IF CARDINALITY(v_fields) = 1 AND BTRIM(v_fields[1]) = '' THEN
            CONTINUE;
        END IF;
        IF CARDINALITY(v_fields) <> CARDINALITY(v_header) THEN
            RAISE EXCEPTION 'Row % does not match the header', v_record.record_no USING ERRCODE = '22P02';
        END IF;
        IF v_dataset = 'credit_plan' THEN
            v_date_text := BTRIM(v_fields[(v_index ->> 'fecha de operacion')::INTEGER]);
        ELSE
            v_date_text := BTRIM(v_fields[(v_index ->> 'fecha')::INTEGER]);
        END IF;
        v_concept := v_fields[(v_index ->> 'concepto')::INTEGER];
        IF v_date_text IS NULL OR v_date_text = '' OR BTRIM(COALESCE(v_concept, '')) = '' THEN
            RAISE EXCEPTION 'Row % needs a date and a concept', v_record.record_no USING ERRCODE = '23514';
        END IF;
        IF v_date_text ~ '^\d{4}-\d{2}-\d{2}$' THEN
            v_date := v_date_text::DATE;
        ELSIF v_date_text ~ '^\d{2}/\d{2}/\d{4}$' THEN
            v_date := TO_DATE(v_date_text, 'DD/MM/YYYY');
        ELSE
            RAISE EXCEPTION 'Row % has an unreadable date', v_record.record_no USING ERRCODE = '22007';
        END IF;
        v_sk := public.concept_sk(v_concept);
        IF v_sk IS NULL OR v_sk = '' THEN
            RAISE EXCEPTION 'Row % concept has no digits or letters to build a key', v_record.record_no
                USING ERRCODE = '23514';
        END IF;

        v_cargos := NULL;
        v_abonos := NULL;
        v_saldos := NULL;
        v_abono := NULL;
        v_cargo := NULL;
        v_tarjeta := NULL;
        v_tasa := NULL;
        v_inicial := NULL;
        v_pendiente := NULL;
        v_pagos := NULL;
        v_mensualidad := NULL;
        IF v_dataset = 'debit' THEN
            v_cargos := ROUND(public.parse_amount(v_fields[(v_index ->> 'cargos')::INTEGER]), 2);
            v_abonos := ROUND(public.parse_amount(v_fields[(v_index ->> 'abonos')::INTEGER]), 2);
            v_saldos := ROUND(public.parse_amount(v_fields[(v_index ->> 'saldos')::INTEGER]), 2);
            IF v_cargos IS NULL OR v_abonos IS NULL OR v_saldos IS NULL THEN
                RAISE EXCEPTION 'Row % is missing a debit amount', v_record.record_no USING ERRCODE = '22P02';
            END IF;
            v_amount := v_cargos + v_abonos;
        ELSIF v_dataset = 'credit_monthly' THEN
            v_abono := ROUND(public.parse_amount(v_fields[(v_index ->> 'abono')::INTEGER]), 2);
            v_cargo := ROUND(public.parse_amount(v_fields[(v_index ->> 'cargo')::INTEGER]), 2);
            v_tarjeta := COALESCE(v_fields[(v_index ->> 'tarjeta')::INTEGER], '');
            IF v_abono IS NULL OR v_cargo IS NULL THEN
                RAISE EXCEPTION 'Row % is missing a credit amount', v_record.record_no USING ERRCODE = '22P02';
            END IF;
            v_amount := v_cargo - v_abono;
        ELSE
            v_tasa := ROUND(
                public.parse_amount(REPLACE(v_fields[(v_index ->> 'tasa anual')::INTEGER], '%', '')),
                4
            );
            v_inicial := ROUND(public.parse_amount(v_fields[(v_index ->> 'importe inicial')::INTEGER]), 2);
            v_pendiente := ROUND(public.parse_amount(v_fields[(v_index ->> 'importe pendiente')::INTEGER]), 2);
            v_pagos := BTRIM(v_fields[(v_index ->> 'pagos pendientes')::INTEGER]);
            v_mensualidad := ROUND(public.parse_amount(v_fields[(v_index ->> 'mensualidad')::INTEGER]), 2);
            IF v_tasa IS NULL OR v_inicial IS NULL OR v_pendiente IS NULL OR v_mensualidad IS NULL THEN
                RAISE EXCEPTION 'Row % is missing an installment amount', v_record.record_no
                    USING ERRCODE = '22P02';
            END IF;
            IF v_pagos IS NULL OR v_pagos = '' THEN
                RAISE EXCEPTION 'Row % is missing pagos pendientes', v_record.record_no USING ERRCODE = '22P02';
            END IF;
            v_amount := v_mensualidad;
        END IF;

        INSERT INTO pg_temp.banorte_catch (
            record_no,
            txn_date,
            concept,
            concept_sk,
            cargos,
            abonos,
            saldos,
            abono,
            cargo,
            tarjeta,
            tasa_anual,
            importe_inicial,
            importe_pendiente,
            pagos_pendientes,
            mensualidad,
            amount
        )
        VALUES (
            v_record.record_no,
            v_date,
            v_concept,
            v_sk,
            v_cargos,
            v_abonos,
            v_saldos,
            v_abono,
            v_cargo,
            v_tarjeta,
            v_tasa,
            v_inicial,
            v_pendiente,
            v_pagos,
            v_mensualidad,
            v_amount
        );
    END LOOP;

    IF NOT EXISTS (SELECT 1 FROM pg_temp.banorte_catch) THEN
        RAISE EXCEPTION 'The CSV has no movements' USING ERRCODE = '22P02';
    END IF;

    UPDATE pg_temp.banorte_catch AS caught
    SET
        occurrence = numbered.occurrence::INTEGER,
        row_hash = public.movement_row_hash(
            caught.txn_date,
            v_account_number,
            caught.amount,
            caught.concept_sk,
            numbered.occurrence::INTEGER
        )
    FROM (
        SELECT
            catch_row.record_no,
            ROW_NUMBER() OVER (
                PARTITION BY catch_row.txn_date, catch_row.amount, catch_row.concept_sk
                ORDER BY catch_row.record_no
            ) AS occurrence
        FROM pg_temp.banorte_catch AS catch_row
    ) AS numbered
    WHERE numbered.record_no = caught.record_no;

    IF v_dataset = 'debit' AND EXISTS (
        SELECT 1
        FROM pg_temp.banorte_catch AS incoming
        INNER JOIN public.master_debit_closed_f AS existing
            ON existing.account_id = p_account_id
            AND existing.row_hash = incoming.row_hash
    ) THEN
        RAISE EXCEPTION 'already uploaded' USING ERRCODE = '23505';
    END IF;
    IF v_dataset = 'credit_monthly' AND EXISTS (
        SELECT 1
        FROM pg_temp.banorte_catch AS incoming
        INNER JOIN public.master_credit_closed_f AS existing
            ON existing.account_id = p_account_id
            AND existing.row_hash = incoming.row_hash
    ) THEN
        RAISE EXCEPTION 'already uploaded' USING ERRCODE = '23505';
    END IF;
    IF v_dataset = 'credit_plan' AND EXISTS (
        SELECT 1
        FROM pg_temp.banorte_catch AS incoming
        INNER JOIN public.credit_plan_closed_f AS existing
            ON existing.account_id = p_account_id
            AND existing.row_hash = incoming.row_hash
    ) THEN
        RAISE EXCEPTION 'already uploaded' USING ERRCODE = '23505';
    END IF;

    SELECT COUNT(*)
    INTO v_rows
    FROM pg_temp.banorte_catch;

    INSERT INTO public.statement_uploads_f (
        tenant_id,
        user_id,
        account_id,
        cutoff_id,
        dataset,
        original_filename,
        content_sha256,
        byte_size,
        row_count,
        storage_mode,
        body_text
    )
    VALUES (
        v_tenant,
        v_user,
        p_account_id,
        p_cutoff_id,
        v_dataset,
        v_filename,
        ENCODE(PUBLIC.DIGEST(CONVERT_TO(v_csv, 'UTF8'), 'sha256'), 'hex'),
        OCTET_LENGTH(CONVERT_TO(v_csv, 'UTF8')),
        v_rows,
        'database',
        v_csv
    )
    RETURNING upload_id
    INTO v_upload_id;

    IF v_dataset = 'debit' THEN
        INSERT INTO public.master_debit_closed_f (
            file_id,
            tenant_id,
            user_id,
            account_id,
            account_number,
            bank_name,
            file_name,
            period_start,
            period_end,
            txn_date,
            concept,
            concept_sk,
            cargos,
            abonos,
            saldos,
            amount,
            occurrence,
            row_hash
        )
        SELECT
            v_upload_id,
            v_tenant,
            v_user,
            p_account_id,
            v_account_number,
            v_bank_name,
            v_filename,
            v_period_start,
            v_period_end,
            caught.txn_date,
            caught.concept,
            caught.concept_sk,
            caught.cargos,
            caught.abonos,
            caught.saldos,
            caught.amount,
            caught.occurrence,
            caught.row_hash
        FROM pg_temp.banorte_catch AS caught;
    ELSIF v_dataset = 'credit_monthly' THEN
        INSERT INTO public.master_credit_closed_f (
            file_id,
            tenant_id,
            user_id,
            account_id,
            account_number,
            bank_name,
            file_name,
            period_start,
            period_end,
            txn_date,
            concept,
            concept_sk,
            abono,
            cargo,
            tarjeta,
            amount,
            occurrence,
            row_hash
        )
        SELECT
            v_upload_id,
            v_tenant,
            v_user,
            p_account_id,
            v_account_number,
            v_bank_name,
            v_filename,
            v_period_start,
            v_period_end,
            caught.txn_date,
            caught.concept,
            caught.concept_sk,
            caught.abono,
            caught.cargo,
            caught.tarjeta,
            caught.amount,
            caught.occurrence,
            caught.row_hash
        FROM pg_temp.banorte_catch AS caught;
    ELSE
        INSERT INTO public.credit_plan_closed_f (
            file_id,
            tenant_id,
            user_id,
            account_id,
            account_number,
            bank_name,
            file_name,
            period_start,
            period_end,
            txn_date,
            concept,
            concept_sk,
            tasa_anual,
            importe_inicial,
            importe_pendiente,
            pagos_pendientes,
            mensualidad,
            amount,
            occurrence,
            row_hash
        )
        SELECT
            v_upload_id,
            v_tenant,
            v_user,
            p_account_id,
            v_account_number,
            v_bank_name,
            v_filename,
            v_period_start,
            v_period_end,
            caught.txn_date,
            caught.concept,
            caught.concept_sk,
            caught.tasa_anual,
            caught.importe_inicial,
            caught.importe_pendiente,
            caught.pagos_pendientes,
            caught.mensualidad,
            caught.amount,
            caught.occurrence,
            caught.row_hash
        FROM pg_temp.banorte_catch AS caught;
    END IF;

    INSERT INTO public.movement_dimensions_d (tenant_id, row_hash, user_id, account_id)
    SELECT v_tenant, caught.row_hash, v_user, p_account_id
    FROM pg_temp.banorte_catch AS caught
    ON CONFLICT (tenant_id, row_hash) DO NOTHING;

    SELECT plan.curated_csv_backup
    INTO v_curated
    FROM public.tenants_d AS tenant
    INNER JOIN public.plans_d AS plan ON plan.plan_code = tenant.plan_code
    WHERE tenant.tenant_id = v_tenant;

    RETURN JSONB_BUILD_OBJECT(
        'upload_id', v_upload_id,
        'file_id', v_upload_id,
        'row_count', v_rows,
        'dataset', v_dataset,
        'curated_csv_backup', v_curated,
        'tenant_id', v_tenant,
        'file_suffix', 'csv'
    );
END
$fn$;

CREATE OR REPLACE FUNCTION public.ingest_period_pdf(
    p_account_id INTEGER,
    p_cutoff_id INTEGER,
    p_filename TEXT,
    p_base64 TEXT,
    p_as_of DATE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_period_end DATE;
    v_filename TEXT := LEFT(BTRIM(COALESCE(p_filename, '')), 200);
    v_bytes BYTEA;
    v_upload_id UUID;
    v_curated BOOLEAN;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    SELECT plan.curated_csv_backup
    INTO v_curated
    FROM public.tenants_d AS tenant
    INNER JOIN public.plans_d AS plan ON plan.plan_code = tenant.plan_code
    WHERE tenant.tenant_id = v_tenant;
    IF NOT COALESCE(v_curated, FALSE) THEN
        RAISE EXCEPTION 'A PDF statement is part of the premium plan' USING ERRCODE = '42501';
    END IF;
    IF v_filename = '' THEN
        RAISE EXCEPTION 'A file name is required' USING ERRCODE = '22023';
    END IF;

    SELECT cutoff.period_end
    INTO v_period_end
    FROM public.cutoff_date_f AS cutoff
    INNER JOIN public.bank_accounts_d AS account ON account.account_id = cutoff.account_id
    WHERE
        cutoff.cutoff_id = p_cutoff_id
        AND cutoff.account_id = p_account_id
        AND cutoff.tenant_id = v_tenant
        AND cutoff.user_id = v_user
    FOR UPDATE OF cutoff;
    IF v_period_end IS NULL THEN
        RAISE EXCEPTION 'period not found' USING ERRCODE = 'P0002';
    END IF;
    IF NOT (p_as_of > v_period_end) THEN
        RAISE EXCEPTION 'The period is not open for upload yet' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1
        FROM public.statement_uploads_f AS upload
        WHERE
            upload.cutoff_id = p_cutoff_id
            AND upload.dataset = 'pdf'
    ) THEN
        RAISE EXCEPTION 'already uploaded' USING ERRCODE = '23505';
    END IF;

    BEGIN
        v_bytes := DECODE(p_base64, 'base64');
    EXCEPTION
        WHEN OTHERS THEN
            RAISE EXCEPTION 'The PDF payload is not valid base64' USING ERRCODE = '22P02';
    END;
    IF v_bytes IS NULL OR OCTET_LENGTH(v_bytes) = 0 OR OCTET_LENGTH(v_bytes) > 2000000 THEN
        RAISE EXCEPTION 'The PDF is empty or larger than 2 MB' USING ERRCODE = '22023';
    END IF;

    INSERT INTO public.statement_uploads_f (
        tenant_id,
        user_id,
        account_id,
        cutoff_id,
        dataset,
        original_filename,
        content_sha256,
        byte_size,
        row_count,
        storage_mode,
        pdf_bytes
    )
    VALUES (
        v_tenant,
        v_user,
        p_account_id,
        p_cutoff_id,
        'pdf',
        v_filename,
        ENCODE(PUBLIC.DIGEST(v_bytes, 'sha256'), 'hex'),
        OCTET_LENGTH(v_bytes),
        0,
        'database',
        v_bytes
    )
    RETURNING upload_id
    INTO v_upload_id;

    RETURN JSONB_BUILD_OBJECT(
        'upload_id', v_upload_id,
        'file_id', v_upload_id,
        'row_count', 0,
        'dataset', 'pdf',
        'curated_csv_backup', v_curated,
        'tenant_id', v_tenant,
        'file_suffix', 'pdf'
    );
END
$fn$;

CREATE OR REPLACE FUNCTION public.delete_statement_upload(p_upload_id UUID)
RETURNS VOID
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

    IF NOT EXISTS (
        SELECT 1
        FROM public.statement_uploads_f AS upload
        WHERE
            upload.upload_id = p_upload_id
            AND upload.tenant_id = v_tenant
            AND upload.user_id = v_user
    ) THEN
        RAISE EXCEPTION 'file not found' USING ERRCODE = 'P0002';
    END IF;

    INSERT INTO public.upload_delete_guard (upload_id)
    VALUES (p_upload_id);

    DELETE FROM public.master_debit_closed_f
    WHERE file_id = p_upload_id;
    DELETE FROM public.master_credit_closed_f
    WHERE file_id = p_upload_id;
    DELETE FROM public.credit_plan_closed_f
    WHERE file_id = p_upload_id;
    DELETE FROM public.upload_delete_guard
    WHERE upload_id = p_upload_id;
    DELETE FROM public.statement_uploads_f
    WHERE upload_id = p_upload_id;
END
$fn$;

CREATE OR REPLACE FUNCTION public.attach_curated_backup(p_upload_id UUID, p_key TEXT)
RETURNS VOID
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
    IF p_key IS NULL OR p_key NOT LIKE 'curated/%' THEN
        RAISE EXCEPTION 'curated key must stay under the curated prefix' USING ERRCODE = '22023';
    END IF;
    UPDATE public.statement_uploads_f
    SET
        curated_s3_key = p_key,
        storage_mode = 'curated'
    WHERE
        upload_id = p_upload_id
        AND tenant_id = v_tenant
        AND user_id = v_user;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'file not found' USING ERRCODE = 'P0002';
    END IF;
END
$fn$;

CREATE OR REPLACE FUNCTION public.truncate_open_movements()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
    DELETE FROM public.open_debit_f;
    DELETE FROM public.open_credit_f;
END
$fn$;

CREATE OR REPLACE FUNCTION public.reload_open_movements(p_payload JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_row JSONB;
    v_account_id INTEGER;
    v_account_number TEXT;
    v_bank_name TEXT;
    v_kind TEXT;
    v_date DATE;
    v_concept TEXT;
    v_sk TEXT;
    v_cargos NUMERIC(18, 2);
    v_abonos NUMERIC(18, 2);
    v_saldos NUMERIC(18, 2);
    v_abono NUMERIC(18, 2);
    v_cargo NUMERIC(18, 2);
    v_tarjeta TEXT;
    v_amount NUMERIC(18, 2);
    v_debit INTEGER := 0;
    v_credit INTEGER := 0;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    DELETE FROM public.open_debit_f
    WHERE
        tenant_id = v_tenant
        AND user_id = v_user;
    DELETE FROM public.open_credit_f
    WHERE
        tenant_id = v_tenant
        AND user_id = v_user;

    DROP TABLE IF EXISTS pg_temp.open_catch;
    CREATE TEMP TABLE open_catch (
        kind TEXT NOT NULL,
        account_id INTEGER NOT NULL,
        account_number TEXT NOT NULL,
        bank_name TEXT NOT NULL,
        txn_date DATE NOT NULL,
        concept TEXT NOT NULL,
        concept_sk TEXT NOT NULL,
        cargos NUMERIC(18, 2),
        abonos NUMERIC(18, 2),
        saldos NUMERIC(18, 2),
        abono NUMERIC(18, 2),
        cargo NUMERIC(18, 2),
        tarjeta TEXT,
        amount NUMERIC(18, 2) NOT NULL,
        occurrence INTEGER,
        row_hash TEXT,
        record_no INTEGER NOT NULL
    ) ON COMMIT DROP;

    FOR v_row IN
        SELECT incoming.value
        FROM JSONB_ARRAY_ELEMENTS(COALESCE(p_payload -> 'debit', '[]'::JSONB)) AS incoming (value)
    LOOP
        v_debit := v_debit + 1;
        SELECT account.account_id, account.account_number, bank.bank_name, kind.ledger_kind
        INTO v_account_id, v_account_number, v_bank_name, v_kind
        FROM public.bank_accounts_d AS account
        INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
        INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
        WHERE
            account.tenant_id = v_tenant
            AND account.user_id = v_user
            AND account.account_number = v_row ->> 'account_number';
        IF v_account_id IS NULL OR v_kind <> 'debit' THEN
            RAISE EXCEPTION 'open debit row does not match an open debit account' USING ERRCODE = 'P0002';
        END IF;
        v_date := (v_row ->> 'txn_date')::DATE;
        v_concept := v_row ->> 'concept';
        v_sk := public.concept_sk(v_concept);
        v_cargos := ROUND((v_row ->> 'cargos')::NUMERIC, 2);
        v_abonos := ROUND((v_row ->> 'abonos')::NUMERIC, 2);
        v_saldos := ROUND((v_row ->> 'saldos')::NUMERIC, 2);
        v_amount := v_cargos + v_abonos;
        INSERT INTO pg_temp.open_catch (
            kind, account_id, account_number, bank_name, txn_date, concept, concept_sk,
            cargos, abonos, saldos, amount, record_no
        )
        VALUES (
            'debit', v_account_id, v_account_number, v_bank_name, v_date, v_concept, v_sk,
            v_cargos, v_abonos, v_saldos, v_amount, v_debit
        );
    END LOOP;

    FOR v_row IN
        SELECT incoming.value
        FROM JSONB_ARRAY_ELEMENTS(COALESCE(p_payload -> 'credit', '[]'::JSONB)) AS incoming (value)
    LOOP
        v_credit := v_credit + 1;
        SELECT account.account_id, account.account_number, bank.bank_name, kind.ledger_kind
        INTO v_account_id, v_account_number, v_bank_name, v_kind
        FROM public.bank_accounts_d AS account
        INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
        INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
        WHERE
            account.tenant_id = v_tenant
            AND account.user_id = v_user
            AND account.account_number = v_row ->> 'account_number';
        IF v_account_id IS NULL OR v_kind <> 'credit' THEN
            RAISE EXCEPTION 'open credit row does not match an open credit account' USING ERRCODE = 'P0002';
        END IF;
        v_date := (v_row ->> 'txn_date')::DATE;
        v_concept := v_row ->> 'concept';
        v_sk := public.concept_sk(v_concept);
        v_abono := ROUND((v_row ->> 'abono')::NUMERIC, 2);
        v_cargo := ROUND((v_row ->> 'cargo')::NUMERIC, 2);
        v_tarjeta := COALESCE(v_row ->> 'tarjeta', '');
        v_amount := v_cargo - v_abono;
        INSERT INTO pg_temp.open_catch (
            kind, account_id, account_number, bank_name, txn_date, concept, concept_sk,
            abono, cargo, tarjeta, amount, record_no
        )
        VALUES (
            'credit', v_account_id, v_account_number, v_bank_name, v_date, v_concept, v_sk,
            v_abono, v_cargo, v_tarjeta, v_amount, v_credit
        );
    END LOOP;

    UPDATE pg_temp.open_catch AS caught
    SET
        occurrence = numbered.occurrence::INTEGER,
        row_hash = public.movement_row_hash(
            caught.txn_date,
            caught.account_number,
            caught.amount,
            caught.concept_sk,
            numbered.occurrence::INTEGER
        )
    FROM (
        SELECT
            catch_row.record_no,
            catch_row.kind,
            ROW_NUMBER() OVER (
                PARTITION BY catch_row.account_id, catch_row.txn_date, catch_row.amount, catch_row.concept_sk
                ORDER BY catch_row.record_no
            ) AS occurrence
        FROM pg_temp.open_catch AS catch_row
    ) AS numbered
    WHERE
        numbered.record_no = caught.record_no
        AND numbered.kind = caught.kind;

    INSERT INTO public.open_debit_f (
        tenant_id, user_id, account_id, account_number, bank_name, file_name,
        txn_date, concept, concept_sk, cargos, abonos, saldos, amount, occurrence, row_hash
    )
    SELECT
        v_tenant, v_user, caught.account_id, caught.account_number, caught.bank_name, 'open reload',
        caught.txn_date, caught.concept, caught.concept_sk, caught.cargos, caught.abonos, caught.saldos,
        caught.amount, caught.occurrence, caught.row_hash
    FROM pg_temp.open_catch AS caught
    WHERE caught.kind = 'debit';

    INSERT INTO public.open_credit_f (
        tenant_id, user_id, account_id, account_number, bank_name, file_name,
        txn_date, concept, concept_sk, abono, cargo, tarjeta, amount, occurrence, row_hash
    )
    SELECT
        v_tenant, v_user, caught.account_id, caught.account_number, caught.bank_name, 'open reload',
        caught.txn_date, caught.concept, caught.concept_sk, caught.abono, caught.cargo, caught.tarjeta,
        caught.amount, caught.occurrence, caught.row_hash
    FROM pg_temp.open_catch AS caught
    WHERE caught.kind = 'credit';

    INSERT INTO public.movement_dimensions_d (tenant_id, row_hash, user_id, account_id)
    SELECT v_tenant, caught.row_hash, v_user, caught.account_id
    FROM pg_temp.open_catch AS caught
    ON CONFLICT (tenant_id, row_hash) DO NOTHING;

    RETURN JSONB_BUILD_OBJECT('debit_rows', v_debit, 'credit_rows', v_credit);
END
$fn$;

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
        ORDER BY account.account_number
    LOOP
        PERFORM public.refresh_statement_periods(v_account.account_id, p_as_of);
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
                    'statement_filename', statement_file.original_filename,
                    'statement_row_count', statement_file.row_count,
                    'installment_upload_id', installment_file.upload_id,
                    'installment_filename', installment_file.original_filename,
                    'installment_row_count', installment_file.row_count,
                    'pdf_upload_id', pdf_file.upload_id,
                    'pdf_filename', pdf_file.original_filename,
                    'show_statement_slot',
                    statement_file.upload_id IS NULL AND p_as_of > cutoff.period_end,
                    'show_installment_slot',
                    v_account.allows_cutoff
                    AND installment_file.upload_id IS NULL
                    AND p_as_of > cutoff.period_end,
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
            WHERE LOWER(bank.bank_name) = 'banorte'
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

DROP FUNCTION IF EXISTS public.refresh_cutoff_dates(UUID, UUID, DATE);
DROP FUNCTION IF EXISTS public.access_window_months(DATE);
DROP FUNCTION IF EXISTS public.show_csv_drop_zone(DATE, DATE, BOOLEAN);
DROP FUNCTION IF EXISTS public.period_cutoff_date(BOOLEAN, INTEGER, INTEGER, INTEGER);
DROP FUNCTION IF EXISTS public.canonical_header(TEXT);
DROP FUNCTION IF EXISTS public.reject_master_row_delete();

ALTER TABLE public.bank_accounts_d ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.cutoff_date_f ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.statement_uploads_f ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.master_debit_closed_f ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.master_credit_closed_f ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.credit_plan_closed_f ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.open_debit_f ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.open_credit_f ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.movement_dimensions_d ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenants_d ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.tenant_users ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.upload_delete_guard ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS bank_accounts_d_tenant ON public.bank_accounts_d;
CREATE POLICY bank_accounts_d_tenant ON public.bank_accounts_d
FOR ALL
TO strm_app
USING (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
)
WITH CHECK (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
);

DROP POLICY IF EXISTS cutoff_date_f_tenant ON public.cutoff_date_f;
CREATE POLICY cutoff_date_f_tenant ON public.cutoff_date_f
FOR ALL
TO strm_app
USING (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
)
WITH CHECK (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
);

DROP POLICY IF EXISTS statement_uploads_f_tenant ON public.statement_uploads_f;
CREATE POLICY statement_uploads_f_tenant ON public.statement_uploads_f
FOR ALL
TO strm_app
USING (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
)
WITH CHECK (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
);

DROP POLICY IF EXISTS master_debit_closed_f_tenant ON public.master_debit_closed_f;
CREATE POLICY master_debit_closed_f_tenant ON public.master_debit_closed_f
FOR ALL
TO strm_app
USING (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
)
WITH CHECK (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
);

DROP POLICY IF EXISTS master_credit_closed_f_tenant ON public.master_credit_closed_f;
CREATE POLICY master_credit_closed_f_tenant ON public.master_credit_closed_f
FOR ALL
TO strm_app
USING (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
)
WITH CHECK (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
);

DROP POLICY IF EXISTS credit_plan_closed_f_tenant ON public.credit_plan_closed_f;
CREATE POLICY credit_plan_closed_f_tenant ON public.credit_plan_closed_f
FOR ALL
TO strm_app
USING (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
)
WITH CHECK (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
);

DROP POLICY IF EXISTS open_debit_f_tenant ON public.open_debit_f;
CREATE POLICY open_debit_f_tenant ON public.open_debit_f
FOR ALL
TO strm_app
USING (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
)
WITH CHECK (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
);

DROP POLICY IF EXISTS open_credit_f_tenant ON public.open_credit_f;
CREATE POLICY open_credit_f_tenant ON public.open_credit_f
FOR ALL
TO strm_app
USING (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
)
WITH CHECK (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
);

DROP POLICY IF EXISTS movement_dimensions_d_tenant ON public.movement_dimensions_d;
CREATE POLICY movement_dimensions_d_tenant ON public.movement_dimensions_d
FOR ALL
TO strm_app
USING (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
)
WITH CHECK (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
);

DROP POLICY IF EXISTS tenants_d_self ON public.tenants_d;
CREATE POLICY tenants_d_self ON public.tenants_d
FOR SELECT
TO strm_app
USING (tenant_id = public.session_tenant());

DROP POLICY IF EXISTS tenant_users_self ON public.tenant_users;
CREATE POLICY tenant_users_self ON public.tenant_users
FOR SELECT
TO strm_app
USING (
    tenant_id = public.session_tenant()
    AND user_id = public.session_user()
);

GRANT USAGE ON SCHEMA public TO strm_app;
GRANT SELECT ON
public.plans_d,
public.banks_d,
public.account_types_d,
public.bank_templates_f
TO strm_app;
GRANT SELECT, INSERT, UPDATE ON public.bank_accounts_d TO strm_app;
GRANT SELECT ON
public.cutoff_date_f,
public.statement_uploads_f,
public.master_debit_closed_f,
public.master_credit_closed_f,
public.credit_plan_closed_f,
public.open_debit_f,
public.open_credit_f,
public.movement_dimensions_d,
public.tenants_d,
public.tenant_users
TO strm_app;
GRANT USAGE, SELECT ON SEQUENCE public.bank_accounts_d_account_id_seq TO strm_app;
GRANT USAGE, SELECT ON SEQUENCE public.cutoff_date_f_cutoff_id_seq TO strm_app;

REVOKE ALL ON FUNCTION public.ensure_personal_tenant(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_bank_account(INTEGER, INTEGER, TEXT, TEXT, INTEGER, INTEGER, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.add_earlier_period(INTEGER, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.remove_statement_period(INTEGER, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ingest_statement_csv(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ingest_period_pdf(INTEGER, INTEGER, TEXT, TEXT, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_statement_upload(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.attach_curated_backup(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.statement_home(DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.refresh_statement_periods(INTEGER, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reload_open_movements(JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.truncate_open_movements() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_closed_row_delete() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reject_closed_row_update() FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.create_bank_account(INTEGER, INTEGER, TEXT, TEXT, INTEGER, INTEGER, DATE) TO strm_app;
GRANT EXECUTE ON FUNCTION public.add_earlier_period(INTEGER, DATE) TO strm_app;
GRANT EXECUTE ON FUNCTION public.remove_statement_period(INTEGER, DATE) TO strm_app;
GRANT EXECUTE ON FUNCTION public.ingest_statement_csv(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE) TO strm_app;
GRANT EXECUTE ON FUNCTION public.ingest_period_pdf(INTEGER, INTEGER, TEXT, TEXT, DATE) TO strm_app;
GRANT EXECUTE ON FUNCTION public.delete_statement_upload(UUID) TO strm_app;
GRANT EXECUTE ON FUNCTION public.attach_curated_backup(UUID, TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.statement_home(DATE) TO strm_app;
GRANT EXECUTE ON FUNCTION public.reload_open_movements(JSONB) TO strm_app;
GRANT EXECUTE ON FUNCTION public.session_tenant() TO strm_app;
GRANT EXECUTE ON FUNCTION public.session_user() TO strm_app;
GRANT EXECUTE ON FUNCTION public.require_session() TO strm_app;
