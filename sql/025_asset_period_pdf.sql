-- sql/025: the optional PDF of a closed period, on savings, investments, assets and credit
-- contracts too (premium plan, the same slot as a debit account: ingest_period_pdf_upload).

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
    v_curated BOOLEAN;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id INTO v_tenant, v_user FROM public.require_session() AS session_row;
    PERFORM public.refresh_statement_periods(p_account_id, p_as_of);
    SELECT MIN(cutoff.period_end) INTO v_current_end
    FROM public.statement_cutoffs_v AS cutoff
    WHERE cutoff.account_id = p_account_id AND cutoff.user_id = v_user
      AND cutoff.period_start <= p_as_of AND cutoff.period_end >= p_as_of;
    SELECT COALESCE(plan.curated_csv_backup, FALSE) INTO v_curated
    FROM public.tenants_d AS tenant
    INNER JOIN public.plans_d AS plan ON plan.plan_code = tenant.plan_code
    WHERE tenant.tenant_id = v_tenant;

    RETURN COALESCE((
        SELECT JSONB_AGG(JSONB_BUILD_OBJECT(
            'cutoff_id', cutoff.cutoff_id,
            'period_start', cutoff.period_start,
            'period_end', cutoff.period_end,
            'period_label', TO_CHAR(cutoff.period_end, 'YYYY-MM'),
            'is_current', cutoff.period_end = v_current_end,
            'pending', files.list IS NULL,
            'files', COALESCE(files.list, '[]'::JSONB),
            'pdf_upload_id', pdf_file.upload_id,
            'pdf_filename', pdf_file.chosen_filename,
            'pdf_stored_filename', pdf_file.original_filename,
            'show_pdf_slot', COALESCE(v_curated, FALSE) AND pdf_file.upload_id IS NULL AND p_as_of > cutoff.period_end,
            'removable', p_as_of > cutoff.period_end
                AND files.list IS NULL
                AND pdf_file.upload_id IS NULL
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
        LEFT JOIN public.statement_uploads_f AS pdf_file
            ON pdf_file.cutoff_id = cutoff.cutoff_id AND pdf_file.dataset = 'pdf'
        WHERE cutoff.account_id = p_account_id AND cutoff.user_id = v_user AND cutoff.tenant_id = v_tenant
    ), '[]'::JSONB);
END
$fn$;

REVOKE ALL ON FUNCTION public.asset_statement_periods(INTEGER, DATE) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.asset_statement_periods(INTEGER, DATE) TO strm_app;
