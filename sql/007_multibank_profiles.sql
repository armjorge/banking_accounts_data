-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- Multi-bank profile registry and statement ingestion on top of 006_statement_flow.sql.
-- Safe to run more than once. Does not drop bank accounts or uploaded rows.

-- 1. Align banks sequence and ensure HSBC and BBVA exist in banks catalog
SELECT setval(
    pg_get_serial_sequence('public.banks_d', 'bank_id'),
    COALESCE((SELECT MAX(bank_id) FROM public.banks_d), 1),
    (SELECT EXISTS (SELECT 1 FROM public.banks_d))
);

INSERT INTO public.banks_d (bank_name)
SELECT seed.bank_name
FROM (VALUES ('HSBC'), ('BBVA')) AS seed (bank_name)
WHERE NOT EXISTS (
    SELECT 1
    FROM public.banks_d AS existing
    WHERE LOWER(existing.bank_name) = LOWER(seed.bank_name)
);

-- 2. File profile registry
CREATE TABLE IF NOT EXISTS public.file_profiles_d (
    profile_code TEXT NOT NULL,
    bank_name TEXT NOT NULL,
    dataset TEXT NOT NULL,
    has_header BOOLEAN NOT NULL DEFAULT TRUE,
    header_signature TEXT [],
    column_count INTEGER NOT NULL,
    column_map JSONB NOT NULL,
    amount_rule TEXT NOT NULL,
    date_format TEXT NOT NULL DEFAULT 'DD/MM/YYYY',
    decimal_sep TEXT NOT NULL DEFAULT '.',
    thousands_sep TEXT NOT NULL DEFAULT ',',
    active BOOLEAN NOT NULL DEFAULT TRUE,
    CONSTRAINT file_profiles_d_pkey PRIMARY KEY (profile_code),
    CONSTRAINT file_profiles_d_dataset_check CHECK (dataset IN ('debit', 'credit_monthly', 'credit_plan')),
    CONSTRAINT file_profiles_d_amount_rule_check CHECK (
        amount_rule IN ('split_signed', 'split_positive_credit', 'single_signed', 'installment')
    )
);

CREATE INDEX IF NOT EXISTS file_profiles_d_bank_idx
ON public.file_profiles_d (LOWER(bank_name), active);

-- 3. Seed profiles
INSERT INTO public.file_profiles_d (
    profile_code,
    bank_name,
    dataset,
    has_header,
    header_signature,
    column_count,
    column_map,
    amount_rule,
    date_format,
    decimal_sep,
    thousands_sep,
    active
)
VALUES
(
    'banorte_debit_v1',
    'Banorte',
    'debit',
    TRUE,
    ARRAY['abonos', 'cargos', 'concepto', 'fecha', 'saldos'],
    5,
    '{"txn_date": "fecha", "concept": "concepto", "cargos": "cargos", "abonos": "abonos", "saldos": "saldos"}'::JSONB,
    'split_signed',
    'DD/MM/YYYY',
    '.',
    ',',
    TRUE
),
(
    'banorte_credit_monthly_v1',
    'Banorte',
    'credit_monthly',
    TRUE,
    ARRAY['abono', 'cargo', 'concepto', 'fecha', 'tarjeta'],
    5,
    '{"txn_date": "fecha", "concept": "concepto", "abono": "abono", "cargo": "cargo", "tarjeta": "tarjeta"}'::JSONB,
    'split_positive_credit',
    'DD/MM/YYYY',
    '.',
    ',',
    TRUE
),
(
    'banorte_credit_plan_v1',
    'Banorte',
    'credit_plan',
    TRUE,
    ARRAY['concepto', 'fecha de operacion', 'importe inicial', 'importe pendiente', 'mensualidad', 'pagos pendientes', 'tasa anual'],
    7,
    '{"txn_date": "fecha de operacion", "concept": "concepto", "tasa_anual": "tasa anual", "importe_inicial": "importe inicial", "importe_pendiente": "importe pendiente", "pagos_pendientes": "pagos pendientes", "mensualidad": "mensualidad"}'::JSONB,
    'installment',
    'DD/MM/YYYY',
    '.',
    ',',
    TRUE
),
(
    'hsbc_debit_v1',
    'HSBC',
    'debit',
    FALSE,
    NULL,
    3,
    '{"txn_date": 0, "concept": 1, "amount": 2}'::JSONB,
    'single_signed',
    'DD/MM/YYYY',
    '.',
    ',',
    TRUE
)
ON CONFLICT (profile_code) DO UPDATE
SET
    bank_name = EXCLUDED.bank_name,
    dataset = EXCLUDED.dataset,
    has_header = EXCLUDED.has_header,
    header_signature = EXCLUDED.header_signature,
    column_count = EXCLUDED.column_count,
    column_map = EXCLUDED.column_map,
    amount_rule = EXCLUDED.amount_rule,
    date_format = EXCLUDED.date_format,
    decimal_sep = EXCLUDED.decimal_sep,
    thousands_sep = EXCLUDED.thousands_sep,
    active = EXCLUDED.active;

