-- sql/023: savings, investments, assets and credit contracts get the same period list as a
-- debit account (rolling months, "Add the previous period", "Remove"). A file sits in the
-- period of its last movement date; its rows still go to the open or closed table by date.

CREATE OR REPLACE FUNCTION public.asset_statement_periods(p_account_id INTEGER, p_as_of DATE)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_current_end DATE;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    PERFORM public.refresh_statement_periods(p_account_id, p_as_of);
    SELECT MIN(cutoff.period_end) INTO v_current_end
    FROM public.statement_cutoffs_v AS cutoff
    WHERE cutoff.account_id = p_account_id AND cutoff.user_id = v_user
      AND cutoff.period_start <= p_as_of AND cutoff.period_end >= p_as_of;

    RETURN COALESCE((
        SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
            'cutoff_id', cutoff.cutoff_id,
            'period_start', cutoff.period_start,
            'period_end', cutoff.period_end,
            'period_label', TO_CHAR(cutoff.period_end, 'YYYY-MM'),
            'is_current', cutoff.period_end = v_current_end,
            'pending', files.list IS NULL,
            'files', COALESCE(files.list, '[]'::JSONB),
            'removable', p_as_of > cutoff.period_end
                AND files.list IS NULL
                AND NOT EXISTS (
                    SELECT 1 FROM public.catcher_periods(FALSE, NULL, p_as_of) AS window_period
                    WHERE window_period.period_end = cutoff.period_end
                )
                AND NOT public.cutoff_in_use(cutoff.cutoff_id)
        ) ORDER BY cutoff.period_end)
        FROM public.statement_cutoffs_v AS cutoff
        LEFT JOIN LATERAL (
            SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
                'upload_id', upload.upload_id,
                'filename', upload.chosen_filename,
                'rows', upload.inserted_count,
                'first_txn_date', upload.first_txn_date,
                'last_txn_date', upload.last_txn_date
            ) ORDER BY upload.created_at DESC) AS list
            FROM public.aaccandass_uploads_f AS upload
            WHERE upload.account_id = p_account_id AND upload.user_id = v_user
              AND COALESCE(upload.last_txn_date, upload.created_at::DATE)
                  BETWEEN cutoff.period_start AND cutoff.period_end
        ) AS files ON TRUE
        WHERE cutoff.account_id = p_account_id AND cutoff.user_id = v_user AND cutoff.tenant_id = v_tenant
    ), '[]'::JSONB);
END
$fn$;

REVOKE ALL ON FUNCTION public.asset_statement_periods(INTEGER, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.asset_statement_periods(INTEGER, DATE) TO strm_app;

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
    v_period_start DATE;
    v_period_end DATE;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    SELECT cutoff.account_id, cutoff.period_start, cutoff.period_end, kind.allows_cutoff, account.account_cutoff_day
    INTO v_account_id, v_period_start, v_period_end, v_allows, v_cutoff_day
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
    ) OR EXISTS (
        SELECT 1
        FROM public.aaccandass_uploads_f AS upload
        WHERE upload.account_id = v_account_id
          AND COALESCE(upload.last_txn_date, upload.created_at::DATE) BETWEEN v_period_start AND v_period_end
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

DO $patch$
DECLARE
    v_def TEXT;
    v_old TEXT := '''periods'', ''[]''::JSONB';
BEGIN
    SELECT PG_GET_FUNCTIONDEF('public.statement_home(date)'::REGPROCEDURE) INTO v_def;
    IF POSITION('asset_statement_periods' IN v_def) > 0 THEN
        RETURN;
    END IF;
    IF POSITION(v_old IN v_def) = 0
        OR POSITION(v_old IN SUBSTRING(v_def FROM POSITION(v_old IN v_def) + 1)) > 0 THEN
        RAISE EXCEPTION 'sql/023: statement_home has an unexpected body; run sql/020 first';
    END IF;
    EXECUTE REPLACE(v_def, v_old, '''periods'', public.asset_statement_periods(account.account_id, p_as_of)');
END
$patch$;
