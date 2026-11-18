-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- Bank Stream ledgers: closed (past), open (current period) and future (remaining MSI).
--
--   * master_debit_open_f / master_credit_open_f: same schema and architecture as the
--     matching *_closed_f master. Filled by the SAME ingest pipe when the upload is for
--     the account's current period (debit: calendar month; credit: day after the last
--     cutoff through the next cutoff). Per-account replace on every open upload.
--   * master_debit_future_f: same schema as master_credit_closed_f. The installment slot
--     (credit accounts, Banorte credit_plan profile) expands "Pagos pendientes" NN/MM
--     (NN = payments still due) into NN rows dated on the next NN cutoff dates after the
--     as-of date. Per-account replace, only when at least one future row exists.
--   * credit_plan_closed_f is left in place (legacy rows) but is no longer written.
--   * Clean switch for the open period: the JSON reload model (reload_open_movements,
--     replace_open_account_movements, truncate_open_movements) is dropped. The legacy
--     open_debit_f / open_credit_f tables are kept read-only for history because 006/007/009
--     still reference them; nothing writes to them after this migration.
--
-- Safe to run more than once. Does not drop accounts, uploads or closed rows.
-- Apply on Neon after 008, 009 and 010 (Jorge applies SQL manually).

-- =============================================================================
-- 1. Upload ledger state: which master the rows of an upload live in
-- =============================================================================
ALTER TABLE public.statement_uploads_f
ADD COLUMN IF NOT EXISTS ledger_state TEXT NOT NULL DEFAULT 'closed';

ALTER TABLE public.statement_uploads_f
DROP CONSTRAINT IF EXISTS statement_uploads_f_ledger_state_check;

ALTER TABLE public.statement_uploads_f
ADD CONSTRAINT statement_uploads_f_ledger_state_check CHECK (
    ledger_state IN ('closed', 'open', 'future')
);

CREATE INDEX IF NOT EXISTS statement_uploads_f_account_state_idx
ON public.statement_uploads_f (account_id, dataset, ledger_state);

-- =============================================================================
-- 2. Open debit master (mirror of master_debit_closed_f, including 007 columns)
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.master_debit_open_f (
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
    saldos NUMERIC(18, 2),
    amount NUMERIC(18, 2) NOT NULL,
    occurrence INTEGER NOT NULL,
    row_hash TEXT NOT NULL,
    source_profile TEXT,
    CONSTRAINT master_debit_open_f_pkey PRIMARY KEY (row_id),
    CONSTRAINT master_debit_open_f_file_fkey
    FOREIGN KEY (file_id) REFERENCES public.statement_uploads_f (upload_id),
    CONSTRAINT master_debit_open_f_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT master_debit_open_f_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id),
    CONSTRAINT master_debit_open_f_account_number_check CHECK (account_number ~ '^[0-9]+$'),
    CONSTRAINT master_debit_open_f_concept_sk_check CHECK (LENGTH(concept_sk) > 0),
    CONSTRAINT master_debit_open_f_occurrence_check CHECK (occurrence >= 1),
    CONSTRAINT master_debit_open_f_hash_check CHECK (LENGTH(row_hash) = 64),
    CONSTRAINT master_debit_open_f_amount_check CHECK (amount = cargos + abonos)
);

CREATE UNIQUE INDEX IF NOT EXISTS master_debit_open_f_hash_idx
ON public.master_debit_open_f (account_id, row_hash);

CREATE INDEX IF NOT EXISTS master_debit_open_f_file_idx
ON public.master_debit_open_f (file_id);

CREATE INDEX IF NOT EXISTS master_debit_open_f_tenant_idx
ON public.master_debit_open_f (tenant_id, user_id);

-- =============================================================================
-- 3. Open credit master and future installments (mirror of master_credit_closed_f)
-- =============================================================================
CREATE TABLE IF NOT EXISTS public.master_credit_open_f (
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
    source_profile TEXT,
    CONSTRAINT master_credit_open_f_pkey PRIMARY KEY (row_id),
    CONSTRAINT master_credit_open_f_file_fkey
    FOREIGN KEY (file_id) REFERENCES public.statement_uploads_f (upload_id),
    CONSTRAINT master_credit_open_f_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT master_credit_open_f_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id),
    CONSTRAINT master_credit_open_f_account_number_check CHECK (account_number ~ '^[0-9]+$'),
    CONSTRAINT master_credit_open_f_concept_sk_check CHECK (LENGTH(concept_sk) > 0),
    CONSTRAINT master_credit_open_f_occurrence_check CHECK (occurrence >= 1),
    CONSTRAINT master_credit_open_f_hash_check CHECK (LENGTH(row_hash) = 64),
    CONSTRAINT master_credit_open_f_amount_check CHECK (amount = cargo - abono)
);