-- 4. Schema relaxations and new columns
ALTER TABLE public.master_debit_closed_f
ALTER COLUMN saldos DROP NOT NULL;

ALTER TABLE public.open_debit_f
ALTER COLUMN saldos DROP NOT NULL;

ALTER TABLE public.master_debit_closed_f
ADD COLUMN IF NOT EXISTS source_profile TEXT;

ALTER TABLE public.master_credit_closed_f
ADD COLUMN IF NOT EXISTS source_profile TEXT;

ALTER TABLE public.credit_plan_closed_f
ADD COLUMN IF NOT EXISTS source_profile TEXT;

ALTER TABLE public.credit_plan_closed_f
ADD COLUMN IF NOT EXISTS pagos_hechos INTEGER;

ALTER TABLE public.credit_plan_closed_f
ADD COLUMN IF NOT EXISTS pagos_totales INTEGER;

ALTER TABLE public.statement_uploads_f
ADD COLUMN IF NOT EXISTS encoding TEXT;

ALTER TABLE public.statement_uploads_f
ADD COLUMN IF NOT EXISTS delimiter TEXT;

ALTER TABLE public.statement_uploads_f
ADD COLUMN IF NOT EXISTS source_profile TEXT;

-- 5. Profile detection functions
CREATE OR REPLACE FUNCTION public.detect_profile(
    p_bank_name TEXT,
    p_headers TEXT [],
    p_first_row TEXT []
) RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_sig TEXT [];
    v_profile TEXT;
    v_date_probe TEXT;
BEGIN
    IF p_headers IS NOT NULL AND CARDINALITY(p_headers) > 0 THEN
        SELECT ARRAY_AGG(public.normalize_header(col) ORDER BY public.normalize_header(col))
        INTO v_sig
        FROM UNNEST(p_headers) AS col;

        SELECT fp.profile_code
        INTO v_profile
        FROM public.file_profiles_d AS fp
        WHERE
            LOWER(fp.bank_name) = LOWER(p_bank_name)
            AND fp.active IS TRUE
            AND fp.has_header IS TRUE
            AND fp.header_signature = v_sig;

        IF v_profile IS NOT NULL THEN
            RETURN v_profile;
        END IF;
    END IF;

    IF p_first_row IS NOT NULL AND CARDINALITY(p_first_row) > 0 THEN
        v_date_probe := BTRIM(p_first_row[1]);
        IF v_date_probe ~ '^\d{2}/\d{2}/\d{4}$' OR v_date_probe ~ '^\d{4}-\d{2}-\d{2}$' THEN
            SELECT fp.profile_code
            INTO v_profile
            FROM public.file_profiles_d AS fp
            WHERE
                LOWER(fp.bank_name) = LOWER(p_bank_name)
                AND fp.active IS TRUE
                AND fp.has_header IS FALSE
                AND fp.column_count = CARDINALITY(p_first_row);

            IF v_profile IS NOT NULL THEN
                RETURN v_profile;
            END IF;
        END IF;
    END IF;

    RETURN NULL;
END
$fn$;

