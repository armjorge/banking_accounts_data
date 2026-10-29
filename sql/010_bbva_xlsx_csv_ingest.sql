-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- BBVA XLSX is converted to CSV in the browser (web/xlsx_to_csv.js) then ingested
-- via public.ingest_statement_csv. This migration teaches SQL to:
--   * find the header row (not assume record 1)
--   * pick profile by bank + dataset when BBVA debit/credit share headers
--   * resolve Fecha/Descripción|Concepto / Cargo(s) / Abono(s) / Saldo(s)
--   * skip Digital/Titular section rows and non-date lines
--   * apply split_credit_abs_income (negative Abono → positive income)
-- Apply on Neon after 008+009. Does not drop accounts.

-- 1. Helpers
CREATE OR REPLACE FUNCTION public.header_field_index(
    p_index JSONB,
    VARIADIC p_names TEXT []
) RETURNS INTEGER
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_name TEXT;
BEGIN
    FOREACH v_name IN ARRAY p_names
    LOOP
        IF p_index ? v_name THEN
            RETURN (p_index ->> v_name)::INTEGER;
        END IF;
    END LOOP;
    RAISE EXCEPTION 'CSV is missing column(s): %', ARRAY_TO_STRING(p_names, ', ')
        USING ERRCODE = '22P02';
END
$fn$;

CREATE OR REPLACE FUNCTION public.is_statement_skip_row(p_fields TEXT [])
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_first TEXT;
BEGIN
    IF p_fields IS NULL OR CARDINALITY(p_fields) = 0 THEN
        RETURN TRUE;
    END IF;
    v_first := BTRIM(COALESCE(p_fields[1], ''));
    IF v_first = '' THEN
        RETURN TRUE;
    END IF;
    v_first := public.normalize_header(v_first);
    IF v_first ~ '^digital \*' OR v_first ~ '^titular \*' THEN
        RETURN TRUE;
    END IF;
    IF v_first LIKE 'detalle de movimientos%' THEN
        RETURN TRUE;
    END IF;
    IF v_first LIKE 'numero de tarjeta%' OR v_first LIKE 'cuenta:%' THEN
        RETURN TRUE;
    END IF;
    IF v_first LIKE 'bbva mexico%' THEN
        RETURN TRUE;
    END IF;
    RETURN FALSE;
END
$fn$;

REVOKE ALL ON FUNCTION public.header_field_index(JSONB, TEXT[]) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.is_statement_skip_row(TEXT[]) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.header_field_index(JSONB, TEXT[]) TO strm_app;
GRANT EXECUTE ON FUNCTION public.is_statement_skip_row(TEXT[]) TO strm_app;

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
    v_parsed_rows TEXT [] := ARRAY[]::TEXT [];
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
                v_date_text := BTRIM(v_fields[public.header_field_index(v_index, VARIADIC ARRAY['fecha de operacion'])]);
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
            v_pagos_hechos := NULLIF(REGEXP_REPLACE(v_pagos, '^\s*(\d+)\s*/\s*(\d+)\s*$', '\1'), v_pagos)::INTEGER;
            v_pagos_totales := NULLIF(REGEXP_REPLACE(v_pagos, '^\s*(\d+)\s*/\s*(\d+)\s*$', '\2'), v_pagos)::INTEGER;
            v_amount := v_mensualidad;
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

    -- Parsed JSON rows are collected separately from the detection row
    v_rows := CARDINALITY(v_parsed_rows);
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
                FROM UNNEST(v_parsed_rows) AS elem
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
                FROM UNNEST(v_parsed_rows) AS elem
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
                FROM UNNEST(v_parsed_rows) AS elem
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
        source_profile,
        period_ym
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
        TO_CHAR(v_period_end, 'YYYY-MM')
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
            FROM UNNEST(v_parsed_rows) AS elem
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
            FROM UNNEST(v_parsed_rows) AS elem
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
            FROM UNNEST(v_parsed_rows) AS elem
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
        FROM UNNEST(v_parsed_rows) AS elem
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

REVOKE ALL ON FUNCTION public.ingest_statement_csv(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE, TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.ingest_statement_csv(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE, TEXT, TEXT) TO strm_app;
