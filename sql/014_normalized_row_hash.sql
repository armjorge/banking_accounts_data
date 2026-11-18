-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- Normalized row_hash for the five movement masters (see docs/row_hash.md).
--
--   * Same column names in every master: credit, open-credit and future tables rename
--     abono -> abonos and cargo -> cargos (debit tables already use abonos/cargos).
--   * bank_id (banks_d) is added to every master and back-filled from the account.
--     bank_name and account_number stay as readable copies; the key uses the ids.
--   * row_hash = sha256 hex of
--         user_id|account_id|bank_id|txn_date|concept_sk|abonos|cargos|occurrence
--     (public.movement_row_hash_v2). Existing rows are re-hashed in place and
--     movement_dimensions_d is remapped old -> new.
--   * Sign CHECKs: debit cargos <= 0, abonos >= 0; credit (and future) cargos >= 0,
--     abonos >= 0, so a card payment (debit -X, credit abono +X) balances.
--   * master_debit_future_f is renamed master_credit_future_f (installments are credit-card
--     rows), with its sequence, indexes, constraints and policy. If an older migration is
--     re-run after 014 and recreates an empty master_debit_future_f, 014 drops it again;
--     a non-empty one stops the migration.
--   * movement_keys_v: one row per stored movement across the five masters.
--   * ingest_statement_csv and update_bank_account_cutoff are replaced to write the
--     new columns and the new hash.
--
-- Safe to run more than once: renames and new columns are guarded, and the re-hash only
-- touches rows whose stored hash differs from movement_row_hash_v2. Apply on Neon by
-- hand after 013, as the table owner (the re-hash briefly disables the append-only
-- update trigger on the closed masters inside one DO block).

-- =============================================================================
-- 1. Hash function
-- =============================================================================
-- Amount text: two decimals, '-' only for negatives, no thousands separator, never
-- "-0.00". Ids as text (uuid lowercase with hyphens), date as YYYY-MM-DD.
CREATE OR REPLACE FUNCTION public.movement_amount_text(p_amount NUMERIC)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE
        WHEN ROUND(COALESCE(p_amount, 0), 2) = 0 THEN '0.00'
        ELSE TO_CHAR(ROUND(p_amount, 2), 'FM999999999999999990.00')
    END
$fn$;

CREATE OR REPLACE FUNCTION public.movement_row_hash_v2(
    p_user_id UUID,
    p_account_id INTEGER,
    p_bank_id INTEGER,
    p_txn_date DATE,
    p_concept_sk TEXT,
    p_abonos NUMERIC,
    p_cargos NUMERIC,
    p_occurrence INTEGER
) RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT ENCODE(
        PUBLIC.DIGEST(
            CONVERT_TO(
                CONCAT_WS(
                    '|',
                    p_user_id::TEXT,
                    p_account_id::TEXT,
                    p_bank_id::TEXT,
                    TO_CHAR(p_txn_date, 'YYYY-MM-DD'),
                    p_concept_sk,
                    public.movement_amount_text(p_abonos),
                    public.movement_amount_text(p_cargos),
                    p_occurrence::TEXT
                ),
                'UTF8'
            ),
            'sha256'
        ),
        'hex'
    )
$fn$;

COMMENT ON FUNCTION public.movement_row_hash_v2(UUID, INTEGER, INTEGER, DATE, TEXT, NUMERIC, NUMERIC, INTEGER) IS
'Movement key (sql/014, docs/row_hash.md): sha256 hex of '
'user_id|account_id|bank_id|YYYY-MM-DD|concept_sk|abonos|cargos|occurrence. Amounts as stored, '
'2 decimals, "-" only for negatives. occurrence numbers identical rows (same day, concept and '
'amounts) within one upload. Balance, period, file and names are not inputs.';
COMMENT ON FUNCTION public.movement_row_hash(DATE, TEXT, NUMERIC, TEXT, INTEGER) IS
'Legacy row_hash (006-013): date|account_number|amount|concept_sk|occurrence. '
'Not written after sql/014; see movement_row_hash_v2.';

-- =============================================================================
-- 2. Installments are credit: master_debit_future_f -> master_credit_future_f
-- =============================================================================
DO $do$
DECLARE
    v_item RECORD;
    v_rows BIGINT;
BEGIN
    IF TO_REGCLASS('public.master_debit_future_f') IS NOT NULL
        AND TO_REGCLASS('public.master_credit_future_f') IS NOT NULL
    THEN
        -- An older migration (011) was re-run after 014: drop its new, empty copy.
        EXECUTE 'SELECT COUNT(*) FROM public.master_debit_future_f' INTO v_rows;
        IF v_rows > 0 THEN
            RAISE EXCEPTION 'Both master_debit_future_f (% rows) and master_credit_future_f exist; '
                'move the rows by hand before re-running 014', v_rows;
        END IF;
        DROP TABLE public.master_debit_future_f;
    ELSIF TO_REGCLASS('public.master_debit_future_f') IS NOT NULL THEN
        ALTER TABLE public.master_debit_future_f RENAME TO master_credit_future_f;
        ALTER SEQUENCE IF EXISTS public.master_debit_future_f_row_id_seq
        RENAME TO master_credit_future_f_row_id_seq;
        FOR v_item IN
            SELECT conname FROM pg_constraint
            WHERE conrelid = 'public.master_credit_future_f'::REGCLASS AND conname LIKE 'master_debit_future_f%'
        LOOP
            EXECUTE FORMAT(
                'ALTER TABLE public.master_credit_future_f RENAME CONSTRAINT %I TO %I',
                v_item.conname, REPLACE(v_item.conname, 'master_debit_future_f', 'master_credit_future_f')
            );
        END LOOP;
        FOR v_item IN
            SELECT indexname FROM pg_indexes
            WHERE schemaname = 'public' AND tablename = 'master_credit_future_f'
                AND indexname LIKE 'master_debit_future_f%'
        LOOP
            EXECUTE FORMAT(
                'ALTER INDEX public.%I RENAME TO %I',
                v_item.indexname, REPLACE(v_item.indexname, 'master_debit_future_f', 'master_credit_future_f')
            );
        END LOOP;
        IF EXISTS (
            SELECT 1 FROM pg_policies
            WHERE schemaname = 'public' AND tablename = 'master_credit_future_f'
                AND policyname = 'master_debit_future_f_tenant'
        ) THEN
            ALTER POLICY master_debit_future_f_tenant ON public.master_credit_future_f
            RENAME TO master_credit_future_f_tenant;
        END IF;
    END IF;
END
$do$;

COMMENT ON TABLE public.master_credit_future_f IS
'Future installment (MSI) payments of credit cards, one row per remaining payment. Same schema as '
'master_credit_closed_f. Replaced per account on each installment upload. Named master_debit_future_f '
'before sql/014.';

-- =============================================================================
-- 2b. Column names: abonos / cargos everywhere, plus bank_id
-- =============================================================================
DO $do$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY['master_credit_closed_f', 'master_credit_open_f', 'master_credit_future_f']
    LOOP
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = v_table AND column_name = 'abono'
        ) THEN
            EXECUTE FORMAT('ALTER TABLE public.%I RENAME COLUMN abono TO abonos', v_table);
        END IF;
        IF EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = v_table AND column_name = 'cargo'
        ) THEN
            EXECUTE FORMAT('ALTER TABLE public.%I RENAME COLUMN cargo TO cargos', v_table);
        END IF;
    END LOOP;
END
$do$;

ALTER TABLE public.master_debit_closed_f
ADD COLUMN IF NOT EXISTS bank_id INTEGER;

ALTER TABLE public.master_debit_open_f
ADD COLUMN IF NOT EXISTS bank_id INTEGER;

ALTER TABLE public.master_credit_closed_f
ADD COLUMN IF NOT EXISTS bank_id INTEGER;

ALTER TABLE public.master_credit_open_f
ADD COLUMN IF NOT EXISTS bank_id INTEGER;

ALTER TABLE public.master_credit_future_f
ADD COLUMN IF NOT EXISTS bank_id INTEGER;

