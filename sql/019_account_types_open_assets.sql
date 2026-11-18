-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- Account types and the open asset master (sql/019).
--
-- Three account types. The type is the only routing source (account_type_family):
--   Bank credit card -> credit (master_credit_open_f, master_credit_closed_f, master_credit_future_f)
--   Bank debit       -> debit  (master_debit_open_f, master_debit_closed_f)
--   Savings, investments, assets, credit contracts -> asset
--     current period   -> master_open_aaccandass_f   (replaced on each open upload)
--     every other date -> master_closed_aaccandass_f (append)
-- The open window is the statement period that contains today (America/Mexico_City)
-- when the account has one, otherwise the calendar month of today.
-- ledger_kind is kept equal to that family. master_open_aaccandass_f shares
-- master_closed_aaccandass_d, the sign rule (cargos >= 0, amount = abonos - cargos) and the
-- transfer trigger. It is replaceable: no append-only trigger.
-- Every other type is dropped; its accounts move to the type of their family.
-- Re-applying sql/006 or sql/017 after this file adds old type names back. Do not.

CREATE OR REPLACE FUNCTION public.account_type_family(p_type_name TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE LOWER(BTRIM(p_type_name))
        WHEN 'bank credit card' THEN 'credit'
        WHEN 'bank debit' THEN 'debit'
        WHEN 'savings, investments, assets, credit contracts' THEN 'asset'
        ELSE NULL
    END
$fn$;

COMMENT ON FUNCTION public.account_type_family(TEXT) IS
'The only routing source (sql/019): Bank credit card -> credit, Bank debit -> debit, '
'Savings, investments, assets, credit contracts -> asset.';

ALTER TABLE public.account_types_d
DROP CONSTRAINT IF EXISTS account_types_d_name_family_check;

-- One row per type. Every account moves onto the type of its family, then the rest go.
DO $remap$
DECLARE
    v_spec RECORD;
    v_keep INTEGER;
BEGIN
    FOR v_spec IN
        SELECT * FROM (VALUES
            (
                'Bank credit card', 'credit', TRUE,
                ARRAY['bank credit card', 'credit', 'credit card', 'tarjeta de credito']
            ),
            ('Bank debit', 'debit', FALSE, ARRAY['bank debit', 'debit']),
            (
                'Savings, investments, assets, credit contracts', 'asset', FALSE,
                ARRAY[
                    'savings, investments, assets, credit contracts', 'savings', 'ahorro',
                    'investment', 'asset', 'credit contract'
                ]
            )
        ) AS spec (type_name, family, allows_cutoff, old_names)
    LOOP
        v_keep := NULL;
        SELECT kind.a_type_id INTO v_keep
        FROM public.account_types_d AS kind
        WHERE LOWER(kind.type_name) = ANY (v_spec.old_names)
        ORDER BY ARRAY_POSITION(v_spec.old_names, LOWER(kind.type_name)), kind.a_type_id
        LIMIT 1;
        IF v_keep IS NULL THEN
            INSERT INTO public.account_types_d (type_name, ledger_kind, allows_cutoff)
            VALUES (v_spec.type_name, v_spec.family, v_spec.allows_cutoff)
            RETURNING a_type_id INTO v_keep;
        END IF;
        -- Old names first, then any leftover type of the same ledger family.
        UPDATE public.bank_accounts_d AS account
        SET a_type_id = v_keep
        FROM public.account_types_d AS old
        WHERE account.a_type_id = old.a_type_id
            AND old.a_type_id <> v_keep
            AND (
                LOWER(old.type_name) = ANY (v_spec.old_names)
                OR (
                    LOWER(old.type_name) <> ALL (ARRAY[
                        'bank credit card', 'credit', 'credit card', 'tarjeta de credito', 'bank debit', 'debit',
                        'savings, investments, assets, credit contracts', 'savings', 'ahorro', 'investment',
                        'asset', 'credit contract'
                    ])
                    AND old.ledger_kind = v_spec.family
                )
            );
        UPDATE public.account_types_d
        SET type_name = v_spec.type_name, ledger_kind = v_spec.family, allows_cutoff = v_spec.allows_cutoff
        WHERE a_type_id = v_keep;
    END LOOP;

    DELETE FROM public.account_types_d AS kind
    WHERE LOWER(kind.type_name) NOT IN (
        'bank credit card', 'bank debit', 'savings, investments, assets, credit contracts'
    );
END
$remap$;

ALTER TABLE public.account_types_d
DROP CONSTRAINT IF EXISTS account_types_d_name_family_check;

ALTER TABLE public.account_types_d
ADD CONSTRAINT account_types_d_name_family_check CHECK (
    ledger_kind = public.account_type_family(type_name)
);

-- Open asset movements: same columns and sign rule as the closed table. Attributes stay
-- in master_closed_aaccandass_d (one row per row_hash, shared by both tables).
CREATE TABLE IF NOT EXISTS public.master_open_aaccandass_f (
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
    amount NUMERIC(18, 2) GENERATED ALWAYS AS (abonos - cargos) STORED,
    concept_sk TEXT NOT NULL,
    row_hash TEXT NOT NULL,
    occurrence INTEGER NOT NULL DEFAULT 1,
    entry_source TEXT NOT NULL DEFAULT 'upload',
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    created_by UUID,
    source_line INTEGER,
    reported_balance NUMERIC(18, 2)
);

DO $open$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.master_open_aaccandass_f'::REGCLASS AND contype = 'p'
    ) THEN
        ALTER TABLE public.master_open_aaccandass_f
        ADD CONSTRAINT master_open_aaccandass_f_pkey PRIMARY KEY (row_id);
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conrelid = 'public.master_open_aaccandass_f'::REGCLASS
            AND conname = 'master_open_aaccandass_f_cutoff_fkey'
    ) THEN
        ALTER TABLE public.master_open_aaccandass_f
        ADD CONSTRAINT master_open_aaccandass_f_file_fkey
            FOREIGN KEY (file_id) REFERENCES public.aaccandass_uploads_f (upload_id),
        ADD CONSTRAINT master_open_aaccandass_f_tenant_user_fkey
            FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
        ADD CONSTRAINT master_open_aaccandass_f_account_fkey
            FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id),
        ADD CONSTRAINT master_open_aaccandass_f_bank_fkey
            FOREIGN KEY (bank_id) REFERENCES public.banks_d (bank_id),
        ADD CONSTRAINT master_open_aaccandass_f_cutoff_fkey
            FOREIGN KEY (cutoff_id) REFERENCES public.cutoff_date_f (cutoff_id),
        ADD CONSTRAINT master_open_aaccandass_f_sign_check CHECK (abonos >= 0 AND cargos >= 0),
        ADD CONSTRAINT master_open_aaccandass_f_concept_sk_check CHECK (LENGTH(concept_sk) > 0),
        ADD CONSTRAINT master_open_aaccandass_f_occurrence_check CHECK (occurrence >= 1),
        ADD CONSTRAINT master_open_aaccandass_f_hash_check CHECK (LENGTH(row_hash) = 64),
        ADD CONSTRAINT master_open_aaccandass_f_note_check CHECK (COALESCE(LENGTH(note), 0) <= 500),
        ADD CONSTRAINT master_open_aaccandass_f_source_check CHECK (
            entry_source IN ('upload', 'manual', 'opening', 'adjustment')
            AND ((entry_source = 'upload') = (file_id IS NOT NULL))
        );
    END IF;
