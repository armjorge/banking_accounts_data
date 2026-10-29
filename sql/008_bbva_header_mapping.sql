-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- BBVA profiles, header-alias flexibility notes, and open replace-by-account.
-- Safe to run more than once. Does not drop bank accounts or closed masters.
-- Apply on Neon after reviewing (Jorge applies SQL manually).

-- 1. Ensure BBVA bank exists
INSERT INTO public.banks_d (bank_name)
SELECT 'BBVA'
WHERE NOT EXISTS (
    SELECT 1 FROM public.banks_d AS existing
    WHERE LOWER(existing.bank_name) = 'bbva'
);

-- 2. Optional aliases column for user-configurable mappings (documentation + future UI)
ALTER TABLE public.file_profiles_d
ADD COLUMN IF NOT EXISTS header_aliases JSONB;

ALTER TABLE public.file_profiles_d
DROP CONSTRAINT IF EXISTS file_profiles_d_amount_rule_check;

ALTER TABLE public.file_profiles_d
ADD CONSTRAINT file_profiles_d_amount_rule_check CHECK (
    amount_rule IN (
        'split_signed',
        'split_positive_credit',
        'single_signed',
        'installment',
        'split_credit_abs_income'
    )
);

-- 3. Seed BBVA profiles (same headers for debit/credit; slot/dataset disambiguates)
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
    active,
    header_aliases
)
VALUES
(
    'bbva_debit_v1',
    'BBVA',
    'debit',
    TRUE,
    ARRAY['abono', 'cargo', 'descripcion', 'fecha', 'saldo'],
    5,
    '{"txn_date": "fecha", "concept": "descripcion", "outcome": "cargo", "income": "abono", "balance": "saldo"}'::JSONB,
    'split_signed',
    'DD/MM/YYYY',
    '.',
    ',',
    TRUE,
    '{"txn_date": ["fecha", "FECHA"], "concept": ["descripcion", "concepto", "DESCRIPCIÓN"], "income": ["abono", "abonos", "ABONO"], "outcome": ["cargo", "cargos", "CARGO"], "balance": ["saldo", "saldos", "SALDO"]}'::JSONB
),
(
    'bbva_credit_v1',
    'BBVA',
    'credit_monthly',
    TRUE,
    ARRAY['abono', 'cargo', 'descripcion', 'fecha', 'saldo'],
    5,
    '{"txn_date": "fecha", "concept": "descripcion", "outcome": "cargo", "income": "abono", "balance": "saldo"}'::JSONB,
    'split_credit_abs_income',
    'DD/MM/YYYY',
    '.',
    ',',
    TRUE,
    '{"txn_date": ["fecha", "FECHA"], "concept": ["descripcion", "concepto", "DESCRIPCIÓN"], "income": ["abono", "abonos", "ABONO"], "outcome": ["cargo", "cargos", "CARGO"], "balance": ["saldo", "saldos", "SALDO"]}'::JSONB
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
    active = EXCLUDED.active,
    header_aliases = EXCLUDED.header_aliases;

-- Enrich existing Banorte/HSBC rows with shared alias metadata (non-destructive)
UPDATE public.file_profiles_d
SET header_aliases = COALESCE(
    header_aliases,
    '{"txn_date": ["fecha", "FECHA"], "concept": ["concepto", "descripcion", "DESCRIPCIÓN", "Concepto"], "income": ["abono", "abonos", "Abono", "Abonos"], "outcome": ["cargo", "cargos", "Cargo", "Cargos"], "balance": ["saldo", "saldos", "Saldos"]}'::JSONB
)
WHERE header_aliases IS NULL;

-- 4. Open period: delete-by-account then insert (leaves other accounts untouched)
CREATE OR REPLACE FUNCTION public.replace_open_account_movements(
    p_account_id INTEGER,
    p_payload JSONB
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
    v_row JSONB;
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
    v_file_name TEXT;
    v_debit INTEGER := 0;
    v_credit INTEGER := 0;
    v_occurrence INTEGER;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    SELECT
        kind.ledger_kind,
        account.account_number,
        bank.bank_name
    INTO v_kind, v_account_number, v_bank_name
    FROM public.bank_accounts_d AS account
    INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
    INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
    WHERE
        account.account_id = p_account_id
        AND account.tenant_id = v_tenant
        AND account.user_id = v_user;

    IF v_kind IS NULL THEN
        RAISE EXCEPTION 'account not found' USING ERRCODE = 'P0002';
    END IF;

    IF v_kind = 'debit' THEN
        DELETE FROM public.open_debit_f
        WHERE
            tenant_id = v_tenant
            AND user_id = v_user
            AND account_id = p_account_id;
    ELSE
        DELETE FROM public.open_credit_f
        WHERE
            tenant_id = v_tenant
            AND user_id = v_user
            AND account_id = p_account_id;
    END IF;

    IF p_payload IS NULL OR JSONB_TYPEOF(p_payload) <> 'array' THEN
        RETURN JSONB_BUILD_OBJECT(
            'account_id', p_account_id,
            'debit_rows', 0,
            'credit_rows', 0
        );
    END IF;

    FOR v_row IN SELECT value FROM JSONB_ARRAY_ELEMENTS(p_payload)
    LOOP
        v_date := (v_row ->> 'txn_date')::DATE;
        v_concept := COALESCE(v_row ->> 'concept', '');
        v_sk := public.concept_sk(v_concept);
        v_file_name := COALESCE(NULLIF(v_row ->> 'file_name', ''), 'open upload');
        v_occurrence := COALESCE((v_row ->> 'occurrence')::INTEGER, 1);

        IF v_kind = 'debit' THEN
            v_cargos := ROUND(COALESCE((v_row ->> 'outcome')::NUMERIC, (v_row ->> 'cargos')::NUMERIC, 0), 2);
            v_abonos := ROUND(COALESCE((v_row ->> 'income')::NUMERIC, (v_row ->> 'abonos')::NUMERIC, 0), 2);
            v_saldos := ROUND(NULLIF(COALESCE(v_row ->> 'balance', v_row ->> 'saldos'), '')::NUMERIC, 2);
            v_amount := ROUND(COALESCE((v_row ->> 'amount')::NUMERIC, v_cargos + v_abonos), 2);
            INSERT INTO public.open_debit_f (
                tenant_id, user_id, account_id, account_number, bank_name, file_name,
                txn_date, concept, concept_sk, cargos, abonos, saldos, amount, occurrence, row_hash,
                source_profile
            )
            VALUES (
                v_tenant, v_user, p_account_id, v_account_number, v_bank_name, v_file_name,
                v_date, v_concept, v_sk, v_cargos, v_abonos, v_saldos, v_amount, v_occurrence,
                COALESCE(
                    NULLIF(v_row ->> 'row_hash', ''),
                    public.movement_row_hash(v_date, v_account_number, v_amount, v_sk, v_occurrence)
                ),
                v_row ->> 'source_profile'
            );
            v_debit := v_debit + 1;
        ELSE
            v_abono := ROUND(ABS(COALESCE((v_row ->> 'income')::NUMERIC, (v_row ->> 'abono')::NUMERIC, 0)), 2);
            v_cargo := ROUND(ABS(COALESCE((v_row ->> 'outcome')::NUMERIC, (v_row ->> 'cargo')::NUMERIC, 0)), 2);
            v_tarjeta := COALESCE(v_row ->> 'card_ref', v_row ->> 'tarjeta', '');
            v_amount := ROUND(COALESCE((v_row ->> 'amount')::NUMERIC, v_cargo - v_abono), 2);
            INSERT INTO public.open_credit_f (
                tenant_id, user_id, account_id, account_number, bank_name, file_name,
                txn_date, concept, concept_sk, abono, cargo, tarjeta, amount, occurrence, row_hash,
                source_profile
            )
            VALUES (
                v_tenant, v_user, p_account_id, v_account_number, v_bank_name, v_file_name,
                v_date, v_concept, v_sk, v_abono, v_cargo, v_tarjeta, v_amount, v_occurrence,
                COALESCE(
                    NULLIF(v_row ->> 'row_hash', ''),
                    public.movement_row_hash(v_date, v_account_number, v_amount, v_sk, v_occurrence)
                ),
                v_row ->> 'source_profile'
            );
            v_credit := v_credit + 1;
        END IF;
    END LOOP;

    RETURN JSONB_BUILD_OBJECT(
        'account_id', p_account_id,
        'debit_rows', v_debit,
        'credit_rows', v_credit
    );
END
$fn$;

REVOKE ALL ON FUNCTION public.replace_open_account_movements(INTEGER, JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.replace_open_account_movements(INTEGER, JSONB) TO strm_app;

GRANT SELECT ON TABLE public.file_profiles_d TO strm_app;
