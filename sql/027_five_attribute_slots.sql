-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- Five fixed dimension slots (openspec/changes/five-attribute-slots).
--
--   * attribute_1 / attribute_3: the two oldest root lists.
--   * attribute_2 / attribute_4: the nested list of each, only under the chosen item.
--   * attribute_5: free text.
-- Safe to run more than once. Requires 026.

ALTER TABLE public.debit_d ADD COLUMN IF NOT EXISTS attribute_4 TEXT;
ALTER TABLE public.debit_d ADD COLUMN IF NOT EXISTS attribute_4_item_id BIGINT;
ALTER TABLE public.debit_d ADD COLUMN IF NOT EXISTS attribute_5 TEXT;
ALTER TABLE public.credit_d ADD COLUMN IF NOT EXISTS attribute_4 TEXT;
ALTER TABLE public.credit_d ADD COLUMN IF NOT EXISTS attribute_4_item_id BIGINT;
ALTER TABLE public.credit_d ADD COLUMN IF NOT EXISTS attribute_5 TEXT;
ALTER TABLE public.master_closed_aaccandass_d ADD COLUMN IF NOT EXISTS attribute_4 TEXT;
ALTER TABLE public.master_closed_aaccandass_d ADD COLUMN IF NOT EXISTS attribute_4_item_id BIGINT;
ALTER TABLE public.master_closed_aaccandass_d ADD COLUMN IF NOT EXISTS attribute_5 TEXT;

ALTER TABLE public.attribute_settings_d DROP CONSTRAINT IF EXISTS attribute_settings_d_slot_check;
ALTER TABLE public.attribute_settings_d
    ADD CONSTRAINT attribute_settings_d_slot_check CHECK (slot BETWEEN 1 AND 5);

DO $fk$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY['debit_d', 'credit_d', 'master_closed_aaccandass_d']
    LOOP
        EXECUTE FORMAT(
            'ALTER TABLE public.%1$I DROP CONSTRAINT IF EXISTS %1$s_attribute_4_len',
            v_table
        );
        EXECUTE FORMAT(
            'ALTER TABLE public.%1$I ADD CONSTRAINT %1$s_attribute_4_len CHECK (COALESCE(LENGTH(attribute_4), 0) <= 500)',
            v_table
        );
        EXECUTE FORMAT(
            'ALTER TABLE public.%1$I DROP CONSTRAINT IF EXISTS %1$s_attribute_5_len',
            v_table
        );
        EXECUTE FORMAT(
            'ALTER TABLE public.%1$I ADD CONSTRAINT %1$s_attribute_5_len CHECK (COALESCE(LENGTH(attribute_5), 0) <= 500)',
            v_table
        );
        IF NOT EXISTS (
            SELECT 1 FROM pg_constraint WHERE conname = v_table || '_attribute_4_item_fkey'
        ) THEN
            EXECUTE FORMAT(
                'ALTER TABLE public.%1$I ADD CONSTRAINT %1$s_attribute_4_item_fkey
                FOREIGN KEY (attribute_4_item_id) REFERENCES public.list_d (item_id)',
                v_table
            );
        END IF;
    END LOOP;
END
$fk$;