END
$open$;

CREATE UNIQUE INDEX IF NOT EXISTS master_open_aaccandass_f_hash_key
ON public.master_open_aaccandass_f (row_hash);
CREATE INDEX IF NOT EXISTS master_open_aaccandass_f_file_idx
ON public.master_open_aaccandass_f (file_id);
CREATE INDEX IF NOT EXISTS master_open_aaccandass_f_tenant_idx
ON public.master_open_aaccandass_f (tenant_id, user_id);
CREATE INDEX IF NOT EXISTS master_open_aaccandass_f_account_idx
ON public.master_open_aaccandass_f (account_id, txn_date, row_id);
CREATE INDEX IF NOT EXISTS master_open_aaccandass_f_cutoff_idx
ON public.master_open_aaccandass_f (cutoff_id);

DROP TRIGGER IF EXISTS master_open_aaccandass_f_attribute_rows ON public.master_open_aaccandass_f;
CREATE TRIGGER master_open_aaccandass_f_attribute_rows
AFTER INSERT ON public.master_open_aaccandass_f
REFERENCING NEW TABLE AS added_rows
FOR EACH STATEMENT
EXECUTE FUNCTION public.add_movement_attribute_rows('master_closed_aaccandass_d');

DROP TRIGGER IF EXISTS master_open_aaccandass_f_transfer_links ON public.master_open_aaccandass_f;
CREATE TRIGGER master_open_aaccandass_f_transfer_links
AFTER INSERT ON public.master_open_aaccandass_f
REFERENCING NEW TABLE AS added_rows
FOR EACH STATEMENT
EXECUTE FUNCTION public.detect_transfers_after_insert();