CREATE UNIQUE INDEX IF NOT EXISTS master_credit_open_f_hash_idx
ON public.master_credit_open_f (account_id, row_hash);

CREATE INDEX IF NOT EXISTS master_credit_open_f_file_idx
ON public.master_credit_open_f (file_id);

CREATE INDEX IF NOT EXISTS master_credit_open_f_tenant_idx
ON public.master_credit_open_f (tenant_id, user_id);

CREATE TABLE IF NOT EXISTS public.master_debit_future_f (
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
    source_profile TEXT,
    CONSTRAINT master_debit_future_f_pkey PRIMARY KEY (row_id),
    CONSTRAINT master_debit_future_f_file_fkey
    FOREIGN KEY (file_id) REFERENCES public.statement_uploads_f (upload_id),
    CONSTRAINT master_debit_future_f_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT master_debit_future_f_account_fkey
    FOREIGN KEY (account_id, user_id) REFERENCES public.bank_accounts_d (account_id, user_id),
    CONSTRAINT master_debit_future_f_account_number_check CHECK (account_number ~ '^[0-9]+$'),
    CONSTRAINT master_debit_future_f_concept_sk_check CHECK (LENGTH(concept_sk) > 0),
    CONSTRAINT master_debit_future_f_occurrence_check CHECK (occurrence >= 1),
    CONSTRAINT master_debit_future_f_hash_check CHECK (LENGTH(row_hash) = 64),
    CONSTRAINT master_debit_future_f_amount_check CHECK (amount = cargo - abono)
);

CREATE UNIQUE INDEX IF NOT EXISTS master_debit_future_f_hash_idx
ON public.master_debit_future_f (account_id, row_hash);

CREATE INDEX IF NOT EXISTS master_debit_future_f_file_idx
ON public.master_debit_future_f (file_id);

CREATE INDEX IF NOT EXISTS master_debit_future_f_tenant_idx
ON public.master_debit_future_f (tenant_id, user_id);

COMMENT ON TABLE public.master_debit_open_f IS
'Current-period debit movements. Same shape as master_debit_closed_f. Replaced per account on each open upload.';
COMMENT ON TABLE public.master_credit_open_f IS
'Current-period credit card movements (after the last cutoff). Same shape as master_credit_closed_f. '
'Replaced per account on each open upload.';
COMMENT ON TABLE public.master_debit_future_f IS
'Future installment (MSI) payments, one row per remaining payment dated on its cutoff. '
'Same shape as master_credit_closed_f. Replaced per account on each installment upload.';
COMMENT ON TABLE public.credit_plan_closed_f IS
'Legacy installment rows (before 011). No longer written; see master_debit_future_f.';
COMMENT ON TABLE public.open_debit_f IS
'Legacy JSON open reload (before 011). No longer written; see master_debit_open_f.';
COMMENT ON TABLE public.open_credit_f IS
'Legacy JSON open reload (before 011). No longer written; see master_credit_open_f.';

-- =============================================================================
-- 4. Period helpers
-- =============================================================================
-- The period that contains p_as_of: the calendar month for debit, the cycle that
-- starts the day after the last cutoff and ends on the next cutoff for credit.
CREATE OR REPLACE FUNCTION public.current_period(
    p_allows_cutoff BOOLEAN,
    p_cutoff_day INTEGER,
    p_as_of DATE,
    OUT period_start DATE,
    OUT period_end DATE
)
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_bounds RECORD;
    v_next DATE;