-- =============================================================================
-- 3. Back-fill bank_id, re-hash in place, remap dimensions (one atomic block)
-- =============================================================================
-- The stored occurrence is kept. Old keys were unique per account on
-- (date, account_number, amount, concept_sk, occurrence); the new inputs include all of
-- those (amount is derived from abonos/cargos), so per-account uniqueness carries over.
DO $do$
DECLARE
    v_table TEXT;
BEGIN
    CREATE TEMP TABLE IF NOT EXISTS row_hash_map_014 (
        tenant_id UUID NOT NULL,
        user_id UUID NOT NULL,
        account_id INTEGER NOT NULL,
        old_hash TEXT NOT NULL,
        new_hash TEXT NOT NULL
    ) ON COMMIT DROP;
    TRUNCATE row_hash_map_014;

    ALTER TABLE public.master_debit_closed_f DISABLE TRIGGER master_debit_closed_f_no_update;
    ALTER TABLE public.master_credit_closed_f DISABLE TRIGGER master_credit_closed_f_no_update;

    FOREACH v_table IN ARRAY ARRAY[
        'master_debit_closed_f',
        'master_debit_open_f',
        'master_credit_closed_f',
        'master_credit_open_f',
        'master_credit_future_f'
    ]
    LOOP
        EXECUTE FORMAT(
            'UPDATE public.%I AS movement
            SET bank_id = account.bank_id
            FROM public.bank_accounts_d AS account
            WHERE
                account.account_id = movement.account_id
                AND movement.bank_id IS DISTINCT FROM account.bank_id',
            v_table
        );
        EXECUTE FORMAT(
            'INSERT INTO row_hash_map_014 (tenant_id, user_id, account_id, old_hash, new_hash)
            SELECT movement.tenant_id, movement.user_id, movement.account_id, movement.row_hash, keyed.new_hash
            FROM public.%I AS movement
            CROSS JOIN LATERAL (
                SELECT public.movement_row_hash_v2(
                    movement.user_id, movement.account_id, movement.bank_id, movement.txn_date,
                    movement.concept_sk, movement.abonos, movement.cargos, movement.occurrence
                ) AS new_hash
            ) AS keyed
            WHERE movement.row_hash IS DISTINCT FROM keyed.new_hash',
            v_table
        );
        EXECUTE FORMAT(
            'UPDATE public.%I AS movement
            SET row_hash = public.movement_row_hash_v2(
                movement.user_id, movement.account_id, movement.bank_id, movement.txn_date,
                movement.concept_sk, movement.abonos, movement.cargos, movement.occurrence
            )
            WHERE movement.row_hash IS DISTINCT FROM public.movement_row_hash_v2(
                movement.user_id, movement.account_id, movement.bank_id, movement.txn_date,
                movement.concept_sk, movement.abonos, movement.cargos, movement.occurrence
            )',
            v_table
        );
    END LOOP;

    ALTER TABLE public.master_debit_closed_f ENABLE TRIGGER master_debit_closed_f_no_update;
    ALTER TABLE public.master_credit_closed_f ENABLE TRIGGER master_credit_closed_f_no_update;

    -- Dimensions follow their movement: insert the new key (keeping created_at), then
    -- drop the old key. Old keys that no master row maps (already orphaned) stay as is.
    INSERT INTO public.movement_dimensions_d (tenant_id, row_hash, user_id, account_id, created_at)
    SELECT DISTINCT ON (map.tenant_id, map.new_hash)
        map.tenant_id, map.new_hash, dims.user_id, dims.account_id, dims.created_at
    FROM row_hash_map_014 AS map
    INNER JOIN public.movement_dimensions_d AS dims
        ON dims.tenant_id = map.tenant_id
        AND dims.row_hash = map.old_hash
        AND dims.account_id = map.account_id
    ORDER BY map.tenant_id, map.new_hash, dims.created_at
    ON CONFLICT (tenant_id, row_hash) DO NOTHING;

    DELETE FROM public.movement_dimensions_d AS dims
    USING row_hash_map_014 AS map
    WHERE
        dims.tenant_id = map.tenant_id
        AND dims.row_hash = map.old_hash
        AND dims.account_id = map.account_id;

    -- Every stored movement has its dimension row (the ingest already writes one).
    FOREACH v_table IN ARRAY ARRAY[
        'master_debit_closed_f',
        'master_debit_open_f',
        'master_credit_closed_f',
        'master_credit_open_f',
        'master_credit_future_f'
    ]
    LOOP
        EXECUTE FORMAT(
            'INSERT INTO public.movement_dimensions_d (tenant_id, row_hash, user_id, account_id)
            SELECT movement.tenant_id, movement.row_hash, movement.user_id, movement.account_id
            FROM public.%I AS movement
            ON CONFLICT (tenant_id, row_hash) DO NOTHING',
            v_table
        );
    END LOOP;

    DROP TABLE row_hash_map_014;
END
$do$;

ALTER TABLE public.master_debit_closed_f
ALTER COLUMN bank_id SET NOT NULL;

DO $do$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'master_debit_closed_f_bank_fkey' AND conrelid = 'public.master_debit_closed_f'::REGCLASS
    ) THEN
        ALTER TABLE public.master_debit_closed_f
        ADD CONSTRAINT master_debit_closed_f_bank_fkey FOREIGN KEY (bank_id) REFERENCES public.banks_d (bank_id);
    END IF;
END
$do$;

COMMENT ON COLUMN public.master_debit_closed_f.row_hash IS
'movement_row_hash_v2(user_id, account_id, bank_id, txn_date, concept_sk, abonos, cargos, occurrence); '
'see docs/row_hash.md.';
COMMENT ON COLUMN public.master_debit_closed_f.bank_id IS
'banks_d.bank_id of the account at load time (sql/014). bank_name is the readable copy.';

ALTER TABLE public.master_debit_open_f
ALTER COLUMN bank_id SET NOT NULL;

DO $do$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'master_debit_open_f_bank_fkey' AND conrelid = 'public.master_debit_open_f'::REGCLASS
    ) THEN
        ALTER TABLE public.master_debit_open_f
        ADD CONSTRAINT master_debit_open_f_bank_fkey FOREIGN KEY (bank_id) REFERENCES public.banks_d (bank_id);
    END IF;
END
$do$;

COMMENT ON COLUMN public.master_debit_open_f.row_hash IS
'movement_row_hash_v2(user_id, account_id, bank_id, txn_date, concept_sk, abonos, cargos, occurrence); '
'see docs/row_hash.md.';
COMMENT ON COLUMN public.master_debit_open_f.bank_id IS
'banks_d.bank_id of the account at load time (sql/014). bank_name is the readable copy.';

ALTER TABLE public.master_credit_closed_f
ALTER COLUMN bank_id SET NOT NULL;

DO $do$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'master_credit_closed_f_bank_fkey' AND conrelid = 'public.master_credit_closed_f'::REGCLASS
    ) THEN
        ALTER TABLE public.master_credit_closed_f
        ADD CONSTRAINT master_credit_closed_f_bank_fkey FOREIGN KEY (bank_id) REFERENCES public.banks_d (bank_id);
    END IF;
END
$do$;

COMMENT ON COLUMN public.master_credit_closed_f.row_hash IS
'movement_row_hash_v2(user_id, account_id, bank_id, txn_date, concept_sk, abonos, cargos, occurrence); '
'see docs/row_hash.md.';
COMMENT ON COLUMN public.master_credit_closed_f.bank_id IS
'banks_d.bank_id of the account at load time (sql/014). bank_name is the readable copy.';

ALTER TABLE public.master_credit_open_f
ALTER COLUMN bank_id SET NOT NULL;

DO $do$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'master_credit_open_f_bank_fkey' AND conrelid = 'public.master_credit_open_f'::REGCLASS
    ) THEN
        ALTER TABLE public.master_credit_open_f
        ADD CONSTRAINT master_credit_open_f_bank_fkey FOREIGN KEY (bank_id) REFERENCES public.banks_d (bank_id);
    END IF;
END
$do$;

