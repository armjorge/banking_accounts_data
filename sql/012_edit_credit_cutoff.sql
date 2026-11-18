-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- Change a credit card's cutoff day and payment window after it is open.
--
--   * update_bank_account_cutoff(account, cutoff_day, credit_days, as_of) updates the
--     account and re-plans its periods.
--   * Periods with any upload (statement, installment or PDF) are frozen: their
--     period_start, period_end and cutoff_date never change.
--   * Empty periods are re-planned on the new cutoff calendar, stitched around the
--     frozen ones so periods never overlap and leave no gap. A loaded current period
--     stays as it is; the new day starts with the period after it.
--   * Future MSI rows (master_debit_future_f) still due after the as-of date are re-dated
--     onto the new cutoff calendar with the same remaining count per payment date.
--     BBVA plans (due on the purchase day) keep their dates; only their period moves.
--   * refresh_statement_periods no longer rewrites the bounds of a loaded period.
--
-- Safe to run more than once. Apply on Neon by hand after 011.

-- =============================================================================
-- 1. Period plan: calendar cutoffs stitched around periods that have uploads
-- =============================================================================
-- Boundaries are the calendar cutoffs (calendar month ends for debit) plus the edges of
-- every loaded period. Each gap between consecutive boundaries that is not inside a
-- loaded period is an empty period. A gap whose cutoff month is already used by a loaded
-- period (cutoff_date_f is unique per account and cutoff month) is merged into the next
-- gap. Returns the plan from the start of the closed window through the period that
-- contains p_as_of.
CREATE OR REPLACE FUNCTION public.planned_statement_periods(
    p_account_id INTEGER,
    p_allows_cutoff BOOLEAN,
    p_cutoff_day INTEGER,
    p_as_of DATE
) RETURNS TABLE (period_start DATE, period_end DATE)
LANGUAGE plpgsql
STABLE
AS $fn$
DECLARE
    v_window DATE;
    v_bounds DATE [];
    v_index INTEGER;
    v_start DATE;
    v_end DATE;
    v_carry DATE;
    v_last_key TEXT;
    v_key TEXT;
BEGIN
    SELECT MIN(window_period.period_start)
    INTO v_window
    FROM public.catcher_periods(p_allows_cutoff, p_cutoff_day, p_as_of) AS window_period;

    WITH loaded AS (
        SELECT cutoff.period_start, cutoff.period_end
        FROM public.cutoff_date_f AS cutoff
        WHERE
            cutoff.account_id = p_account_id
            AND EXISTS (
                SELECT 1
                FROM public.statement_uploads_f AS upload
                WHERE upload.cutoff_id = cutoff.cutoff_id
            )
    ),
    edges AS (
        SELECT bounds.period_end AS edge
        FROM GENERATE_SERIES(
            DATE_TRUNC('month', v_window) - INTERVAL '1 month',
            DATE_TRUNC('month', p_as_of) + INTERVAL '3 months',
            INTERVAL '1 month'
        ) AS months (month_start)
        CROSS JOIN LATERAL public.period_bounds(
            p_allows_cutoff,
            p_cutoff_day,
            EXTRACT(YEAR FROM months.month_start)::INTEGER,
            EXTRACT(MONTH FROM months.month_start)::INTEGER
        ) AS bounds
        UNION
        SELECT loaded.period_start - 1 FROM loaded
        UNION
        SELECT loaded.period_end FROM loaded
    )
    SELECT ARRAY_AGG(edges.edge ORDER BY edges.edge)
    INTO v_bounds
    FROM edges;

    FOR v_index IN 1..CARDINALITY(v_bounds) - 1 LOOP
        v_start := v_bounds[v_index] + 1;
        v_end := v_bounds[v_index + 1];
        IF EXISTS (
            SELECT 1
            FROM public.cutoff_date_f AS cutoff
            WHERE
                cutoff.account_id = p_account_id
                AND cutoff.period_start <= v_start
                AND cutoff.period_end >= v_end
                AND EXISTS (
                    SELECT 1
                    FROM public.statement_uploads_f AS upload
                    WHERE upload.cutoff_id = cutoff.cutoff_id
                )
        ) THEN
            -- Inside a frozen period; a carry cannot jump over it.
            v_carry := NULL;
            CONTINUE;
        END IF;
        v_start := COALESCE(v_carry, v_start);
        v_key := TO_CHAR(v_end, 'YYYY-MM');
        IF v_key = v_last_key OR EXISTS (
            SELECT 1
            FROM public.cutoff_date_f AS cutoff
            WHERE
                cutoff.account_id = p_account_id
                AND TO_CHAR(cutoff.period_end, 'YYYY-MM') = v_key
                AND EXISTS (
                    SELECT 1
                    FROM public.statement_uploads_f AS upload
                    WHERE upload.cutoff_id = cutoff.cutoff_id
                )
        ) THEN
            v_carry := v_start;
            CONTINUE;
        END IF;
        v_carry := NULL;
        v_last_key := v_key;
        IF v_end >= v_window AND v_start <= p_as_of THEN
            period_start := v_start;
            period_end := v_end;
            RETURN NEXT;
        END IF;
    END LOOP;
