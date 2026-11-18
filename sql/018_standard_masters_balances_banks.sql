-- sqlfluff:exclude_rules: JJ01,LT01,LT02,LT05,CP02,CP03,CP04,CP05,RF04,RF06,AM04
-- sql/018: one column layout for every master_*_f table, opening balances and monthly
-- adjustments for any account, banks users can add, rename, and remove, and moving an account to
-- another bank. See docs/standard_masters.md.
--
--   * Every master (master_debit_open_f, master_debit_closed_f, master_credit_open_f,
--     master_credit_closed_f, master_credit_future_f, master_closed_aaccandass_f) is rebuilt
--     with the same leading columns, in this order:
--         row_id | file_id, tenant_id, user_id, account_id, bank_id, cutoff_id |
--         txn_date, concept, abonos, cargos | amount, concept_sk, row_hash
--     followed by occurrence, entry_source, note, created_at, created_by. Debit and credit
--     masters have that same column list. Assets add source_line and reported_balance.
--     saldos and tarjeta are not stored. account_number, bank_name, file_name, source_profile,
--     period_start and period_end are not stored on the row: movement_keys_v reads file_name
--     and source_profile from statement_uploads_f (assets: aaccandass_uploads_f) and the other
--     names from bank_accounts_d, banks_d and cutoff_date_f.
--   * Signs stay as they were. Debit cargos are stored <= 0 and amount = abonos + cargos.
--     Credit cargos are stored >= 0 and amount = abonos - cargos (a purchase is negative;
--     before 018 credit amount was cargos - abonos). Assets keep both amounts >= 0, like
--     credit, so amount = abonos - cargos. Opening and adjustment rows use the same signs.
--   * concept_sk: the digits of the concept or, with no digit, its letters A-Z upper-cased
--     with accents folded (Á -> A, Ñ -> N).
--   * row_hash keeps sql/014's inputs (user, account, bank, date, concept_sk, abonos, cargos,
--     occurrence). Debit cargos keep their sign. The new concept_sk changes some hashes: every old
--     -> new pair is written to row_hash_remap_f and debit_d, credit_d,
--     master_closed_aaccandass_d (with their list items), movement_dimensions_d,
--     inter_accounts_d and aaccandass_checks_f follow it.
--   * cutoff_id: cutoff_date_f (sql/006/012) gives period_start / period_end. Statement rows
--     take their upload's cutoff; installment rows and investment / asset rows get a
--     cutoff_date_f row with period_source = 'ledger' when no statement period exists for
--     that month (the Statements page and completeness only read period_source =
--     'statement').
--   * entry_source: 'upload' (file_id set) or 'opening' / 'adjustment' (file_id null; closed
--     tables only); assets also 'manual'. Opening and adjustment rows live in the closed
--     masters, so GraphQL, Sheets, dimensions and balances see them with no union, and the
--     transfer finder skips them.
--
-- Forward-only and safe to run more than once: a table already in the new layout is left
-- alone. After this migration do not re-run 006-017 (their old column lists no longer fit):
-- the config console and the test helper skip them and re-apply this file instead.
-- Apply on Neon by hand after 017, as the table owner.

-- =============================================================================
-- 1. concept_sk, cutoff source, hash remap registry
-- =============================================================================
CREATE OR REPLACE FUNCTION public.concept_sk(p_concept TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE
        WHEN cleaned.concept ~ '[0-9]' THEN REGEXP_REPLACE(cleaned.concept, '[^0-9]', '', 'g')
        -- Keep ASCII letters first, then upper-case (the same in every locale).
        ELSE UPPER(REGEXP_REPLACE(
            TRANSLATE(
                cleaned.concept,
                'ÁÀÂÄÃÅáàâäãåÉÈÊËéèêëÍÌÎÏíìîïÓÒÔÖÕóòôöõÚÙÛÜúùûüÑñÇç',
                'AAAAAAaaaaaaEEEEeeeeIIIIiiiiOOOOOoooooUUUUuuuuNnCc'
            ),
            '[^A-Za-z]', '', 'g'
        ))
    END
    FROM (
        SELECT BTRIM(REPLACE(REPLACE(COALESCE(p_concept, ''), CHR(160), ' '), CHR(65279), '')) AS concept
    ) AS cleaned
$fn$;

COMMENT ON FUNCTION public.concept_sk(TEXT) IS
'Concept key (sql/018): the digits of the trimmed concept, or when it has no digit its letters '
'A-Z, upper-cased, accents folded (Á -> A, Ñ -> N), everything else removed.';

ALTER TABLE public.cutoff_date_f
ADD COLUMN IF NOT EXISTS period_source TEXT NOT NULL DEFAULT 'statement';

DO $do$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.cutoff_date_f'::REGCLASS AND conname = 'cutoff_date_f_period_source_check'
    ) THEN
        ALTER TABLE public.cutoff_date_f
        ADD CONSTRAINT cutoff_date_f_period_source_check CHECK (period_source IN ('statement', 'ledger'));
    END IF;
END
$do$;

COMMENT ON COLUMN public.cutoff_date_f.period_source IS
'statement: a statement period (Statements page, completeness, uploads). ledger (sql/018): a '
'period that exists only so movements can point at it (installments due after the planned '
'periods, investment and asset months).';

-- Statement periods only: the Statements page, completeness and the period buttons read this.
CREATE OR REPLACE VIEW public.statement_cutoffs_v
WITH (security_invoker = TRUE) AS
SELECT cutoff.*
FROM public.cutoff_date_f AS cutoff
WHERE cutoff.period_source = 'statement';

CREATE TABLE IF NOT EXISTS public.row_hash_remap_f (
    remap_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch TEXT NOT NULL,
    reason TEXT NOT NULL,
    kind TEXT NOT NULL CHECK (kind IN ('debit', 'credit', 'asset')),
    source_table TEXT NOT NULL,
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    account_id INTEGER NOT NULL,
    old_hash TEXT NOT NULL CHECK (LENGTH(old_hash) = 64),
    new_hash TEXT NOT NULL CHECK (LENGTH(new_hash) = 64),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (batch, source_table, old_hash)
);
CREATE INDEX IF NOT EXISTS row_hash_remap_f_old_idx ON public.row_hash_remap_f (old_hash);
ALTER TABLE public.row_hash_remap_f ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.row_hash_remap_f FROM PUBLIC;

COMMENT ON TABLE public.row_hash_remap_f IS
'Every row_hash change (sql/018 layout, a bank change): old -> new per stored movement. '
'apply_row_hash_remap moves attributes, list items and transfer links to the new hash. '
'Owner only (no app grant).';

-- Cutoff for a movement period: the account's cutoff for the month of p_period_end, or a new
-- 'ledger' one. A ledger cutoff with no statement upload follows the requested dates;
-- statement periods are planned by refresh_statement_periods and are never moved here.
CREATE OR REPLACE FUNCTION public.ledger_cutoff_id(
    p_tenant UUID,
    p_user UUID,
    p_account_id INTEGER,
    p_period_start DATE,
    p_period_end DATE
) RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_cutoff RECORD;
    v_id INTEGER;
BEGIN
    IF p_period_start IS NULL OR p_period_end IS NULL OR p_period_start > p_period_end THEN
        RAISE EXCEPTION 'invalid period % - %', p_period_start, p_period_end USING ERRCODE = '22023';
    END IF;
    SELECT cutoff.cutoff_id, cutoff.period_start, cutoff.period_end, cutoff.period_source
    INTO v_cutoff
    FROM public.cutoff_date_f AS cutoff
    WHERE
        cutoff.account_id = p_account_id
        AND cutoff.cutoff_year = EXTRACT(YEAR FROM p_period_end)::INTEGER
        AND cutoff.cutoff_month = EXTRACT(MONTH FROM p_period_end)::INTEGER;
    IF v_cutoff.cutoff_id IS NOT NULL THEN
        IF v_cutoff.period_source = 'ledger'
            AND (v_cutoff.period_start, v_cutoff.period_end) IS DISTINCT FROM (p_period_start, p_period_end)
            AND NOT EXISTS (
                SELECT 1 FROM public.statement_uploads_f AS upload WHERE upload.cutoff_id = v_cutoff.cutoff_id
            )
        THEN
            UPDATE public.cutoff_date_f
            SET period_start = p_period_start, period_end = p_period_end, cutoff_date = p_period_end
            WHERE cutoff_id = v_cutoff.cutoff_id;
        END IF;
        RETURN v_cutoff.cutoff_id;
    END IF;
    INSERT INTO public.cutoff_date_f (
        account_id, user_id, tenant_id, cutoff_month, cutoff_year, is_required, cutoff_date,
        period_start, period_end, added_by_user, period_source
    )
    VALUES (
        p_account_id, p_user, p_tenant, EXTRACT(MONTH FROM p_period_end)::INTEGER,
        EXTRACT(YEAR FROM p_period_end)::INTEGER, FALSE, p_period_end, p_period_start, p_period_end,
        FALSE, 'ledger'
    )
    ON CONFLICT (account_id, cutoff_year, cutoff_month) DO NOTHING
    RETURNING cutoff_id INTO v_id;
    IF v_id IS NULL THEN
        SELECT cutoff.cutoff_id INTO v_id
        FROM public.cutoff_date_f AS cutoff
        WHERE
            cutoff.account_id = p_account_id
            AND cutoff.cutoff_year = EXTRACT(YEAR FROM p_period_end)::INTEGER
            AND cutoff.cutoff_month = EXTRACT(MONTH FROM p_period_end)::INTEGER;
    END IF;
    RETURN v_id;
END
$fn$;

-- Calendar month cutoff (investment and asset accounts).
CREATE OR REPLACE FUNCTION public.month_cutoff_id(p_tenant UUID, p_user UUID, p_account_id INTEGER, p_date DATE)
RETURNS INTEGER
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $fn$
    SELECT public.ledger_cutoff_id(
        p_tenant, p_user, p_account_id, DATE_TRUNC('month', p_date)::DATE,
        (DATE_TRUNC('month', p_date) + INTERVAL '1 month - 1 day')::DATE
    )
$fn$;

-- Is a cutoff used by an upload or a stored movement?
CREATE OR REPLACE FUNCTION public.cutoff_in_use(p_cutoff_id INTEGER)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
    RETURN EXISTS (SELECT 1 FROM public.statement_uploads_f AS upload WHERE upload.cutoff_id = p_cutoff_id)
        OR EXISTS (SELECT 1 FROM public.master_debit_closed_f AS m WHERE m.cutoff_id = p_cutoff_id)
        OR EXISTS (SELECT 1 FROM public.master_debit_open_f AS m WHERE m.cutoff_id = p_cutoff_id)
        OR EXISTS (SELECT 1 FROM public.master_credit_closed_f AS m WHERE m.cutoff_id = p_cutoff_id)
        OR EXISTS (SELECT 1 FROM public.master_credit_open_f AS m WHERE m.cutoff_id = p_cutoff_id)
        OR EXISTS (SELECT 1 FROM public.master_credit_future_f AS m WHERE m.cutoff_id = p_cutoff_id)
        OR EXISTS (SELECT 1 FROM public.master_closed_aaccandass_f AS m WHERE m.cutoff_id = p_cutoff_id);
END
$fn$;

-- Ledger cutoffs nobody points at any more (installments replaced, rows deleted).
CREATE OR REPLACE FUNCTION public.prune_ledger_cutoffs(p_account_id INTEGER)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_count INTEGER;
BEGIN
    DELETE FROM public.cutoff_date_f AS cutoff
    WHERE
        cutoff.account_id = p_account_id
        AND cutoff.period_source = 'ledger'
        AND NOT public.cutoff_in_use(cutoff.cutoff_id);
    GET DIAGNOSTICS v_count = ROW_COUNT;
    RETURN v_count;
END
$fn$;