COMMENT ON COLUMN public.master_credit_open_f.row_hash IS
'movement_row_hash_v2(user_id, account_id, bank_id, txn_date, concept_sk, abonos, cargos, occurrence); '
'see docs/row_hash.md.';
COMMENT ON COLUMN public.master_credit_open_f.bank_id IS
'banks_d.bank_id of the account at load time (sql/014). bank_name is the readable copy.';

ALTER TABLE public.master_credit_future_f
ALTER COLUMN bank_id SET NOT NULL;

DO $do$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'master_credit_future_f_bank_fkey' AND conrelid = 'public.master_credit_future_f'::REGCLASS
    ) THEN
        ALTER TABLE public.master_credit_future_f
        ADD CONSTRAINT master_credit_future_f_bank_fkey FOREIGN KEY (bank_id) REFERENCES public.banks_d (bank_id);
    END IF;
END
$do$;

COMMENT ON COLUMN public.master_credit_future_f.row_hash IS
'movement_row_hash_v2(user_id, account_id, bank_id, txn_date, concept_sk, abonos, cargos, occurrence); '
'see docs/row_hash.md.';
COMMENT ON COLUMN public.master_credit_future_f.bank_id IS
'banks_d.bank_id of the account at load time (sql/014). bank_name is the readable copy.';

-- =============================================================================
-- 3b. Sign convention (docs/row_hash.md, "Signs")
-- =============================================================================
-- Debit (bank account): cargos <= 0 (money out), abonos >= 0 (money in).
-- Credit card (closed, open and future installments): cargos >= 0 (charges),
-- abonos >= 0 (payments and refunds). Paying the card is a debit cargo of -X on the
-- bank account and a credit abono of +X on the card, so the two legs offset.
-- A table with rows that break the rule gets the CHECK as NOT VALID (new rows are
-- checked, old rows are left as they are) and a NOTICE with the count; nothing is fixed.
DO $do$
DECLARE
    v_spec TEXT [];
    v_bad BIGINT;
BEGIN
    FOREACH v_spec SLICE 1 IN ARRAY ARRAY[
        ['master_debit_closed_f', 'cargos <= 0 AND abonos >= 0'],
        ['master_debit_open_f', 'cargos <= 0 AND abonos >= 0'],
        ['master_credit_closed_f', 'cargos >= 0 AND abonos >= 0'],
        ['master_credit_open_f', 'cargos >= 0 AND abonos >= 0'],
        ['master_credit_future_f', 'cargos >= 0 AND abonos >= 0']
    ]
    LOOP
        IF EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conname = v_spec[1] || '_sign_check' AND conrelid = ('public.' || v_spec[1])::REGCLASS
        ) THEN
            CONTINUE;
        END IF;
        EXECUTE FORMAT('SELECT COUNT(*) FROM public.%I WHERE NOT (%s)', v_spec[1], v_spec[2]) INTO v_bad;
        IF v_bad = 0 THEN
            EXECUTE FORMAT(
                'ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (%s)',
                v_spec[1], v_spec[1] || '_sign_check', v_spec[2]
            );
        ELSE
            RAISE NOTICE '% has % row(s) outside the sign rule (%); CHECK added NOT VALID',
                v_spec[1], v_bad, v_spec[2];
            EXECUTE FORMAT(
                'ALTER TABLE public.%I ADD CONSTRAINT %I CHECK (%s) NOT VALID',
                v_spec[1], v_spec[1] || '_sign_check', v_spec[2]
            );
        END IF;
    END LOOP;
END
$do$;

COMMENT ON COLUMN public.master_debit_closed_f.cargos IS
'Money out of the bank account, stored <= 0 (e.g. a card payment of 1,500.00 is -1500.00). Hash input.';
COMMENT ON COLUMN public.master_debit_closed_f.abonos IS
'Money into the bank account, stored >= 0. Hash input.';
COMMENT ON COLUMN public.master_debit_open_f.cargos IS
'Money out of the bank account, stored <= 0 (e.g. a card payment of 1,500.00 is -1500.00). Hash input.';
COMMENT ON COLUMN public.master_debit_open_f.abonos IS
'Money into the bank account, stored >= 0. Hash input.';
COMMENT ON COLUMN public.master_credit_closed_f.cargos IS
'Card charge, stored >= 0 (was "cargo" before sql/014). Hash input.';
COMMENT ON COLUMN public.master_credit_closed_f.abonos IS
'Card payment or refund, stored >= 0 (was "abono" before sql/014). A payment offsets the debit cargo. Hash input.';
COMMENT ON COLUMN public.master_credit_open_f.cargos IS
'Card charge, stored >= 0 (was "cargo" before sql/014). Hash input.';
COMMENT ON COLUMN public.master_credit_open_f.abonos IS
'Card payment or refund, stored >= 0 (was "abono" before sql/014). A payment offsets the debit cargo. Hash input.';
COMMENT ON COLUMN public.master_credit_future_f.cargos IS
'Card charge, stored >= 0 (was "cargo" before sql/014). Hash input.';
COMMENT ON COLUMN public.master_credit_future_f.abonos IS
'Card payment or refund, stored >= 0 (was "abono" before sql/014). A payment offsets the debit cargo. Hash input.';

-- =============================================================================
-- 4. Ingest, cutoff edit, home and delete use the new names, columns and hash
-- =============================================================================
-- When a movement's key changes (a re-dated installment, sql/012), its user attributes
-- (sql/015 debit_d / credit_d) follow it. p_pairs: [{"old_hash": ..., "new_hash": ...}].
-- A no-op until 015 has created the attribute tables.
CREATE OR REPLACE FUNCTION public.movement_rekeyed(p_pairs JSONB)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY['debit_d', 'credit_d']
    LOOP
        IF TO_REGCLASS('public.' || v_table) IS NULL THEN
            CONTINUE;
        END IF;
        EXECUTE FORMAT(
            'UPDATE public.%1$I AS target
            SET
                attribute_1 = COALESCE(target.attribute_1, source.attribute_1),
                attribute_2 = COALESCE(target.attribute_2, source.attribute_2),
                attribute_3 = COALESCE(target.attribute_3, source.attribute_3),
                updated_at = NOW(),
                updated_by = source.updated_by
            FROM JSONB_ARRAY_ELEMENTS($1) AS pair (item)
            INNER JOIN public.%1$I AS source ON source.row_hash = pair.item ->> ''old_hash''
            WHERE
                target.row_hash = pair.item ->> ''new_hash''
                AND target.tenant_id = source.tenant_id
                AND (source.attribute_1 IS NOT NULL OR source.attribute_2 IS NOT NULL
                    OR source.attribute_3 IS NOT NULL)',
            v_table
        )
        USING p_pairs;
    END LOOP;