CREATE OR REPLACE FUNCTION public.detect_any_profile(
    p_headers TEXT [],
    p_first_row TEXT []
) RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_sig TEXT [];
    v_profile TEXT;
    v_date_probe TEXT;
BEGIN
    IF p_headers IS NOT NULL AND CARDINALITY(p_headers) > 0 THEN
        SELECT ARRAY_AGG(public.normalize_header(col) ORDER BY public.normalize_header(col))
        INTO v_sig
        FROM UNNEST(p_headers) AS col;

        SELECT fp.profile_code
        INTO v_profile
        FROM public.file_profiles_d AS fp
        WHERE
            fp.active IS TRUE
            AND fp.has_header IS TRUE
            AND fp.header_signature = v_sig
        LIMIT 1;

        IF v_profile IS NOT NULL THEN
            RETURN v_profile;
        END IF;
    END IF;

    IF p_first_row IS NOT NULL AND CARDINALITY(p_first_row) > 0 THEN
        v_date_probe := BTRIM(p_first_row[1]);
        IF v_date_probe ~ '^\d{2}/\d{2}/\d{4}$' OR v_date_probe ~ '^\d{4}-\d{2}-\d{2}$' THEN
            SELECT fp.profile_code
            INTO v_profile
            FROM public.file_profiles_d AS fp
            WHERE
                fp.active IS TRUE
                AND fp.has_header IS FALSE
                AND fp.column_count = CARDINALITY(p_first_row)
            LIMIT 1;

            IF v_profile IS NOT NULL THEN
                RETURN v_profile;
            END IF;
        END IF;
    END IF;

    RETURN NULL;
END
$fn$;

CREATE OR REPLACE FUNCTION public.banorte_profile(p_headers TEXT [])
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_dataset TEXT;
BEGIN
    SELECT dataset
    INTO v_dataset
    FROM public.file_profiles_d
    WHERE profile_code = public.detect_profile('Banorte', p_headers, NULL);
    RETURN v_dataset;
END
$fn$;

-- 6. Enforce bank account limits and profile support
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
    ELSE
        IF NEW.account_cutoff_day IS NOT NULL OR NEW.credit_days IS NOT NULL THEN
            RAISE EXCEPTION 'Debit accounts do not have a cutoff day or payment window'
                USING ERRCODE = '23514';
        END IF;
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

-- 7. CSV Parser supporting optional delimiter
CREATE OR REPLACE FUNCTION public.parse_csv(p_csv TEXT, p_delim TEXT DEFAULT ',')
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
    v_delimiter TEXT := COALESCE(NULLIF(p_delim, ''), ',');
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
        IF v_char = v_delimiter THEN
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
    IF v_field <> '' OR CARDINALITY(v_fields) > 0 THEN
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

-- 8. Updated Statement ingestion function dispatching on profile
DROP FUNCTION IF EXISTS public.ingest_statement_csv(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE);