END
$fn$;

-- =============================================================================
-- 2. Refresh materializes the plan; loaded periods are never rewritten
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
            is_required = EXCLUDED.is_required
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
$fn$;

-- =============================================================================
-- 3. Change the cutoff day / payment window of a credit card
-- =============================================================================
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
            FROM public.master_debit_future_f AS future_row
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
                    PARTITION BY schedule.period_end, remaining.amount, remaining.concept_sk
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
                    'abono', moved.abono,
                    'cargo', moved.cargo,
                    'tarjeta', moved.tarjeta,
                    'amount', moved.amount,
                    'occurrence', moved.new_occurrence,
                    'row_hash', public.movement_row_hash(
                        moved.new_date, v_account_number, moved.amount, moved.concept_sk, moved.new_occurrence
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
            DELETE FROM public.master_debit_future_f AS future_row
            WHERE future_row.row_id IN (
                SELECT (item ->> 'row_id')::BIGINT
                FROM JSONB_ARRAY_ELEMENTS(v_moved) AS moved_rows (item)
            );
            INSERT INTO public.master_debit_future_f (
                file_id, tenant_id, user_id, account_id, account_number, bank_name, file_name,
                period_start, period_end, txn_date, concept, concept_sk,
                abono, cargo, tarjeta, amount, occurrence, row_hash, source_profile
            )
            SELECT
                (item ->> 'file_id')::UUID,
                v_tenant,
                v_user,
                p_account_id,
                v_account_number,
                item ->> 'bank_name',
                item ->> 'file_name',
                (item ->> 'period_start')::DATE,
                (item ->> 'period_end')::DATE,
                (item ->> 'txn_date')::DATE,
                item ->> 'concept',
                item ->> 'concept_sk',
                (item ->> 'abono')::NUMERIC(18, 2),
                (item ->> 'cargo')::NUMERIC(18, 2),
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
        END IF;
    END IF;

    -- BBVA-style plans (profile column_map has pagos_hechos, sql/011 4b) are due on the purchase day, not
    -- on a cutoff: their dates stay, only the period that contains each date follows
    -- the new cutoff day.
    IF v_allows THEN
        UPDATE public.master_debit_future_f AS future_row
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


-- =============================================================================
-- 4. Home: the current period is the stored period that contains the as-of date
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
-- 5. Grants
-- =============================================================================
REVOKE ALL ON FUNCTION public.planned_statement_periods(INTEGER, BOOLEAN, INTEGER, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.refresh_statement_periods(INTEGER, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_bank_account_cutoff(INTEGER, INTEGER, INTEGER, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.statement_home(DATE) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.update_bank_account_cutoff(INTEGER, INTEGER, INTEGER, DATE) TO strm_app;
GRANT EXECUTE ON FUNCTION public.statement_home(DATE) TO strm_app;
