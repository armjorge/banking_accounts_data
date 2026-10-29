-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- BNKS: clear existing statement movement data (allowed), keep accounts/banks,
-- store period_ym on uploads, per-account open reload, user profile upsert.
-- Safe to run more than once. Jorge applies on Neon manually — do not auto-apply.

-- =============================================================================
-- 1. Clear transformed statement data (source files live with the user / vault)
-- =============================================================================
TRUNCATE TABLE
    public.open_debit_f,
    public.open_credit_f,
    public.master_debit_closed_f,
    public.master_credit_closed_f,
    public.credit_plan_closed_f,
    public.movement_dimensions_d,
    public.statement_uploads_f;  -- all in one statement so FKs between them are allowed

-- =============================================================================
-- 2. Source metadata: keep account (FK) + period yyyy-mm on each upload
-- =============================================================================
ALTER TABLE public.statement_uploads_f
ADD COLUMN IF NOT EXISTS period_ym TEXT;

UPDATE public.statement_uploads_f AS upload
SET period_ym = TO_CHAR(cutoff.period_end, 'YYYY-MM')
FROM public.cutoff_date_f AS cutoff
WHERE
    cutoff.cutoff_id = upload.cutoff_id
    AND (upload.period_ym IS NULL OR upload.period_ym = '');

ALTER TABLE public.statement_uploads_f
DROP CONSTRAINT IF EXISTS statement_uploads_f_period_ym_check;

ALTER TABLE public.statement_uploads_f
ADD CONSTRAINT statement_uploads_f_period_ym_check CHECK (
    period_ym IS NULL OR period_ym ~ '^[0-9]{4}-[0-9]{2}$'
);

-- =============================================================================
-- 3. Open period: reload only replaces accounts present in the payload
-- =============================================================================
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
    v_touched INTEGER[] := ARRAY[]::INTEGER[];
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

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
        record_no INTEGER NOT NULL,
        source_profile TEXT,
        file_name TEXT
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
        v_touched := ARRAY(SELECT DISTINCT x FROM UNNEST(v_touched || v_account_id) AS t(x));
        v_date := (v_row ->> 'txn_date')::DATE;
        v_concept := v_row ->> 'concept';
        v_sk := public.concept_sk(v_concept);
        v_cargos := ROUND(COALESCE((v_row ->> 'outcome')::NUMERIC, (v_row ->> 'cargos')::NUMERIC, 0), 2);
        v_abonos := ROUND(COALESCE((v_row ->> 'income')::NUMERIC, (v_row ->> 'abonos')::NUMERIC, 0), 2);
        v_saldos := ROUND(NULLIF(COALESCE(v_row ->> 'balance', v_row ->> 'saldos'), '')::NUMERIC, 2);
        v_amount := ROUND(COALESCE((v_row ->> 'amount')::NUMERIC, v_cargos + v_abonos), 2);
        INSERT INTO pg_temp.open_catch (
            kind, account_id, account_number, bank_name, txn_date, concept, concept_sk,
            cargos, abonos, saldos, amount, record_no, source_profile, file_name
        )
        VALUES (
            'debit', v_account_id, v_account_number, v_bank_name, v_date, v_concept, v_sk,
            v_cargos, v_abonos, v_saldos, v_amount, v_debit,
            v_row ->> 'source_profile',
            COALESCE(NULLIF(v_row ->> 'file_name', ''), 'open reload')
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
        v_touched := ARRAY(SELECT DISTINCT x FROM UNNEST(v_touched || v_account_id) AS t(x));
        v_date := (v_row ->> 'txn_date')::DATE;
        v_concept := v_row ->> 'concept';
        v_sk := public.concept_sk(v_concept);
        v_abono := ROUND(ABS(COALESCE((v_row ->> 'income')::NUMERIC, (v_row ->> 'abono')::NUMERIC, 0)), 2);
        v_cargo := ROUND(ABS(COALESCE((v_row ->> 'outcome')::NUMERIC, (v_row ->> 'cargo')::NUMERIC, 0)), 2);
        v_tarjeta := COALESCE(v_row ->> 'card_ref', v_row ->> 'tarjeta', '');
        v_amount := ROUND(COALESCE((v_row ->> 'amount')::NUMERIC, v_cargo - v_abono), 2);
        INSERT INTO pg_temp.open_catch (
            kind, account_id, account_number, bank_name, txn_date, concept, concept_sk,
            abono, cargo, tarjeta, amount, record_no, source_profile, file_name
        )
        VALUES (
            'credit', v_account_id, v_account_number, v_bank_name, v_date, v_concept, v_sk,
            v_abono, v_cargo, v_tarjeta, v_amount, v_credit,
            v_row ->> 'source_profile',
            COALESCE(NULLIF(v_row ->> 'file_name', ''), 'open reload')
        );
    END LOOP;

    -- Delete ONLY accounts present in this upload; leave other open accounts alone.
    IF COALESCE(ARRAY_LENGTH(v_touched, 1), 0) > 0 THEN
        DELETE FROM public.open_debit_f
        WHERE
            tenant_id = v_tenant
            AND user_id = v_user
            AND account_id = ANY (v_touched);
        DELETE FROM public.open_credit_f
        WHERE
            tenant_id = v_tenant
            AND user_id = v_user
            AND account_id = ANY (v_touched);
    END IF;

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
        txn_date, concept, concept_sk, cargos, abonos, saldos, amount, occurrence, row_hash,
        source_profile
    )
    SELECT
        v_tenant, v_user, caught.account_id, caught.account_number, caught.bank_name, caught.file_name,
        caught.txn_date, caught.concept, caught.concept_sk, caught.cargos, caught.abonos, caught.saldos,
        caught.amount, caught.occurrence, caught.row_hash, caught.source_profile
    FROM pg_temp.open_catch AS caught
    WHERE caught.kind = 'debit';

    INSERT INTO public.open_credit_f (
        tenant_id, user_id, account_id, account_number, bank_name, file_name,
        txn_date, concept, concept_sk, abono, cargo, tarjeta, amount, occurrence, row_hash,
        source_profile
    )
    SELECT
        v_tenant, v_user, caught.account_id, caught.account_number, caught.bank_name, caught.file_name,
        caught.txn_date, caught.concept, caught.concept_sk, caught.abono, caught.cargo, caught.tarjeta,
        caught.amount, caught.occurrence, caught.row_hash, caught.source_profile
    FROM pg_temp.open_catch AS caught
    WHERE caught.kind = 'credit';

    RETURN JSONB_BUILD_OBJECT(
        'debit_rows', v_debit,
        'credit_rows', v_credit,
        'accounts_replaced', COALESCE(ARRAY_LENGTH(v_touched, 1), 0)
    );
