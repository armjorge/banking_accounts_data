-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- Self-checking file-catcher cases. A failing check raises.

DO $checks$
DECLARE
    v_user UUID;
    v_tenant UUID;
    v_bank INTEGER;
    v_debit_type INTEGER;
    v_credit_type INTEGER;
    v_debit INTEGER;
    v_credit INTEGER;
    v_home JSONB;
    v_labels TEXT;
    v_cutoff INTEGER;
    v_loaded JSONB;
    v_hash_a TEXT;
    v_hash_b TEXT;
BEGIN
    INSERT INTO cognito_users.users (cognito_sub, email)
    VALUES ('sql-check', 'sql-check@example.com')
    RETURNING user_id
    INTO v_user;
    v_tenant := public.ensure_personal_tenant(v_user);
    PERFORM set_config('app.user_id', v_user::TEXT, FALSE);
    PERFORM set_config('app.tenant_id', v_tenant::TEXT, FALSE);

    SELECT bank_id
    INTO v_bank
    FROM public.banks_d
    WHERE LOWER(bank_name) = 'banorte';
    SELECT a_type_id
    INTO v_debit_type
    FROM public.account_types_d
    WHERE type_name = 'bank debit';
    SELECT a_type_id
    INTO v_credit_type
    FROM public.account_types_d
    WHERE type_name = 'bank credit card';

    v_debit := public.create_bank_account(v_bank, v_debit_type, 'Debit', '0639', NULL, NULL, DATE '2026-10-20');
    v_credit := public.create_bank_account(v_bank, v_credit_type, 'Credit', '3978', 6, 20, DATE '2026-10-20');
    v_home := public.statement_home(DATE '2026-10-20');

    SELECT STRING_AGG(period_row.label, ',' ORDER BY period_row.label)
    INTO v_labels
    FROM (
        SELECT period.value ->> 'period_label' AS label
        FROM JSONB_ARRAY_ELEMENTS(v_home -> 'accounts') AS account (value)
        CROSS JOIN JSONB_ARRAY_ELEMENTS(account.value -> 'periods') AS period (value)
        WHERE account.value ->> 'account_number' = '0639'
    ) AS period_row;
    IF v_labels IS DISTINCT FROM '2026-07,2026-08,2026-09' THEN
        RAISE EXCEPTION 'FAIL debit window %', v_labels;
    END IF;

    SELECT STRING_AGG(period_row.label, ',' ORDER BY period_row.label)
    INTO v_labels
    FROM (
        SELECT period.value ->> 'period_label' AS label
        FROM JSONB_ARRAY_ELEMENTS(v_home -> 'accounts') AS account (value)
        CROSS JOIN JSONB_ARRAY_ELEMENTS(account.value -> 'periods') AS period (value)
        WHERE account.value ->> 'account_number' = '3978'
    ) AS period_row;
    IF v_labels IS DISTINCT FROM '2026-08,2026-09,2026-10' THEN
        RAISE EXCEPTION 'FAIL credit window %', v_labels;
    END IF;

    IF public.concept_sk('SPEI 123-45') IS DISTINCT FROM '12345' THEN
        RAISE EXCEPTION 'FAIL concept_sk digits';
    END IF;
    IF public.concept_sk('I.V.A') IS DISTINCT FROM 'IVA' THEN
        RAISE EXCEPTION 'FAIL concept_sk letters';
    END IF;
    IF public.normalize_header('Fecha de operación') IS DISTINCT FROM 'fecha de operacion' THEN
        RAISE EXCEPTION 'FAIL header fold';
    END IF;

    v_hash_a := public.movement_row_hash(DATE '2026-09-26', '0639', -49, '4275', 1);
    v_hash_b := public.movement_row_hash(DATE '2026-09-26', '639', -49, '4275', 1);
    IF v_hash_a = v_hash_b THEN
        RAISE EXCEPTION 'FAIL leading zero changed the hash';
    END IF;

    SELECT (period.value ->> 'cutoff_id')::INTEGER
    INTO v_cutoff
    FROM JSONB_ARRAY_ELEMENTS(v_home -> 'accounts') AS account (value)
    CROSS JOIN JSONB_ARRAY_ELEMENTS(account.value -> 'periods') AS period (value)
    WHERE
        account.value ->> 'account_number' = '0639'
        AND period.value ->> 'period_label' = '2026-09';

    v_loaded := public.ingest_statement_csv(
        v_debit,
        v_cutoff,
        'statement',
        '0639.csv',
        E'Fecha,Concepto,Cargos,Abonos,Saldos\n07/10/2025,PAYPAL *SHOP 150323,-99.0,0.0,172.83\n',
        DATE '2026-10-20'
    );
    IF (v_loaded ->> 'row_count')::INTEGER <> 1 THEN
        RAISE EXCEPTION 'FAIL debit load %', v_loaded;
    END IF;
    IF (
        SELECT account_number
        FROM public.master_debit_closed_f
        WHERE file_id = (v_loaded ->> 'file_id')::UUID
    ) IS DISTINCT FROM '0639' THEN
        RAISE EXCEPTION 'FAIL account number was not kept as text';
    END IF;

    BEGIN
        PERFORM public.ingest_statement_csv(
            v_debit,
            v_cutoff,
            'statement',
            'again.csv',
            E'Fecha,Concepto,Cargos,Abonos,Saldos\n07/10/2025,PAYPAL *SHOP 150323,-99.0,0.0,1\n',
            DATE '2026-10-20'
        );
        RAISE EXCEPTION 'FAIL duplicate was accepted';
    EXCEPTION
        WHEN unique_violation THEN
            NULL;
    END;
    IF (SELECT COUNT(*) FROM public.master_debit_closed_f WHERE account_id = v_debit) <> 1 THEN
        RAISE EXCEPTION 'FAIL duplicate changed the master';
    END IF;

    BEGIN
        DELETE FROM public.master_debit_closed_f
        WHERE account_id = v_debit;
        RAISE EXCEPTION 'FAIL a single row delete was accepted';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;

    PERFORM public.delete_statement_upload((v_loaded ->> 'file_id')::UUID);
    IF (SELECT COUNT(*) FROM public.master_debit_closed_f WHERE account_id = v_debit) <> 0 THEN
        RAISE EXCEPTION 'FAIL file delete left rows';
    END IF;
    IF (SELECT COUNT(*) FROM public.movement_dimensions_d WHERE account_id = v_debit) <> 1 THEN
        RAISE EXCEPTION 'FAIL file delete removed the dimension';
    END IF;

    BEGIN
        PERFORM public.create_bank_account(v_bank, v_debit_type, 'Second', '1111', NULL, NULL, DATE '2026-10-20');
        RAISE EXCEPTION 'FAIL free plan accepted a second debit account';
    EXCEPTION
        WHEN check_violation THEN
            NULL;
    END;
END
$checks$;
