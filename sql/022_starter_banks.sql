-- sql/022: the starter banks are Banorte, BBVA and HSBC only. Every other bank belongs to
-- the user who added it and that user can remove it once no account is linked.

-- A bank inserted during a session (create_bank, create_asset_account with a typed
-- institution) belongs to that user; only migrations insert banks without an owner.
CREATE OR REPLACE FUNCTION public.banks_d_owner()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF NEW.created_by IS NULL AND NULLIF(CURRENT_SETTING('app.user_id', TRUE), '') IS NOT NULL THEN
        NEW.created_by := CURRENT_SETTING('app.user_id', TRUE)::UUID;
        NEW.tenant_id := COALESCE(NEW.tenant_id, NULLIF(CURRENT_SETTING('app.tenant_id', TRUE), '')::UUID);
    END IF;
    RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS banks_d_owner ON public.banks_d;
CREATE TRIGGER banks_d_owner BEFORE INSERT ON public.banks_d
FOR EACH ROW EXECUTE FUNCTION public.banks_d_owner();

DO $cleanup$
DECLARE
    v_bank RECORD;
BEGIN
    FOR v_bank IN
        SELECT bank.bank_id, bank.bank_name
        FROM public.banks_d AS bank
        WHERE bank.created_by IS NULL
          AND LOWER(bank.bank_name) NOT IN ('banorte', 'bbva', 'hsbc')
          AND NOT EXISTS (SELECT 1 FROM public.bank_accounts_d AS account WHERE account.bank_id = bank.bank_id)
    LOOP
        BEGIN
            DELETE FROM public.banks_d WHERE bank_id = v_bank.bank_id;
        EXCEPTION WHEN foreign_key_violation THEN
            RAISE NOTICE 'bank % (%) is still referenced and stays', v_bank.bank_id, v_bank.bank_name;
        END;
    END LOOP;
END
$cleanup$;

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
            'has_profile', profile.found,
            'my_accounts', (
                SELECT COUNT(*) FROM public.bank_accounts_d AS account
                WHERE account.bank_id = bank.bank_id AND account.tenant_id = v_tenant AND account.user_id = v_user
            ),
            'can_rename', NOT EXISTS (
                SELECT 1 FROM public.bank_accounts_d AS account
                WHERE account.bank_id = bank.bank_id AND account.tenant_id <> v_tenant
            ) AND NOT profile.any_profile,
            'can_remove', owned.mine AND NOT profile.any_profile AND NOT linked.found,
            'remove_block', CASE
                WHEN bank.created_by IS NULL THEN 'Starter bank; it cannot be removed'
                WHEN NOT owned.mine THEN 'Added by another user'
                WHEN profile.any_profile THEN 'A built-in statement layout reads this bank'
                WHEN linked.found THEN 'Move or delete its accounts first'
            END
        ) ORDER BY bank.is_institution, LOWER(bank.bank_name))
        FROM public.banks_d AS bank
        CROSS JOIN LATERAL (
            SELECT COALESCE(bank.created_by = v_user AND bank.tenant_id = v_tenant, FALSE) AS mine
        ) AS owned
        CROSS JOIN LATERAL (
            SELECT
                EXISTS (
                    SELECT 1 FROM public.file_profiles_d AS fp
                    WHERE LOWER(fp.bank_name) = LOWER(bank.bank_name) AND fp.active IS TRUE
                ) AS found,
                EXISTS (
                    SELECT 1 FROM public.file_profiles_d AS fp WHERE LOWER(fp.bank_name) = LOWER(bank.bank_name)
                ) AS any_profile
        ) AS profile
        CROSS JOIN LATERAL (
            SELECT EXISTS (
                SELECT 1 FROM public.bank_accounts_d AS account WHERE account.bank_id = bank.bank_id
            ) AS found
        ) AS linked
    ), '[]'::JSONB);
END
$fn$;