BEGIN
    SELECT bounds.period_start, bounds.period_end
    INTO v_bounds
    FROM public.period_bounds(
        p_allows_cutoff,
        p_cutoff_day,
        EXTRACT(YEAR FROM p_as_of)::INTEGER,
        EXTRACT(MONTH FROM p_as_of)::INTEGER
    ) AS bounds;
    IF p_as_of > v_bounds.period_end THEN
        v_next := (DATE_TRUNC('month', p_as_of) + INTERVAL '1 month')::DATE;
        SELECT bounds.period_start, bounds.period_end
        INTO v_bounds
        FROM public.period_bounds(
            p_allows_cutoff,
            p_cutoff_day,
            EXTRACT(YEAR FROM v_next)::INTEGER,
            EXTRACT(MONTH FROM v_next)::INTEGER
        ) AS bounds;
    END IF;
    period_start := v_bounds.period_start;
    period_end := v_bounds.period_end;
END
$fn$;

-- The next p_count credit cutoff periods whose cutoff date is strictly after p_as_of.
-- payment_no 1 is the first cutoff after p_as_of.
CREATE OR REPLACE FUNCTION public.future_cutoff_periods(
    p_cutoff_day INTEGER,
    p_as_of DATE,
    p_count INTEGER
) RETURNS TABLE (payment_no INTEGER, period_start DATE, period_end DATE)
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_first DATE;
    v_month DATE;
    v_bounds RECORD;
    v_index INTEGER;
BEGIN
    IF p_count IS NULL OR p_count < 1 THEN
        RETURN;
    END IF;
    SELECT current_row.period_start, current_row.period_end
    INTO v_bounds
    FROM public.current_period(TRUE, p_cutoff_day, p_as_of) AS current_row;
    IF v_bounds.period_end > p_as_of THEN
        v_first := DATE_TRUNC('month', v_bounds.period_end)::DATE;
    ELSE
        v_first := (DATE_TRUNC('month', v_bounds.period_end) + INTERVAL '1 month')::DATE;
    END IF;
    FOR v_index IN 1..p_count LOOP
        v_month := (v_first + MAKE_INTERVAL(months => v_index - 1))::DATE;
        SELECT bounds.period_start, bounds.period_end
        INTO v_bounds
        FROM public.period_bounds(
            TRUE,
            p_cutoff_day,
            EXTRACT(YEAR FROM v_month)::INTEGER,
            EXTRACT(MONTH FROM v_month)::INTEGER
        ) AS bounds;
        payment_no := v_index;
        period_start := v_bounds.period_start;
        period_end := v_bounds.period_end;
        RETURN NEXT;
    END LOOP;
END
$fn$;

-- "Pagos pendientes" NN/MM: NN payments still due out of MM. Returns NULL when unreadable.
CREATE OR REPLACE FUNCTION public.installment_remaining(p_pagos TEXT)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE
        WHEN p_pagos ~ '^\s*\d+\s*/\s*\d+\s*$'
            THEN (REGEXP_REPLACE(p_pagos, '^\s*(\d+)\s*/\s*(\d+)\s*$', '\1'))::INTEGER
    END
$fn$;

CREATE OR REPLACE FUNCTION public.installment_total(p_pagos TEXT)
RETURNS INTEGER
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE
        WHEN p_pagos ~ '^\s*\d+\s*/\s*\d+\s*$'
            THEN (REGEXP_REPLACE(p_pagos, '^\s*(\d+)\s*/\s*(\d+)\s*$', '\2'))::INTEGER
    END
$fn$;

