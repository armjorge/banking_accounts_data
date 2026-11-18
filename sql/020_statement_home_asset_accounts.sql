-- sql/020: Savings, investments, assets, credit contracts accounts are listed on the
-- Statements page too: one upload box (this month's ledger cutoff), their files and row
-- counts. Rows dated in the current month go to master_open_aaccandass_f, other dates to
-- master_closed_aaccandass_f (sql/019). Safe to run more than once.

-- Asset uploads live in aaccandass_uploads_f, not statement_uploads_f: return them as
-- ingested (the vault backup of an asset file goes through /assets/uploads).
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
DECLARE
    v_result JSONB;
BEGIN
    v_result := public.ingest_statement_csv(
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
    );
    IF COALESCE(v_result ->> 'target_table', '') LIKE '%aaccandass%' THEN
        UPDATE public.aaccandass_uploads_f
        SET chosen_filename = COALESCE(public.clean_chosen_filename(p_chosen_filename), chosen_filename)
        WHERE upload_id = (v_result ->> 'upload_id')::UUID;
        RETURN v_result - 'curated_csv_backup' - 'vault_key' - 'vault_metadata' - 'vault_manifest'
            - 'vault_manifest_key';
    END IF;
    RETURN public.remember_chosen_filename(v_result, COALESCE(public.clean_chosen_filename(p_chosen_filename), p_filename));
END
$fn$;

-- Accounts that became Savings, investments, assets, credit contracts in sql/019 can still
-- have files and opening/adjustment rows from when they were debit or credit accounts. The
-- asset pages do not read those tables, so they are removed (upload the file again).
DO $cleanup$
DECLARE
    v_owner RECORD;
    v_item RECORD;
BEGIN
    FOR v_owner IN
        SELECT DISTINCT account.tenant_id, account.user_id
        FROM public.bank_accounts_d AS account
        INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
        WHERE public.account_type_family(kind.type_name) = 'asset'
    LOOP
        PERFORM SET_CONFIG('app.user_id', v_owner.user_id::TEXT, TRUE);
        PERFORM SET_CONFIG('app.tenant_id', v_owner.tenant_id::TEXT, TRUE);
        FOR v_item IN
            SELECT upload.upload_id
            FROM public.statement_uploads_f AS upload
            INNER JOIN public.bank_accounts_d AS account ON account.account_id = upload.account_id
            INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
            WHERE public.account_type_family(kind.type_name) = 'asset'
              AND upload.tenant_id = v_owner.tenant_id AND upload.user_id = v_owner.user_id
        LOOP
            PERFORM public.delete_statement_upload(v_item.upload_id);
        END LOOP;
        FOR v_item IN
            SELECT DISTINCT keys.row_hash
            FROM public.movement_keys_v AS keys
            INNER JOIN public.bank_accounts_d AS account ON account.account_id = keys.account_id
            INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
            WHERE public.account_type_family(kind.type_name) = 'asset'
              AND keys.kind IN ('debit', 'credit')
              AND keys.entry_source IN ('opening', 'adjustment')
              AND keys.tenant_id = v_owner.tenant_id AND keys.user_id = v_owner.user_id
        LOOP
            PERFORM public.delete_balance_row(v_item.row_hash);
        END LOOP;
    END LOOP;
    PERFORM SET_CONFIG('app.user_id', '', TRUE);
    PERFORM SET_CONFIG('app.tenant_id', '', TRUE);
END
$cleanup$;

DO $patch$
DECLARE
    v_def TEXT;
    v_next TEXT;
BEGIN
    SELECT PG_GET_FUNCTIONDEF(proc.oid) INTO v_def
    FROM pg_proc AS proc
    INNER JOIN pg_namespace AS ns ON ns.oid = proc.pronamespace
    WHERE ns.nspname = 'public' AND proc.proname = 'statement_home';
    IF POSITION('upload_cutoff_id' IN v_def) = 0 THEN
        IF POSITION(E'    END LOOP;\n\n    SELECT JSONB_BUILD_OBJECT(\n        ''as_of'', p_as_of,' IN v_def) = 0 THEN
            RAISE EXCEPTION 'sql/020: statement_home has an unexpected body';
        END IF;
        v_next := REPLACE(
            v_def,
            E'    END LOOP;\n\n    SELECT JSONB_BUILD_OBJECT(\n        ''as_of'', p_as_of,',
            E'    END LOOP;\n\n'
            || E'    v_accounts := v_accounts || COALESCE((\n'
            || E'        SELECT JSONB_AGG(JSONB_BUILD_OBJECT(\n'
            || E'            ''account_id'', account.account_id,\n'
            || E'            ''account_name'', account.account_name,\n'
            || E'            ''account_number'', account.account_number,\n'
            || E'            ''bank_name'', bank.bank_name,\n'
            || E'            ''type_name'', kind.type_name,\n'
            || E'            ''ledger_kind'', ''asset'',\n'
            || E'            ''allows_cutoff'', FALSE,\n'
            || E'            ''upload_cutoff_id'', public.month_cutoff_id(v_tenant, v_user, account.account_id, p_as_of),\n'
            || E'            ''open_row_count'', (SELECT COUNT(*) FROM public.master_open_aaccandass_f AS r WHERE r.account_id = account.account_id),\n'
            || E'            ''closed_row_count'', (SELECT COUNT(*) FROM public.master_closed_aaccandass_f AS r WHERE r.account_id = account.account_id),\n'
            || E'            ''uploads'', COALESCE((\n'
            || E'                SELECT JSONB_AGG(JSONB_BUILD_OBJECT(\n'
            || E'                    ''upload_id'', upload.upload_id, ''filename'', upload.chosen_filename,\n'
            || E'                    ''rows'', upload.inserted_count, ''first_txn_date'', upload.first_txn_date,\n'
            || E'                    ''last_txn_date'', upload.last_txn_date\n'
            || E'                ) ORDER BY upload.created_at DESC)\n'
            || E'                FROM public.aaccandass_uploads_f AS upload\n'
            || E'                WHERE upload.account_id = account.account_id AND upload.user_id = v_user\n'
            || E'            ), ''[]''::JSONB),\n'
            || E'            ''periods'', ''[]''::JSONB\n'
            || E'        ) ORDER BY account.account_number)\n'
            || E'        FROM public.bank_accounts_d AS account\n'
            || E'        INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id\n'
            || E'        INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id\n'
            || E'        WHERE account.tenant_id = v_tenant AND account.user_id = v_user\n'
            || E'            AND public.account_type_family(kind.type_name) = ''asset''\n'
            || E'    ), ''[]''::JSONB);\n\n'
            || E'    SELECT JSONB_BUILD_OBJECT(\n        ''as_of'', p_as_of,'
        );
        EXECUTE v_next;
    END IF;
END
$patch$;