CREATE OR REPLACE FUNCTION public.ingest_statement_csv(
    p_account_id INTEGER,
    p_cutoff_id INTEGER,
    p_slot TEXT,
    p_filename TEXT,
    p_csv TEXT,
    p_as_of DATE,
    p_encoding TEXT DEFAULT NULL,
    p_delimiter TEXT DEFAULT NULL
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
    v_other_profile TEXT;
    v_prof_dataset TEXT;
    v_prof_col_count INTEGER;
    v_col_map JSONB;
    v_amount_rule TEXT;
    v_has_header BOOLEAN;
    v_delim TEXT := COALESCE(NULLIF(p_delimiter, ''), ',');
    v_filename TEXT := LEFT(BTRIM(COALESCE(p_filename, '')), 200);
    v_csv TEXT;
    v_first_row TEXT [];
    v_first_line TEXT;
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
    v_pagos_hechos INTEGER;
    v_pagos_totales INTEGER;
    v_mensualidad NUMERIC(18, 2);
    v_raw_amt NUMERIC(18, 2);
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

    -- Delimiter auto-detection if not specified
    IF p_delimiter IS NULL OR p_delimiter = '' THEN
        v_first_line := SPLIT_PART(SPLIT_PART(v_csv, E'\r\n', 1), E'\n', 1);
        IF (CARDINALITY(STRING_TO_ARRAY(v_first_line, ';')) - 1) > (CARDINALITY(STRING_TO_ARRAY(v_first_line, ',')) - 1)
           AND (CARDINALITY(STRING_TO_ARRAY(v_first_line, ';')) - 1) > (CARDINALITY(STRING_TO_ARRAY(v_first_line, E'\t')) - 1) THEN
            v_delim := ';';
        ELSIF (CARDINALITY(STRING_TO_ARRAY(v_first_line, E'\t')) - 1) > (CARDINALITY(STRING_TO_ARRAY(v_first_line, ',')) - 1)
              AND (CARDINALITY(STRING_TO_ARRAY(v_first_line, E'\t')) - 1) > (CARDINALITY(STRING_TO_ARRAY(v_first_line, ';')) - 1) THEN
            v_delim := E'\t';
        ELSE
            v_delim := ',';
        END IF;
    END IF;

    SELECT parsed.fields
    INTO v_first_row
    FROM public.parse_csv(v_csv, v_delim) AS parsed
    WHERE parsed.record_no = 1;

    IF v_first_row IS NULL THEN
        RAISE EXCEPTION 'The CSV has no movements' USING ERRCODE = '22P02';
    END IF;

    -- Profile detection for this bank: first try header, then headerless
    v_profile := public.detect_profile(v_bank_name, v_first_row, NULL);
    IF v_profile IS NOT NULL THEN
        v_has_header := TRUE;
    ELSE
        v_profile := public.detect_profile(v_bank_name, NULL, v_first_row);
        IF v_profile IS NOT NULL THEN
            v_has_header := FALSE;
        ELSE
            v_other_profile := public.detect_any_profile(v_first_row, v_first_row);
            IF v_other_profile IS NOT NULL THEN
                RAISE EXCEPTION 'These headers belong to a different file than this slot accepts'
                    USING ERRCODE = '22P02';
            ELSE
                RAISE EXCEPTION 'These headers do not match a supported statement profile'
                    USING ERRCODE = '22P02';
            END IF;
        END IF;
    END IF;

    SELECT
        fp.dataset,
        fp.column_count,
        fp.column_map,
        fp.amount_rule
    INTO
        v_prof_dataset,
        v_prof_col_count,
        v_col_map,
        v_amount_rule
    FROM public.file_profiles_d AS fp
    WHERE fp.profile_code = v_profile;

    IF v_prof_dataset IS DISTINCT FROM v_dataset THEN
        RAISE EXCEPTION 'These headers belong to a different file than this slot accepts'
            USING ERRCODE = '22P02';
    END IF;

    IF v_has_header THEN
        FOR v_position IN 1..CARDINALITY(v_first_row) LOOP
            v_index := v_index || JSONB_BUILD_OBJECT(
                public.normalize_header(v_first_row[v_position]),
                v_position
            );
        END LOOP;
    END IF;

    FOR v_record IN
        SELECT parsed.record_no, parsed.fields
        FROM public.parse_csv(v_csv, v_delim) AS parsed
        WHERE parsed.record_no > (CASE WHEN v_has_header THEN 1 ELSE 0 END)
    LOOP
        v_fields := v_record.fields;
        IF CARDINALITY(v_fields) = 1 AND BTRIM(v_fields[1]) = '' THEN
            CONTINUE;
        END IF;
        IF CARDINALITY(v_fields) <> v_prof_col_count THEN
            RAISE EXCEPTION 'Row % does not match the header', v_record.record_no USING ERRCODE = '22P02';
        END IF;

        IF v_has_header THEN
            IF v_dataset = 'credit_plan' THEN
                v_date_text := BTRIM(v_fields[(v_index ->> 'fecha de operacion')::INTEGER]);
            ELSE
                v_date_text := BTRIM(v_fields[(v_index ->> 'fecha')::INTEGER]);
            END IF;
            v_concept := v_fields[(v_index ->> 'concepto')::INTEGER];
        ELSE
            v_date_text := BTRIM(v_fields[(v_col_map ->> 'txn_date')::INTEGER + 1]);
            v_concept := v_fields[(v_col_map ->> 'concept')::INTEGER + 1];
        END IF;

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
        v_pagos_hechos := NULL;
        v_pagos_totales := NULL;
        v_mensualidad := NULL;

        IF v_amount_rule = 'split_signed' THEN
            v_cargos := ROUND(public.parse_amount(v_fields[(v_index ->> 'cargos')::INTEGER]), 2);
            v_abonos := ROUND(public.parse_amount(v_fields[(v_index ->> 'abonos')::INTEGER]), 2);
            v_saldos := ROUND(public.parse_amount(v_fields[(v_index ->> 'saldos')::INTEGER]), 2);
            IF v_cargos IS NULL OR v_abonos IS NULL OR v_saldos IS NULL THEN
                RAISE EXCEPTION 'Row % is missing a debit amount', v_record.record_no USING ERRCODE = '22P02';
            END IF;
            v_amount := v_cargos + v_abonos;
        ELSIF v_amount_rule = 'split_positive_credit' THEN
            v_abono := ROUND(public.parse_amount(v_fields[(v_index ->> 'abono')::INTEGER]), 2);
            v_cargo := ROUND(public.parse_amount(v_fields[(v_index ->> 'cargo')::INTEGER]), 2);
            v_tarjeta := COALESCE(v_fields[(v_index ->> 'tarjeta')::INTEGER], '');
            IF v_abono IS NULL OR v_cargo IS NULL THEN
                RAISE EXCEPTION 'Row % is missing a credit amount', v_record.record_no USING ERRCODE = '22P02';
            END IF;
            v_amount := v_cargo - v_abono;
            v_cargos := -v_cargo;
            v_abonos := v_abono;
            v_saldos := NULL;
        ELSIF v_amount_rule = 'single_signed' THEN
            v_raw_amt := ROUND(public.parse_amount(v_fields[(v_col_map ->> 'amount')::INTEGER + 1]), 2);
            IF v_raw_amt IS NULL THEN
                RAISE EXCEPTION 'Row % is missing an amount', v_record.record_no USING ERRCODE = '22P02';
            END IF;
            IF v_raw_amt < 0 THEN
                v_cargos := v_raw_amt;
                v_abonos := 0.00;
            ELSE
                v_cargos := 0.00;
                v_abonos := v_raw_amt;
            END IF;
            v_saldos := NULL;
            v_amount := v_cargos + v_abonos;
        ELSIF v_amount_rule = 'installment' THEN
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
            v_pagos_hechos := NULLIF(REGEXP_REPLACE(v_pagos, '^\s*(\d+)\s*/\s*(\d+)\s*$', '\1'), v_pagos)::INTEGER;
            v_pagos_totales := NULLIF(REGEXP_REPLACE(v_pagos, '^\s*(\d+)\s*/\s*(\d+)\s*$', '\2'), v_pagos)::INTEGER;
            v_amount := v_mensualidad;
        ELSE
            RAISE EXCEPTION 'Unknown amount rule %', v_amount_rule USING ERRCODE = '22P02';
        END IF;

        v_first_row := ARRAY_APPEND(
            v_first_row,
            JSONB_BUILD_OBJECT(
                'record_no', v_record.record_no,
                'txn_date', v_date,
                'concept', v_concept,
                'concept_sk', v_sk,
                'cargos', v_cargos,
                'abonos', v_abonos,
                'saldos', v_saldos,
                'abono', v_abono,
                'cargo', v_cargo,
                'tarjeta', v_tarjeta,
                'tasa_anual', v_tasa,
                'importe_inicial', v_inicial,
                'importe_pendiente', v_pendiente,
                'pagos_pendientes', v_pagos,
                'pagos_hechos', v_pagos_hechos,
                'pagos_totales', v_pagos_totales,
                'mensualidad', v_mensualidad,
                'amount', v_amount
            )::TEXT
        );
    END LOOP;

    -- Note: v_first_row was reused as row collector after detection
    v_rows := CARDINALITY(v_first_row);
    IF v_rows = 0 THEN
        RAISE EXCEPTION 'The CSV has no movements' USING ERRCODE = '22P02';
    END IF;

    IF v_dataset = 'debit' THEN
        IF EXISTS (
            WITH raw_rows AS (
                SELECT
                    (elem::JSONB ->> 'record_no')::INTEGER AS record_no,
                    (elem::JSONB ->> 'txn_date')::DATE AS txn_date,
                    (elem::JSONB ->> 'concept_sk') AS concept_sk,
                    (elem::JSONB ->> 'amount')::NUMERIC(18, 2) AS amount
                FROM UNNEST(v_first_row) AS elem
            ),
            caught AS (
                SELECT
                    r.record_no,
                    public.movement_row_hash(
                        r.txn_date,
                        v_account_number,
                        r.amount,
                        r.concept_sk,
                        (ROW_NUMBER() OVER (
                            PARTITION BY r.txn_date, r.amount, r.concept_sk
                            ORDER BY r.record_no
                        ))::INTEGER
                    ) AS row_hash
                FROM raw_rows AS r
            )
            SELECT 1
            FROM caught AS incoming
            INNER JOIN public.master_debit_closed_f AS existing
                ON existing.account_id = p_account_id
                AND existing.row_hash = incoming.row_hash
        ) THEN
            RAISE EXCEPTION 'already uploaded' USING ERRCODE = '23505';
        END IF;
    ELSIF v_dataset = 'credit_monthly' THEN
        IF EXISTS (
            WITH raw_rows AS (
                SELECT
                    (elem::JSONB ->> 'record_no')::INTEGER AS record_no,
                    (elem::JSONB ->> 'txn_date')::DATE AS txn_date,
                    (elem::JSONB ->> 'concept_sk') AS concept_sk,
                    (elem::JSONB ->> 'amount')::NUMERIC(18, 2) AS amount
                FROM UNNEST(v_first_row) AS elem
            ),
            caught AS (
                SELECT
                    r.record_no,
                    public.movement_row_hash(
                        r.txn_date,
                        v_account_number,
                        r.amount,
                        r.concept_sk,
                        (ROW_NUMBER() OVER (
                            PARTITION BY r.txn_date, r.amount, r.concept_sk
                            ORDER BY r.record_no
                        ))::INTEGER
                    ) AS row_hash
                FROM raw_rows AS r
            )
            SELECT 1
            FROM caught AS incoming
            INNER JOIN public.master_credit_closed_f AS existing
                ON existing.account_id = p_account_id
                AND existing.row_hash = incoming.row_hash
        ) THEN
            RAISE EXCEPTION 'already uploaded' USING ERRCODE = '23505';
        END IF;
    ELSE
        IF EXISTS (
            WITH raw_rows AS (
                SELECT
                    (elem::JSONB ->> 'record_no')::INTEGER AS record_no,
                    (elem::JSONB ->> 'txn_date')::DATE AS txn_date,
                    (elem::JSONB ->> 'concept_sk') AS concept_sk,
                    (elem::JSONB ->> 'amount')::NUMERIC(18, 2) AS amount
                FROM UNNEST(v_first_row) AS elem
            ),
            caught AS (
                SELECT
                    r.record_no,
                    public.movement_row_hash(
                        r.txn_date,
                        v_account_number,
                        r.amount,
                        r.concept_sk,
                        (ROW_NUMBER() OVER (
                            PARTITION BY r.txn_date, r.amount, r.concept_sk
                            ORDER BY r.record_no
                        ))::INTEGER
                    ) AS row_hash
                FROM raw_rows AS r
            )
            SELECT 1
            FROM caught AS incoming
            INNER JOIN public.credit_plan_closed_f AS existing
                ON existing.account_id = p_account_id
                AND existing.row_hash = incoming.row_hash
        ) THEN
            RAISE EXCEPTION 'already uploaded' USING ERRCODE = '23505';
        END IF;
    END IF;

    v_upload_id := GEN_RANDOM_UUID();

    INSERT INTO public.statement_uploads_f (
        upload_id,
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
        body_text,
        encoding,
        delimiter,
        source_profile
    )
    VALUES (
        v_upload_id,
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
        v_csv,
        COALESCE(p_encoding, 'utf-8'),
        v_delim,
        v_profile
    );

    IF v_dataset = 'debit' THEN
        WITH raw_rows AS (
            SELECT
                (elem::JSONB ->> 'record_no')::INTEGER AS record_no,
                (elem::JSONB ->> 'txn_date')::DATE AS txn_date,
                (elem::JSONB ->> 'concept') AS concept,
                (elem::JSONB ->> 'concept_sk') AS concept_sk,
                (elem::JSONB ->> 'cargos')::NUMERIC(18, 2) AS cargos,
                (elem::JSONB ->> 'abonos')::NUMERIC(18, 2) AS abonos,
                (elem::JSONB ->> 'saldos')::NUMERIC(18, 2) AS saldos,
                (elem::JSONB ->> 'amount')::NUMERIC(18, 2) AS amount
            FROM UNNEST(v_first_row) AS elem
        ),
        caught AS (
            SELECT
                r.record_no,
                r.txn_date,
                r.concept,
                r.concept_sk,
                r.cargos,
                r.abonos,
                r.saldos,
                r.amount,
                (ROW_NUMBER() OVER (
                    PARTITION BY r.txn_date, r.amount, r.concept_sk
                    ORDER BY r.record_no
                ))::INTEGER AS occurrence,
                public.movement_row_hash(
                    r.txn_date,
                    v_account_number,
                    r.amount,
                    r.concept_sk,
                    (ROW_NUMBER() OVER (
                        PARTITION BY r.txn_date, r.amount, r.concept_sk
                        ORDER BY r.record_no
                    ))::INTEGER
                ) AS row_hash
            FROM raw_rows AS r
        )
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
            row_hash,
            source_profile
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
            caught.row_hash,
            v_profile
        FROM caught;
    ELSIF v_dataset = 'credit_monthly' THEN
        WITH raw_rows AS (
            SELECT
                (elem::JSONB ->> 'record_no')::INTEGER AS record_no,
                (elem::JSONB ->> 'txn_date')::DATE AS txn_date,
                (elem::JSONB ->> 'concept') AS concept,
                (elem::JSONB ->> 'concept_sk') AS concept_sk,
                (elem::JSONB ->> 'abono')::NUMERIC(18, 2) AS abono,
                (elem::JSONB ->> 'cargo')::NUMERIC(18, 2) AS cargo,
                (elem::JSONB ->> 'tarjeta') AS tarjeta,
                (elem::JSONB ->> 'amount')::NUMERIC(18, 2) AS amount
            FROM UNNEST(v_first_row) AS elem
        ),
        caught AS (
            SELECT
                r.record_no,
                r.txn_date,
                r.concept,
                r.concept_sk,
                r.abono,
                r.cargo,
                r.tarjeta,
                r.amount,
                (ROW_NUMBER() OVER (
                    PARTITION BY r.txn_date, r.amount, r.concept_sk
                    ORDER BY r.record_no
                ))::INTEGER AS occurrence,
                public.movement_row_hash(
                    r.txn_date,
                    v_account_number,
                    r.amount,
                    r.concept_sk,
                    (ROW_NUMBER() OVER (
                        PARTITION BY r.txn_date, r.amount, r.concept_sk
                        ORDER BY r.record_no
                    ))::INTEGER
                ) AS row_hash
            FROM raw_rows AS r
        )
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
            row_hash,
            source_profile
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
            caught.row_hash,
            v_profile
        FROM caught;
    ELSE
        WITH raw_rows AS (
            SELECT
                (elem::JSONB ->> 'record_no')::INTEGER AS record_no,
                (elem::JSONB ->> 'txn_date')::DATE AS txn_date,
                (elem::JSONB ->> 'concept') AS concept,
                (elem::JSONB ->> 'concept_sk') AS concept_sk,
                (elem::JSONB ->> 'tasa_anual')::NUMERIC(18, 4) AS tasa_anual,
                (elem::JSONB ->> 'importe_inicial')::NUMERIC(18, 2) AS importe_inicial,
                (elem::JSONB ->> 'importe_pendiente')::NUMERIC(18, 2) AS importe_pendiente,
                (elem::JSONB ->> 'pagos_pendientes') AS pagos_pendientes,
                (elem::JSONB ->> 'pagos_hechos')::INTEGER AS pagos_hechos,
                (elem::JSONB ->> 'pagos_totales')::INTEGER AS pagos_totales,
                (elem::JSONB ->> 'mensualidad')::NUMERIC(18, 2) AS mensualidad,
                (elem::JSONB ->> 'amount')::NUMERIC(18, 2) AS amount
            FROM UNNEST(v_first_row) AS elem
        ),
        caught AS (
            SELECT
                r.record_no,
                r.txn_date,
                r.concept,
                r.concept_sk,
                r.tasa_anual,
                r.importe_inicial,
                r.importe_pendiente,
                r.pagos_pendientes,
                r.pagos_hechos,
                r.pagos_totales,
                r.mensualidad,
                r.amount,
                (ROW_NUMBER() OVER (
                    PARTITION BY r.txn_date, r.amount, r.concept_sk
                    ORDER BY r.record_no
                ))::INTEGER AS occurrence,
                public.movement_row_hash(
                    r.txn_date,
                    v_account_number,
                    r.amount,
                    r.concept_sk,
                    (ROW_NUMBER() OVER (
                        PARTITION BY r.txn_date, r.amount, r.concept_sk
                        ORDER BY r.record_no
                    ))::INTEGER
                ) AS row_hash
            FROM raw_rows AS r
        )
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
            pagos_hechos,
            pagos_totales,
            mensualidad,
            amount,
            occurrence,
            row_hash,
            source_profile
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
            caught.pagos_hechos,
            caught.pagos_totales,
            caught.mensualidad,
            caught.amount,
            caught.occurrence,
            caught.row_hash,
            v_profile
        FROM caught;
    END IF;

    WITH raw_rows AS (
        SELECT
            (elem::JSONB ->> 'record_no')::INTEGER AS record_no,
            (elem::JSONB ->> 'txn_date')::DATE AS txn_date,
            (elem::JSONB ->> 'concept_sk') AS concept_sk,
            (elem::JSONB ->> 'amount')::NUMERIC(18, 2) AS amount
        FROM UNNEST(v_first_row) AS elem
    ),
    caught AS (
        SELECT
            public.movement_row_hash(
                r.txn_date,
                v_account_number,
                r.amount,
                r.concept_sk,
                (ROW_NUMBER() OVER (
                    PARTITION BY r.txn_date, r.amount, r.concept_sk
                    ORDER BY r.record_no
                ))::INTEGER
            ) AS row_hash
        FROM raw_rows AS r
    )
    INSERT INTO public.movement_dimensions_d (tenant_id, row_hash, user_id, account_id)
    SELECT v_tenant, caught.row_hash, v_user, p_account_id
    FROM caught
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
        'profile', v_profile,
        'curated_csv_backup', v_curated,
        'tenant_id', v_tenant,
        'file_suffix', 'csv'
    );
END
$fn$;

-- 9. Updated statement_home listing banks with active profiles
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
                    'statement_source_profile', statement_file.source_profile,
                    'installment_upload_id', installment_file.upload_id,
                    'installment_filename', installment_file.original_filename,
                    'installment_row_count', installment_file.row_count,
                    'installment_source_profile', installment_file.source_profile,
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

-- 10. Grants and Revocations
REVOKE ALL ON FUNCTION public.ingest_statement_csv(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.detect_profile(TEXT, TEXT[], TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.detect_any_profile(TEXT[], TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.statement_home(DATE) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.ingest_statement_csv(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE, TEXT, TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.detect_profile(TEXT, TEXT[], TEXT[]) TO strm_app;
GRANT EXECUTE ON FUNCTION public.detect_any_profile(TEXT[], TEXT[]) TO strm_app;
GRANT EXECUTE ON FUNCTION public.statement_home(DATE) TO strm_app;
GRANT SELECT ON TABLE public.file_profiles_d TO strm_app;