-- =============================================================================
-- 4b. BBVA installments ("Meses sin intereses"): one value per line, paid count
-- =============================================================================
-- BBVA's web page copies as one value per line: 7 labels (Fecha, Descripcion, Compra,
-- Mensualidad, Pagos, Interes, Saldo actual), then 7 values per plan, then a Total
-- block. Amounts come doubled ("$5,750.00$5,750.00"), dates as "06 jul. 2026", and
-- "Pagos 4 de 6" counts payments already MADE (Banorte's NN/MM counts the ones left).
-- Payments fall on the purchase day of each month: payment k (1-based) is due on
-- purchase date + (k - 1) months. Bank, account and period always come from the slot.
-- The profile keeps amount_rule 'installment' (no CHECK change, so 007/008 stay
-- re-runnable); a column_map with a "pagos_hechos" key marks the paid-count reading.
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
VALUES (
    'bbva_credit_plan_v1',
    'BBVA',
    'credit_plan',
    TRUE,
    ARRAY['compra', 'descripcion', 'fecha', 'interes', 'mensualidad', 'pagos', 'saldo actual'],
    7,
    JSONB_BUILD_OBJECT(
        'txn_date', 'fecha',
        'concept', 'descripcion',
        'importe_inicial', 'compra',
        'mensualidad', 'mensualidad',
        'pagos_hechos', 'pagos',
        'tasa_anual', 'interes',
        'importe_pendiente', 'saldo actual'
    ),
    'installment',
    'DD mon. YYYY',
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
    active = EXCLUDED.active;

-- "06 jul. 2026" / "6 Sept 2026" -> DATE; NULL when the text is not that shape.
CREATE OR REPLACE FUNCTION public.spanish_short_date(p_text TEXT)
RETURNS DATE
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_parts TEXT [];
    v_month INTEGER;
BEGIN
    v_parts := REGEXP_MATCH(
        public.normalize_header(p_text),
        '^([0-9]{1,2})[ /-]+([a-z]{3,10})\.?[ /-]+([0-9]{4})$'
    );
    IF v_parts IS NULL THEN
        RETURN NULL;
    END IF;
    v_month := CASE LEFT(v_parts[2], 3)
        WHEN 'ene' THEN 1
        WHEN 'feb' THEN 2
        WHEN 'mar' THEN 3
        WHEN 'abr' THEN 4
        WHEN 'may' THEN 5
        WHEN 'jun' THEN 6
        WHEN 'jul' THEN 7
        WHEN 'ago' THEN 8
        WHEN 'sep' THEN 9
        WHEN 'set' THEN 9
        WHEN 'oct' THEN 10
        WHEN 'nov' THEN 11
        WHEN 'dic' THEN 12
    END;
    IF v_month IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN MAKE_DATE(v_parts[3]::INTEGER, v_month, v_parts[1]::INTEGER);
EXCEPTION
    WHEN OTHERS THEN
        RETURN NULL;
END
$fn$;

-- "$5,750.00$5,750.00" -> "$5,750.00" (BBVA web copies each amount twice).
CREATE OR REPLACE FUNCTION public.undouble_amount(p_text TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE
        WHEN CHAR_LENGTH(BTRIM(p_text)) % 2 = 0
            AND CHAR_LENGTH(BTRIM(p_text)) > 0
            AND LEFT(BTRIM(p_text), CHAR_LENGTH(BTRIM(p_text)) / 2)
            = RIGHT(BTRIM(p_text), CHAR_LENGTH(BTRIM(p_text)) / 2)
            AND BTRIM(p_text) ~ '[0-9]'
            THEN LEFT(BTRIM(p_text), CHAR_LENGTH(BTRIM(p_text)) / 2)
        ELSE BTRIM(p_text)
    END
$fn$;

-- "4 de 6" / "4/6" -> (paid, total); NULLs when unreadable.
CREATE OR REPLACE FUNCTION public.installment_paid_counts(p_pagos TEXT, OUT paid INTEGER, OUT total INTEGER)
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_parts TEXT [];
BEGIN
    v_parts := REGEXP_MATCH(public.normalize_header(p_pagos), '^([0-9]{1,3}) *(?:de|/) *([0-9]{1,3})$');
    IF v_parts IS NOT NULL THEN
        paid := v_parts[1]::INTEGER;
        total := v_parts[2]::INTEGER;
    END IF;
END
$fn$;

-- One-value-per-line BBVA installment text -> a normal 7-column CSV (NULL when the
-- text is not that layout, so every other file goes through unchanged).
CREATE OR REPLACE FUNCTION public.reshape_one_column_installments(p_csv TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_values TEXT [];
    v_out TEXT;
    v_index INTEGER;
    v_offset INTEGER;
    v_cell TEXT;
    v_line TEXT;
BEGIN
    IF EXISTS (
        SELECT 1
        FROM public.parse_csv(p_csv, ',') AS parsed
        WHERE EXISTS (
            SELECT 1
            FROM UNNEST(parsed.fields[2:]) AS extra
            WHERE BTRIM(COALESCE(extra, '')) <> ''
        )
    ) THEN
        RETURN NULL;
    END IF;
    SELECT ARRAY_AGG(BTRIM(parsed.fields[1]) ORDER BY parsed.record_no)
    INTO v_values
    FROM public.parse_csv(p_csv, ',') AS parsed
    WHERE BTRIM(COALESCE(parsed.fields[1], '')) <> '';
    IF COALESCE(CARDINALITY(v_values), 0) < 8 THEN
        RETURN NULL;
    END IF;
    IF ARRAY(SELECT public.normalize_header(label) FROM UNNEST(v_values[1:7]) AS label)
        <> ARRAY['fecha', 'descripcion', 'compra', 'mensualidad', 'pagos', 'interes', 'saldo actual']
    THEN
        RETURN NULL;
    END IF;
    v_out := 'Fecha,Descripcion,Compra,Mensualidad,Pagos,Interes,Saldo actual';
    v_index := 8;
    WHILE v_index <= CARDINALITY(v_values) LOOP
        EXIT WHEN public.normalize_header(v_values[v_index]) = 'total';
        IF v_index + 6 > CARDINALITY(v_values) THEN
            RAISE EXCEPTION 'The installment list ends in the middle of a plan (value %)', v_index
                USING ERRCODE = '22P02';
        END IF;
        v_line := NULL;
        FOR v_offset IN 0..6 LOOP
            v_cell := v_values[v_index + v_offset];
            IF v_offset IN (2, 3, 5, 6) THEN
                v_cell := public.undouble_amount(v_cell);
            END IF;
            v_cell := '"' || REPLACE(v_cell, '"', '""') || '"';
            v_line := CASE WHEN v_line IS NULL THEN v_cell ELSE v_line || ',' || v_cell END;
        END LOOP;
        v_out := v_out || E'\n' || v_line;
        v_index := v_index + 7;
    END LOOP;
    RETURN v_out;
END
$fn$;

-- =============================================================================
-- 5. Periods: closed window (latest closed + the two before it) plus the current one
-- =============================================================================
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
        UNION ALL
        SELECT current_row.period_start, current_row.period_end
        FROM public.current_period(v_allows, v_cutoff_day, p_as_of) AS current_row
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
            is_required = EXCLUDED.is_required;
    END LOOP;

    UPDATE public.cutoff_date_f
    SET is_required = p_as_of > period_end
    WHERE
        account_id = p_account_id
        AND user_id = v_user;
END
$fn$;

-- =============================================================================
-- 6. One ingest pipe, three ledgers
--    statement slot + closed period  -> master_*_closed_f (append-only, duplicate hashes rejected)
--    statement slot + current period -> master_*_open_f   (per-account replace)
--    installment slot (credit)       -> master_debit_future_f (expanded, per-account replace)
-- =============================================================================
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
        cutoff.period_start,
        cutoff.period_end
    INTO v_kind, v_account_number, v_cutoff_day, v_bank_name, v_period_start, v_period_end
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
        WHEN v_ledger = 'future' THEN 'master_debit_future_f'
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
                    PARTITION BY e.txn_date, e.cargo, e.concept_sk
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
                    'row_hash', public.movement_row_hash(
                        n.txn_date, v_account_number, n.cargo, n.concept_sk, n.occurrence
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
                (elem::JSONB ->> 'amount')::NUMERIC(18, 2) AS amount
            FROM UNNEST(v_parsed_rows) AS elem
        ),
        numbered AS (
            SELECT
                r.*,
                (ROW_NUMBER() OVER (
                    PARTITION BY r.txn_date, r.amount, r.concept_sk
                    ORDER BY r.record_no
                ))::INTEGER AS occurrence
            FROM raw_rows AS r
        )
        SELECT JSONB_AGG(
            n.item || JSONB_BUILD_OBJECT(
                'period_start', v_period_start,
                'period_end', v_period_end,
                'occurrence', n.occurrence,
                'row_hash', public.movement_row_hash(
                    n.txn_date, v_account_number, n.amount, n.concept_sk, n.occurrence
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
            DELETE FROM public.master_debit_future_f WHERE file_id = v_stale.upload_id;
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
                file_id, tenant_id, user_id, account_id, account_number, bank_name, file_name,
                period_start, period_end, txn_date, concept, concept_sk,
                cargos, abonos, saldos, amount, occurrence, row_hash, source_profile
            )
            SELECT
                $1, $2, $3, $4, $5, $6, $7,
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
            v_filename, v_profile, v_final_rows;
    ELSE
        EXECUTE FORMAT(
            'INSERT INTO public.%I (
                file_id, tenant_id, user_id, account_id, account_number, bank_name, file_name,
                period_start, period_end, txn_date, concept, concept_sk,
                abono, cargo, tarjeta, amount, occurrence, row_hash, source_profile
            )
            SELECT
                $1, $2, $3, $4, $5, $6, $7,
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
            v_filename, v_profile, v_final_rows;
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
        'account_number', v_account_number,
        'period_ym', v_period_ym,
        'cutoff_id', p_cutoff_id
    );
END
$fn$;

REVOKE ALL ON FUNCTION public.ingest_statement_csv(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ingest_statement_csv(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE, TEXT, TEXT) TO strm_app;

-- =============================================================================
-- 7. Whole-file delete also clears open and future rows
-- =============================================================================
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
    DELETE FROM public.master_debit_future_f
    WHERE file_id = p_upload_id;
    DELETE FROM public.upload_delete_guard
    WHERE upload_id = p_upload_id;
    DELETE FROM public.statement_uploads_f
    WHERE upload_id = p_upload_id;
END
$fn$;

-- =============================================================================
-- 8. Home: closed window + current period, with open/future slot flags
-- =============================================================================
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
        SELECT current_row.period_start, current_row.period_end
        INTO v_current
        FROM public.current_period(
            v_account.allows_cutoff,
            v_account.account_cutoff_day,
            p_as_of
        ) AS current_row;

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
                    'statement_filename', statement_file.original_filename,
                    'statement_row_count', statement_file.row_count,
                    'statement_source_profile', statement_file.source_profile,
                    'statement_ledger_state', statement_file.ledger_state,
                    'installment_upload_id', installment_file.upload_id,
                    'installment_filename', installment_file.original_filename,
                    'installment_row_count', installment_file.row_count,
                    'installment_source_profile', installment_file.source_profile,
                    'installment_ledger_state', installment_file.ledger_state,
                    'pdf_upload_id', pdf_file.upload_id,
                    'pdf_filename', pdf_file.original_filename,
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
                FROM public.master_debit_future_f AS future_row
                WHERE
                    future_row.account_id = v_account.account_id
                    AND future_row.user_id = v_user
            ),
            'future_total', (
                SELECT COALESCE(SUM(future_row.amount), 0)
                FROM public.master_debit_future_f AS future_row
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

-- =============================================================================
-- 9. Clean switch off the JSON open reload (tables kept read-only for history)
-- =============================================================================
DROP FUNCTION IF EXISTS public.reload_open_movements(JSONB);
DROP FUNCTION IF EXISTS public.replace_open_account_movements(INTEGER, JSONB);
DROP FUNCTION IF EXISTS public.truncate_open_movements();

-- =============================================================================
-- 10. Row level security and grants (same as the closed masters)
-- =============================================================================
ALTER TABLE public.master_debit_open_f ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.master_credit_open_f ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.master_debit_future_f ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS master_debit_open_f_tenant ON public.master_debit_open_f;
CREATE POLICY master_debit_open_f_tenant ON public.master_debit_open_f
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

DROP POLICY IF EXISTS master_credit_open_f_tenant ON public.master_credit_open_f;
CREATE POLICY master_credit_open_f_tenant ON public.master_credit_open_f
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

DROP POLICY IF EXISTS master_debit_future_f_tenant ON public.master_debit_future_f;
CREATE POLICY master_debit_future_f_tenant ON public.master_debit_future_f
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

GRANT SELECT ON
public.master_debit_open_f,
public.master_credit_open_f,
public.master_debit_future_f
TO strm_app;

REVOKE ALL ON FUNCTION public.current_period(BOOLEAN, INTEGER, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.future_cutoff_periods(INTEGER, DATE, INTEGER) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.installment_remaining(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.spanish_short_date(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.undouble_amount(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.installment_paid_counts(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reshape_one_column_installments(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.installment_total(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.refresh_statement_periods(INTEGER, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.delete_statement_upload(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.statement_home(DATE) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.current_period(BOOLEAN, INTEGER, DATE) TO strm_app;
GRANT EXECUTE ON FUNCTION public.future_cutoff_periods(INTEGER, DATE, INTEGER) TO strm_app;
GRANT EXECUTE ON FUNCTION public.installment_remaining(TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.spanish_short_date(TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.undouble_amount(TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.installment_paid_counts(TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.reshape_one_column_installments(TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.installment_total(TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.delete_statement_upload(UUID) TO strm_app;
GRANT EXECUTE ON FUNCTION public.statement_home(DATE) TO strm_app;