ALTER TABLE public.master_open_aaccandass_f ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS master_open_aaccandass_f_tenant ON public.master_open_aaccandass_f;
CREATE POLICY master_open_aaccandass_f_tenant ON public.master_open_aaccandass_f
TO strm_app
USING (tenant_id = public.session_tenant() AND user_id = public.session_user())
WITH CHECK (tenant_id = public.session_tenant() AND user_id = public.session_user());
REVOKE ALL ON public.master_open_aaccandass_f FROM PUBLIC;
GRANT SELECT ON public.master_open_aaccandass_f TO strm_app;

COMMENT ON TABLE public.master_open_aaccandass_f IS
'Current-period investment, savings, asset and credit-contract movements (sql/019). Same '
'columns and signs as master_closed_aaccandass_f (cargos >= 0, amount = abonos - cargos). '
'An upload replaces every open row of the account; other dates append to the closed table. '
'Attributes are master_closed_aaccandass_d.';

-- Keys: open asset rows sit beside the closed ones (layer open). Grants on the view survive.
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
LEFT JOIN public.aaccandass_uploads_f AS upload ON movement.file_id = upload.upload_id
UNION ALL
SELECT
    movement.row_hash,
    'open'::TEXT AS layer,
    'asset'::TEXT AS kind,
    'master_open_aaccandass_f'::TEXT AS source_table,
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
FROM public.master_open_aaccandass_f AS movement
INNER JOIN public.bank_accounts_d AS account ON movement.account_id = account.account_id
INNER JOIN public.banks_d AS bank ON movement.bank_id = bank.bank_id
INNER JOIN public.cutoff_date_f AS cutoff ON movement.cutoff_id = cutoff.cutoff_id
LEFT JOIN public.aaccandass_uploads_f AS upload ON movement.file_id = upload.upload_id;

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
        UNION ALL
        SELECT amount FROM public.master_open_aaccandass_f WHERE account_id = p_account_id AND txn_date <= p_date
    ) AS movement
$fn$;

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
        OR EXISTS (SELECT 1 FROM public.master_closed_aaccandass_f AS m WHERE m.cutoff_id = p_cutoff_id)
        OR EXISTS (SELECT 1 FROM public.master_open_aaccandass_f AS m WHERE m.cutoff_id = p_cutoff_id);
END
$fn$;

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
        kind.type_name, public.account_type_family(kind.type_name), kind.allows_cutoff
    FROM public.bank_accounts_d AS account
    INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
    INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
    WHERE account.account_id = p_account_id AND account.tenant_id = p_tenant AND account.user_id = p_user;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'account not found' USING ERRCODE = 'P0002';
    END IF;