REVOKE ALL ON FUNCTION public.ledger_cutoff_id(UUID, UUID, INTEGER, DATE, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.month_cutoff_id(UUID, UUID, INTEGER, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.prune_ledger_cutoffs(INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.cutoff_in_use(INTEGER) FROM PUBLIC;

-- Closed rows stay append-only. Two narrow exceptions, set for one transaction by the
-- functions that need them: moving an account to another bank re-keys its rows
-- (strm.rekey), and an opening / adjustment row (no file) can be deleted (strm.balance_row).
CREATE OR REPLACE FUNCTION public.reject_closed_row_update()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF COALESCE(CURRENT_SETTING('strm.rekey', TRUE), '') = 'on' THEN
        RETURN NEW;
    END IF;
    RAISE EXCEPTION 'closed statement rows are append-only' USING ERRCODE = '42501';
END
$fn$;

CREATE OR REPLACE FUNCTION public.reject_closed_row_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
    IF OLD.file_id IS NULL AND COALESCE(CURRENT_SETTING('strm.balance_row', TRUE), '') = OLD.row_hash THEN
        RETURN OLD;
    END IF;
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

-- =============================================================================
-- 2. Move attributes, list items, transfer links and checks to new hashes
-- =============================================================================
-- Reads row_hash_remap_f for one batch. Attribute rows keep their values (an attribute
-- already set on the new hash wins); a transfer link gets both new hashes and a new
-- link_hash (dismissed auto links stay dismissed).
CREATE OR REPLACE FUNCTION public.apply_row_hash_remap(p_batch TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_kind TEXT;
    v_table TEXT;
    v_count INTEGER;
    v_result JSONB := '{}'::JSONB;
    v_links_before INTEGER;
    v_links_after INTEGER;
BEGIN
    DROP TABLE IF EXISTS pg_temp.remap_tmp;
    CREATE TEMP TABLE remap_tmp ON COMMIT DROP AS
    SELECT DISTINCT ON (remap.old_hash) remap.kind, remap.old_hash, remap.new_hash
    FROM public.row_hash_remap_f AS remap
    WHERE remap.batch = p_batch AND remap.old_hash <> remap.new_hash
    -- A closed row wins over its open copy when both exist.
    ORDER BY remap.old_hash, CASE WHEN remap.source_table LIKE '%closed%' THEN 0 ELSE 1 END, remap.remap_id;
    CREATE INDEX ON pg_temp.remap_tmp (old_hash);

    FOR v_kind, v_table IN
        SELECT * FROM (VALUES ('debit', 'debit_d'), ('credit', 'credit_d'), ('asset', 'master_closed_aaccandass_d'))
            AS dims (kind, dim_table)
    LOOP
        DROP TABLE IF EXISTS pg_temp.moved_dims_tmp;
        EXECUTE FORMAT(
            'CREATE TEMP TABLE moved_dims_tmp ON COMMIT DROP AS
            WITH gone AS (
                DELETE FROM public.%1$I AS dim
                USING pg_temp.remap_tmp AS remap
                WHERE dim.row_hash = remap.old_hash AND remap.kind = %2$L
                RETURNING remap.new_hash, dim.tenant_id, dim.user_id, dim.account_id,
                    dim.attribute_1, dim.attribute_2, dim.attribute_3,
                    dim.attribute_1_item_id, dim.attribute_2_item_id, dim.attribute_3_item_id,
                    dim.created_at, dim.created_by, dim.updated_at, dim.updated_by
            )
            SELECT * FROM gone',
            v_table, v_kind
        );
        EXECUTE FORMAT(
            'INSERT INTO public.%1$I AS dim (
                row_hash, tenant_id, user_id, account_id, attribute_1, attribute_2, attribute_3,
                attribute_1_item_id, attribute_2_item_id, attribute_3_item_id,
                created_at, created_by, updated_at, updated_by
            )
            SELECT new_hash, tenant_id, user_id, account_id, attribute_1, attribute_2, attribute_3,
                attribute_1_item_id, attribute_2_item_id, attribute_3_item_id,
                created_at, created_by, updated_at, updated_by
            FROM pg_temp.moved_dims_tmp
            ON CONFLICT (row_hash) DO UPDATE SET
                attribute_1 = COALESCE(dim.attribute_1, EXCLUDED.attribute_1),
                attribute_2 = COALESCE(dim.attribute_2, EXCLUDED.attribute_2),
                attribute_3 = COALESCE(dim.attribute_3, EXCLUDED.attribute_3),
                attribute_1_item_id = COALESCE(dim.attribute_1_item_id, EXCLUDED.attribute_1_item_id),
                attribute_2_item_id = COALESCE(dim.attribute_2_item_id, EXCLUDED.attribute_2_item_id),
                attribute_3_item_id = COALESCE(dim.attribute_3_item_id, EXCLUDED.attribute_3_item_id)',
            v_table
        );
        GET DIAGNOSTICS v_count = ROW_COUNT;
        v_result := v_result || JSONB_BUILD_OBJECT(v_table, v_count);
    END LOOP;

    IF TO_REGCLASS('public.movement_dimensions_d') IS NOT NULL THEN
        WITH gone AS (
            DELETE FROM public.movement_dimensions_d AS registry
            USING pg_temp.remap_tmp AS remap
            WHERE registry.row_hash = remap.old_hash
            RETURNING registry.tenant_id, remap.new_hash, registry.user_id, registry.account_id, registry.created_at
        )
        INSERT INTO public.movement_dimensions_d (tenant_id, row_hash, user_id, account_id, created_at)
        SELECT tenant_id, new_hash, user_id, account_id, created_at FROM gone
        ON CONFLICT (tenant_id, row_hash) DO NOTHING;
        GET DIAGNOSTICS v_count = ROW_COUNT;
        v_result := v_result || JSONB_BUILD_OBJECT('movement_dimensions_d', v_count);
    END IF;

    SELECT COUNT(*) INTO v_links_before FROM public.inter_accounts_d;
    DROP TABLE IF EXISTS pg_temp.moved_links_tmp;
    CREATE TEMP TABLE moved_links_tmp ON COMMIT DROP AS
    WITH gone AS (
        DELETE FROM public.inter_accounts_d AS link
        WHERE
            EXISTS (SELECT 1 FROM pg_temp.remap_tmp AS remap WHERE remap.old_hash = link.sending_hash)
            OR EXISTS (SELECT 1 FROM pg_temp.remap_tmp AS remap WHERE remap.old_hash = link.receiving_hash)
        RETURNING link.*
    )
    SELECT * FROM gone;
    INSERT INTO public.inter_accounts_d (
        link_hash, tenant_id, user_id, sending_hash, receiving_hash, sending_account_id,
        receiving_account_id, receiving_kind, transfer_type, source, status, txn_date, receiving_date,
        amount, amount_difference, match_candidates, reviewed_at, reviewed_by, created_at, created_by,
        updated_at, updated_by
    )
    SELECT
        public.transfer_link_hash(
            COALESCE(sending.new_hash, link.sending_hash), COALESCE(receiving.new_hash, link.receiving_hash)
        ),
        link.tenant_id, link.user_id,
        COALESCE(sending.new_hash, link.sending_hash), COALESCE(receiving.new_hash, link.receiving_hash),
        link.sending_account_id, link.receiving_account_id, link.receiving_kind, link.transfer_type,
        link.source, link.status, link.txn_date, link.receiving_date, link.amount, link.amount_difference,
        link.match_candidates, link.reviewed_at, link.reviewed_by, link.created_at, link.created_by,
        link.updated_at, link.updated_by
    FROM pg_temp.moved_links_tmp AS link
    LEFT JOIN pg_temp.remap_tmp AS sending ON sending.old_hash = link.sending_hash
    LEFT JOIN pg_temp.remap_tmp AS receiving ON receiving.old_hash = link.receiving_hash
    ON CONFLICT DO NOTHING;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    SELECT COUNT(*) INTO v_links_after FROM public.inter_accounts_d;
    v_result := v_result || JSONB_BUILD_OBJECT(
        'inter_accounts_d', v_count,
        'inter_accounts_d_lost', v_links_before - v_links_after
    );

    UPDATE public.aaccandass_checks_f AS checks
    SET adjustment_hash = remap.new_hash
    FROM pg_temp.remap_tmp AS remap
    WHERE checks.adjustment_hash = remap.old_hash;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_result := v_result || JSONB_BUILD_OBJECT(
        'aaccandass_checks_f', v_count,
        'pairs', (SELECT COUNT(*) FROM pg_temp.remap_tmp)
    );
    RETURN v_result;
END
$fn$;

REVOKE ALL ON FUNCTION public.apply_row_hash_remap(TEXT) FROM PUBLIC;

-- =============================================================================
-- 3. Rebuild the six masters in the standard layout (only tables still in the old one)
-- =============================================================================
DO $do$
DECLARE
    v_spec RECORD;
    v_new TEXT;
    v_extra_cols TEXT;
    v_extra_select TEXT;
    v_amount_sql TEXT;
    v_cargos TEXT;
    v_cutoff TEXT;
    v_rows BIGINT;
    v_rebuilt TEXT [] := ARRAY[]::TEXT [];
BEGIN
    FOR v_spec IN
        SELECT * FROM (VALUES
            ('master_debit_closed_f', 'debit', 'closed'),
            ('master_debit_open_f', 'debit', 'open'),
            ('master_credit_closed_f', 'credit', 'closed'),
            ('master_credit_open_f', 'credit', 'open'),
            ('master_credit_future_f', 'credit', 'future'),
            ('master_closed_aaccandass_f', 'asset', 'closed')
        ) AS spec (table_name, kind, layer)
    LOOP
        CONTINUE WHEN NOT EXISTS (
            SELECT 1 FROM information_schema.columns
            WHERE table_schema = 'public' AND table_name = v_spec.table_name AND column_name = 'file_name'
        );
        v_new := v_spec.table_name || '_018';
        EXECUTE FORMAT('DROP TABLE IF EXISTS public.%I', v_new);

        v_extra_cols := CASE
            WHEN v_spec.kind = 'asset' THEN ', source_line INTEGER, reported_balance NUMERIC(18, 2)'
            ELSE ''
        END;
        v_amount_sql := CASE
            WHEN v_spec.kind = 'debit' THEN 'abonos + cargos'
            ELSE 'abonos - cargos'
        END;
        EXECUTE FORMAT(
            'CREATE TABLE public.%I (
                row_id BIGINT GENERATED ALWAYS AS IDENTITY,
                file_id UUID,
                tenant_id UUID NOT NULL,
                user_id UUID NOT NULL,
                account_id INTEGER NOT NULL,
                bank_id INTEGER NOT NULL,
                cutoff_id INTEGER NOT NULL,
                txn_date DATE NOT NULL,
                concept TEXT NOT NULL,
                abonos NUMERIC(18, 2) NOT NULL DEFAULT 0,
                cargos NUMERIC(18, 2) NOT NULL DEFAULT 0,
                amount NUMERIC(18, 2) GENERATED ALWAYS AS (%s) STORED,
                concept_sk TEXT NOT NULL,
                row_hash TEXT NOT NULL,
                occurrence INTEGER NOT NULL DEFAULT 1,
                entry_source TEXT NOT NULL DEFAULT ''upload'',
                note TEXT,
                created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
                created_by UUID
                %s
            )',
            v_new, v_amount_sql, v_extra_cols
        );

        -- Keep the stored signs: debit cargos <= 0, credit and asset cargos >= 0.
        v_cargos := 'old.cargos';
        v_cutoff := CASE
            WHEN v_spec.layer IN ('closed', 'open') AND v_spec.kind <> 'asset' THEN
                'COALESCE(exact.cutoff_id, upload.cutoff_id, public.ledger_cutoff_id(
                    old.tenant_id, old.user_id, old.account_id, old.period_start, old.period_end))'
            ELSE
                'COALESCE(exact.cutoff_id, public.ledger_cutoff_id(
                    old.tenant_id, old.user_id, old.account_id, old.period_start, old.period_end))'
        END;
        v_extra_select := CASE v_spec.kind
            WHEN 'asset' THEN 'old.entry_source, old.note, old.created_at, old.created_by, old.source_line, old.reported_balance'
            ELSE '''upload'', NULL::TEXT, COALESCE(upload.created_at, NOW()), old.user_id'
        END;

        EXECUTE FORMAT(
            'INSERT INTO public.%1$I (
                row_id, file_id, tenant_id, user_id, account_id, bank_id, cutoff_id, txn_date, concept,
                abonos, cargos, concept_sk, row_hash, occurrence, entry_source, note, created_at, created_by%2$s
            )
            OVERRIDING SYSTEM VALUE
            WITH keyed AS (
                SELECT old.*, public.concept_sk(old.concept) AS new_sk, %3$s AS new_cargos
                FROM public.%4$I AS old
            ),
            counted AS (
                SELECT keyed.*,
                    COUNT(*) OVER (
                        PARTITION BY keyed.account_id, keyed.txn_date, keyed.new_sk, keyed.abonos, keyed.new_cargos,
                            keyed.occurrence
                    ) AS same_occurrence,
                    ROW_NUMBER() OVER (
                        PARTITION BY keyed.account_id, keyed.txn_date, keyed.new_sk, keyed.abonos, keyed.new_cargos
                        ORDER BY keyed.occurrence, keyed.row_id
                    )::INTEGER AS renumbered
                FROM keyed
            ),
            numbered AS (
                -- Keep the stored occurrence unless the new key made two rows identical.
                SELECT counted.*,
                    CASE
                        WHEN MAX(counted.same_occurrence) OVER (
                            PARTITION BY counted.account_id, counted.txn_date, counted.new_sk, counted.abonos,
                                counted.new_cargos
                        ) > 1 THEN counted.renumbered
                        ELSE counted.occurrence
                    END AS new_occurrence
                FROM counted
            )
            SELECT
                old.row_id, old.file_id, old.tenant_id, old.user_id, old.account_id, old.bank_id,
                %5$s,
                old.txn_date, old.concept, old.abonos, old.new_cargos, old.new_sk,
                public.movement_row_hash_v2(
                    old.user_id, old.account_id, old.bank_id, old.txn_date, old.new_sk, old.abonos,
                    old.new_cargos, old.new_occurrence
                ),
                old.new_occurrence,
                %6$s
            FROM numbered AS old
            LEFT JOIN public.%7$I AS upload ON upload.upload_id = old.file_id
            LEFT JOIN LATERAL (
                SELECT cutoff.cutoff_id
                FROM public.cutoff_date_f AS cutoff
                WHERE
                    cutoff.account_id = old.account_id
                    AND cutoff.period_start = old.period_start
                    AND cutoff.period_end = old.period_end
                ORDER BY cutoff.cutoff_id
                LIMIT 1
            ) AS exact ON TRUE
            ORDER BY old.row_id',
            v_new,
            CASE WHEN v_spec.kind = 'asset' THEN ', source_line, reported_balance' ELSE '' END,
            v_cargos,
            v_spec.table_name,
            v_cutoff,
            v_extra_select,
            CASE WHEN v_spec.kind = 'asset' THEN 'aaccandass_uploads_f' ELSE 'statement_uploads_f' END
        );
        GET DIAGNOSTICS v_rows = ROW_COUNT;

        EXECUTE FORMAT(
            'INSERT INTO public.row_hash_remap_f (
                batch, reason, kind, source_table, tenant_id, user_id, account_id, old_hash, new_hash
            )
            SELECT ''sql/018'', ''standard columns, concept_sk'', %1$L, %2$L,
                old.tenant_id, old.user_id, old.account_id, old.row_hash, new.row_hash
            FROM public.%2$I AS old
            INNER JOIN public.%3$I AS new ON new.row_id = old.row_id
            WHERE old.row_hash <> new.row_hash
            ON CONFLICT (batch, source_table, old_hash) DO NOTHING',
            v_spec.kind, v_spec.table_name, v_new
        );

        EXECUTE FORMAT('DROP TABLE public.%I CASCADE', v_spec.table_name);
        EXECUTE FORMAT('ALTER TABLE public.%I RENAME TO %I', v_new, v_spec.table_name);
        EXECUTE FORMAT(
            'ALTER SEQUENCE IF EXISTS public.%I RENAME TO %I',
            v_new || '_row_id_seq', v_spec.table_name || '_row_id_seq'
        );
        EXECUTE FORMAT(
            'SELECT SETVAL(PG_GET_SERIAL_SEQUENCE(%L, ''row_id''), GREATEST((SELECT MAX(row_id) FROM public.%I), 1))',
            'public.' || v_spec.table_name, v_spec.table_name
        );
        RAISE NOTICE 'sql/018: rebuilt % (% rows)', v_spec.table_name, v_rows;
        v_rebuilt := v_rebuilt || v_spec.table_name;
    END LOOP;

    IF CARDINALITY(v_rebuilt) > 0 THEN
        RAISE NOTICE 'sql/018: remap %', public.apply_row_hash_remap('sql/018');
    END IF;
END
$do$;

-- =============================================================================
-- 4. Keys, checks, indexes, triggers and row security on the rebuilt masters
-- =============================================================================
DO $do$
DECLARE
    v_spec RECORD;
    v_sources TEXT;
BEGIN
    FOR v_spec IN
        SELECT * FROM (VALUES
            ('master_debit_closed_f', 'debit', 'closed', 'debit_d'),
            ('master_debit_open_f', 'debit', 'open', 'debit_d'),
            ('master_credit_closed_f', 'credit', 'closed', 'credit_d'),
            ('master_credit_open_f', 'credit', 'open', 'credit_d'),
            ('master_credit_future_f', 'credit', 'future', 'credit_d'),
            ('master_closed_aaccandass_f', 'asset', 'closed', 'master_closed_aaccandass_d')
        ) AS spec (table_name, kind, layer, dim_table)
    LOOP
        v_sources := CASE
            WHEN v_spec.kind = 'asset' THEN '''upload'', ''manual'', ''opening'', ''adjustment'''
            WHEN v_spec.layer = 'closed' THEN '''upload'', ''opening'', ''adjustment'''
            ELSE '''upload'''
        END;
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = ('public.' || v_spec.table_name)::REGCLASS AND contype = 'p'
        ) THEN
            EXECUTE FORMAT('ALTER TABLE public.%1$I ADD CONSTRAINT %1$s_pkey PRIMARY KEY (row_id)', v_spec.table_name);
        END IF;
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint
            WHERE conrelid = ('public.' || v_spec.table_name)::REGCLASS AND conname = v_spec.table_name || '_cutoff_fkey'
        ) THEN
            EXECUTE FORMAT(
                'ALTER TABLE public.%1$I
                ADD CONSTRAINT %1$s_file_fkey FOREIGN KEY (file_id) REFERENCES public.%2$I (upload_id),
                ADD CONSTRAINT %1$s_tenant_user_fkey FOREIGN KEY (tenant_id, user_id)
                    REFERENCES public.tenant_users (tenant_id, user_id),
                ADD CONSTRAINT %1$s_account_fkey FOREIGN KEY (account_id, user_id)
                    REFERENCES public.bank_accounts_d (account_id, user_id),
                ADD CONSTRAINT %1$s_bank_fkey FOREIGN KEY (bank_id) REFERENCES public.banks_d (bank_id),
                ADD CONSTRAINT %1$s_cutoff_fkey FOREIGN KEY (cutoff_id) REFERENCES public.cutoff_date_f (cutoff_id),
                ADD CONSTRAINT %1$s_sign_check CHECK (%4$s),
                ADD CONSTRAINT %1$s_concept_sk_check CHECK (LENGTH(concept_sk) > 0),
                ADD CONSTRAINT %1$s_occurrence_check CHECK (occurrence >= 1),
                ADD CONSTRAINT %1$s_hash_check CHECK (LENGTH(row_hash) = 64),
                ADD CONSTRAINT %1$s_note_check CHECK (COALESCE(LENGTH(note), 0) <= 500),
                ADD CONSTRAINT %1$s_source_check CHECK (
                    entry_source IN (%3$s) AND ((entry_source = ''upload'') = (file_id IS NOT NULL))
                )',
                v_spec.table_name,
                CASE WHEN v_spec.kind = 'asset' THEN 'aaccandass_uploads_f' ELSE 'statement_uploads_f' END,
                v_sources,
                CASE
                    WHEN v_spec.kind = 'debit' THEN 'abonos >= 0 AND cargos <= 0'
                    ELSE 'abonos >= 0 AND cargos >= 0'
                END
            );
        END IF;
        IF v_spec.kind = 'asset' THEN
            EXECUTE 'CREATE UNIQUE INDEX IF NOT EXISTS master_closed_aaccandass_f_hash_key
                ON public.master_closed_aaccandass_f (row_hash)';
        ELSE
            EXECUTE FORMAT(
                'CREATE UNIQUE INDEX IF NOT EXISTS %1$s_hash_idx ON public.%1$I (account_id, row_hash)',
                v_spec.table_name
            );
        END IF;
        EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS %1$s_file_idx ON public.%1$I (file_id)', v_spec.table_name);
        EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS %1$s_tenant_idx ON public.%1$I (tenant_id, user_id)', v_spec.table_name);
        EXECUTE FORMAT(
            'CREATE INDEX IF NOT EXISTS %1$s_account_idx ON public.%1$I (account_id, txn_date, row_id)',
            v_spec.table_name
        );
        EXECUTE FORMAT('CREATE INDEX IF NOT EXISTS %1$s_cutoff_idx ON public.%1$I (cutoff_id)', v_spec.table_name);

        EXECUTE FORMAT('DROP TRIGGER IF EXISTS %1$s_attribute_rows ON public.%1$I', v_spec.table_name);
        EXECUTE FORMAT(
            'CREATE TRIGGER %1$s_attribute_rows AFTER INSERT ON public.%1$I
            REFERENCING NEW TABLE AS added_rows FOR EACH STATEMENT
            EXECUTE FUNCTION public.add_movement_attribute_rows(%2$L)',
            v_spec.table_name, v_spec.dim_table
        );
        IF v_spec.kind <> 'asset' AND v_spec.layer IN ('closed', 'open') THEN
            EXECUTE FORMAT('DROP TRIGGER IF EXISTS %1$s_transfer_links ON public.%1$I', v_spec.table_name);
            EXECUTE FORMAT(
                'CREATE TRIGGER %1$s_transfer_links AFTER INSERT ON public.%1$I
                REFERENCING NEW TABLE AS added_rows FOR EACH STATEMENT
                EXECUTE FUNCTION public.detect_transfers_after_insert()',
                v_spec.table_name
            );
        END IF;
        IF v_spec.layer = 'closed' THEN
            EXECUTE FORMAT('DROP TRIGGER IF EXISTS %1$s_no_update ON public.%1$I', v_spec.table_name);
            EXECUTE FORMAT(
                'CREATE TRIGGER %1$s_no_update BEFORE UPDATE ON public.%1$I
                FOR EACH ROW EXECUTE FUNCTION public.reject_closed_row_update()',
                v_spec.table_name
            );
        END IF;
        IF v_spec.layer = 'closed' AND v_spec.kind <> 'asset' THEN
            EXECUTE FORMAT('DROP TRIGGER IF EXISTS %1$s_no_row_delete ON public.%1$I', v_spec.table_name);
            EXECUTE FORMAT(
                'CREATE TRIGGER %1$s_no_row_delete BEFORE DELETE ON public.%1$I
                FOR EACH ROW EXECUTE FUNCTION public.reject_closed_row_delete()',
                v_spec.table_name
            );
        END IF;

        EXECUTE FORMAT('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', v_spec.table_name);
        EXECUTE FORMAT('DROP POLICY IF EXISTS %1$s_tenant ON public.%1$I', v_spec.table_name);
        EXECUTE FORMAT(
            'CREATE POLICY %1$s_tenant ON public.%1$I TO strm_app
            USING (tenant_id = public.session_tenant() AND user_id = public.session_user())
            WITH CHECK (tenant_id = public.session_tenant() AND user_id = public.session_user())',
            v_spec.table_name
        );
        EXECUTE FORMAT('REVOKE ALL ON public.%I FROM PUBLIC', v_spec.table_name);
        EXECUTE FORMAT('GRANT SELECT ON public.%I TO strm_app', v_spec.table_name);
    END LOOP;
END
$do$;

COMMENT ON TABLE public.master_debit_closed_f IS
'Closed debit movements (sql/018 layout): row_id | file_id, tenant_id, user_id, account_id, bank_id, '
'cutoff_id | txn_date, concept, abonos, cargos | amount, concept_sk, row_hash | occurrence, entry_source, '
'note, created_at, created_by. abonos >= 0, cargos <= 0, amount = abonos + cargos. Opening and '
'adjustment rows have entry_source opening/adjustment and no file.';
COMMENT ON TABLE public.master_debit_open_f IS
'Current (open) debit period, replaced by each open upload (sql/018 layout, see master_debit_closed_f).';
COMMENT ON TABLE public.master_credit_closed_f IS
'Closed credit card movements (sql/018 layout): abonos = payments and refunds, cargos = purchases, both '
'>= 0, amount = abonos - cargos (a purchase is negative). Same columns as the debit masters. '
'Opening and adjustment rows have no file.';
COMMENT ON TABLE public.master_credit_open_f IS
'Current (open) credit card period, replaced by each open upload (sql/018 layout).';
COMMENT ON TABLE public.master_credit_future_f IS
'Installments still due (sql/018 layout); cutoff_id is the period each payment falls in.';
COMMENT ON TABLE public.master_closed_aaccandass_f IS
'Investment and asset movements (sql/017, sql/018 layout): abonos = money in or gain, cargos = money out '
'or loss, both >= 0; entry_source upload, manual, opening or adjustment; cutoff_id = calendar month.';

-- =============================================================================
-- 5. Views: keys (same field names as before, read through the keys), balances
-- =============================================================================
-- account_number, bank_name, period_start, period_end, file_name and source_profile come
-- from bank_accounts_d, banks_d, cutoff_date_f and the upload. source_profile is the
-- statement profile (or column map) of the file, or the entry source for rows with no file
-- and for investment / asset rows.
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
    account.account_number,
    bank.bank_name,
    movement.concept,
    cutoff.period_start,
    cutoff.period_end,
    upload.original_filename AS file_name,
    COALESCE(upload.source_profile, movement.entry_source) AS source_profile,
    movement.entry_source,
    movement.cutoff_id,
    movement.note
FROM public.master_debit_closed_f AS movement
INNER JOIN public.bank_accounts_d AS account ON movement.account_id = account.account_id
INNER JOIN public.banks_d AS bank ON movement.bank_id = bank.bank_id
INNER JOIN public.cutoff_date_f AS cutoff ON movement.cutoff_id = cutoff.cutoff_id
LEFT JOIN public.statement_uploads_f AS upload ON movement.file_id = upload.upload_id
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
    account.account_number,
    bank.bank_name,
    movement.concept,
    cutoff.period_start,
    cutoff.period_end,
    upload.original_filename AS file_name,
    COALESCE(upload.source_profile, movement.entry_source) AS source_profile,
    movement.entry_source,
    movement.cutoff_id,
    movement.note
FROM public.master_debit_open_f AS movement
INNER JOIN public.bank_accounts_d AS account ON movement.account_id = account.account_id
INNER JOIN public.banks_d AS bank ON movement.bank_id = bank.bank_id
INNER JOIN public.cutoff_date_f AS cutoff ON movement.cutoff_id = cutoff.cutoff_id
LEFT JOIN public.statement_uploads_f AS upload ON movement.file_id = upload.upload_id
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
    account.account_number,
    bank.bank_name,
    movement.concept,
    cutoff.period_start,
    cutoff.period_end,
    upload.original_filename AS file_name,
    COALESCE(upload.source_profile, movement.entry_source) AS source_profile,
    movement.entry_source,
    movement.cutoff_id,
    movement.note
FROM public.master_credit_closed_f AS movement
INNER JOIN public.bank_accounts_d AS account ON movement.account_id = account.account_id
INNER JOIN public.banks_d AS bank ON movement.bank_id = bank.bank_id
INNER JOIN public.cutoff_date_f AS cutoff ON movement.cutoff_id = cutoff.cutoff_id
LEFT JOIN public.statement_uploads_f AS upload ON movement.file_id = upload.upload_id
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
    account.account_number,
    bank.bank_name,
    movement.concept,
    cutoff.period_start,
    cutoff.period_end,
    upload.original_filename AS file_name,
    COALESCE(upload.source_profile, movement.entry_source) AS source_profile,
    movement.entry_source,
    movement.cutoff_id,
    movement.note
FROM public.master_credit_open_f AS movement
INNER JOIN public.bank_accounts_d AS account ON movement.account_id = account.account_id
INNER JOIN public.banks_d AS bank ON movement.bank_id = bank.bank_id
INNER JOIN public.cutoff_date_f AS cutoff ON movement.cutoff_id = cutoff.cutoff_id
LEFT JOIN public.statement_uploads_f AS upload ON movement.file_id = upload.upload_id
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
    account.account_number,
    bank.bank_name,
    movement.concept,
    planned.period_start,
    planned.period_end,
    upload.original_filename AS file_name,
    COALESCE(upload.source_profile, movement.entry_source) AS source_profile,
    movement.entry_source,
    movement.cutoff_id,
    movement.note
FROM public.master_credit_future_f AS movement
INNER JOIN public.bank_accounts_d AS account ON movement.account_id = account.account_id
INNER JOIN public.banks_d AS bank ON movement.bank_id = bank.bank_id
INNER JOIN public.cutoff_date_f AS cutoff ON movement.cutoff_id = cutoff.cutoff_id
-- A future installment sits in the period its month has on the card's current cutoff day
-- (that month's stored cutoff can be an uploaded one, planned on an older day).
CROSS JOIN LATERAL public.period_bounds(TRUE, account.account_cutoff_day, cutoff.cutoff_year, cutoff.cutoff_month) AS planned
LEFT JOIN public.statement_uploads_f AS upload ON movement.file_id = upload.upload_id
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
    account.account_number,
    bank.bank_name,
    movement.concept,
    cutoff.period_start,
    cutoff.period_end,
    upload.chosen_filename AS file_name,
    movement.entry_source AS source_profile,
    movement.entry_source,
    movement.cutoff_id,
    movement.note
FROM public.master_closed_aaccandass_f AS movement
INNER JOIN public.bank_accounts_d AS account ON movement.account_id = account.account_id
INNER JOIN public.banks_d AS bank ON movement.bank_id = bank.bank_id
INNER JOIN public.cutoff_date_f AS cutoff ON movement.cutoff_id = cutoff.cutoff_id
LEFT JOIN public.aaccandass_uploads_f AS upload ON movement.file_id = upload.upload_id;

-- Balance after each row, per account: debit and credit count closed and open rows (the
-- open period never overlaps a closed one), assets their table. Credit: negative = owed.
CREATE OR REPLACE VIEW public.movement_balance_v
WITH (security_invoker = TRUE) AS
SELECT
    keys.row_hash,
    keys.source_table,
    keys.row_id,
    keys.tenant_id,
    keys.user_id,
    keys.account_id,
    keys.kind,
    keys.txn_date,
    keys.amount,
    keys.entry_source,
    (SUM(keys.amount) OVER (
        PARTITION BY keys.account_id
        ORDER BY keys.txn_date, CASE WHEN keys.entry_source = 'opening' THEN 0 ELSE 1 END,
            CASE keys.layer WHEN 'closed' THEN 0 ELSE 1 END, keys.row_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ))::NUMERIC(18, 2) AS balance
FROM public.movement_keys_v AS keys
WHERE keys.layer IN ('closed', 'open');

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
    (SUM(movement.amount) OVER (
        PARTITION BY movement.account_id
        ORDER BY movement.txn_date, CASE WHEN movement.entry_source = 'opening' THEN 0 ELSE 1 END, movement.row_id
        ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW
    ))::NUMERIC(18, 2) AS balance
FROM public.master_closed_aaccandass_f AS movement;

GRANT SELECT ON public.movement_keys_v, public.movement_balance_v, public.master_closed_aaccandass_balance_v,
    public.statement_cutoffs_v TO strm_app;

-- Attribute rows for movements stored before their trigger existed (or moved here).
INSERT INTO public.debit_d (row_hash, tenant_id, user_id, account_id, created_by)
SELECT DISTINCT ON (keys.row_hash) 
    keys.row_hash,
    keys.tenant_id,
    keys.user_id,
    keys.account_id,
    keys.user_id AS created_by
FROM public.movement_keys_v AS keys
WHERE keys.kind = 'debit'
ON CONFLICT (row_hash) DO NOTHING;
INSERT INTO public.credit_d (row_hash, tenant_id, user_id, account_id, created_by)
SELECT DISTINCT ON (keys.row_hash) 
    keys.row_hash,
    keys.tenant_id,
    keys.user_id,
    keys.account_id,
    keys.user_id AS created_by
FROM public.movement_keys_v AS keys
WHERE keys.kind = 'credit'
ON CONFLICT (row_hash) DO NOTHING;
INSERT INTO public.master_closed_aaccandass_d (row_hash, tenant_id, user_id, account_id, created_by)
SELECT 
    keys.row_hash,
    keys.tenant_id,
    keys.user_id,
    keys.account_id,
    keys.user_id AS created_by
FROM public.movement_keys_v AS keys
WHERE keys.kind = 'asset'
ON CONFLICT (row_hash) DO NOTHING;

-- =============================================================================
-- 6. Statement ingest: new layout, original cargo signs, column map for unknown files
-- =============================================================================
ALTER TABLE public.aaccandass_templates_d ADD COLUMN IF NOT EXISTS header_signature TEXT [];
CREATE INDEX IF NOT EXISTS aaccandass_templates_d_signature_idx
ON public.aaccandass_templates_d (account_id, header_signature);
COMMENT ON TABLE public.aaccandass_templates_d IS
'Column maps per account (sql/017 for investments, sql/018 for every account): date, concept, abono, '
'cargo / amount. header_signature (sorted normalized headers) finds the map again for a file of the '
'same shape.';
ALTER TABLE public.statement_uploads_f
ADD COLUMN IF NOT EXISTS column_map_id BIGINT REFERENCES public.aaccandass_templates_d (template_id) ON DELETE SET NULL;

CREATE OR REPLACE FUNCTION public.column_map_signature(p_headers TEXT [])
RETURNS TEXT []
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT ARRAY_AGG(header ORDER BY header)
    FROM (
        SELECT public.normalize_header(col) AS header
        FROM UNNEST(p_headers) AS col
        WHERE BTRIM(COALESCE(col, '')) <> ''
    ) AS cleaned
$fn$;

CREATE OR REPLACE FUNCTION public.set_column_map_signature()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
BEGIN
    NEW.header_signature := public.column_map_signature(NEW.headers);
    RETURN NEW;
END
$fn$;
DROP TRIGGER IF EXISTS aaccandass_templates_d_signature ON public.aaccandass_templates_d;
CREATE TRIGGER aaccandass_templates_d_signature BEFORE INSERT OR UPDATE OF headers ON public.aaccandass_templates_d
FOR EACH ROW EXECUTE FUNCTION public.set_column_map_signature();

UPDATE public.aaccandass_templates_d
SET header_signature = public.column_map_signature(headers)
WHERE header_signature IS NULL AND headers IS NOT NULL;

DROP FUNCTION IF EXISTS public.ingest_statement_csv(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE, TEXT, TEXT);
CREATE OR REPLACE FUNCTION public.ingest_statement_csv(p_account_id integer, p_cutoff_id integer, p_slot text, p_filename text, p_csv text, p_as_of date, p_encoding text DEFAULT NULL::text, p_delimiter text DEFAULT NULL::text, p_mapping jsonb DEFAULT NULL::jsonb, p_template_name text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    v_map JSONB := CASE WHEN JSONB_TYPEOF(p_mapping) = 'object' AND p_mapping <> '{}'::JSONB THEN p_mapping END;
    v_template_id BIGINT;
    v_template_name TEXT := NULLIF(BTRIM(COALESCE(p_template_name, '')), '');
    v_map_headers TEXT [];
    v_mapped RECORD;
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
        public.account_type_family(kind.type_name),
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

    -- Asset accounts never use a debit/credit master or an open/closed statement slot.
    -- The column map stores a signed amount as a positive cargo (money out) or abono (money in).
    IF v_kind = 'asset' THEN
        IF v_map IS NULL OR NOT public.aaccandass_mapping_ready(public.aaccandass_clean_mapping(v_map)) THEN
            RAISE EXCEPTION 'This file matches no known layout: map the columns' USING ERRCODE = '22P02';
        END IF;
        RETURN public.ingest_aaccandass_upload(
            p_account_id, p_filename, p_filename, p_csv, v_map, v_template_name,
            CASE WHEN p_filename ~* '\.(xlsx|xlsm|xls)$' THEN 'xlsx' ELSE 'csv' END
        );
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

    IF v_map IS NOT NULL AND p_slot = 'installment' THEN
        RAISE EXCEPTION 'Installment files need a bank profile; the column map is for statement files'
            USING ERRCODE = '22023';
    END IF;

    -- Find header row (BBVA XLSX→CSV may keep a clean header at row 1;
    -- tolerate preamble if present). Prefer dataset-matching profile.
    v_header_record_no := NULL;
    FOR v_record IN
        SELECT parsed.record_no, parsed.fields
        FROM public.parse_csv(v_csv, v_delim) AS parsed
        WHERE v_map IS NULL
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

    -- sql/018: no bank profile -> a column map this account saved for the same headers.
    IF v_profile IS NULL AND v_map IS NULL AND p_slot = 'statement' THEN
        FOR v_record IN
            SELECT parsed.record_no, parsed.fields
            FROM public.parse_csv(v_csv, v_delim) AS parsed
            ORDER BY parsed.record_no
            LIMIT 40
        LOOP
            SELECT template.template_id, template.mapping
            INTO v_template_id, v_map
            FROM public.aaccandass_templates_d AS template
            WHERE
                template.account_id = p_account_id
                AND template.user_id = v_user
                AND template.header_signature = public.column_map_signature(v_record.fields)
            ORDER BY template.last_used_at DESC NULLS LAST, template.template_id DESC
            LIMIT 1;
            IF v_map IS NOT NULL THEN
                v_map := v_map || JSONB_BUILD_OBJECT('header_row', v_record.record_no, 'delimiter', v_delim);
                EXIT;
            END IF;
        END LOOP;
    END IF;

    IF v_map IS NULL THEN
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
                RAISE EXCEPTION 'These headers do not match a supported statement profile or a saved column map for this account: map the columns'
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

        -- Debit cargos stay <= 0. Credit keeps the positive cargo in "cargo".
        v_parsed_rows := ARRAY_APPEND(
            v_parsed_rows,
            JSONB_BUILD_OBJECT(
                'record_no', v_record.record_no,
                'txn_date', v_date,
                'concept', v_concept,
                'concept_sk', v_sk,
                'cargos', v_cargos,
                'abonos', v_abonos,
                'abono', v_abono,
                'cargo', v_cargo,
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
    ELSE
        -- sql/018 column map (the sql/017 mapper): date, concept (columns can be joined),
        -- abono and cargo (one shared column = signed amount: positive abono, negative
        -- cargo). Every other column is ignored. Debit stores that cargo negative;
        -- credit stores it positive.
        v_map := public.aaccandass_clean_mapping(
            JSONB_BUILD_OBJECT('delimiter', v_delim) || v_map
        );
        IF NOT public.aaccandass_mapping_ready(v_map) THEN
            RAISE EXCEPTION 'Map the date column and an abono, cargo or amount column' USING ERRCODE = '22023';
        END IF;
        v_map_headers := public.aaccandass_headers(v_csv, v_map);
        v_profile := 'column_map';
        v_amount_rule := 'column_map';
        FOR v_mapped IN
            SELECT mapped.*
            FROM public.aaccandass_map_rows(v_csv, v_map) AS mapped
            WHERE mapped.status = 'ok'
            ORDER BY mapped.line_no
        LOOP
            v_concept := v_mapped.concept;
            IF public.concept_sk(v_concept) = '' THEN
                v_concept := 'Movimiento';
            END IF;
            v_parsed_rows := ARRAY_APPEND(
                v_parsed_rows,
                JSONB_BUILD_OBJECT(
                    'record_no', v_mapped.line_no,
                    'txn_date', v_mapped.txn_date,
                    'concept', v_concept,
                    'concept_sk', public.concept_sk(v_concept),
                    'cargos', CASE WHEN v_kind = 'debit' THEN -v_mapped.cargos ELSE v_mapped.cargos END,
                    'abonos', v_mapped.abonos,
                    'abono', v_mapped.abonos,
                    'cargo', v_mapped.cargos,
                    'amount', v_mapped.abonos - v_mapped.cargos
                )::TEXT
            );
        END LOOP;
    END IF;

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
                    'amount', -n.cargo,
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
                -- Stored signs: debit cargos <= 0 (the "cargos" field); credit cargos >= 0 (the "cargo" field).
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

    -- sql/018 layout. Statement rows point at the upload's period; installments at the
    -- period each payment falls in (a 'ledger' cutoff when no statement period exists yet).
    EXECUTE FORMAT(
        'INSERT INTO public.%1$I (
            file_id, tenant_id, user_id, account_id, bank_id, cutoff_id, txn_date, concept,
            abonos, cargos, concept_sk, row_hash, occurrence, entry_source, created_by
        )
        SELECT
            $1, $2, $3, $4, $5,
            CASE
                WHEN $6 = ''future'' THEN public.ledger_cutoff_id(
                    $2, $3, $4, (item ->> ''period_start'')::DATE, (item ->> ''period_end'')::DATE
                )
                ELSE $7
            END,
            (item ->> ''txn_date'')::DATE,
            item ->> ''concept'',
            COALESCE((item ->> %2$L)::NUMERIC(18, 2), 0),
            COALESCE((item ->> %3$L)::NUMERIC(18, 2), 0),
            item ->> ''concept_sk'',
            item ->> ''row_hash'',
            (item ->> ''occurrence'')::INTEGER,
            ''upload'',
            $3
        FROM JSONB_ARRAY_ELEMENTS($8) AS src_rows (item)',
        v_table,
        CASE WHEN v_kind = 'credit' THEN 'abono' ELSE 'abonos' END,
        CASE WHEN v_kind = 'credit' THEN 'cargo' ELSE 'cargos' END
    )
    USING v_upload_id, v_tenant, v_user, p_account_id, v_bank_id, v_ledger, p_cutoff_id, v_final_rows;
    IF v_ledger = 'future' THEN
        PERFORM public.prune_ledger_cutoffs(p_account_id);
    END IF;

    -- A column map is saved for the account (by name) and found again by its headers.
    IF v_profile = 'column_map' THEN
        IF v_template_name IS NOT NULL THEN
            INSERT INTO public.aaccandass_templates_d AS template (
                tenant_id, user_id, account_id, template_name, mapping, headers, last_used_at, created_by
            )
            VALUES (v_tenant, v_user, p_account_id, LEFT(v_template_name, 60), v_map, v_map_headers, NOW(), v_user)
            ON CONFLICT (account_id, (LOWER(template_name))) DO UPDATE
            SET
                mapping = EXCLUDED.mapping,
                headers = EXCLUDED.headers,
                last_used_at = NOW(),
                updated_at = NOW(),
                updated_by = v_user
            RETURNING template.template_id INTO v_template_id;
        ELSIF v_template_id IS NOT NULL THEN
            UPDATE public.aaccandass_templates_d SET last_used_at = NOW() WHERE template_id = v_template_id;
        END IF;
        UPDATE public.statement_uploads_f
        SET column_map_id = v_template_id
        WHERE upload_id = v_upload_id;
    END IF;

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
        'cutoff_id', p_cutoff_id,
        'column_map_id', v_template_id,
        'column_map', CASE WHEN v_profile = 'column_map' THEN v_map END
    );
END
$function$;

-- The API entry point gains the same two optional arguments (column map and its name).
DROP FUNCTION IF EXISTS public.ingest_statement_upload(INTEGER, INTEGER, TEXT, TEXT, TEXT, TEXT, DATE, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.ingest_statement_upload(
    p_account_id INTEGER,
    p_cutoff_id INTEGER,
    p_slot TEXT,
    p_filename TEXT,
    p_chosen_filename TEXT,
    p_csv TEXT,
    p_as_of DATE,
    p_encoding TEXT DEFAULT NULL,
    p_delimiter TEXT DEFAULT NULL,
    p_mapping JSONB DEFAULT NULL,
    p_template_name TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
    RETURN public.remember_chosen_filename(
        public.ingest_statement_csv(
            p_account_id,
            p_cutoff_id,
            p_slot,
            COALESCE(NULLIF(BTRIM(COALESCE(p_filename, '')), ''), public.clean_chosen_filename(p_chosen_filename)),
            p_csv,
            p_as_of,
            p_encoding,
            p_delimiter,
            p_mapping,
            p_template_name
        ),
        COALESCE(public.clean_chosen_filename(p_chosen_filename), p_filename)
    );
END
$fn$;

-- =============================================================================
-- 7. Existing functions on the new layout
-- =============================================================================

CREATE OR REPLACE FUNCTION public.aaccandass_clean_mapping(p_mapping jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 IMMUTABLE
AS $function$
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
    -- sql/018: abono and cargo on the same column = signed amount (positive abono, negative cargo).
    IF v_out ->> 'abono' IS NOT NULL AND v_out ->> 'amount' IS NULL
        AND public.normalize_header(v_out ->> 'abono') = public.normalize_header(COALESCE(v_out ->> 'cargo', ''))
    THEN
        v_out := v_out || JSONB_BUILD_OBJECT('amount', v_out ->> 'abono', 'abono', NULL, 'cargo', NULL);
    END IF;
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
$function$;

CREATE OR REPLACE FUNCTION public.enforce_bank_account()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
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
    ELSIF NOT EXISTS (SELECT 1 FROM public.banks_d AS bank WHERE bank.bank_id = NEW.bank_id) THEN
        -- sql/018: a bank without a statement profile is fine (files are read with a column map).
        RAISE EXCEPTION 'bank not found' USING ERRCODE = '23503';
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
$function$;

CREATE OR REPLACE FUNCTION public.refresh_statement_periods(p_account_id integer, p_as_of date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        SELECT planned.period_start, planned.period_end
        FROM public.planned_statement_periods(p_account_id, v_allows, v_cutoff_day, p_as_of) AS planned
    LOOP
        INSERT INTO public.cutoff_date_f AS cutoff (
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
            p_as_of > v_period.period_end,
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
            is_required = EXCLUDED.is_required,
            period_source = 'statement'
        WHERE NOT EXISTS (
            SELECT 1
            FROM public.statement_uploads_f AS upload
            WHERE upload.cutoff_id = cutoff.cutoff_id
        );
    END LOOP;

    UPDATE public.cutoff_date_f
    SET is_required = p_as_of > period_end
    WHERE
        account_id = p_account_id
        AND user_id = v_user;
END
$function$;

CREATE OR REPLACE FUNCTION public.statement_home(p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        FROM public.statement_cutoffs_v AS cutoff
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
            FROM public.statement_cutoffs_v AS cutoff
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
            -- Still owed on future installments (positive), as before sql/018.
            'future_total', (
                SELECT COALESCE(SUM(future_row.cargos - future_row.abonos), 0)
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
                    JSONB_BUILD_OBJECT(
                        'bank_id', bank.bank_id,
                        'bank_name', bank.bank_name,
                        -- sql/018: any bank; without a built-in profile the column map reads its files.
                        'has_profile', EXISTS (
                            SELECT 1
                            FROM public.file_profiles_d AS fp
                            WHERE LOWER(fp.bank_name) = LOWER(bank.bank_name)
                              AND fp.active IS TRUE
                        )
                    )
                    ORDER BY bank.bank_name
                ),
                '[]'::JSONB
            )
            FROM public.banks_d AS bank
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
$function$;

CREATE OR REPLACE FUNCTION public.upload_completeness(p_as_of date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        FROM public.statement_cutoffs_v AS cutoff
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
                FROM public.statement_cutoffs_v AS cutoff
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
$function$;

CREATE OR REPLACE FUNCTION public.add_earlier_period(p_account_id integer, p_as_of date)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    INNER JOIN public.statement_cutoffs_v AS cutoff ON cutoff.account_id = account.account_id
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
    ON CONFLICT (account_id, cutoff_year, cutoff_month) DO UPDATE
    SET period_source = 'statement', added_by_user = TRUE
    WHERE public.cutoff_date_f.period_source = 'ledger'
    RETURNING cutoff_id
    INTO v_cutoff_id;

    IF v_cutoff_id IS NULL THEN
        RAISE EXCEPTION 'That period is already on the account' USING ERRCODE = '23505';
    END IF;
    RETURN v_cutoff_id;
END
$function$;

CREATE OR REPLACE FUNCTION public.remove_statement_period(p_cutoff_id integer, p_as_of date)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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

    IF public.cutoff_in_use(p_cutoff_id) THEN
        RAISE EXCEPTION 'An opening or adjustment row is in that period; delete it first' USING ERRCODE = '23503';
    END IF;
    DELETE FROM public.cutoff_date_f
    WHERE cutoff_id = p_cutoff_id;
END
$function$;

CREATE OR REPLACE FUNCTION public.delete_statement_upload(p_upload_id uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    DELETE FROM public.master_debit_open_f
    WHERE file_id = p_upload_id;
    DELETE FROM public.master_credit_open_f
    WHERE file_id = p_upload_id;
    DELETE FROM public.master_credit_future_f
    WHERE file_id = p_upload_id;
    -- Old installment plan copy (sql/006) until sql/018b drops the table.
    IF TO_REGCLASS('public.credit_plan_closed_f') IS NOT NULL THEN
        EXECUTE 'DELETE FROM public.credit_plan_closed_f WHERE file_id = $1' USING p_upload_id;
    END IF;
    DELETE FROM public.upload_delete_guard
    WHERE upload_id = p_upload_id;
    DELETE FROM public.statement_uploads_f
    WHERE upload_id = p_upload_id;
    PERFORM public.prune_ledger_cutoffs(account.account_id)
    FROM public.bank_accounts_d AS account
    WHERE account.tenant_id = v_tenant AND account.user_id = v_user;
END
$function$;

CREATE OR REPLACE FUNCTION public.transfer_pool(p_tenant uuid, p_user uuid)
 RETURNS TABLE(row_hash text, kind text, layer text, transfer_role text, account_id integer, account_number text, bank_id integer, bank_name text, txn_date date, concept text, concept_sk text, abs_amount numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
    SELECT DISTINCT ON (keys.row_hash)
        keys.row_hash,
        keys.kind,
        keys.layer,
        CASE
            WHEN keys.kind = 'debit' AND keys.amount < 0 THEN 'sending'
            WHEN keys.kind = 'asset' AND keys.amount < 0 THEN 'sending'
            ELSE 'receiving'
        END AS transfer_role,
        keys.account_id,
        keys.account_number,
        keys.bank_id,
        keys.bank_name,
        keys.txn_date,
        keys.concept,
        keys.concept_sk,
        CASE
            WHEN keys.kind IN ('debit', 'asset') THEN ABS(keys.amount)
            ELSE keys.abonos
        END::NUMERIC AS abs_amount
    FROM public.movement_keys_v AS keys
    WHERE
        keys.tenant_id = p_tenant
        AND keys.user_id = p_user
        AND keys.layer IN ('open', 'closed')
        AND keys.entry_source = 'upload'
        AND (
            (keys.kind = 'debit' AND keys.amount <> 0)
            OR (keys.kind = 'credit' AND COALESCE(keys.abonos, 0) > 0 AND COALESCE(keys.cargos, 0) = 0)
            OR (
                keys.kind = 'asset'
                AND keys.amount <> 0
                AND (COALESCE(keys.abonos, 0) = 0 OR COALESCE(keys.cargos, 0) = 0)
            )
        )
    ORDER BY keys.row_hash, CASE keys.layer WHEN 'closed' THEN 0 ELSE 1 END
$function$;

-- Asset uploads are detected the same way as debit and credit uploads.
DROP TRIGGER IF EXISTS master_closed_aaccandass_f_transfer_links ON public.master_closed_aaccandass_f;
CREATE TRIGGER master_closed_aaccandass_f_transfer_links
AFTER INSERT ON public.master_closed_aaccandass_f
REFERENCING NEW TABLE AS added_rows
FOR EACH STATEMENT
EXECUTE FUNCTION public.detect_transfers_after_insert();

ALTER TABLE public.inter_accounts_d DROP CONSTRAINT IF EXISTS inter_accounts_d_kind_check;
ALTER TABLE public.inter_accounts_d
    ADD CONSTRAINT inter_accounts_d_kind_check CHECK (receiving_kind IN ('debit', 'credit', 'asset'));

CREATE OR REPLACE FUNCTION public.aaccandass_store_row(p_tenant uuid, p_user uuid, p_account_id integer, p_txn_date date, p_concept text, p_abonos numeric, p_cargos numeric, p_source text, p_note text, p_reported numeric)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        v_concept := CASE p_source WHEN 'adjustment' THEN 'Ajuste de saldo' WHEN 'opening' THEN 'Saldo inicial' ELSE 'Movimiento' END;
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
        file_id, tenant_id, user_id, account_id, bank_id, cutoff_id, txn_date, concept, abonos, cargos,
        concept_sk, row_hash, occurrence, entry_source, note, created_by, reported_balance
    )
    VALUES (
        NULL, p_tenant, p_user, p_account_id, v_account.bank_id,
        public.month_cutoff_id(p_tenant, p_user, p_account_id, p_txn_date), p_txn_date, v_concept, v_abonos,
        v_cargos, v_sk, v_hash, v_occurrence, p_source, NULLIF(BTRIM(COALESCE(p_note, '')), ''), p_user,
        ROUND(p_reported, 2)
    );
    RETURN v_hash;
END
$function$;

CREATE OR REPLACE FUNCTION public.ingest_aaccandass_upload(p_account_id integer, p_filename text, p_chosen_filename text, p_csv text, p_mapping jsonb, p_template_name text DEFAULT NULL::text, p_source_format text DEFAULT 'csv'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
        file_id, tenant_id, user_id, account_id, bank_id, cutoff_id, txn_date, concept, abonos, cargos,
        concept_sk, row_hash, occurrence, entry_source, created_by, source_line
    )
    SELECT
        v_upload, v_tenant, v_user, p_account_id, v_account.bank_id,
        public.month_cutoff_id(v_tenant, v_user, p_account_id, tmp.txn_date), tmp.txn_date, tmp.concept,
        tmp.abonos, tmp.cargos, tmp.concept_sk,
        public.movement_row_hash_v2(
            v_user, p_account_id, v_account.bank_id, tmp.txn_date, tmp.concept_sk, tmp.abonos, tmp.cargos,
            tmp.occurrence
        ),
        tmp.occurrence, 'upload', v_user, tmp.line_no
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
        'row_count', v_inserted,
        'read_rows', v_stats.ok_rows,
        'inserted', v_inserted,
        'target_table', 'master_closed_aaccandass_f',
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
$function$;

CREATE OR REPLACE FUNCTION public.aaccandass_rows(p_account_id integer DEFAULT NULL::integer, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_search text DEFAULT NULL::text, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
            keys.account_number,
            keys.bank_name,
            movement.txn_date,
            movement.concept,
            movement.concept_sk,
            movement.abonos,
            movement.cargos,
            movement.amount,
            movement.occurrence,
            movement.entry_source,
            movement.file_id,
            keys.file_name,
            movement.source_line,
            movement.reported_balance,
            movement.note,
            keys.period_start,
            running.balance,
            attrs.attribute_1,
            attrs.attribute_2,
            attrs.attribute_3,
            attrs.attribute_1_item_id,
            attrs.attribute_2_item_id,
            attrs.attribute_3_item_id
        FROM public.master_closed_aaccandass_f AS movement
        INNER JOIN public.movement_keys_v AS keys
            ON keys.source_table = 'master_closed_aaccandass_f' AND keys.row_id = movement.row_id
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
                OR keys.bank_name ILIKE '%' || v_search || '%'
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
$function$;

CREATE OR REPLACE FUNCTION public.graphql_rows(p_table text, p_months integer DEFAULT NULL::integer, p_after date DEFAULT NULL::date, p_as_of date DEFAULT NULL::date, p_limit integer DEFAULT 20000, p_exclude_transfers boolean DEFAULT false)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
                    keys.occurrence,
                    keys.file_name,
                    keys.source_profile,
                    keys.entry_source,
                    keys.cutoff_id,
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
                LEFT JOIN public.movement_balance_v AS running
                    ON running.source_table = keys.source_table AND running.row_id = keys.row_id
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
$function$;

CREATE OR REPLACE FUNCTION public.dimension_rows(p_kind text, p_layer text, p_from date DEFAULT NULL::date, p_to date DEFAULT NULL::date, p_search text DEFAULT NULL::text, p_limit integer DEFAULT 200, p_offset integer DEFAULT 0)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
            keys.entry_source,
            keys.cutoff_id,
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
        LEFT JOIN public.movement_balance_v AS running
            ON running.source_table = keys.source_table AND running.row_id = keys.row_id
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
$function$;

CREATE OR REPLACE FUNCTION public.update_bank_account_cutoff(p_account_id integer, p_cutoff_day integer, p_credit_days integer, p_as_of date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
                    FROM public.statement_uploads_f AS upload
                    INNER JOIN public.file_profiles_d AS profile ON profile.profile_code = upload.source_profile
                    WHERE
                        upload.upload_id = future_row.file_id
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
                    'period_start', moved.new_start,
                    'period_end', moved.new_date,
                    'txn_date', moved.new_date,
                    'concept', moved.concept,
                    'concept_sk', moved.concept_sk,
                    'bank_id', moved.bank_id,
                    'abonos', moved.abonos,
                    'cargos', moved.cargos,
                    'created_at', moved.created_at,
                    'occurrence', moved.new_occurrence,
                    'old_hash', moved.row_hash,
                    'row_hash', public.movement_row_hash_v2(
                        moved.user_id, moved.account_id, moved.bank_id, moved.new_date, moved.concept_sk,
                        moved.abonos, moved.cargos, moved.new_occurrence
                    )
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
                file_id, tenant_id, user_id, account_id, bank_id, cutoff_id, txn_date, concept,
                abonos, cargos, concept_sk, row_hash, occurrence, entry_source, created_at, created_by
            )
            SELECT
                (item ->> 'file_id')::UUID,
                v_tenant,
                v_user,
                p_account_id,
                (item ->> 'bank_id')::INTEGER,
                public.ledger_cutoff_id(
                    v_tenant, v_user, p_account_id, (item ->> 'period_start')::DATE, (item ->> 'period_end')::DATE
                ),
                (item ->> 'txn_date')::DATE,
                item ->> 'concept',
                (item ->> 'abonos')::NUMERIC(18, 2),
                (item ->> 'cargos')::NUMERIC(18, 2),
                item ->> 'concept_sk',
                item ->> 'row_hash',
                (item ->> 'occurrence')::INTEGER,
                'upload',
                COALESCE((item ->> 'created_at')::TIMESTAMPTZ, NOW()),
                v_user
            FROM JSONB_ARRAY_ELEMENTS(v_moved) AS moved_rows (item);

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
        SET cutoff_id = public.ledger_cutoff_id(
            v_tenant, v_user, p_account_id,
            (public.current_period(TRUE, p_cutoff_day, future_row.txn_date)).period_start,
            (public.current_period(TRUE, p_cutoff_day, future_row.txn_date)).period_end
        )
        FROM public.statement_uploads_f AS upload
        INNER JOIN public.file_profiles_d AS profile ON profile.profile_code = upload.source_profile
        WHERE
            future_row.account_id = p_account_id
            AND future_row.tenant_id = v_tenant
            AND future_row.user_id = v_user
            AND upload.upload_id = future_row.file_id
            AND profile.column_map ? 'pagos_hechos';
    END IF;

    IF p_cutoff_day IS DISTINCT FROM v_old_day THEN
        -- Empty periods were planned on the old day: drop them (unless a movement points at
        -- them) and re-plan.
        DELETE FROM public.cutoff_date_f AS cutoff
        WHERE
            cutoff.account_id = p_account_id
            AND cutoff.tenant_id = v_tenant
            AND cutoff.user_id = v_user
            AND NOT public.cutoff_in_use(cutoff.cutoff_id);
        GET DIAGNOSTICS v_cleared = ROW_COUNT;
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
$function$;

-- =============================================================================
-- 8. Any account: lookup, balance, column map preview
-- =============================================================================
CREATE OR REPLACE FUNCTION public.ledger_account(p_tenant UUID, p_user UUID, p_account_id INTEGER)
RETURNS TABLE (
    account_id INTEGER, account_name TEXT, account_number TEXT, bank_id INTEGER, bank_name TEXT,
    type_name TEXT, ledger_kind TEXT, allows_cutoff BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
    RETURN QUERY
    SELECT account.account_id, account.account_name, account.account_number, bank.bank_id, bank.bank_name,
        kind.type_name, kind.ledger_kind, kind.allows_cutoff
    FROM public.bank_accounts_d AS account
    INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
    INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
    WHERE account.account_id = p_account_id AND account.tenant_id = p_tenant AND account.user_id = p_user;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'account not found' USING ERRCODE = 'P0002';
    END IF;
END
$fn$;

-- Sum of amount up to a date: closed and open rows (or the asset table).
-- Debit amount is abonos + cargos; credit and assets are abonos - cargos.
-- For a credit card this sum is negative while money is owed.
CREATE OR REPLACE FUNCTION public.account_balance_at(p_account_id INTEGER, p_date DATE)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
    SELECT COALESCE(SUM(movement.amount), 0)::NUMERIC(18, 2)
    FROM (
        SELECT amount FROM public.master_debit_closed_f WHERE account_id = p_account_id AND txn_date <= p_date
        UNION ALL
        SELECT amount FROM public.master_debit_open_f WHERE account_id = p_account_id AND txn_date <= p_date
        UNION ALL
        SELECT amount FROM public.master_credit_closed_f WHERE account_id = p_account_id AND txn_date <= p_date
        UNION ALL
        SELECT amount FROM public.master_credit_open_f WHERE account_id = p_account_id AND txn_date <= p_date
        UNION ALL
        SELECT amount FROM public.master_closed_aaccandass_f WHERE account_id = p_account_id AND txn_date <= p_date
    ) AS movement
$fn$;

-- The balance as the bank shows it: debit and assets = money there, credit = amount owed.
CREATE OR REPLACE FUNCTION public.account_shown_balance(p_kind TEXT, p_sum NUMERIC)
RETURNS NUMERIC
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE WHEN p_kind = 'credit' THEN -p_sum ELSE p_sum END::NUMERIC(18, 2)
$fn$;

CREATE OR REPLACE FUNCTION public.aaccandass_balance_at(p_account_id INTEGER, p_date DATE)
RETURNS NUMERIC
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
    SELECT public.account_balance_at(p_account_id, p_date)
$fn$;

CREATE OR REPLACE FUNCTION public.column_map_preview(p_account_id integer, p_csv text, p_mapping jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
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
    v_saved RECORD;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    SELECT * INTO v_account FROM public.ledger_account(v_tenant, v_user, p_account_id);
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
    v_balance := public.account_balance_at(p_account_id, '9999-12-31');

    -- A map this account saved for files with the same headers.
    SELECT template.template_id, template.template_name, template.mapping
    INTO v_saved
    FROM public.aaccandass_templates_d AS template
    WHERE
        template.account_id = p_account_id
        AND template.user_id = v_user
        AND template.header_signature = public.column_map_signature(v_headers)
    ORDER BY template.last_used_at DESC NULLS LAST, template.template_id DESC
    LIMIT 1;

    IF NOT public.aaccandass_mapping_ready(v_map) THEN
        RETURN JSONB_BUILD_OBJECT(
            'ready', FALSE,
            'kind', public.account_type_family(v_account.type_name),
            'saved_mapping', CASE WHEN v_saved.template_id IS NULL THEN NULL ELSE JSONB_BUILD_OBJECT(
                'template_id', v_saved.template_id, 'template_name', v_saved.template_name, 'mapping', v_saved.mapping
            ) END,
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
    -- The mapper stores a signed column as + abono or a positive cargo. Only a debit
    -- account then stores that cargo negative. Credit and asset cargos stay positive.
    IF public.account_type_family(v_account.type_name) = 'debit' THEN
        UPDATE pg_temp.aaccandass_preview_tmp SET cargos = -cargos WHERE status = 'ok';
    END IF;
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
        'new_net', COALESCE(SUM(
            CASE WHEN public.account_type_family(v_account.type_name) = 'debit' THEN tmp.abonos + tmp.cargos ELSE tmp.abonos - tmp.cargos END
        ) FILTER (WHERE tmp.status = 'ok' AND stored.row_hash IS NULL), 0),
        'first_txn_date', MIN(tmp.txn_date) FILTER (WHERE tmp.status = 'ok'),
        'last_txn_date', MAX(tmp.txn_date) FILTER (WHERE tmp.status = 'ok')
    )
    INTO v_totals
    FROM pg_temp.aaccandass_preview_tmp AS tmp
    LEFT JOIN LATERAL (
        SELECT keys.row_hash FROM public.movement_keys_v AS keys
        WHERE keys.account_id = p_account_id AND keys.row_hash = tmp.row_hash AND keys.layer <> 'future'
        LIMIT 1
    ) AS stored ON TRUE;

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
        LEFT JOIN LATERAL (
            SELECT keys.row_hash FROM public.movement_keys_v AS keys
            WHERE keys.account_id = p_account_id AND keys.row_hash = tmp.row_hash AND keys.layer <> 'future'
            LIMIT 1
        ) AS stored ON TRUE
        ORDER BY tmp.line_no
        LIMIT 200
    ) AS page;
    DROP TABLE IF EXISTS pg_temp.aaccandass_preview_tmp;

    RETURN JSONB_BUILD_OBJECT(
        'ready', TRUE,
        'kind', public.account_type_family(v_account.type_name),
        'cargo_sign', CASE WHEN public.account_type_family(v_account.type_name) = 'debit' THEN 'negative' ELSE 'positive' END,
        'saved_mapping', CASE WHEN v_saved.template_id IS NULL THEN NULL ELSE JSONB_BUILD_OBJECT(
            'template_id', v_saved.template_id, 'template_name', v_saved.template_name, 'mapping', v_saved.mapping
        ) END,
        'headers', TO_JSONB(v_headers),
        'lines', v_lines,
        'mapping', v_map,
        'rows', v_rows,
        'totals', v_totals,
        'balance_before', v_balance,
        'balance_after', v_balance + (v_totals ->> 'new_net')::NUMERIC
    );
END
$function$;

CREATE OR REPLACE FUNCTION public.aaccandass_preview(p_account_id INTEGER, p_csv TEXT, p_mapping JSONB)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    PERFORM 1 FROM public.aaccandass_account(v_tenant, v_user, p_account_id);
    RETURN public.column_map_preview(p_account_id, p_csv, p_mapping);
END
$fn$;

-- =============================================================================
-- 9. Opening balance, monthly adjustment, balance rows (any account)
-- =============================================================================
-- One opening / adjustment row in the account's closed table (assets: their table). Bank
-- rows point at the statement period that contains the date; an opening row dated before
-- the first period points at the first period (it is that period's opening balance).
CREATE OR REPLACE FUNCTION public.balance_store_row(
    p_tenant UUID, p_user UUID, p_account_id INTEGER, p_txn_date DATE, p_concept TEXT,
    p_abonos NUMERIC, p_cargos NUMERIC, p_source TEXT, p_note TEXT, p_reported NUMERIC
) RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_account RECORD;
    v_table TEXT;
    v_concept TEXT := LEFT(BTRIM(REGEXP_REPLACE(COALESCE(p_concept, ''), '\s+', ' ', 'g')), 500);
    v_sk TEXT;
    v_abonos NUMERIC(18, 2) := ROUND(COALESCE(p_abonos, 0), 2);
    v_cargos NUMERIC(18, 2) := ROUND(COALESCE(p_cargos, 0), 2);
    v_cutoff INTEGER;
    v_occurrence INTEGER;
    v_hash TEXT;
BEGIN
    SELECT * INTO v_account FROM public.ledger_account(p_tenant, p_user, p_account_id);
    IF p_source NOT IN ('opening', 'adjustment') THEN
        RAISE EXCEPTION 'unknown entry source %', p_source USING ERRCODE = '22023';
    END IF;
    IF v_account.ledger_kind = 'asset' THEN
        RETURN public.aaccandass_store_row(
            p_tenant, p_user, p_account_id, p_txn_date, p_concept, p_abonos, p_cargos, p_source, p_note, p_reported
        );
    END IF;
    IF p_txn_date IS NULL OR p_txn_date < DATE '1950-01-01'
        OR p_txn_date > (NOW() AT TIME ZONE 'America/Mexico_City')::DATE + 366
    THEN
        RAISE EXCEPTION 'Pick a date between 1950 and next year' USING ERRCODE = '22023';
    END IF;
    IF v_abonos < 0 OR v_cargos < 0 OR (v_abonos = 0 AND v_cargos = 0) THEN
        RAISE EXCEPTION 'The amount must not be zero' USING ERRCODE = '22023';
    END IF;
    -- Callers pass magnitudes. Debit stores the cargo negative; credit stores it positive.
    IF v_account.ledger_kind = 'debit' THEN
        v_cargos := -v_cargos;
    END IF;
    IF COALESCE(LENGTH(p_note), 0) > 500 THEN
        RAISE EXCEPTION 'A note can have at most 500 characters' USING ERRCODE = '22023';
    END IF;
    IF public.concept_sk(v_concept) = '' THEN
        v_concept := CASE p_source WHEN 'opening' THEN 'Saldo inicial' ELSE 'Ajuste de saldo' END;
    END IF;
    v_sk := public.concept_sk(v_concept);
    v_table := CASE v_account.ledger_kind WHEN 'credit' THEN 'master_credit_closed_f' ELSE 'master_debit_closed_f' END;

    IF NOT EXISTS (SELECT 1 FROM public.statement_cutoffs_v AS cutoff WHERE cutoff.account_id = p_account_id) THEN
        PERFORM public.refresh_statement_periods(p_account_id, (NOW() AT TIME ZONE 'America/Mexico_City')::DATE);
    END IF;
    SELECT picked.cutoff_id INTO v_cutoff
    FROM (
        SELECT cutoff.cutoff_id, 0 AS rank_no, cutoff.period_start - DATE '2000-01-01' AS sort_key
        FROM public.statement_cutoffs_v AS cutoff
        WHERE cutoff.account_id = p_account_id AND p_txn_date BETWEEN cutoff.period_start AND cutoff.period_end
        UNION ALL
        SELECT cutoff.cutoff_id, 1, cutoff.period_start - DATE '2000-01-01'
        FROM public.statement_cutoffs_v AS cutoff
        WHERE cutoff.account_id = p_account_id AND cutoff.period_start > p_txn_date
        UNION ALL
        SELECT cutoff.cutoff_id, 2, DATE '2000-01-01' - cutoff.period_end
        FROM public.statement_cutoffs_v AS cutoff
        WHERE cutoff.account_id = p_account_id AND cutoff.period_end < p_txn_date
    ) AS picked
    ORDER BY picked.rank_no, picked.sort_key
    LIMIT 1;
    IF v_cutoff IS NULL THEN
        RAISE EXCEPTION 'The account has no statement period yet' USING ERRCODE = '22023';
    END IF;

    PERFORM PG_ADVISORY_XACT_LOCK(HASHTEXTEXTENDED('balance:' || p_account_id::TEXT, 0));
    EXECUTE FORMAT(
        'SELECT COALESCE(MAX(occurrence), 0) + 1 FROM public.%I
        WHERE account_id = $1 AND txn_date = $2 AND concept_sk = $3 AND abonos = $4 AND cargos = $5',
        v_table
    )
    INTO v_occurrence
    USING p_account_id, p_txn_date, v_sk, v_abonos, v_cargos;
    v_hash := public.movement_row_hash_v2(
        p_user, p_account_id, v_account.bank_id, p_txn_date, v_sk, v_abonos, v_cargos, v_occurrence
    );
    EXECUTE FORMAT(
        'INSERT INTO public.%I (
            file_id, tenant_id, user_id, account_id, bank_id, cutoff_id, txn_date, concept, abonos, cargos,
            concept_sk, row_hash, occurrence, entry_source, note, created_by
        )
        VALUES (NULL, $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $2)',
        v_table
    )
    USING p_tenant, p_user, p_account_id, v_account.bank_id, v_cutoff, p_txn_date, v_concept, v_abonos,
        v_cargos, v_sk, v_hash, v_occurrence, p_source, NULLIF(BTRIM(COALESCE(p_note, '')), '');
    RETURN v_hash;
END
$fn$;

-- First stored movement of an account (opening rows not counted).
CREATE OR REPLACE FUNCTION public.account_first_txn_date(p_account_id INTEGER)
RETURNS DATE
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
    SELECT MIN(keys.txn_date)
    FROM public.movement_keys_v AS keys
    WHERE keys.account_id = p_account_id AND keys.layer IN ('closed', 'open') AND keys.entry_source <> 'opening'
$fn$;

CREATE OR REPLACE FUNCTION public.account_opening_row(p_account_id INTEGER)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
    SELECT JSONB_BUILD_OBJECT(
        'row_hash', keys.row_hash, 'txn_date', keys.txn_date, 'concept', keys.concept,
        'abonos', keys.abonos, 'cargos', keys.cargos, 'note', keys.note
    )
    FROM public.movement_keys_v AS keys
    WHERE keys.account_id = p_account_id AND keys.entry_source = 'opening'
    ORDER BY keys.txn_date
    LIMIT 1
$fn$;

-- Saldo inicial: one row dated before the account's first movement (default: the day before).
-- p_balance is the balance as the bank showed it then: money in the account (debit, asset)
-- or the amount owed (credit card).
CREATE OR REPLACE FUNCTION public.add_opening_balance(
    p_account_id INTEGER, p_balance NUMERIC, p_txn_date DATE DEFAULT NULL, p_concept TEXT DEFAULT NULL,
    p_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_account RECORD;
    v_first DATE;
    v_date DATE;
    v_balance NUMERIC(18, 2) := ROUND(p_balance, 2);
    v_in NUMERIC(18, 2);
    v_hash TEXT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    SELECT * INTO v_account FROM public.ledger_account(v_tenant, v_user, p_account_id);
    IF v_balance IS NULL OR v_balance = 0 THEN
        RAISE EXCEPTION 'Type the opening balance' USING ERRCODE = '22023';
    END IF;
    PERFORM PG_ADVISORY_XACT_LOCK(HASHTEXTEXTENDED('balance:' || p_account_id::TEXT, 0));
    IF public.account_opening_row(p_account_id) IS NOT NULL THEN
        RAISE EXCEPTION 'This account already has an opening balance; delete it first' USING ERRCODE = '23505';
    END IF;
    v_first := public.account_first_txn_date(p_account_id);
    v_date := COALESCE(p_txn_date, v_first - 1);
    IF v_date IS NULL THEN
        RAISE EXCEPTION 'Pick the opening date (the account has no movements yet)' USING ERRCODE = '22023';
    END IF;
    IF v_first IS NOT NULL AND v_date >= v_first THEN
        RAISE EXCEPTION 'The opening balance must be dated before the first movement (%)', v_first
            USING ERRCODE = '22023';
    END IF;
    -- Money in the account: positive = abono. Credit: amount owed, positive = cargo.
    v_in := CASE WHEN v_account.ledger_kind = 'credit' THEN -v_balance ELSE v_balance END;
    v_hash := public.balance_store_row(
        v_tenant, v_user, p_account_id, v_date, COALESCE(NULLIF(BTRIM(p_concept), ''), 'Saldo inicial'),
        GREATEST(v_in, 0), GREATEST(-v_in, 0), 'opening', p_note, v_balance
    );
    RETURN JSONB_BUILD_OBJECT(
        'row_hash', v_hash,
        'account_id', p_account_id,
        'kind', v_account.ledger_kind,
        'txn_date', v_date,
        'first_txn_date', v_first,
        'opening_balance', v_balance,
        'balance', public.account_shown_balance(
            v_account.ledger_kind, public.account_balance_at(p_account_id, '9999-12-31')
        )
    );
END
$fn$;

-- Monthly check: the balance the bank shows at p_as_of minus the balance of the stored rows
-- becomes one adjustment row (dated p_as_of, or an earlier p_adjust_date). Kept in
-- aaccandass_checks_f (used by every account since sql/018).
CREATE OR REPLACE FUNCTION public.reconcile_account(
    p_account_id INTEGER, p_as_of DATE, p_reported_balance NUMERIC, p_adjust_date DATE DEFAULT NULL,
    p_concept TEXT DEFAULT NULL, p_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_account RECORD;
    v_reported NUMERIC(18, 2) := ROUND(p_reported_balance, 2);
    v_tracked NUMERIC(18, 2);
    v_difference NUMERIC(18, 2);
    v_in NUMERIC(18, 2);
    v_date DATE := COALESCE(p_adjust_date, p_as_of);
    v_hash TEXT;
    v_check BIGINT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    SELECT * INTO v_account FROM public.ledger_account(v_tenant, v_user, p_account_id);
    IF p_as_of IS NULL OR v_reported IS NULL THEN
        RAISE EXCEPTION 'Type the date and the balance the institution shows' USING ERRCODE = '22023';
    END IF;
    IF v_date > p_as_of THEN
        RAISE EXCEPTION 'The adjustment date must be on or before the balance date' USING ERRCODE = '22023';
    END IF;
    PERFORM PG_ADVISORY_XACT_LOCK(HASHTEXTEXTENDED('balance:' || p_account_id::TEXT, 0));
    v_tracked := public.account_shown_balance(v_account.ledger_kind, public.account_balance_at(p_account_id, p_as_of));
    v_difference := v_reported - v_tracked;
    IF v_difference <> 0 THEN
        v_in := CASE WHEN v_account.ledger_kind = 'credit' THEN -v_difference ELSE v_difference END;
        v_hash := public.balance_store_row(
            v_tenant, v_user, p_account_id, v_date, COALESCE(NULLIF(BTRIM(p_concept), ''), 'Ajuste de saldo'),
            GREATEST(v_in, 0), GREATEST(-v_in, 0), 'adjustment', p_note, v_reported
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
        'kind', v_account.ledger_kind,
        'as_of', p_as_of,
        'reported_balance', v_reported,
        'tracked_balance', v_tracked,
        'difference', v_difference,
        'adjustment', CASE WHEN v_hash IS NULL THEN NULL ELSE JSONB_BUILD_OBJECT(
            'row_hash', v_hash,
            'txn_date', v_date,
            'abonos', GREATEST(v_in, 0),
            'cargos', CASE
                WHEN v_account.ledger_kind = 'debit' THEN -GREATEST(-v_in, 0)
                ELSE GREATEST(-v_in, 0)
            END
        ) END,
        'balance', public.account_shown_balance(v_account.ledger_kind, public.account_balance_at(p_account_id, p_as_of))
    );
END
$fn$;

CREATE OR REPLACE FUNCTION public.reconcile_aaccandass(
    p_account_id INTEGER, p_as_of DATE, p_reported_balance NUMERIC, p_adjust_date DATE DEFAULT NULL,
    p_concept TEXT DEFAULT NULL, p_note TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    PERFORM 1 FROM public.aaccandass_account(v_tenant, v_user, p_account_id);
    RETURN public.reconcile_account(p_account_id, p_as_of, p_reported_balance, p_adjust_date, p_concept, p_note);
END
$fn$;

-- Delete an opening or adjustment row (uploaded rows go only with their file).
CREATE OR REPLACE FUNCTION public.delete_balance_row(p_row_hash TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_row RECORD;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    SELECT keys.source_table, keys.kind, keys.entry_source, keys.account_id
    INTO v_row
    FROM public.movement_keys_v AS keys
    WHERE keys.row_hash = p_row_hash AND keys.tenant_id = v_tenant AND keys.user_id = v_user
    ORDER BY CASE keys.layer WHEN 'closed' THEN 0 ELSE 1 END
    LIMIT 1;
    IF v_row.source_table IS NULL THEN
        RAISE EXCEPTION 'row not found' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.entry_source NOT IN ('opening', 'adjustment') THEN
        RAISE EXCEPTION 'Only an opening or adjustment row can be changed here' USING ERRCODE = '22023';
    END IF;
    EXECUTE FORMAT(
        'DELETE FROM public.%I WHERE row_hash = $1 AND tenant_id = $2',
        CASE v_row.kind WHEN 'debit' THEN 'debit_d' WHEN 'credit' THEN 'credit_d' ELSE 'master_closed_aaccandass_d' END
    )
    USING p_row_hash, v_tenant;
    PERFORM SET_CONFIG('strm.balance_row', p_row_hash, TRUE);
    EXECUTE FORMAT(
        'DELETE FROM public.%I WHERE row_hash = $1 AND tenant_id = $2 AND user_id = $3 AND file_id IS NULL',
        v_row.source_table
    )
    USING p_row_hash, v_tenant, v_user;
    PERFORM SET_CONFIG('strm.balance_row', '', TRUE);
    IF v_row.kind = 'asset' THEN
        PERFORM public.prune_ledger_cutoffs(v_row.account_id);
    END IF;
    RETURN JSONB_BUILD_OBJECT(
        'row_hash', p_row_hash,
        'deleted', TRUE,
        'balance', public.account_shown_balance(
            v_row.kind,
            public.account_balance_at(v_row.account_id, (NOW() AT TIME ZONE 'America/Mexico_City')::DATE)
        )
    );
END
$fn$;

-- Change the date or signed amount of one opening / adjustment row. Uploaded rows stay
-- with their file. p_amount is the ledger amount (debit: abonos + cargos; credit and
-- asset: abonos - cargos). Attributes and transfer links follow the new hash.
CREATE OR REPLACE FUNCTION public.update_balance_row(p_row_hash TEXT, p_txn_date DATE, p_amount NUMERIC)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_row RECORD;
    v_amount NUMERIC(18, 2) := ROUND(p_amount, 2);
    v_abonos NUMERIC(18, 2);
    v_cargos NUMERIC(18, 2);
    v_occurrence INTEGER;
    v_cutoff INTEGER;
    v_hash TEXT;
    v_batch TEXT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    SELECT keys.source_table, keys.kind, keys.entry_source, keys.account_id, keys.bank_id,
        keys.concept_sk, keys.concept, keys.txn_date
    INTO v_row
    FROM public.movement_keys_v AS keys
    WHERE keys.row_hash = p_row_hash AND keys.tenant_id = v_tenant AND keys.user_id = v_user
    ORDER BY CASE keys.layer WHEN 'closed' THEN 0 ELSE 1 END
    LIMIT 1;
    IF v_row.source_table IS NULL THEN
        RAISE EXCEPTION 'row not found' USING ERRCODE = 'P0002';
    END IF;
    IF v_row.entry_source NOT IN ('opening', 'adjustment') THEN
        RAISE EXCEPTION 'Only an opening or adjustment row can be changed here' USING ERRCODE = '22023';
    END IF;
    IF p_txn_date IS NULL OR p_txn_date < DATE '1950-01-01'
        OR p_txn_date > (NOW() AT TIME ZONE 'America/Mexico_City')::DATE + 366
    THEN
        RAISE EXCEPTION 'Pick a date between 1950 and next year' USING ERRCODE = '22023';
    END IF;
    IF v_amount IS NULL OR v_amount = 0 THEN
        RAISE EXCEPTION 'The amount must not be zero' USING ERRCODE = '22023';
    END IF;
    IF v_row.kind = 'debit' THEN
        v_abonos := GREATEST(v_amount, 0);
        v_cargos := LEAST(v_amount, 0);
    ELSE
        v_abonos := GREATEST(v_amount, 0);
        v_cargos := GREATEST(-v_amount, 0);
    END IF;
    PERFORM PG_ADVISORY_XACT_LOCK(HASHTEXTEXTENDED('balance:' || v_row.account_id::TEXT, 0));
    EXECUTE FORMAT(
        'SELECT COALESCE(MAX(occurrence), 0) + 1 FROM public.%I
        WHERE account_id = $1 AND txn_date = $2 AND concept_sk = $3 AND abonos = $4 AND cargos = $5 AND row_hash <> $6',
        v_row.source_table
    )
    INTO v_occurrence
    USING v_row.account_id, p_txn_date, v_row.concept_sk, v_abonos, v_cargos, p_row_hash;
    v_hash := public.movement_row_hash_v2(
        v_user, v_row.account_id, v_row.bank_id, p_txn_date, v_row.concept_sk, v_abonos, v_cargos, v_occurrence
    );
    SELECT cutoff.cutoff_id INTO v_cutoff
    FROM public.cutoff_date_f AS cutoff
    WHERE cutoff.account_id = v_row.account_id AND cutoff.user_id = v_user
      AND p_txn_date BETWEEN cutoff.period_start AND cutoff.period_end
    ORDER BY cutoff.cutoff_id
    LIMIT 1;
    IF v_cutoff IS NULL THEN
        v_cutoff := public.month_cutoff_id(v_tenant, v_user, v_row.account_id, p_txn_date);
    END IF;
    PERFORM SET_CONFIG('strm.rekey', 'on', TRUE);
    EXECUTE FORMAT(
        'UPDATE public.%I
        SET txn_date = $2, cutoff_id = $3, abonos = $4, cargos = $5, occurrence = $6, row_hash = $7
        WHERE row_hash = $1 AND tenant_id = $8 AND user_id = $9 AND file_id IS NULL',
        v_row.source_table
    )
    USING p_row_hash, p_txn_date, v_cutoff, v_abonos, v_cargos, v_occurrence, v_hash, v_tenant, v_user;
    PERFORM SET_CONFIG('strm.rekey', 'off', TRUE);
    IF v_hash <> p_row_hash THEN
        v_batch := FORMAT('balance:%s', v_hash);
        INSERT INTO public.row_hash_remap_f (
            batch, reason, kind, source_table, tenant_id, user_id, account_id, old_hash, new_hash
        )
        VALUES (
            v_batch, 'balance edit', v_row.kind, v_row.source_table, v_tenant, v_user,
            v_row.account_id, p_row_hash, v_hash
        );
        PERFORM public.apply_row_hash_remap(v_batch);
    END IF;
    RETURN JSONB_BUILD_OBJECT(
        'row_hash', v_hash,
        'previous_hash', p_row_hash,
        'txn_date', p_txn_date,
        'amount', v_amount,
        'balance', public.account_shown_balance(
            v_row.kind,
            public.account_balance_at(v_row.account_id, (NOW() AT TIME ZONE 'America/Mexico_City')::DATE)
        )
    );
END
$fn$;

-- Balance panel of one account: balance, first movement, opening row, balance rows, checks
-- and the last 12 month ends.
CREATE OR REPLACE FUNCTION public.account_balance_home(p_account_id INTEGER, p_as_of DATE DEFAULT NULL)
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
    v_first DATE;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    SELECT * INTO v_account FROM public.ledger_account(v_tenant, v_user, p_account_id);
    v_first := public.account_first_txn_date(p_account_id);
    RETURN JSONB_BUILD_OBJECT(
        'account_id', p_account_id,
        'account_name', v_account.account_name,
        'account_number', v_account.account_number,
        'bank_id', v_account.bank_id,
        'bank_name', v_account.bank_name,
        'kind', v_account.ledger_kind,
        'balance_meaning', CASE WHEN v_account.ledger_kind = 'credit' THEN 'owed' ELSE 'available' END,
        'as_of', v_as_of,
        'balance', public.account_shown_balance(v_account.ledger_kind, public.account_balance_at(p_account_id, v_as_of)),
        'first_txn_date', v_first,
        'default_opening_date', v_first - 1,
        'opening', public.account_opening_row(p_account_id),
        'balance_rows', COALESCE((
            SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
                'row_hash', keys.row_hash, 'txn_date', keys.txn_date, 'concept', keys.concept,
                'abonos', keys.abonos, 'cargos', keys.cargos, 'amount', keys.amount,
                'entry_source', keys.entry_source, 'note', keys.note
            ) ORDER BY keys.txn_date DESC, keys.row_id DESC)
            FROM public.movement_keys_v AS keys
            WHERE keys.account_id = p_account_id AND keys.user_id = v_user AND keys.entry_source IN ('opening', 'adjustment')
        ), '[]'::JSONB),
        'checks', COALESCE((
            SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
                'check_id', checks.check_id, 'as_of', checks.as_of, 'reported_balance', checks.reported_balance,
                'tracked_balance', checks.tracked_balance, 'difference', checks.difference,
                'adjustment_hash', checks.adjustment_hash
            ) ORDER BY checks.as_of DESC, checks.check_id DESC)
            FROM (
                SELECT * FROM public.aaccandass_checks_f AS checks
                WHERE checks.account_id = p_account_id AND checks.user_id = v_user
                ORDER BY checks.as_of DESC, checks.check_id DESC
                LIMIT 24
            ) AS checks
        ), '[]'::JSONB),
        'month_ends', COALESCE((
            SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
                'month_end', month_end,
                'balance', public.account_shown_balance(v_account.ledger_kind, public.account_balance_at(p_account_id, month_end))
            ) ORDER BY month_end DESC)
            FROM (
                SELECT (DATE_TRUNC('month', v_as_of) - MAKE_INTERVAL(months => step) + INTERVAL '1 month - 1 day')::DATE AS month_end
                FROM GENERATE_SERIES(0, 11) AS step
            ) AS months
        ), '[]'::JSONB)
    );
END
$fn$;

-- =============================================================================
-- 10. Banks: add, rename, remove, move an account to another bank
-- =============================================================================
ALTER TABLE public.banks_d ADD COLUMN IF NOT EXISTS created_by UUID;
ALTER TABLE public.banks_d ADD COLUMN IF NOT EXISTS created_at TIMESTAMPTZ DEFAULT NOW();
ALTER TABLE public.banks_d ADD COLUMN IF NOT EXISTS tenant_id UUID;

-- A bank a person adds belongs to that person and their tenant. Seeded banks (Banorte,
-- BBVA, institutions) stay with both empty, so the delete policy below cannot match them.
UPDATE public.banks_d AS bank
SET tenant_id = membership.tenant_id
FROM public.tenant_users AS membership
WHERE bank.tenant_id IS NULL
  AND bank.created_by = membership.user_id
  AND NOT EXISTS (
      SELECT 1 FROM public.tenant_users AS other
      WHERE other.user_id = bank.created_by AND other.tenant_id <> membership.tenant_id
  );

ALTER TABLE public.banks_d DROP CONSTRAINT IF EXISTS banks_d_tenant_user_fkey;
ALTER TABLE public.banks_d
    ADD CONSTRAINT banks_d_tenant_user_fkey
    FOREIGN KEY (tenant_id, created_by) REFERENCES public.tenant_users (tenant_id, user_id);

-- strm_app can read the shared catalogue. It can delete only a row it added, for the
-- session tenant and user. create_bank / rename_bank / delete_bank are SECURITY DEFINER
-- and repeat that scope; this policy is what a direct DELETE is limited to.
ALTER TABLE public.banks_d ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS banks_d_read ON public.banks_d;
CREATE POLICY banks_d_read ON public.banks_d
FOR SELECT
TO strm_app
USING (TRUE);
DROP POLICY IF EXISTS banks_d_delete ON public.banks_d;
CREATE POLICY banks_d_delete ON public.banks_d
FOR DELETE
TO strm_app
USING (
    tenant_id = public.session_tenant()
    AND created_by = public.session_user()
);
GRANT DELETE ON public.banks_d TO strm_app;

-- banks_d is one shared catalogue. A user can rename a bank when no other customer has an
-- account there and no built-in statement profile reads it (Banorte, BBVA: those names
-- are matched by the profiles and stay as seeded).
CREATE OR REPLACE FUNCTION public.bank_catalog()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    RETURN COALESCE((
        SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
            'bank_id', bank.bank_id,
            'bank_name', bank.bank_name,
            'is_institution', bank.is_institution,
            'has_profile', EXISTS (
                SELECT 1 FROM public.file_profiles_d AS fp
                WHERE LOWER(fp.bank_name) = LOWER(bank.bank_name) AND fp.active IS TRUE
            ),
            'my_accounts', (
                SELECT COUNT(*) FROM public.bank_accounts_d AS account
                WHERE account.bank_id = bank.bank_id AND account.tenant_id = v_tenant AND account.user_id = v_user
            ),
            'can_rename', NOT EXISTS (
                SELECT 1 FROM public.bank_accounts_d AS account
                WHERE account.bank_id = bank.bank_id AND account.tenant_id <> v_tenant
            ) AND NOT EXISTS (
                SELECT 1 FROM public.file_profiles_d AS fp WHERE LOWER(fp.bank_name) = LOWER(bank.bank_name)
            ),
            'can_remove', bank.created_by = v_user
                AND bank.tenant_id = v_tenant
                AND NOT EXISTS (
                    SELECT 1 FROM public.file_profiles_d AS fp
                    WHERE LOWER(fp.bank_name) = LOWER(bank.bank_name)
                )
                AND NOT EXISTS (
                    SELECT 1 FROM public.bank_accounts_d AS account
                    WHERE account.bank_id = bank.bank_id
                ),
            'remove_block', CASE
                WHEN bank.created_by = v_user
                    AND bank.tenant_id = v_tenant
                    AND NOT EXISTS (
                        SELECT 1 FROM public.file_profiles_d AS fp
                        WHERE LOWER(fp.bank_name) = LOWER(bank.bank_name)
                    )
                    AND EXISTS (
                        SELECT 1 FROM public.bank_accounts_d AS account
                        WHERE account.bank_id = bank.bank_id
                    )
                THEN 'Move or delete its accounts first'
            END
        ) ORDER BY bank.is_institution, LOWER(bank.bank_name))
        FROM public.banks_d AS bank
    ), '[]'::JSONB);
END
$fn$;

CREATE OR REPLACE FUNCTION public.clean_bank_name(p_name TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_name TEXT := BTRIM(REGEXP_REPLACE(COALESCE(p_name, ''), '\s+', ' ', 'g'));
BEGIN
    IF LENGTH(v_name) < 2 OR LENGTH(v_name) > 60 THEN
        RAISE EXCEPTION 'A bank name has 2 to 60 characters' USING ERRCODE = '22023';
    END IF;
    RETURN v_name;
END
$fn$;

CREATE OR REPLACE FUNCTION public.create_bank(p_bank_name TEXT, p_is_institution BOOLEAN DEFAULT FALSE)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_name TEXT := public.clean_bank_name(p_bank_name);
    v_id INTEGER;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    IF EXISTS (SELECT 1 FROM public.banks_d AS bank WHERE LOWER(bank.bank_name) = LOWER(v_name)) THEN
        RAISE EXCEPTION 'That bank already exists' USING ERRCODE = '23505';
    END IF;
    INSERT INTO public.banks_d (bank_name, is_institution, created_by, tenant_id)
    VALUES (v_name, COALESCE(p_is_institution, FALSE), v_user, v_tenant)
    RETURNING bank_id INTO v_id;
    RETURN JSONB_BUILD_OBJECT('bank_id', v_id, 'bank_name', v_name, 'is_institution', COALESCE(p_is_institution, FALSE));
END
$fn$;

CREATE OR REPLACE FUNCTION public.rename_bank(p_bank_id INTEGER, p_bank_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_name TEXT := public.clean_bank_name(p_bank_name);
    v_old TEXT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    SELECT bank.bank_name INTO v_old FROM public.banks_d AS bank WHERE bank.bank_id = p_bank_id FOR UPDATE;
    IF v_old IS NULL THEN
        RAISE EXCEPTION 'bank not found' USING ERRCODE = 'P0002';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.bank_accounts_d AS account
        WHERE account.bank_id = p_bank_id AND account.tenant_id <> v_tenant
    ) THEN
        RAISE EXCEPTION 'Other customers have accounts at this bank; it cannot be renamed here' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (SELECT 1 FROM public.file_profiles_d AS fp WHERE LOWER(fp.bank_name) = LOWER(v_old)) THEN
        RAISE EXCEPTION 'This bank has a built-in statement profile; its name stays as it is' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.banks_d AS bank WHERE LOWER(bank.bank_name) = LOWER(v_name) AND bank.bank_id <> p_bank_id
    ) THEN
        RAISE EXCEPTION 'That bank already exists' USING ERRCODE = '23505';
    END IF;
    UPDATE public.banks_d SET bank_name = v_name WHERE bank_id = p_bank_id;
    RETURN JSONB_BUILD_OBJECT('bank_id', p_bank_id, 'bank_name', v_name, 'previous_name', v_old);
END
$fn$;

-- Remove a bank the session user added. Built-in names (Banorte, BBVA, any file profile)
-- and banks added by someone else stay. Any account, of any customer, blocks the delete.
-- The DELETE predicate matches banks_d_delete, so a direct delete by strm_app is the same
-- scope (that user's tenant and created_by).
CREATE OR REPLACE FUNCTION public.delete_bank(p_bank_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_name TEXT;
    v_created_by UUID;
    v_owner_tenant UUID;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    SELECT bank.bank_name, bank.created_by, bank.tenant_id
    INTO v_name, v_created_by, v_owner_tenant
    FROM public.banks_d AS bank
    WHERE bank.bank_id = p_bank_id
    FOR UPDATE;
    IF v_name IS NULL THEN
        RAISE EXCEPTION 'bank not found' USING ERRCODE = 'P0002';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.file_profiles_d AS fp WHERE LOWER(fp.bank_name) = LOWER(v_name)
    ) OR v_created_by IS NULL OR v_created_by <> v_user OR v_owner_tenant IS DISTINCT FROM v_tenant THEN
        RAISE EXCEPTION 'Only a bank you added can be removed' USING ERRCODE = '42501';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.bank_accounts_d AS account WHERE account.bank_id = p_bank_id
    ) THEN
        RAISE EXCEPTION 'Move or delete its accounts first' USING ERRCODE = '42501';
    END IF;
    BEGIN
        DELETE FROM public.banks_d AS bank
        WHERE bank.bank_id = p_bank_id
          AND bank.tenant_id = v_tenant
          AND bank.created_by = v_user;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Only a bank you added can be removed' USING ERRCODE = '42501';
        END IF;
    EXCEPTION
        WHEN foreign_key_violation THEN
            RAISE EXCEPTION 'Move or delete its accounts first' USING ERRCODE = '42501';
    END;
    RETURN JSONB_BUILD_OBJECT('bank_id', p_bank_id, 'bank_name', v_name);
END
$fn$;

-- Move an account to another bank. row_hash includes bank_id, so every stored row of the
-- account is re-keyed (closed rows too, inside this function only) and its attributes, list
-- items, transfer links and checks follow (row_hash_remap_f, apply_row_hash_remap).
-- Uploads, periods and completeness are keyed by account and do not change. Vault files
-- already written keep their names (write-once); the next files use the new bank name.
CREATE OR REPLACE FUNCTION public.set_account_bank(p_account_id INTEGER, p_bank_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_account RECORD;
    v_batch TEXT;
    v_spec RECORD;
    v_rows INTEGER := 0;
    v_count INTEGER;
    v_remap JSONB;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    SELECT * INTO v_account FROM public.ledger_account(v_tenant, v_user, p_account_id);
    IF NOT EXISTS (SELECT 1 FROM public.banks_d AS bank WHERE bank.bank_id = p_bank_id) THEN
        RAISE EXCEPTION 'bank not found' USING ERRCODE = 'P0002';
    END IF;
    IF v_account.bank_id = p_bank_id THEN
        RETURN JSONB_BUILD_OBJECT('account_id', p_account_id, 'bank_id', p_bank_id, 'rows_rekeyed', 0);
    END IF;
    PERFORM PG_ADVISORY_XACT_LOCK(HASHTEXTEXTENDED('balance:' || p_account_id::TEXT, 0));
    UPDATE public.bank_accounts_d
    SET bank_id = p_bank_id
    WHERE account_id = p_account_id AND tenant_id = v_tenant AND user_id = v_user;

    v_batch := FORMAT('bank:%s:%s', p_account_id, TO_CHAR(CLOCK_TIMESTAMP(), 'YYYYMMDDHH24MISSUS'));
    PERFORM SET_CONFIG('strm.rekey', 'on', TRUE);
    FOR v_spec IN
        SELECT * FROM (VALUES
            ('master_debit_closed_f', 'debit'), ('master_debit_open_f', 'debit'),
            ('master_credit_closed_f', 'credit'), ('master_credit_open_f', 'credit'),
            ('master_credit_future_f', 'credit'), ('master_closed_aaccandass_f', 'asset')
        ) AS spec (table_name, kind)
    LOOP
        EXECUTE FORMAT(
            'WITH changed AS (
                UPDATE public.%1$I AS movement
                SET
                    bank_id = $1,
                    row_hash = public.movement_row_hash_v2(
                        movement.user_id, movement.account_id, $1, movement.txn_date, movement.concept_sk,
                        movement.abonos, movement.cargos, movement.occurrence
                    )
                FROM (SELECT row_id, row_hash AS old_hash FROM public.%1$I WHERE account_id = $2) AS old
                WHERE movement.row_id = old.row_id
                RETURNING old.old_hash, movement.row_hash AS new_hash, movement.tenant_id, movement.user_id
            )
            INSERT INTO public.row_hash_remap_f (
                batch, reason, kind, source_table, tenant_id, user_id, account_id, old_hash, new_hash
            )
            SELECT $3, ''bank change'', %2$L, %1$L, tenant_id, user_id, $2, old_hash, new_hash FROM changed',
            v_spec.table_name, v_spec.kind
        )
        USING p_bank_id, p_account_id, v_batch;
        GET DIAGNOSTICS v_count = ROW_COUNT;
        v_rows := v_rows + v_count;
    END LOOP;
    PERFORM SET_CONFIG('strm.rekey', 'off', TRUE);
    v_remap := public.apply_row_hash_remap(v_batch);
    RETURN JSONB_BUILD_OBJECT(
        'account_id', p_account_id,
        'previous_bank_id', v_account.bank_id,
        'bank_id', p_bank_id,
        'rows_rekeyed', v_rows,
        'remap', v_remap
    );
END
$fn$;

-- =============================================================================
-- 11. Grants
-- =============================================================================
DO $do$
DECLARE
    v_fn TEXT;
BEGIN
    FOREACH v_fn IN ARRAY ARRAY[
        'public.ingest_statement_csv(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE, TEXT, TEXT, JSONB, TEXT)',
        'public.ingest_statement_upload(INTEGER, INTEGER, TEXT, TEXT, TEXT, TEXT, DATE, TEXT, TEXT, JSONB, TEXT)',
        'public.column_map_preview(INTEGER, TEXT, JSONB)',
        'public.aaccandass_preview(INTEGER, TEXT, JSONB)',
        'public.add_opening_balance(INTEGER, NUMERIC, DATE, TEXT, TEXT)',
        'public.reconcile_account(INTEGER, DATE, NUMERIC, DATE, TEXT, TEXT)',
        'public.reconcile_aaccandass(INTEGER, DATE, NUMERIC, DATE, TEXT, TEXT)',
        'public.delete_balance_row(TEXT)',
        'public.update_balance_row(TEXT, DATE, NUMERIC)',
        'public.account_balance_home(INTEGER, DATE)',
        'public.bank_catalog()',
        'public.create_bank(TEXT, BOOLEAN)',
        'public.rename_bank(INTEGER, TEXT)',
        'public.delete_bank(INTEGER)',
        'public.set_account_bank(INTEGER, INTEGER)'
    ] LOOP
        EXECUTE FORMAT('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_fn);
        EXECUTE FORMAT('GRANT EXECUTE ON FUNCTION %s TO strm_app', v_fn);
    END LOOP;
    FOREACH v_fn IN ARRAY ARRAY[
        'public.apply_row_hash_remap(TEXT)',
        'public.balance_store_row(UUID, UUID, INTEGER, DATE, TEXT, NUMERIC, NUMERIC, TEXT, TEXT, NUMERIC)',
        'public.ledger_account(UUID, UUID, INTEGER)',
        'public.account_balance_at(INTEGER, DATE)',
        'public.account_first_txn_date(INTEGER)',
        'public.account_opening_row(INTEGER)'
    ] LOOP
        EXECUTE FORMAT('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_fn);
    END LOOP;
END
$do$;