-- Move values that were stored under the old three-slot binding onto the fixed roles.
-- A second run is a no-op: list items are already on the slot that matches their role.
CREATE OR REPLACE FUNCTION public.migrate_five_attribute_slots()
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $move$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY['debit_d', 'credit_d', 'master_closed_aaccandass_d']
    LOOP
        EXECUTE FORMAT(
            'UPDATE public.%1$I AS dim
            SET
                attribute_3_item_id = dim.attribute_2_item_id,
                attribute_3 = NULL,
                attribute_2_item_id = NULL,
                attribute_2 = NULL
            FROM public.list_d AS item
            INNER JOIN public.list_f AS list ON list.list_id = item.list_id
            WHERE
                item.item_id = dim.attribute_2_item_id
                AND item.parent_item_id IS NULL
                AND list.parent_list_id IS NULL
                AND list.list_id <> (
                    SELECT root.list_id
                    FROM public.list_f AS root
                    WHERE root.tenant_id = dim.tenant_id AND root.user_id = dim.user_id
                        AND root.parent_list_id IS NULL
                    ORDER BY root.created_at, root.list_id
                    LIMIT 1
                )
                AND dim.attribute_3_item_id IS NULL',
            v_table
        );
        EXECUTE FORMAT(
            'UPDATE public.%1$I AS dim
            SET
                attribute_2_item_id = dim.attribute_1_item_id,
                attribute_2 = NULL,
                attribute_1_item_id = item.parent_item_id,
                attribute_1 = NULL
            FROM public.list_d AS item
            WHERE
                item.item_id = dim.attribute_1_item_id
                AND item.parent_item_id IS NOT NULL
                AND dim.attribute_2_item_id IS NULL',
            v_table
        );
        EXECUTE FORMAT(
            'UPDATE public.%1$I AS dim
            SET attribute_5 = COALESCE(
                dim.attribute_5,
                CASE WHEN dim.attribute_1_item_id IS NULL THEN NULLIF(BTRIM(dim.attribute_1), '''') END,
                CASE WHEN dim.attribute_2_item_id IS NULL THEN NULLIF(BTRIM(dim.attribute_2), '''') END,
                CASE WHEN dim.attribute_3_item_id IS NULL THEN NULLIF(BTRIM(dim.attribute_3), '''') END
            )
            WHERE dim.attribute_5 IS NULL',
            v_table
        );
        EXECUTE FORMAT(
            'UPDATE public.%1$I AS dim
            SET attribute_1 = NULL, attribute_2 = NULL, attribute_3 = NULL, attribute_4 = NULL
            WHERE attribute_1 IS NOT NULL OR attribute_2 IS NOT NULL
                OR attribute_3 IS NOT NULL OR attribute_4 IS NOT NULL',
            v_table
        );
    END LOOP;
END
$move$;

SELECT public.migrate_five_attribute_slots();

CREATE OR REPLACE VIEW public.movement_attributes_v
WITH (security_invoker = TRUE) AS
SELECT
    'debit'::TEXT AS kind,
    dim.row_hash,
    dim.tenant_id,
    dim.user_id,
    dim.account_id,
    COALESCE(item_1.item_name, dim.attribute_1) AS attribute_1,
    COALESCE(item_2.item_name, dim.attribute_2) AS attribute_2,
    COALESCE(item_3.item_name, dim.attribute_3) AS attribute_3,
    COALESCE(item_4.item_name, dim.attribute_4) AS attribute_4,
    dim.attribute_5,
    dim.attribute_1_item_id,
    dim.attribute_2_item_id,
    dim.attribute_3_item_id,
    dim.attribute_4_item_id,
    dim.updated_at
FROM public.debit_d AS dim
LEFT JOIN public.list_d AS item_1 ON dim.attribute_1_item_id = item_1.item_id
LEFT JOIN public.list_d AS item_2 ON dim.attribute_2_item_id = item_2.item_id
LEFT JOIN public.list_d AS item_3 ON dim.attribute_3_item_id = item_3.item_id
LEFT JOIN public.list_d AS item_4 ON dim.attribute_4_item_id = item_4.item_id
UNION ALL
SELECT
    'credit'::TEXT,
    dim.row_hash, dim.tenant_id, dim.user_id, dim.account_id,
    COALESCE(item_1.item_name, dim.attribute_1),
    COALESCE(item_2.item_name, dim.attribute_2),
    COALESCE(item_3.item_name, dim.attribute_3),
    COALESCE(item_4.item_name, dim.attribute_4),
    dim.attribute_5,
    dim.attribute_1_item_id, dim.attribute_2_item_id, dim.attribute_3_item_id, dim.attribute_4_item_id,
    dim.updated_at
FROM public.credit_d AS dim
LEFT JOIN public.list_d AS item_1 ON dim.attribute_1_item_id = item_1.item_id
LEFT JOIN public.list_d AS item_2 ON dim.attribute_2_item_id = item_2.item_id
LEFT JOIN public.list_d AS item_3 ON dim.attribute_3_item_id = item_3.item_id
LEFT JOIN public.list_d AS item_4 ON dim.attribute_4_item_id = item_4.item_id
UNION ALL
SELECT
    'asset'::TEXT,
    dim.row_hash, dim.tenant_id, dim.user_id, dim.account_id,
    COALESCE(item_1.item_name, dim.attribute_1),
    COALESCE(item_2.item_name, dim.attribute_2),
    COALESCE(item_3.item_name, dim.attribute_3),
    COALESCE(item_4.item_name, dim.attribute_4),
    dim.attribute_5,
    dim.attribute_1_item_id, dim.attribute_2_item_id, dim.attribute_3_item_id, dim.attribute_4_item_id,
    dim.updated_at
FROM public.master_closed_aaccandass_d AS dim
LEFT JOIN public.list_d AS item_1 ON dim.attribute_1_item_id = item_1.item_id
LEFT JOIN public.list_d AS item_2 ON dim.attribute_2_item_id = item_2.item_id
LEFT JOIN public.list_d AS item_3 ON dim.attribute_3_item_id = item_3.item_id
LEFT JOIN public.list_d AS item_4 ON dim.attribute_4_item_id = item_4.item_id;

CREATE OR REPLACE FUNCTION public.create_list(p_list_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_name TEXT := public.list_clean_name(p_list_name);
    v_list RECORD;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    IF v_name IS NULL OR LENGTH(v_name) > 100 THEN
        RAISE EXCEPTION 'A list name needs 1 to 100 characters' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.list_f AS list
        WHERE list.tenant_id = v_tenant AND list.user_id = v_user AND LOWER(list.list_name) = LOWER(v_name)
    ) THEN
        RAISE EXCEPTION 'A list named "%" already exists', v_name USING ERRCODE = '23505';
    END IF;
    IF (
        SELECT COUNT(*) FROM public.list_f AS list
        WHERE list.tenant_id = v_tenant AND list.user_id = v_user AND list.parent_list_id IS NULL
    ) >= 2 THEN
        RAISE EXCEPTION 'At most two lists' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.list_f (tenant_id, user_id, list_name, created_by)
    VALUES (v_tenant, v_user, v_name, v_user)
    RETURNING list_f.list_id, list_f.list_name INTO v_list;
    RETURN JSONB_BUILD_OBJECT('list_id', v_list.list_id, 'list_name', v_list.list_name);
END
$fn$;

CREATE OR REPLACE FUNCTION public.dimension_roles(p_tenant UUID, p_user UUID)
RETURNS TABLE(list_1 BIGINT, nested_1 BIGINT, list_2 BIGINT, nested_2 BIGINT)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
    WITH roots AS (
        SELECT list.list_id, ROW_NUMBER() OVER (ORDER BY list.created_at, list.list_id) AS n
        FROM public.list_f AS list
        WHERE list.tenant_id = p_tenant AND list.user_id = p_user AND list.parent_list_id IS NULL
    )
    SELECT
        (SELECT list_id FROM roots WHERE n = 1),
        (SELECT nested.list_id FROM public.list_f AS nested WHERE nested.parent_list_id = (SELECT list_id FROM roots WHERE n = 1) LIMIT 1),
        (SELECT list_id FROM roots WHERE n = 2),
        (SELECT nested.list_id FROM public.list_f AS nested WHERE nested.parent_list_id = (SELECT list_id FROM roots WHERE n = 2) LIMIT 1);
$fn$;

CREATE OR REPLACE FUNCTION public.dimension_store(
    p_tenant UUID,
    p_user UUID,
    p_row_hash TEXT,
    p_values JSONB
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_kind TEXT;
    v_account INTEGER;
    v_table TEXT;
    v_slot INTEGER;
    v_parent_slot INTEGER;
    v_key TEXT;
    v_value JSONB;
    v_name TEXT;
    v_item BIGINT;
    v_list BIGINT;
    v_nested BIGINT;
    v_parent BIGINT;
    v_keep BOOLEAN[] := ARRAY[TRUE, TRUE, TRUE, TRUE, TRUE];
    v_text TEXT[] := ARRAY[NULL, NULL, NULL, NULL, NULL]::TEXT[];
    v_items BIGINT[] := ARRAY[NULL, NULL, NULL, NULL, NULL]::BIGINT[];
    v_current BIGINT[] := ARRAY[NULL, NULL, NULL, NULL, NULL]::BIGINT[];
    v_cur1 BIGINT;
    v_cur2 BIGINT;
    v_cur3 BIGINT;
    v_cur4 BIGINT;
    v_roles RECORD;
    v_saved JSONB;
BEGIN
    IF p_values IS NULL OR JSONB_TYPEOF(p_values) <> 'object' THEN
        RAISE EXCEPTION 'values must be an object' USING ERRCODE = '22023';
    END IF;
    SELECT keys.kind, keys.account_id INTO v_kind, v_account
    FROM public.movement_keys_v AS keys
    WHERE keys.row_hash = p_row_hash AND keys.tenant_id = p_tenant AND keys.user_id = p_user
    LIMIT 1;
    IF v_kind IS NULL THEN
        RAISE EXCEPTION 'movement not found' USING ERRCODE = 'P0002';
    END IF;
    v_table := CASE v_kind
        WHEN 'debit' THEN 'debit_d'
        WHEN 'asset' THEN 'master_closed_aaccandass_d'
        ELSE 'credit_d'
    END;
    SELECT * INTO v_roles FROM public.dimension_roles(p_tenant, p_user);
    EXECUTE FORMAT(
        'SELECT attribute_1_item_id, attribute_2_item_id, attribute_3_item_id, attribute_4_item_id
        FROM public.%I WHERE row_hash = $1 AND tenant_id = $2 AND user_id = $3',
        v_table
    )
    INTO v_cur1, v_cur2, v_cur3, v_cur4
    USING p_row_hash, p_tenant, p_user;
    v_current := ARRAY[v_cur1, v_cur2, v_cur3, v_cur4, NULL];

    FOR v_slot IN 1..5 LOOP
        v_key := 'attribute_' || v_slot;
        CONTINUE WHEN NOT p_values ? v_key;
        v_keep[v_slot] := FALSE;
        v_value := p_values -> v_key;
        IF v_slot = 5 THEN
            IF v_value IS NULL OR JSONB_TYPEOF(v_value) = 'null' THEN
                v_text[5] := NULL;
            ELSIF JSONB_TYPEOF(v_value) = 'string' THEN
                v_text[5] := NULLIF(BTRIM(v_value #>> '{}'), '');
            ELSIF JSONB_TYPEOF(v_value) = 'object' AND v_value ? 'text' THEN
                v_text[5] := NULLIF(BTRIM(v_value ->> 'text'), '');
            ELSE
                RAISE EXCEPTION 'Attribute 5 is free text' USING ERRCODE = '22023';
            END IF;
            IF LENGTH(v_text[5]) > 500 THEN
                RAISE EXCEPTION 'Each attribute can have at most 500 characters' USING ERRCODE = '22023';
            END IF;
            CONTINUE;
        END IF;

        v_list := CASE WHEN v_slot IN (1, 2) THEN v_roles.list_1 ELSE v_roles.list_2 END;
        v_nested := CASE WHEN v_slot IN (1, 2) THEN v_roles.nested_1 ELSE v_roles.nested_2 END;
        IF v_value IS NULL OR JSONB_TYPEOF(v_value) = 'null' OR v_value = '""'::JSONB THEN
            v_items[v_slot] := NULL;
            v_text[v_slot] := NULL;
            CONTINUE;
        END IF;
        IF JSONB_TYPEOF(v_value) = 'string' THEN
            v_name := v_value #>> '{}';
            v_item := NULL;
        ELSIF JSONB_TYPEOF(v_value) = 'object' THEN
            IF v_value ? 'child_item_id' OR (v_slot IN (1, 3) AND v_value ? 'new_item' AND v_value ? 'item_id') THEN
                RAISE EXCEPTION 'A sub-item is stored on the sublist slot' USING ERRCODE = '22023';
            END IF;
            IF v_value ? 'item_id' AND JSONB_TYPEOF(v_value -> 'item_id') <> 'null' THEN
                v_item := (v_value ->> 'item_id')::BIGINT;
                v_name := NULL;
            ELSE
                v_item := NULL;
                v_name := COALESCE(v_value ->> 'new_item', v_value ->> 'text');
            END IF;
        ELSE
            RAISE EXCEPTION 'attribute % must be text, null or an object', v_slot USING ERRCODE = '22023';
        END IF;

        IF v_slot IN (1, 3) THEN
            IF v_list IS NULL THEN
                IF v_item IS NOT NULL THEN
                    RAISE EXCEPTION 'That list is not available' USING ERRCODE = '22023';
                END IF;
                v_text[v_slot] := NULLIF(BTRIM(v_name), '');
                IF LENGTH(v_text[v_slot]) > 500 THEN
                    RAISE EXCEPTION 'Each attribute can have at most 500 characters' USING ERRCODE = '22023';
                END IF;
                v_items[v_slot] := NULL;
                CONTINUE;
            END IF;
            IF v_item IS NOT NULL THEN
                IF NOT EXISTS (
                    SELECT 1 FROM public.list_d AS item
                    WHERE item.item_id = v_item AND item.list_id = v_list AND item.parent_item_id IS NULL
                        AND item.tenant_id = p_tenant AND item.user_id = p_user
                ) THEN
                    RAISE EXCEPTION 'That item is not in the list of attribute %', v_slot USING ERRCODE = '22023';
                END IF;
                v_items[v_slot] := v_item;
            ELSE
                v_items[v_slot] := public.list_item_ensure(p_tenant, p_user, v_list, v_name);
            END IF;
        ELSE
            v_parent_slot := v_slot - 1;
            v_parent := CASE
                WHEN v_keep[v_parent_slot] THEN v_current[v_parent_slot]
                ELSE v_items[v_parent_slot]
            END;
            IF v_nested IS NULL THEN
                IF v_item IS NOT NULL THEN
                    RAISE EXCEPTION 'This list has no sublist' USING ERRCODE = '22023';
                END IF;
                v_text[v_slot] := NULLIF(BTRIM(v_name), '');
                IF LENGTH(v_text[v_slot]) > 500 THEN
                    RAISE EXCEPTION 'Each attribute can have at most 500 characters' USING ERRCODE = '22023';
                END IF;
                v_items[v_slot] := NULL;
                CONTINUE;
            END IF;
            IF v_parent IS NULL THEN
                IF v_item IS NOT NULL OR public.list_clean_name(v_name) IS NOT NULL THEN
                    RAISE EXCEPTION 'Choose the parent item before adding a sub-item' USING ERRCODE = '22023';
                END IF;
                v_items[v_slot] := NULL;
                CONTINUE;
            END IF;
            IF v_item IS NOT NULL THEN
                IF NOT EXISTS (
                    SELECT 1 FROM public.list_d AS item
                    WHERE item.item_id = v_item AND item.list_id = v_nested AND item.parent_item_id = v_parent
                        AND item.tenant_id = p_tenant AND item.user_id = p_user
                ) THEN
                    RAISE EXCEPTION 'That sub-item does not belong to the selected parent item' USING ERRCODE = '22023';
                END IF;
                v_items[v_slot] := v_item;
            ELSE
                v_items[v_slot] := public.list_item_ensure(p_tenant, p_user, v_nested, v_name, v_parent);
            END IF;
        END IF;
    END LOOP;

    FOREACH v_slot IN ARRAY ARRAY[2, 4]
    LOOP
        v_parent_slot := v_slot - 1;
        v_parent := CASE WHEN v_keep[v_parent_slot] THEN v_current[v_parent_slot] ELSE v_items[v_parent_slot] END;
        v_item := CASE WHEN v_keep[v_slot] THEN v_current[v_slot] ELSE v_items[v_slot] END;
        CONTINUE WHEN v_item IS NULL;
        IF v_parent IS NULL OR NOT EXISTS (
            SELECT 1 FROM public.list_d AS item
            WHERE item.item_id = v_item AND item.parent_item_id = v_parent
        ) THEN
            IF v_keep[v_slot] THEN
                v_keep[v_slot] := FALSE;
                v_items[v_slot] := NULL;
            ELSE
                RAISE EXCEPTION 'That sub-item does not belong to the selected parent item' USING ERRCODE = '22023';
            END IF;
        END IF;
    END LOOP;

    EXECUTE FORMAT(
        'INSERT INTO public.%I (row_hash, tenant_id, user_id, account_id, created_by)
        VALUES ($1, $2, $3, $4, $3)
        ON CONFLICT (row_hash) DO NOTHING',
        v_table
    )
    USING p_row_hash, p_tenant, p_user, v_account;

    EXECUTE FORMAT(
        'UPDATE public.%I AS target
        SET
            attribute_1 = CASE WHEN $4[1] THEN target.attribute_1 ELSE $5[1] END,
            attribute_2 = CASE WHEN $4[2] THEN target.attribute_2 ELSE $5[2] END,
            attribute_3 = CASE WHEN $4[3] THEN target.attribute_3 ELSE $5[3] END,
            attribute_4 = CASE WHEN $4[4] THEN target.attribute_4 ELSE $5[4] END,
            attribute_5 = CASE WHEN $4[5] THEN target.attribute_5 ELSE $5[5] END,
            attribute_1_item_id = CASE WHEN $4[1] THEN target.attribute_1_item_id ELSE $6[1] END,
            attribute_2_item_id = CASE WHEN $4[2] THEN target.attribute_2_item_id ELSE $6[2] END,
            attribute_3_item_id = CASE WHEN $4[3] THEN target.attribute_3_item_id ELSE $6[3] END,
            attribute_4_item_id = CASE WHEN $4[4] THEN target.attribute_4_item_id ELSE $6[4] END,
            updated_at = NOW(),
            updated_by = $3
        WHERE target.row_hash = $1 AND target.tenant_id = $2 AND target.user_id = $3',
        v_table
    )
    USING p_row_hash, p_tenant, p_user, v_keep, v_text, v_items;

    SELECT JSONB_BUILD_OBJECT(
        'row_hash', attrs.row_hash,
        'kind', attrs.kind,
        'attribute_1', attrs.attribute_1,
        'attribute_2', attrs.attribute_2,
        'attribute_3', attrs.attribute_3,
        'attribute_4', attrs.attribute_4,
        'attribute_5', attrs.attribute_5,
        'attribute_1_item_id', attrs.attribute_1_item_id,
        'attribute_2_item_id', attrs.attribute_2_item_id,
        'attribute_3_item_id', attrs.attribute_3_item_id,
        'attribute_4_item_id', attrs.attribute_4_item_id,
        'updated_at', attrs.updated_at
    )
    INTO v_saved
    FROM public.movement_attributes_v AS attrs
    WHERE attrs.kind = v_kind AND attrs.row_hash = p_row_hash AND attrs.tenant_id = p_tenant;
    IF v_saved IS NULL THEN
        RAISE EXCEPTION 'tenant isolation' USING ERRCODE = '42501';
    END IF;
    RETURN v_saved;
END
$fn$;

CREATE OR REPLACE FUNCTION public.list_catalog()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_roles RECORD;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    SELECT * INTO v_roles FROM public.dimension_roles(v_tenant, v_user);

    RETURN JSONB_BUILD_OBJECT(
        'attributes', (
            SELECT JSONB_AGG(
                JSONB_BUILD_OBJECT(
                    'slot', slot.n,
                    'field', 'attribute_' || slot.n,
                    'label', COALESCE(
                        NULLIF(setting.label, ''),
                        (ARRAY['List 1', 'Sublist 1', 'List 2', 'Sublist 2', 'Note'])[slot.n]
                    ),
                    'custom_label', setting.label,
                    'mode', CASE WHEN slot.n = 5 THEN 'text' ELSE 'list' END,
                    'list_id', (ARRAY[v_roles.list_1, v_roles.nested_1, v_roles.list_2, v_roles.nested_2, NULL::BIGINT])[slot.n],
                    'list_name', bound.list_name,
                    'parent_list_id', bound.parent_list_id
                )
                ORDER BY slot.n
            )
            FROM GENERATE_SERIES(1, 5) AS slot (n)
            LEFT JOIN public.attribute_settings_d AS setting
                ON setting.tenant_id = v_tenant AND setting.user_id = v_user AND setting.slot = slot.n
            LEFT JOIN public.list_f AS bound
                ON bound.list_id = (ARRAY[v_roles.list_1, v_roles.nested_1, v_roles.list_2, v_roles.nested_2, NULL::BIGINT])[slot.n]
        ),
        'lists', COALESCE(
            (
                SELECT JSONB_AGG(
                    JSONB_BUILD_OBJECT(
                        'list_id', list.list_id,
                        'list_name', list.list_name,
                        'parent_list_id', list.parent_list_id,
                        'slots', '[]'::JSONB,
                        'items', COALESCE(
                            (
                                SELECT JSONB_AGG(
                                    JSONB_BUILD_OBJECT(
                                        'item_id', item.item_id,
                                        'item_name', item.item_name,
                                        'parent_item_id', item.parent_item_id,
                                        'used', (
                                            SELECT COUNT(*)
                                            FROM public.movement_attributes_v AS used
                                            WHERE used.tenant_id = v_tenant AND used.user_id = v_user
                                                AND item.item_id IN (
                                                    used.attribute_1_item_id,
                                                    used.attribute_2_item_id,
                                                    used.attribute_3_item_id,
                                                    used.attribute_4_item_id
                                                )
                                        )
                                    )
                                    ORDER BY item.parent_item_id NULLS FIRST, LOWER(item.item_name)
                                )
                                FROM public.list_d AS item
                                WHERE item.list_id = list.list_id
                            ),
                            '[]'::JSONB
                        )
                    )
                    ORDER BY list.parent_list_id NULLS FIRST, list.created_at, list.list_id
                )
                FROM public.list_f AS list
                WHERE list.tenant_id = v_tenant AND list.user_id = v_user
                    AND (
                        (list.parent_list_id IS NULL AND list.list_id IN (v_roles.list_1, v_roles.list_2))
                        OR list.list_id IN (v_roles.nested_1, v_roles.nested_2)
                    )
            ),
            '[]'::JSONB
        )
    );
END
$fn$;

CREATE OR REPLACE FUNCTION public.set_attribute_setting(
    p_slot INTEGER,
    p_label TEXT,
    p_list_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_label TEXT := public.list_clean_name(p_label);
    v_roles RECORD;
    v_role_list BIGINT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    IF p_slot IS NULL OR p_slot NOT BETWEEN 1 AND 5 THEN
        RAISE EXCEPTION 'slot must be 1 to 5' USING ERRCODE = '22023';
    END IF;
    IF COALESCE(LENGTH(v_label), 0) > 60 THEN
        RAISE EXCEPTION 'A label can have at most 60 characters' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_roles FROM public.dimension_roles(v_tenant, v_user);
    v_role_list := (ARRAY[v_roles.list_1, v_roles.nested_1, v_roles.list_2, v_roles.nested_2, NULL::BIGINT])[p_slot];
    INSERT INTO public.attribute_settings_d AS setting (tenant_id, user_id, slot, label, list_id, created_by)
    VALUES (v_tenant, v_user, p_slot, v_label, NULL, v_user)
    ON CONFLICT (tenant_id, user_id, slot) DO UPDATE
    SET label = EXCLUDED.label, updated_at = NOW(), updated_by = v_user;
    RETURN JSONB_BUILD_OBJECT(
        'slot', p_slot,
        'label', v_label,
        'list_id', v_role_list,
        'mode', CASE WHEN p_slot = 5 THEN 'text' ELSE 'list' END,
        'converted', 0
    );
END
$fn$;

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
            attrs.attribute_4,
            attrs.attribute_5,
            attrs.attribute_1_item_id,
            attrs.attribute_2_item_id,
            attrs.attribute_3_item_id,
            attrs.attribute_4_item_id,
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
                OR COALESCE(attrs.attribute_4, '') ILIKE '%' || v_search || '%'
                OR COALESCE(attrs.attribute_5, '') ILIKE '%' || v_search || '%'
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


REVOKE ALL ON FUNCTION public.dimension_roles(UUID, UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.migrate_five_attribute_slots() FROM PUBLIC;

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
                    attrs.attribute_4,
                    attrs.attribute_5,
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

CREATE OR REPLACE FUNCTION public.dimension_summary()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_result JSONB;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    WITH movement AS (
        SELECT
            keys.kind,
            keys.layer,
            (
                NULLIF(BTRIM(COALESCE(attrs.attribute_1, '')), '') IS NOT NULL
                OR NULLIF(BTRIM(COALESCE(attrs.attribute_2, '')), '') IS NOT NULL
                OR NULLIF(BTRIM(COALESCE(attrs.attribute_3, '')), '') IS NOT NULL
                OR NULLIF(BTRIM(COALESCE(attrs.attribute_4, '')), '') IS NOT NULL
                OR NULLIF(BTRIM(COALESCE(attrs.attribute_5, '')), '') IS NOT NULL
            ) AS filled,
            side.row_hash IS NOT NULL AS is_transfer
        FROM public.movement_keys_v AS keys
        LEFT JOIN public.movement_attributes_v AS attrs
            ON attrs.kind = keys.kind AND attrs.row_hash = keys.row_hash
        LEFT JOIN public.movement_transfers_v AS side
            ON side.row_hash = keys.row_hash AND side.tenant_id = keys.tenant_id
        WHERE keys.tenant_id = v_tenant AND keys.user_id = v_user
    ),
    levels AS (
        SELECT
            spec.kind,
            spec.layer,
            COUNT(movement.kind) AS total,
            COUNT(movement.kind) FILTER (WHERE movement.filled) AS filled,
            COUNT(movement.kind) FILTER (WHERE movement.is_transfer) AS transfers
        FROM (
            VALUES
                ('debit', 'open'), ('debit', 'closed'),
                ('credit', 'open'), ('credit', 'closed'), ('credit', 'future'),
                ('asset', 'closed')
        ) AS spec (kind, layer)
        LEFT JOIN movement ON movement.kind = spec.kind AND movement.layer = spec.layer
        GROUP BY spec.kind, spec.layer
    ),
    kinds AS (
        SELECT
            levels.kind,
            SUM(levels.total)::BIGINT AS total,
            SUM(levels.filled)::BIGINT AS filled,
            SUM(levels.transfers)::BIGINT AS transfers,
            JSONB_OBJECT_AGG(
                levels.layer,
                JSONB_BUILD_OBJECT(
                    'total', levels.total,
                    'filled', levels.filled,
                    'transfers', levels.transfers,
                    'pct', CASE WHEN levels.total = 0 THEN 0 ELSE ROUND(100.0 * levels.filled / levels.total, 1) END
                )
            ) AS layers
        FROM levels
        GROUP BY levels.kind
    )
    SELECT JSONB_OBJECT_AGG(
        kinds.kind,
        JSONB_BUILD_OBJECT(
            'total', kinds.total,
            'filled', kinds.filled,
            'transfers', kinds.transfers,
            'pct', CASE WHEN kinds.total = 0 THEN 0 ELSE ROUND(100.0 * kinds.filled / kinds.total, 1) END,
            'layers', kinds.layers
        )
    )
    INTO v_result
    FROM kinds;
    RETURN v_result;
END
$fn$;

CREATE OR REPLACE FUNCTION public.movement_rekeyed(p_pairs JSONB)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_table TEXT;
BEGIN
    FOREACH v_table IN ARRAY ARRAY['debit_d', 'credit_d']
    LOOP
        EXECUTE FORMAT(
            'UPDATE public.%1$I AS target
            SET
                attribute_1 = COALESCE(target.attribute_1, source.attribute_1),
                attribute_2 = COALESCE(target.attribute_2, source.attribute_2),
                attribute_3 = COALESCE(target.attribute_3, source.attribute_3),
                attribute_4 = COALESCE(target.attribute_4, source.attribute_4),
                attribute_5 = COALESCE(target.attribute_5, source.attribute_5),
                attribute_1_item_id = COALESCE(target.attribute_1_item_id, source.attribute_1_item_id),
                attribute_2_item_id = COALESCE(target.attribute_2_item_id, source.attribute_2_item_id),
                attribute_3_item_id = COALESCE(target.attribute_3_item_id, source.attribute_3_item_id),
                attribute_4_item_id = COALESCE(target.attribute_4_item_id, source.attribute_4_item_id),
                updated_at = NOW(),
                updated_by = source.updated_by
            FROM JSONB_ARRAY_ELEMENTS($1) AS pair (item)
            INNER JOIN public.%1$I AS source ON source.row_hash = pair.item ->> ''old_hash''
            WHERE
                target.row_hash = pair.item ->> ''new_hash''
                AND target.tenant_id = source.tenant_id
                AND (
                    source.attribute_1 IS NOT NULL OR source.attribute_2 IS NOT NULL
                    OR source.attribute_3 IS NOT NULL OR source.attribute_4 IS NOT NULL
                    OR source.attribute_5 IS NOT NULL OR source.attribute_1_item_id IS NOT NULL
                    OR source.attribute_2_item_id IS NOT NULL OR source.attribute_3_item_id IS NOT NULL
                    OR source.attribute_4_item_id IS NOT NULL
                )',
            v_table
        )
        USING p_pairs;
    END LOOP;
END
$fn$;