END
$fn$;

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
    v_open_inserted INTEGER := 0;
    v_closed_inserted INTEGER := 0;
    v_today DATE;
    v_open_start DATE;
    v_open_end DATE;
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
    -- Open window: the statement period that contains today, else this calendar month.
    v_today := (NOW() AT TIME ZONE 'America/Mexico_City')::DATE;
    SELECT cutoff.period_start, cutoff.period_end
    INTO v_open_start, v_open_end
    FROM public.statement_cutoffs_v AS cutoff
    WHERE cutoff.account_id = p_account_id AND v_today BETWEEN cutoff.period_start AND cutoff.period_end
    ORDER BY cutoff.period_start
    LIMIT 1;
    IF v_open_start IS NULL THEN
        v_open_start := DATE_TRUNC('month', v_today)::DATE;
        v_open_end := (DATE_TRUNC('month', v_today) + INTERVAL '1 month - 1 day')::DATE;
    END IF;

    IF EXISTS (
        SELECT 1 FROM pg_temp.aaccandass_ingest_tmp AS tmp
        WHERE tmp.txn_date BETWEEN v_open_start AND v_open_end
    ) THEN
        DELETE FROM public.master_closed_aaccandass_d AS dim
        USING public.master_open_aaccandass_f AS movement
        WHERE movement.account_id = p_account_id
            AND dim.row_hash = movement.row_hash
            AND NOT EXISTS (
                SELECT 1 FROM public.master_closed_aaccandass_f AS closed
                WHERE closed.row_hash = dim.row_hash
            );
        DELETE FROM public.master_open_aaccandass_f WHERE account_id = p_account_id;
    END IF;

    INSERT INTO public.master_open_aaccandass_f (
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
    WHERE tmp.txn_date BETWEEN v_open_start AND v_open_end
    ORDER BY tmp.txn_date, tmp.line_no;
    GET DIAGNOSTICS v_open_inserted = ROW_COUNT;

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
    WHERE tmp.txn_date < v_open_start OR tmp.txn_date > v_open_end
    ORDER BY tmp.txn_date, tmp.line_no
    ON CONFLICT (row_hash) DO NOTHING;
    GET DIAGNOSTICS v_closed_inserted = ROW_COUNT;
    v_inserted := v_open_inserted + v_closed_inserted;
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
        'target_table', CASE
            WHEN v_open_inserted > 0 AND v_closed_inserted > 0
                THEN 'master_open_aaccandass_f, master_closed_aaccandass_f'
            WHEN v_open_inserted > 0 THEN 'master_open_aaccandass_f'
            ELSE 'master_closed_aaccandass_f'
        END,
        'open_inserted', v_open_inserted,
        'closed_inserted', v_closed_inserted,
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
        FROM (
            SELECT movement.*, 'master_closed_aaccandass_f'::TEXT AS source_table
            FROM public.master_closed_aaccandass_f AS movement
            UNION ALL
            SELECT movement.*, 'master_open_aaccandass_f'::TEXT AS source_table
            FROM public.master_open_aaccandass_f AS movement
        ) AS movement
        INNER JOIN public.movement_keys_v AS keys
            ON keys.source_table = movement.source_table AND keys.row_id = movement.row_id
        INNER JOIN public.movement_balance_v AS running
            ON running.source_table = movement.source_table AND running.row_id = movement.row_id
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
        'master_closed_aaccandass_f', 'master_open_aaccandass_f'
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
        ('asset', 'closed'), ('asset', 'open')
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
            ('master_credit_future_f', 'credit'), ('master_closed_aaccandass_f', 'asset'), ('master_open_aaccandass_f', 'asset')
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

-- Installed over an older sql/018 so routing follows the type and the preview keeps
-- asset-family cargos positive. A database that already has this body is unchanged.
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

-- Deleting a file removes its rows from both asset tables.
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
    v_rows INTEGER := 0;
    v_count INTEGER;
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
    USING (
        SELECT movement.row_hash FROM public.master_closed_aaccandass_f AS movement
        WHERE movement.file_id = p_upload_id
        UNION ALL
        SELECT movement.row_hash FROM public.master_open_aaccandass_f AS movement
        WHERE movement.file_id = p_upload_id
    ) AS movement
    WHERE dim.row_hash = movement.row_hash
        AND NOT EXISTS (
            SELECT 1 FROM public.master_closed_aaccandass_f AS closed
            WHERE closed.row_hash = dim.row_hash AND closed.file_id IS DISTINCT FROM p_upload_id
        )
        AND NOT EXISTS (
            SELECT 1 FROM public.master_open_aaccandass_f AS opened
            WHERE opened.row_hash = dim.row_hash AND opened.file_id IS DISTINCT FROM p_upload_id
        );
    DELETE FROM public.master_closed_aaccandass_f WHERE file_id = p_upload_id AND tenant_id = v_tenant;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_rows := v_rows + v_count;
    DELETE FROM public.master_open_aaccandass_f WHERE file_id = p_upload_id AND tenant_id = v_tenant;
    GET DIAGNOSTICS v_count = ROW_COUNT;
    v_rows := v_rows + v_count;
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

-- A database that already applied an older sql/018 still routes from ledger_kind and
-- forces the closed asset table. Replace those bodies only when the old text is present.
DO $patch$
DECLARE
    v_name TEXT;
    v_def TEXT;
    v_next TEXT;
    v_spec RECORD;
BEGIN
    FOR v_spec IN
        SELECT * FROM (VALUES
            ('ingest_statement_csv', NULL::TEXT, NULL::TEXT),
            ('column_map_preview', NULL::TEXT, NULL::TEXT),
            ('enforce_bank_account', 'kind.ledger_kind', 'public.account_type_family(kind.type_name)'),
            (
                'create_asset_account',
                'LOWER(kind.type_name) = ''investment''',
                'public.account_type_family(kind.type_name) = ''asset'''
            ),
            ('statement_home', 'kind.ledger_kind <> ''asset''', 'public.account_type_family(kind.type_name) <> ''asset'''),
            ('aaccandass_home', 'kind.ledger_kind = ''asset''', 'public.account_type_family(kind.type_name) = ''asset'''),
            ('aaccandass_balances', 'kind.ledger_kind = ''asset''', 'public.account_type_family(kind.type_name) = ''asset'''),
            (
                'aaccandass_balance',
                'SELECT COUNT(*) FROM public.master_closed_aaccandass_f AS movement',
                'SELECT COUNT(*) FROM ('
                || 'SELECT account_id, txn_date FROM public.master_closed_aaccandass_f '
                || 'UNION ALL SELECT account_id, txn_date FROM public.master_open_aaccandass_f'
                || ') AS movement'
            ),
            (
                'aaccandass_balances',
                'LEFT JOIN public.master_closed_aaccandass_f AS movement',
                'LEFT JOIN ('
                || 'SELECT account_id, txn_date, abonos, cargos, amount FROM public.master_closed_aaccandass_f '
                || 'UNION ALL SELECT account_id, txn_date, abonos, cargos, amount FROM public.master_open_aaccandass_f'
                || ') AS movement'
            ),
            (
                'aaccandass_store_row',
                'FROM public.master_closed_aaccandass_f AS movement',
                'FROM ('
                || 'SELECT occurrence, account_id, txn_date, concept_sk, abonos, cargos FROM public.master_closed_aaccandass_f '
                || 'UNION ALL SELECT occurrence, account_id, txn_date, concept_sk, abonos, cargos FROM public.master_open_aaccandass_f'
                || ') AS movement'
            )
        ) AS spec (proname, old_text, new_text)
    LOOP
        SELECT PG_GET_FUNCTIONDEF(proc.oid) INTO v_def
        FROM pg_proc AS proc
        INNER JOIN pg_namespace AS ns ON ns.oid = proc.pronamespace
        WHERE ns.nspname = 'public' AND proc.proname = v_spec.proname
        ORDER BY proc.oid
        LIMIT 1;
        IF v_def IS NULL THEN
            RAISE EXCEPTION 'sql/019: function % is missing', v_spec.proname;
        END IF;
        v_next := v_def;
        IF v_spec.proname = 'ingest_statement_csv' THEN
            v_next := REPLACE(v_next, 'kind.ledger_kind,', 'public.account_type_family(kind.type_name),');
            v_next := REGEXP_REPLACE(
                v_next,
                '\|\|\s*JSONB_BUILD_OBJECT\(\s*''target_table'',\s*''master_closed_aaccandass_f'',\s*''ledger_state'',\s*''closed''\s*\)',
                '',
                'in'
            );
        ELSIF v_spec.proname = 'column_map_preview' THEN
            IF POSITION('account_type_family' IN v_next) = 0 THEN
                v_next := REPLACE(
                    v_next,
                    'v_account.ledger_kind = ''debit''',
                    'public.account_type_family(v_account.type_name) = ''debit'''
                );
                v_next := REPLACE(
                    v_next,
                    '''kind'', v_account.ledger_kind',
                    '''kind'', public.account_type_family(v_account.type_name)'
                );
            END IF;
        ELSIF POSITION(v_spec.old_text IN v_next) > 0 THEN
            v_next := REPLACE(v_next, v_spec.old_text, v_spec.new_text);
        ELSIF POSITION(v_spec.new_text IN v_next) = 0 THEN
            RAISE EXCEPTION 'sql/019: % has neither the old nor the new text', v_spec.proname;
        END IF;
        IF v_next IS DISTINCT FROM v_def THEN
            EXECUTE v_next;
        END IF;
    END LOOP;

    -- The type list is every type. Asset accounts stay off the statement cards.
    SELECT PG_GET_FUNCTIONDEF(proc.oid) INTO v_def
    FROM pg_proc AS proc
    INNER JOIN pg_namespace AS ns ON ns.oid = proc.pronamespace
    WHERE ns.nspname = 'public' AND proc.proname = 'statement_home';
    v_next := REGEXP_REPLACE(
        v_def,
        'FROM public\.account_types_d AS kind\s+WHERE\s+(?:public\.account_type_family\(kind\.type_name\)|kind\.ledger_kind)\s*<>\s*''asset''',
        'FROM public.account_types_d AS kind',
        'n'
    );
    IF v_next IS DISTINCT FROM v_def THEN
        EXECUTE v_next;
    END IF;

END
$patch$;