END
$fn$;

REVOKE ALL ON FUNCTION public.reload_open_movements(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.reload_open_movements(JSONB) TO strm_app;

-- =============================================================================
-- 4. User-configurable bank mapping (upsert into file_profiles_d)
-- =============================================================================
CREATE OR REPLACE FUNCTION public.upsert_user_file_profile(p_profile JSONB)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_code TEXT;
    v_bank TEXT;
    v_dataset TEXT;
    v_rule TEXT;
BEGIN
    PERFORM public.require_session();

    v_code := NULLIF(BTRIM(p_profile ->> 'profile_code'), '');
    v_bank := NULLIF(BTRIM(p_profile ->> 'bank_name'), '');
    v_dataset := NULLIF(BTRIM(p_profile ->> 'dataset'), '');
    v_rule := NULLIF(BTRIM(p_profile ->> 'amount_rule'), '');

    IF v_code IS NULL OR v_bank IS NULL OR v_dataset IS NULL OR v_rule IS NULL THEN
        RAISE EXCEPTION 'profile_code, bank_name, dataset, amount_rule are required'
            USING ERRCODE = '22023';
    END IF;

    IF v_dataset NOT IN ('debit', 'credit_monthly', 'credit_plan') THEN
        RAISE EXCEPTION 'unsupported dataset' USING ERRCODE = '22023';
    END IF;

    IF v_rule NOT IN (
        'split_signed',
        'split_positive_credit',
        'single_signed',
        'installment',
        'split_credit_abs_income'
    ) THEN
        RAISE EXCEPTION 'unsupported amount_rule' USING ERRCODE = '22023';
    END IF;

    -- Ensure bank catalog row exists so accounts can reference it later.
    INSERT INTO public.banks_d (bank_name)
    SELECT v_bank
    WHERE NOT EXISTS (
        SELECT 1 FROM public.banks_d AS existing
        WHERE LOWER(existing.bank_name) = LOWER(v_bank)
    );

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
    VALUES (
        v_code,
        v_bank,
        v_dataset,
        COALESCE((p_profile ->> 'has_header')::BOOLEAN, TRUE),
        CASE
            WHEN p_profile ? 'header_signature' AND JSONB_TYPEOF(p_profile -> 'header_signature') = 'array'
                THEN ARRAY(SELECT JSONB_ARRAY_ELEMENTS_TEXT(p_profile -> 'header_signature'))
            ELSE NULL
        END,
        COALESCE(
            (p_profile ->> 'column_count')::INTEGER,
            (SELECT COUNT(*)::INTEGER FROM JSONB_OBJECT_KEYS(COALESCE(p_profile -> 'column_map', '{}'::JSONB)))
        ),
        COALESCE(p_profile -> 'column_map', '{}'::JSONB),
        v_rule,
        COALESCE(NULLIF(p_profile ->> 'date_format', ''), 'DD/MM/YYYY'),
        COALESCE(NULLIF(p_profile ->> 'decimal_sep', ''), '.'),
        COALESCE(NULLIF(p_profile ->> 'thousands_sep', ''), ','),
        COALESCE((p_profile ->> 'active')::BOOLEAN, TRUE),
        p_profile -> 'header_aliases'
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

    RETURN v_code;
END
$fn$;

REVOKE ALL ON FUNCTION public.upsert_user_file_profile(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.upsert_user_file_profile(JSONB) TO strm_app;

GRANT SELECT, INSERT, UPDATE ON TABLE public.file_profiles_d TO strm_app;
