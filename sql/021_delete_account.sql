-- sql/021: delete a whole account. Its files (every period, statement / installment / PDF
-- and asset uploads) are deleted first with their rows, then opening, adjustment and manual
-- rows, its periods and finally the account. Vault objects already written stay in S3.
-- A bank is removed with delete_bank (sql/018), which refuses while it has accounts.

CREATE OR REPLACE FUNCTION public.delete_bank_account(p_account_id INTEGER)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_account RECORD;
    v_item RECORD;
    v_files INTEGER := 0;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    SELECT account.account_id, account.account_name, account.account_number
    INTO v_account
    FROM public.bank_accounts_d AS account
    WHERE account.account_id = p_account_id AND account.tenant_id = v_tenant AND account.user_id = v_user
    FOR UPDATE;
    IF v_account.account_id IS NULL THEN
        RAISE EXCEPTION 'account not found' USING ERRCODE = 'P0002';
    END IF;

    FOR v_item IN
        SELECT upload.upload_id FROM public.statement_uploads_f AS upload
        WHERE upload.account_id = p_account_id AND upload.user_id = v_user
    LOOP
        PERFORM public.delete_statement_upload(v_item.upload_id);
        v_files := v_files + 1;
    END LOOP;
    FOR v_item IN
        SELECT upload.upload_id FROM public.aaccandass_uploads_f AS upload
        WHERE upload.account_id = p_account_id AND upload.user_id = v_user
    LOOP
        PERFORM public.delete_aaccandass_upload(v_item.upload_id);
        v_files := v_files + 1;
    END LOOP;
    FOR v_item IN
        SELECT DISTINCT keys.row_hash, keys.entry_source
        FROM public.movement_keys_v AS keys
        WHERE keys.account_id = p_account_id AND keys.user_id = v_user
    LOOP
        IF v_item.entry_source IN ('opening', 'adjustment') THEN
            PERFORM public.delete_balance_row(v_item.row_hash);
        ELSIF v_item.entry_source = 'manual' THEN
            PERFORM public.delete_aaccandass_row(v_item.row_hash);
        END IF;
    END LOOP;
    IF EXISTS (SELECT 1 FROM public.movement_keys_v AS keys WHERE keys.account_id = p_account_id) THEN
        RAISE EXCEPTION 'This account still has rows that could not be deleted' USING ERRCODE = '23514';
    END IF;

    IF TO_REGCLASS('public.credit_plan_closed_f') IS NOT NULL THEN
        EXECUTE 'DELETE FROM public.credit_plan_closed_f WHERE account_id = $1' USING p_account_id;
    END IF;
    IF TO_REGCLASS('public.open_debit_f') IS NOT NULL THEN
        EXECUTE 'DELETE FROM public.open_debit_f WHERE account_id = $1' USING p_account_id;
    END IF;
    IF TO_REGCLASS('public.open_credit_f') IS NOT NULL THEN
        EXECUTE 'DELETE FROM public.open_credit_f WHERE account_id = $1' USING p_account_id;
    END IF;
    IF TO_REGCLASS('public.movement_dimensions_d') IS NOT NULL THEN
        EXECUTE 'DELETE FROM public.movement_dimensions_d WHERE account_id = $1' USING p_account_id;
    END IF;
    DELETE FROM public.cutoff_date_f WHERE account_id = p_account_id;
    DELETE FROM public.bank_accounts_d WHERE account_id = p_account_id;

    RETURN JSONB_BUILD_OBJECT(
        'account_id', p_account_id,
        'account_name', v_account.account_name,
        'account_number', v_account.account_number,
        'deleted_files', v_files
    );
END
$fn$;

REVOKE ALL ON FUNCTION public.delete_bank_account(INTEGER) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.delete_bank_account(INTEGER) TO strm_app;