END
$fn$;

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
    v_bank_id INTEGER;
    v_cutoff_day INTEGER;
    v_period_start DATE;
    v_period_end DATE;
    v_as_of DATE := COALESCE(p_as_of, CURRENT_DATE);
    v_ledger TEXT;
    v_table TEXT;
    v_closed_table TEXT;
    v_existing_upload UUID;
    v_existing_state TEXT;
    v_stale RECORD;
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
    v_period_ym TEXT;
    v_from_sheet BOOLEAN := FALSE;
    v_csv TEXT;
    v_first_row TEXT [];
    v_parsed_rows TEXT [] := ARRAY[]::TEXT [];
    v_final_rows JSONB;
    v_first_line TEXT;
    v_index JSONB := '{}'::JSONB;
    v_position INTEGER;
    v_header_record_no INTEGER;
    v_sig TEXT [];
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
    v_pagos_restantes INTEGER;
    v_mensualidad NUMERIC(18, 2);
    v_raw_amt NUMERIC(18, 2);
    v_amount NUMERIC(18, 2);
    v_upload_id UUID;
    v_source_rows INTEGER;
    v_rows INTEGER;
    v_replaced INTEGER := 0;
    v_duplicate BOOLEAN;
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
        account.account_cutoff_day,
        bank.bank_name,
        bank.bank_id,
        cutoff.period_start,
        cutoff.period_end
    INTO v_kind, v_account_number, v_cutoff_day, v_bank_name, v_bank_id, v_period_start, v_period_end
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
    FOR UPDATE OF cutoff, account;

    IF v_kind IS NULL THEN
        RAISE EXCEPTION 'period not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_slot = 'installment' AND v_kind <> 'credit' THEN
        RAISE EXCEPTION 'Debit accounts do not have an installment file' USING ERRCODE = '23514';
    END IF;

    -- Routing: closed period, current (open) period, or installments (future).
    IF v_as_of > v_period_end THEN
        v_ledger := 'closed';
    ELSIF v_as_of >= v_period_start THEN
        v_ledger := 'open';
    ELSE
        RAISE EXCEPTION 'The period is not open for upload yet' USING ERRCODE = '22023';
    END IF;
    IF p_slot = 'installment' THEN
        v_ledger := 'future';
    END IF;

    v_dataset := CASE
        WHEN p_slot = 'installment' THEN 'credit_plan'
        WHEN v_kind = 'credit' THEN 'credit_monthly'
        ELSE 'debit'
    END;
    v_table := CASE
        WHEN v_ledger = 'future' THEN 'master_credit_future_f'
        WHEN v_kind = 'credit' AND v_ledger = 'open' THEN 'master_credit_open_f'
        WHEN v_kind = 'credit' THEN 'master_credit_closed_f'
        WHEN v_ledger = 'open' THEN 'master_debit_open_f'
        ELSE 'master_debit_closed_f'
    END;
    v_closed_table := CASE
        WHEN v_kind = 'credit' THEN 'master_credit_closed_f'
        ELSE 'master_debit_closed_f'
    END;

    -- Stored upload is always CSV; spreadsheet uploads get a canonical
    -- bank_account_period.csv name so BBVA matches Banorte/HSBC metadata.
    v_period_ym := TO_CHAR(v_period_end, 'YYYY-MM');
    v_from_sheet := v_filename ~* '\.(xlsx|xlsm|xls)$';
    IF v_from_sheet THEN
        v_filename := REGEXP_REPLACE(v_filename, '\.(xlsx|xlsm|xls)$', '.csv', 'i');
    ELSIF v_filename !~* '\.csv$' THEN
        v_filename := v_filename || '.csv';
    END IF;
    IF v_from_sheet
        OR (
            POSITION(LOWER(v_bank_name) IN LOWER(v_filename)) = 0
            AND POSITION(v_account_number IN v_filename) = 0
        )
    THEN
        v_filename := LEFT(
            REGEXP_REPLACE(
                FORMAT('%s_%s_%s.csv', v_bank_name, v_account_number, v_period_ym),
                '[^\w.\-]+',
                '_',
                'g'
            ),
            200
        );
    END IF;

    -- One upload per period slot. A stale open upload on a period that has since
    -- closed is replaced by the closed statement; open/future uploads are replaced
    -- per account further down. Legacy (pre-011) installment uploads must be deleted first.
    SELECT upload.upload_id, upload.ledger_state
    INTO v_existing_upload, v_existing_state
    FROM public.statement_uploads_f AS upload
    WHERE
        upload.cutoff_id = p_cutoff_id
        AND upload.dataset = v_dataset;
    IF v_existing_upload IS NOT NULL AND v_existing_state = 'closed' THEN
        RAISE EXCEPTION 'already uploaded' USING ERRCODE = '23505';
    END IF;

    v_csv := REPLACE(REPLACE(p_csv, CHR(65279), ''), CHR(160), ' ');
    -- BBVA installments pasted/downloaded as one value per line (sql/011 section 4b).
    IF p_slot = 'installment' THEN
        v_csv := COALESCE(public.reshape_one_column_installments(v_csv), v_csv);
    END IF;

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

    -- Find header row (BBVA XLSX→CSV may keep a clean header at row 1;
    -- tolerate preamble if present). Prefer dataset-matching profile.
    v_header_record_no := NULL;
    FOR v_record IN
        SELECT parsed.record_no, parsed.fields
        FROM public.parse_csv(v_csv, v_delim) AS parsed
        ORDER BY parsed.record_no
        LIMIT 40
    LOOP
        SELECT ARRAY_AGG(public.normalize_header(col) ORDER BY public.normalize_header(col))
        INTO v_sig
        FROM UNNEST(v_record.fields) AS col;

        SELECT fp.profile_code
        INTO v_profile
        FROM public.file_profiles_d AS fp
        WHERE
            LOWER(fp.bank_name) = LOWER(v_bank_name)
            AND fp.active IS TRUE
            AND fp.has_header IS TRUE
            AND fp.dataset = v_dataset
            AND fp.header_signature = v_sig
        LIMIT 1;

        IF v_profile IS NULL THEN
            -- Alias-tolerant: fecha + (cargo|cargos) + (abono|abonos)
            IF EXISTS (
                SELECT 1
                FROM UNNEST(v_record.fields) AS col
                WHERE public.normalize_header(col) = 'fecha'
            )
            AND EXISTS (
                SELECT 1
                FROM UNNEST(v_record.fields) AS col
                WHERE public.normalize_header(col) IN ('cargo', 'cargos')
            )
            AND EXISTS (
                SELECT 1
                FROM UNNEST(v_record.fields) AS col
                WHERE public.normalize_header(col) IN ('abono', 'abonos')
            ) THEN
                SELECT fp.profile_code
                INTO v_profile
                FROM public.file_profiles_d AS fp
                WHERE
                    LOWER(fp.bank_name) = LOWER(v_bank_name)
                    AND fp.active IS TRUE
                    AND fp.has_header IS TRUE
                    AND fp.dataset = v_dataset
                ORDER BY fp.profile_code
                LIMIT 1;
            END IF;
        END IF;

        IF v_profile IS NOT NULL THEN
            v_first_row := v_record.fields;
            v_header_record_no := v_record.record_no;
            v_has_header := TRUE;
            EXIT;
        END IF;
    END LOOP;

    IF v_profile IS NULL THEN
        SELECT parsed.fields
        INTO v_first_row
        FROM public.parse_csv(v_csv, v_delim) AS parsed
        WHERE parsed.record_no = 1;
        IF v_first_row IS NULL THEN
            RAISE EXCEPTION 'The CSV has no movements' USING ERRCODE = '22P02';
        END IF;
        v_profile := public.detect_profile(v_bank_name, NULL, v_first_row);
        IF v_profile IS NOT NULL THEN
            SELECT dataset INTO v_prof_dataset FROM public.file_profiles_d WHERE profile_code = v_profile;
            IF v_prof_dataset IS DISTINCT FROM v_dataset THEN
                v_profile := NULL;
            END IF;
        END IF;
        IF v_profile IS NOT NULL THEN
            v_has_header := FALSE;
            v_header_record_no := 0;
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
    -- BBVA (section 4b): "Pagos N de M" counts payments made, due on the purchase day.
    IF v_amount_rule = 'installment' AND v_col_map ? 'pagos_hechos' THEN
        v_amount_rule := 'installment_paid';
    END IF;

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
        WHERE parsed.record_no > COALESCE(v_header_record_no, 0)
    LOOP
        v_fields := v_record.fields;
        IF CARDINALITY(v_fields) = 1 AND BTRIM(v_fields[1]) = '' THEN
            CONTINUE;
        END IF;

        -- Skip BBVA Digital/Titular split markers and short preamble/footer rows.
        IF public.is_statement_skip_row(v_fields) THEN
            CONTINUE;
        END IF;

        IF v_has_header AND CARDINALITY(v_fields) < 3 THEN
            CONTINUE;
        END IF;

        IF (NOT v_has_header) AND CARDINALITY(v_fields) <> v_prof_col_count THEN
            RAISE EXCEPTION 'Row % does not match the header', v_record.record_no USING ERRCODE = '22P02';
        END IF;

        IF v_has_header THEN
            IF v_dataset = 'credit_plan' THEN
                v_date_text := BTRIM(v_fields[public.header_field_index(v_index, VARIADIC ARRAY['fecha de operacion', 'fecha'])]);
                -- BBVA writes "06 jul. 2026".
                v_date_text := COALESCE(TO_CHAR(public.spanish_short_date(v_date_text), 'DD/MM/YYYY'), v_date_text);
            ELSE
                v_date_text := BTRIM(v_fields[public.header_field_index(v_index, VARIADIC ARRAY['fecha', 'date'])]);
            END IF;
            v_concept := v_fields[public.header_field_index(v_index, VARIADIC ARRAY['concepto', 'descripcion', 'description', 'concept'])];
        ELSE
            v_date_text := BTRIM(v_fields[(v_col_map ->> 'txn_date')::INTEGER + 1]);
            v_concept := v_fields[(v_col_map ->> 'concept')::INTEGER + 1];
        END IF;

        -- Non-date first movement cell after header => skip (section leftovers).
        IF v_date_text IS NULL OR v_date_text = '' THEN
            CONTINUE;
        END IF;
        IF NOT (
            v_date_text ~ '^\d{4}-\d{2}-\d{2}$'
            OR v_date_text ~ '^\d{2}/\d{2}/\d{4}$'
        ) THEN
            CONTINUE;
        END IF;
        IF BTRIM(COALESCE(v_concept, '')) = '' THEN
            CONTINUE;
        END IF;
        IF v_date_text ~ '^\d{4}-\d{2}-\d{2}$' THEN
            v_date := v_date_text::DATE;
        ELSE
            v_date := TO_DATE(v_date_text, 'DD/MM/YYYY');
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
            v_cargos := ROUND(COALESCE(public.parse_amount(v_fields[public.header_field_index(v_index, VARIADIC ARRAY['cargos', 'cargo', 'outcome'])]), 0), 2);
            v_abonos := ROUND(COALESCE(public.parse_amount(v_fields[public.header_field_index(v_index, VARIADIC ARRAY['abonos', 'abono', 'income'])]), 0), 2);
            BEGIN
                v_saldos := ROUND(public.parse_amount(v_fields[public.header_field_index(v_index, VARIADIC ARRAY['saldos', 'saldo', 'balance'])]), 2);
            EXCEPTION WHEN OTHERS THEN
                v_saldos := NULL;
            END;
            IF v_saldos IS NULL THEN
                RAISE EXCEPTION 'Row % is missing a debit amount', v_record.record_no USING ERRCODE = '22P02';
            END IF;
            v_amount := v_cargos + v_abonos;
        ELSIF v_amount_rule = 'split_positive_credit' THEN
            v_abono := ROUND(ABS(COALESCE(public.parse_amount(v_fields[public.header_field_index(v_index, VARIADIC ARRAY['abono', 'abonos', 'income'])]), 0)), 2);
            v_cargo := ROUND(ABS(COALESCE(public.parse_amount(v_fields[public.header_field_index(v_index, VARIADIC ARRAY['cargo', 'cargos', 'outcome'])]), 0)), 2);
            BEGIN
                v_tarjeta := COALESCE(v_fields[public.header_field_index(v_index, VARIADIC ARRAY['tarjeta', 'card', 'card_ref'])], '');
            EXCEPTION WHEN OTHERS THEN
                v_tarjeta := '';
            END;
            v_amount := v_cargo - v_abono;
            v_cargos := -v_cargo;
            v_abonos := v_abono;
            v_saldos := NULL;
        ELSIF v_amount_rule = 'split_credit_abs_income' THEN
            v_abono := ROUND(ABS(COALESCE(public.parse_amount(v_fields[public.header_field_index(v_index, VARIADIC ARRAY['abono', 'abonos', 'income'])]), 0)), 2);
            v_cargo := ROUND(ABS(COALESCE(public.parse_amount(v_fields[public.header_field_index(v_index, VARIADIC ARRAY['cargo', 'cargos', 'outcome'])]), 0)), 2);
            v_tarjeta := '';
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
            -- "Pagos pendientes" NN/MM: NN payments still due, MM payments in the plan.
            v_pagos_restantes := public.installment_remaining(v_pagos);
            v_pagos_totales := public.installment_total(v_pagos);
            IF v_pagos_restantes IS NULL OR v_pagos_totales IS NULL OR v_pagos_restantes > v_pagos_totales THEN
                RAISE EXCEPTION 'Row % has an unreadable pagos pendientes %', v_record.record_no, v_pagos
                    USING ERRCODE = '22P02';
            END IF;
            IF v_mensualidad <= 0 THEN
                RAISE EXCEPTION 'Row % has no monthly payment', v_record.record_no USING ERRCODE = '22P02';
            END IF;
            v_pagos_hechos := v_pagos_totales - v_pagos_restantes;
            v_cargo := v_mensualidad;
            v_abono := 0.00;
            v_tarjeta := '';
            v_amount := v_cargo - v_abono;
        ELSIF v_amount_rule = 'installment_paid' THEN
            -- BBVA: "Pagos N de M" = N payments already made out of M.
            v_inicial := ROUND(public.parse_amount(public.undouble_amount(
                v_fields[public.header_field_index(v_index, VARIADIC ARRAY['compra'])]
            )), 2);
            v_mensualidad := ROUND(public.parse_amount(public.undouble_amount(
                v_fields[public.header_field_index(v_index, VARIADIC ARRAY['mensualidad'])]
            )), 2);
            v_pendiente := ROUND(public.parse_amount(public.undouble_amount(
                v_fields[public.header_field_index(v_index, VARIADIC ARRAY['saldo actual', 'saldo'])]
            )), 2);
            v_tasa := COALESCE(ROUND(public.parse_amount(REPLACE(public.undouble_amount(
                v_fields[public.header_field_index(v_index, VARIADIC ARRAY['interes', 'tasa anual'])]
            ), '%', '')), 4), 0);
            v_pagos := BTRIM(v_fields[public.header_field_index(v_index, VARIADIC ARRAY['pagos'])]);
            SELECT counts.paid, counts.total
            INTO v_pagos_hechos, v_pagos_totales
            FROM public.installment_paid_counts(v_pagos) AS counts;
            IF v_inicial IS NULL OR v_pendiente IS NULL OR v_mensualidad IS NULL OR v_mensualidad <= 0 THEN
                RAISE EXCEPTION 'Row % is missing an installment amount', v_record.record_no
                    USING ERRCODE = '22P02';
            END IF;
            IF v_pagos_hechos IS NULL OR v_pagos_totales IS NULL OR v_pagos_hechos > v_pagos_totales
                OR v_pagos_totales < 1
            THEN
                RAISE EXCEPTION 'Row % has an unreadable pagos %', v_record.record_no, v_pagos
                    USING ERRCODE = '22P02';
            END IF;
            v_pagos_restantes := v_pagos_totales - v_pagos_hechos;
            IF v_pagos_restantes = 0 THEN
                -- Paid off: nothing left to plan.
                CONTINUE;
            END IF;
            IF ABS(v_pendiente - v_pagos_restantes * v_mensualidad) >= 1.00 THEN
                RAISE EXCEPTION 'Row %: saldo actual % does not match % pending payments of %',
                    v_record.record_no, v_pendiente, v_pagos_restantes, v_mensualidad
                    USING ERRCODE = '22P02';
            END IF;
            v_cargo := v_mensualidad;
            v_abono := 0.00;
            v_tarjeta := '';
            v_amount := v_cargo - v_abono;
        ELSE
            RAISE EXCEPTION 'Unknown amount rule %', v_amount_rule USING ERRCODE = '22P02';
        END IF;

        v_parsed_rows := ARRAY_APPEND(
            v_parsed_rows,
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
                'importe_pendiente', v_pendiente,
                'pagos_restantes', v_pagos_restantes,
                'pagos_totales', v_pagos_totales,
                'pagos_hechos', v_pagos_hechos,
                'schedule', CASE WHEN v_amount_rule = 'installment_paid' THEN 'purchase_day' ELSE 'next_cutoff' END,
                'mensualidad', v_mensualidad,
                'amount', v_amount
            )::TEXT
        );
    END LOOP;

    v_source_rows := CARDINALITY(v_parsed_rows);
    IF v_source_rows = 0 THEN
        RAISE EXCEPTION 'The CSV has no movements' USING ERRCODE = '22P02';
    END IF;

    -- Final rows: one per stored movement, with its own period, occurrence and hash.
    IF v_ledger = 'future' THEN
        -- Expand each plan into its remaining payments, dated on the next cutoff dates
        -- strictly after the as-of date (never the purchase date). The last payment
        -- absorbs a sub-peso rounding gap so the plan sums to importe pendiente.
        WITH src AS (
            SELECT
                (elem::JSONB ->> 'record_no')::INTEGER AS record_no,
                (elem::JSONB ->> 'concept') AS concept,
                (elem::JSONB ->> 'concept_sk') AS concept_sk,
                (elem::JSONB ->> 'importe_pendiente')::NUMERIC(18, 2) AS pendiente,
                (elem::JSONB ->> 'mensualidad')::NUMERIC(18, 2) AS mensualidad,
                (elem::JSONB ->> 'pagos_restantes')::INTEGER AS restantes,
                COALESCE((elem::JSONB ->> 'pagos_hechos')::INTEGER, 0) AS hechos,
                (elem::JSONB ->> 'txn_date')::DATE AS purchase_date,
                COALESCE(elem::JSONB ->> 'schedule', 'next_cutoff') AS schedule_kind
            FROM UNNEST(v_parsed_rows) AS elem
        ),
        scheduled AS (
            -- Banorte (and the default): NN payments left, one per cutoff after as-of.
            SELECT
                src.*,
                schedule.payment_no,
                schedule.period_end AS txn_date,
                schedule.period_start,
                schedule.period_end
            FROM src
            CROSS JOIN LATERAL public.future_cutoff_periods(v_cutoff_day, v_as_of, src.restantes) AS schedule
            WHERE
                src.schedule_kind = 'next_cutoff'
                AND schedule.period_end > v_as_of
            UNION ALL
            -- BBVA: payment k falls on purchase date + (k - 1) months. The bank still
            -- lists these as pending, so a date on or before as-of is kept as is.
            SELECT
                src.*,
                pending.payment_no,
                pending.due_date AS txn_date,
                bounds.period_start,
                bounds.period_end
            FROM src
            CROSS JOIN LATERAL (
                SELECT
                    step.n AS payment_no,
                    (src.purchase_date + MAKE_INTERVAL(months => src.hechos + step.n - 1))::DATE AS due_date
                FROM GENERATE_SERIES(1, src.restantes) AS step (n)
            ) AS pending
            CROSS JOIN LATERAL public.current_period(TRUE, v_cutoff_day, pending.due_date) AS bounds
            WHERE src.schedule_kind = 'purchase_day'
        ),
        expanded AS (
            SELECT
                sch.record_no * 1000 + sch.payment_no AS record_no,
                sch.txn_date,
                sch.period_start,
                sch.period_end,
                sch.concept,
                sch.concept_sk,
                CASE
                    WHEN sch.payment_no = sch.restantes
                        AND ABS(sch.pendiente - sch.restantes * sch.mensualidad) < 1.00
                        AND sch.pendiente - (sch.restantes - 1) * sch.mensualidad > 0
                        THEN sch.pendiente - (sch.restantes - 1) * sch.mensualidad
                    ELSE sch.mensualidad
                END::NUMERIC(18, 2) AS cargo
            FROM scheduled AS sch
        ),
        numbered AS (
            SELECT
                e.*,
                (ROW_NUMBER() OVER (
                    PARTITION BY e.txn_date, e.concept_sk, e.cargo
                    ORDER BY e.record_no
                ))::INTEGER AS occurrence
            FROM expanded AS e
        )
        SELECT COALESCE(
            JSONB_AGG(
                JSONB_BUILD_OBJECT(
                    'record_no', n.record_no,
                    'txn_date', n.txn_date,
                    'period_start', n.period_start,
                    'period_end', n.period_end,
                    'concept', n.concept,
                    'concept_sk', n.concept_sk,
                    'abono', 0.00,
                    'cargo', n.cargo,
                    'tarjeta', '',
                    'amount', n.cargo,
                    'occurrence', n.occurrence,
                    'row_hash', public.movement_row_hash_v2(
                        v_user, p_account_id, v_bank_id, n.txn_date, n.concept_sk, 0.00, n.cargo, n.occurrence
                    )
                )
                ORDER BY n.txn_date, n.record_no
            ),
            '[]'::JSONB
        )
        INTO v_final_rows
        FROM numbered AS n;

        IF JSONB_ARRAY_LENGTH(v_final_rows) = 0 THEN
            -- Nothing due after the as-of date: keep the account's current future rows.
            RAISE EXCEPTION 'The installment file has no payments due after %', v_as_of
                USING ERRCODE = '22P02';
        END IF;
    ELSE
        WITH raw_rows AS (
            SELECT
                elem::JSONB AS item,
                (elem::JSONB ->> 'record_no')::INTEGER AS record_no,
                (elem::JSONB ->> 'txn_date')::DATE AS txn_date,
                (elem::JSONB ->> 'concept_sk') AS concept_sk,
                -- The amounts exactly as the target table stores them (sql/014):
                -- debit cargos <= 0 and abonos >= 0; credit cargos and abonos both >= 0.
                CASE
                    WHEN v_kind = 'credit' THEN (elem::JSONB ->> 'abono')::NUMERIC(18, 2)
                    ELSE (elem::JSONB ->> 'abonos')::NUMERIC(18, 2)
                END AS abonos,
                CASE
                    WHEN v_kind = 'credit' THEN (elem::JSONB ->> 'cargo')::NUMERIC(18, 2)
                    ELSE (elem::JSONB ->> 'cargos')::NUMERIC(18, 2)
                END AS cargos
            FROM UNNEST(v_parsed_rows) AS elem
        ),
        numbered AS (
            SELECT
                r.*,
                (ROW_NUMBER() OVER (
                    PARTITION BY r.txn_date, r.concept_sk, r.abonos, r.cargos
                    ORDER BY r.record_no
                ))::INTEGER AS occurrence
            FROM raw_rows AS r
        )
        SELECT JSONB_AGG(
            n.item || JSONB_BUILD_OBJECT(
                'period_start', v_period_start,
                'period_end', v_period_end,
                'occurrence', n.occurrence,
                'row_hash', public.movement_row_hash_v2(
                    v_user, p_account_id, v_bank_id, n.txn_date, n.concept_sk, n.abonos, n.cargos, n.occurrence
                )
            )
            ORDER BY n.record_no
        )
        INTO v_final_rows
        FROM numbered AS n;
    END IF;
    v_rows := JSONB_ARRAY_LENGTH(v_final_rows);

    IF v_ledger = 'closed' THEN
        -- Closed masters stay append-only: any hash already stored means a repeat file.
        EXECUTE FORMAT(
            'SELECT EXISTS (
                SELECT 1
                FROM JSONB_ARRAY_ELEMENTS($1) AS incoming (item)
                INNER JOIN public.%I AS existing
                    ON existing.account_id = $2
                    AND existing.row_hash = incoming.item ->> ''row_hash''
            )',
            v_closed_table
        )
        INTO v_duplicate
        USING v_final_rows, p_account_id;
        IF v_duplicate THEN
            RAISE EXCEPTION 'already uploaded' USING ERRCODE = '23505';
        END IF;
    END IF;

    -- Replace: drop the rows and upload records this upload supersedes.
    --   closed:  a stale open upload on this same period (it has closed since).
    --   open:    every open upload of this account for this dataset.
    --   future:  every future upload of this account.
    FOR v_stale IN
        SELECT upload.upload_id, upload.ledger_state
        FROM public.statement_uploads_f AS upload
        WHERE
            upload.account_id = p_account_id
            AND upload.tenant_id = v_tenant
            AND upload.user_id = v_user
            AND upload.dataset = v_dataset
            AND (
                (v_ledger = 'closed' AND upload.ledger_state = 'open' AND upload.cutoff_id = p_cutoff_id)
                OR (v_ledger = 'open' AND upload.ledger_state = 'open')
                OR (v_ledger = 'future' AND upload.ledger_state = 'future')
            )
    LOOP
        IF v_stale.ledger_state = 'open' THEN
            DELETE FROM public.master_debit_open_f WHERE file_id = v_stale.upload_id;
            DELETE FROM public.master_credit_open_f WHERE file_id = v_stale.upload_id;
        ELSE
            DELETE FROM public.master_credit_future_f WHERE file_id = v_stale.upload_id;
        END IF;
        DELETE FROM public.statement_uploads_f WHERE upload_id = v_stale.upload_id;
        v_replaced := v_replaced + 1;
    END LOOP;
    IF v_ledger IN ('open', 'future') THEN
        -- Per-account replace (never the whole table: other accounts keep their rows).
        EXECUTE FORMAT(
            'DELETE FROM public.%I WHERE account_id = $1 AND tenant_id = $2 AND user_id = $3',
            v_table
        )
        USING p_account_id, v_tenant, v_user;
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
        source_profile,
        period_ym,
        ledger_state
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
        v_profile,
        v_period_ym,
        v_ledger
    );

    IF v_table IN ('master_debit_closed_f', 'master_debit_open_f') THEN
        EXECUTE FORMAT(
            'INSERT INTO public.%I (
                file_id, tenant_id, user_id, account_id, bank_id, account_number, bank_name, file_name,
                period_start, period_end, txn_date, concept, concept_sk,
                cargos, abonos, saldos, amount, occurrence, row_hash, source_profile
            )
            SELECT
                $1, $2, $3, $4, $10, $5, $6, $7,
                (item ->> ''period_start'')::DATE,
                (item ->> ''period_end'')::DATE,
                (item ->> ''txn_date'')::DATE,
                item ->> ''concept'',
                item ->> ''concept_sk'',
                (item ->> ''cargos'')::NUMERIC(18, 2),
                (item ->> ''abonos'')::NUMERIC(18, 2),
                (item ->> ''saldos'')::NUMERIC(18, 2),
                (item ->> ''amount'')::NUMERIC(18, 2),
                (item ->> ''occurrence'')::INTEGER,
                item ->> ''row_hash'',
                $8
            FROM JSONB_ARRAY_ELEMENTS($9) AS src_rows (item)',
            v_table
        )
        USING
            v_upload_id, v_tenant, v_user, p_account_id, v_account_number, v_bank_name,
            v_filename, v_profile, v_final_rows, v_bank_id;
    ELSE
        EXECUTE FORMAT(
            'INSERT INTO public.%I (
                file_id, tenant_id, user_id, account_id, bank_id, account_number, bank_name, file_name,
                period_start, period_end, txn_date, concept, concept_sk,
                abonos, cargos, tarjeta, amount, occurrence, row_hash, source_profile
            )
            SELECT
                $1, $2, $3, $4, $10, $5, $6, $7,
                (item ->> ''period_start'')::DATE,
                (item ->> ''period_end'')::DATE,
                (item ->> ''txn_date'')::DATE,
                item ->> ''concept'',
                item ->> ''concept_sk'',
                (item ->> ''abono'')::NUMERIC(18, 2),
                (item ->> ''cargo'')::NUMERIC(18, 2),
                COALESCE(item ->> ''tarjeta'', ''''),
                (item ->> ''amount'')::NUMERIC(18, 2),
                (item ->> ''occurrence'')::INTEGER,
                item ->> ''row_hash'',
                $8
            FROM JSONB_ARRAY_ELEMENTS($9) AS src_rows (item)',
            v_table
        )
        USING
            v_upload_id, v_tenant, v_user, p_account_id, v_account_number, v_bank_name,
            v_filename, v_profile, v_final_rows, v_bank_id;
    END IF;

    -- Dimensions carry over by hash across closed, open and future rows.
    INSERT INTO public.movement_dimensions_d (tenant_id, row_hash, user_id, account_id)
    SELECT v_tenant, incoming.item ->> 'row_hash', v_user, p_account_id
    FROM JSONB_ARRAY_ELEMENTS(v_final_rows) AS incoming (item)
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
        'source_row_count', v_source_rows,
        'dataset', v_dataset,
        'ledger_state', v_ledger,
        'target_table', v_table,
        'replaced_uploads', v_replaced,
        'profile', v_profile,
        'curated_csv_backup', v_curated,
        'tenant_id', v_tenant,
        'file_suffix', 'csv',
        'original_filename', v_filename,
        'bank_name', v_bank_name,
        'bank_id', v_bank_id,
        'account_number', v_account_number,
        'period_ym', v_period_ym,
        'cutoff_id', p_cutoff_id
    );
END
$fn$;

CREATE OR REPLACE FUNCTION public.update_bank_account_cutoff(
    p_account_id INTEGER,
    p_cutoff_day INTEGER,
    p_credit_days INTEGER,
    p_as_of DATE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_as_of DATE := COALESCE(p_as_of, CURRENT_DATE);
    v_allows BOOLEAN;
    v_account_number TEXT;
    v_old_day INTEGER;
    v_old_days INTEGER;
    v_cleared INTEGER := 0;
    v_moved JSONB := '[]'::JSONB;
    v_redated INTEGER := 0;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    SELECT kind.allows_cutoff, account.account_number, account.account_cutoff_day, account.credit_days
    INTO v_allows, v_account_number, v_old_day, v_old_days
    FROM public.bank_accounts_d AS account
    INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
    WHERE
        account.account_id = p_account_id
        AND account.tenant_id = v_tenant
        AND account.user_id = v_user
    FOR UPDATE OF account;

    IF v_allows IS NULL THEN
        RAISE EXCEPTION 'account not found' USING ERRCODE = 'P0002';
    END IF;
    IF NOT v_allows THEN
        RAISE EXCEPTION 'Debit accounts do not have a cutoff day or payment window'
            USING ERRCODE = '23514';
    END IF;
    IF p_cutoff_day IS NULL OR p_cutoff_day < 1 OR p_cutoff_day > 31 THEN
        RAISE EXCEPTION 'Credit card accounts require a cutoff day from 1 to 31'
            USING ERRCODE = '23514';
    END IF;
    IF p_credit_days IS NULL OR p_credit_days < 1 OR p_credit_days > 90 THEN
        RAISE EXCEPTION 'Credit card accounts require a payment window from 1 to 90 days'
            USING ERRCODE = '23514';
    END IF;

    UPDATE public.bank_accounts_d
    SET
        account_cutoff_day = p_cutoff_day,
        credit_days = p_credit_days
    WHERE
        account_id = p_account_id
        AND tenant_id = v_tenant
        AND user_id = v_user;

    IF p_cutoff_day IS DISTINCT FROM v_old_day THEN
        -- Empty periods were planned on the old day: drop them and re-plan.
        DELETE FROM public.cutoff_date_f AS cutoff
        WHERE
            cutoff.account_id = p_account_id
            AND cutoff.tenant_id = v_tenant
            AND cutoff.user_id = v_user
            AND NOT EXISTS (
                SELECT 1
                FROM public.statement_uploads_f AS upload
                WHERE upload.cutoff_id = cutoff.cutoff_id
            );
        GET DIAGNOSTICS v_cleared = ROW_COUNT;

        -- Future MSI still due after the as-of date: the k-th remaining payment date
        -- moves to the k-th new cutoff after the as-of date. Rows already due stay.
        WITH remaining AS (
            SELECT future_row.*
            FROM public.master_credit_future_f AS future_row
            WHERE
                future_row.account_id = p_account_id
                AND future_row.tenant_id = v_tenant
                AND future_row.user_id = v_user
                AND future_row.txn_date > v_as_of
                AND NOT EXISTS (
                    SELECT 1
                    FROM public.file_profiles_d AS profile
                    WHERE
                        profile.profile_code = future_row.source_profile
                        AND profile.column_map ? 'pagos_hechos'
                )
        ),
        old_dates AS (
            SELECT
                dated.txn_date,
                (ROW_NUMBER() OVER (ORDER BY dated.txn_date))::INTEGER AS payment_no
            FROM (SELECT DISTINCT remaining.txn_date FROM remaining) AS dated
        ),
        schedule AS (
            SELECT planned.payment_no, planned.period_start, planned.period_end
            FROM public.future_cutoff_periods(
                p_cutoff_day,
                v_as_of,
                (SELECT COUNT(*)::INTEGER FROM old_dates)
            ) AS planned
        ),
        moved AS (
            SELECT
                remaining.*,
                schedule.period_start AS new_start,
                schedule.period_end AS new_date,
                (ROW_NUMBER() OVER (
                    PARTITION BY schedule.period_end, remaining.concept_sk, remaining.abonos, remaining.cargos
                    ORDER BY remaining.row_id
                ))::INTEGER AS new_occurrence
            FROM remaining
            INNER JOIN old_dates ON old_dates.txn_date = remaining.txn_date
            INNER JOIN schedule ON schedule.payment_no = old_dates.payment_no
        )
        SELECT COALESCE(
            JSONB_AGG(
                JSONB_BUILD_OBJECT(
                    'row_id', moved.row_id,
                    'file_id', moved.file_id,
                    'bank_name', moved.bank_name,
                    'file_name', moved.file_name,
                    'period_start', moved.new_start,
                    'period_end', moved.new_date,
                    'txn_date', moved.new_date,
                    'concept', moved.concept,
                    'concept_sk', moved.concept_sk,
                    'bank_id', moved.bank_id,
                    'abonos', moved.abonos,
                    'cargos', moved.cargos,
                    'tarjeta', moved.tarjeta,
                    'amount', moved.amount,
                    'occurrence', moved.new_occurrence,
                    'old_hash', moved.row_hash,
                    'row_hash', public.movement_row_hash_v2(
                        moved.user_id, moved.account_id, moved.bank_id, moved.new_date, moved.concept_sk,
                        moved.abonos, moved.cargos, moved.new_occurrence
                    ),
                    'source_profile', moved.source_profile
                )
            ),
            '[]'::JSONB
        )
        INTO v_moved
        FROM moved;

        v_redated := JSONB_ARRAY_LENGTH(v_moved);
        IF v_redated > 0 THEN
            DELETE FROM public.master_credit_future_f AS future_row
            WHERE future_row.row_id IN (
                SELECT (item ->> 'row_id')::BIGINT
                FROM JSONB_ARRAY_ELEMENTS(v_moved) AS moved_rows (item)
            );
            INSERT INTO public.master_credit_future_f (
                file_id, tenant_id, user_id, account_id, bank_id, account_number, bank_name, file_name,
                period_start, period_end, txn_date, concept, concept_sk,
                abonos, cargos, tarjeta, amount, occurrence, row_hash, source_profile
            )
            SELECT
                (item ->> 'file_id')::UUID,
                v_tenant,
                v_user,
                p_account_id,
                (item ->> 'bank_id')::INTEGER,
                v_account_number,
                item ->> 'bank_name',
                item ->> 'file_name',
                (item ->> 'period_start')::DATE,
                (item ->> 'period_end')::DATE,
                (item ->> 'txn_date')::DATE,
                item ->> 'concept',
                item ->> 'concept_sk',
                (item ->> 'abonos')::NUMERIC(18, 2),
                (item ->> 'cargos')::NUMERIC(18, 2),
                item ->> 'tarjeta',
                (item ->> 'amount')::NUMERIC(18, 2),
                (item ->> 'occurrence')::INTEGER,
                item ->> 'row_hash',
                item ->> 'source_profile'
            FROM JSONB_ARRAY_ELEMENTS(v_moved) AS moved_rows (item);

            INSERT INTO public.movement_dimensions_d (tenant_id, row_hash, user_id, account_id)
            SELECT v_tenant, item ->> 'row_hash', v_user, p_account_id
            FROM JSONB_ARRAY_ELEMENTS(v_moved) AS moved_rows (item)
            ON CONFLICT (tenant_id, row_hash) DO NOTHING;

            PERFORM public.movement_rekeyed(
                (
                    SELECT JSONB_AGG(JSONB_BUILD_OBJECT('old_hash', item ->> 'old_hash', 'new_hash', item ->> 'row_hash'))
                    FROM JSONB_ARRAY_ELEMENTS(v_moved) AS moved_rows (item)
                )
            );
        END IF;
    END IF;

    -- BBVA-style plans (profile column_map has pagos_hechos, sql/011 4b) are due on the purchase day, not
    -- on a cutoff: their dates stay, only the period that contains each date follows
    -- the new cutoff day.
    IF v_allows THEN
        UPDATE public.master_credit_future_f AS future_row
        SET
            period_start = (public.current_period(TRUE, p_cutoff_day, future_row.txn_date)).period_start,
            period_end = (public.current_period(TRUE, p_cutoff_day, future_row.txn_date)).period_end
        FROM public.file_profiles_d AS profile
        WHERE
            future_row.account_id = p_account_id
            AND future_row.tenant_id = v_tenant
            AND future_row.user_id = v_user
            AND profile.profile_code = future_row.source_profile
            AND profile.column_map ? 'pagos_hechos';
    END IF;

    PERFORM public.refresh_statement_periods(p_account_id, v_as_of);

    RETURN JSONB_BUILD_OBJECT(
        'account_id', p_account_id,
        'account_cutoff_day', p_cutoff_day,
        'credit_days', p_credit_days,
        'previous_cutoff_day', v_old_day,
        'previous_credit_days', v_old_days,
        'empty_periods_replanned', v_cleared,
        'frozen_periods', (
            SELECT COUNT(*)
            FROM public.cutoff_date_f AS cutoff
            WHERE
                cutoff.account_id = p_account_id
                AND cutoff.user_id = v_user
                AND EXISTS (
                    SELECT 1
                    FROM public.statement_uploads_f AS upload
                    WHERE upload.cutoff_id = cutoff.cutoff_id
                )
        ),
        'future_rows_redated', v_redated
    );
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
    DELETE FROM public.master_debit_open_f
    WHERE file_id = p_upload_id;
    DELETE FROM public.master_credit_open_f
    WHERE file_id = p_upload_id;
    DELETE FROM public.master_credit_future_f
    WHERE file_id = p_upload_id;
    DELETE FROM public.upload_delete_guard
    WHERE upload_id = p_upload_id;
    DELETE FROM public.statement_uploads_f
    WHERE upload_id = p_upload_id;
END
$fn$;

-- =============================================================================
-- 5. Soft key view over the five masters (for the dimensions page)
-- =============================================================================
-- security_invoker: the caller's row level security on each master applies.
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
FROM public.master_credit_future_f AS movement;

COMMENT ON VIEW public.movement_keys_v IS
'One row per stored movement across the five masters: row_hash with its layer (closed, open, '
'future), kind (debit, credit), key inputs and readable columns (saldos is debit only, tarjeta '
'credit only). Future installments are credit-card rows.';

-- =============================================================================
-- 6. Grants
-- =============================================================================
REVOKE ALL ON FUNCTION public.movement_amount_text(NUMERIC) FROM PUBLIC;
REVOKE ALL ON FUNCTION
public.movement_row_hash_v2(UUID, INTEGER, INTEGER, DATE, TEXT, NUMERIC, NUMERIC, INTEGER)
FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.movement_amount_text(NUMERIC) TO strm_app;
GRANT EXECUTE ON FUNCTION
public.movement_row_hash_v2(UUID, INTEGER, INTEGER, DATE, TEXT, NUMERIC, NUMERIC, INTEGER)
TO strm_app;
REVOKE ALL ON public.movement_keys_v FROM PUBLIC;
GRANT SELECT ON public.movement_keys_v TO strm_app;
REVOKE ALL ON FUNCTION public.ingest_statement_csv(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ingest_statement_csv(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE, TEXT, TEXT) TO strm_app;
REVOKE ALL ON FUNCTION public.update_bank_account_cutoff(INTEGER, INTEGER, INTEGER, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.statement_home(DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.statement_home(DATE) TO strm_app;
REVOKE ALL ON FUNCTION public.delete_statement_upload(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_statement_upload(UUID) TO strm_app;
REVOKE ALL ON FUNCTION public.movement_rekeyed(JSONB) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.update_bank_account_cutoff(INTEGER, INTEGER, INTEGER, DATE) TO strm_app;
