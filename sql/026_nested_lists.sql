-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- One nested list per root list, and sub-items that point at a parent item
-- (openspec/changes/nested-attribute-lists).
--
--   * list_f.parent_list_id: null on a root list. A nested list stores its parent
--     list_id. A root list has at most one nested list, and a nested list cannot
--     nest again.
--   * list_d.parent_item_id: null on a root item. A sub-item stores the parent
--     item_id. The same name may exist under two parent items. A name is unique
--     under one parent item, and root items stay unique per list.
--   * Attribute 1 cannot bind to a nested list. Attribute 2 or 3 can, only when
--     the previous slot is bound to that list's parent. A save rejects a child
--     item that does not belong to the selected parent item.
--
-- Safe to run more than once. Requires 017. Apply on Neon by hand after 025.

ALTER TABLE public.list_f ADD COLUMN IF NOT EXISTS parent_list_id BIGINT;
ALTER TABLE public.list_d ADD COLUMN IF NOT EXISTS parent_item_id BIGINT;

DO $fk$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'list_f_parent_fkey'
    ) THEN
        ALTER TABLE public.list_f
        ADD CONSTRAINT list_f_parent_fkey
        FOREIGN KEY (parent_list_id) REFERENCES public.list_f (list_id) ON DELETE CASCADE;
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM pg_constraint WHERE conname = 'list_d_parent_item_fkey'
    ) THEN
        ALTER TABLE public.list_d
        ADD CONSTRAINT list_d_parent_item_fkey
        FOREIGN KEY (parent_item_id) REFERENCES public.list_d (item_id) ON DELETE CASCADE;
    END IF;
END
$fk$;

DROP INDEX IF EXISTS public.list_d_name_idx;
CREATE UNIQUE INDEX IF NOT EXISTS list_f_one_nested_idx
ON public.list_f (parent_list_id) WHERE parent_list_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS list_d_root_name_idx
ON public.list_d (list_id, LOWER(item_name)) WHERE parent_item_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS list_d_sub_name_idx
ON public.list_d (list_id, parent_item_id, LOWER(item_name)) WHERE parent_item_id IS NOT NULL;

COMMENT ON COLUMN public.list_f.parent_list_id IS
'Root list this nested list belongs to. NULL means this row is a root list.';
COMMENT ON COLUMN public.list_d.parent_item_id IS
'Parent item (a root item of the parent list). NULL means this row is a root item.';

CREATE OR REPLACE FUNCTION public.list_f_nested_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF NEW.parent_list_id IS NULL THEN
        RETURN NEW;
    END IF;
    IF NEW.parent_list_id = NEW.list_id THEN
        RAISE EXCEPTION 'A list cannot nest under itself' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.list_f AS parent
        WHERE
            parent.list_id = NEW.parent_list_id
            AND parent.tenant_id = NEW.tenant_id
            AND parent.user_id = NEW.user_id
            AND parent.parent_list_id IS NULL
    ) THEN
        RAISE EXCEPTION 'A nested list can only sit under a root list' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.list_f AS child
        WHERE child.parent_list_id = NEW.list_id
    ) THEN
        RAISE EXCEPTION 'A list that already has a nested list cannot itself be nested' USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS list_f_nested_guard ON public.list_f;
CREATE TRIGGER list_f_nested_guard
BEFORE INSERT OR UPDATE OF parent_list_id ON public.list_f
FOR EACH ROW EXECUTE FUNCTION public.list_f_nested_guard();

CREATE OR REPLACE FUNCTION public.list_d_parent_guard()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_parent_list BIGINT;
BEGIN
    SELECT list.parent_list_id INTO v_parent_list
    FROM public.list_f AS list
    WHERE list.list_id = NEW.list_id;
    IF v_parent_list IS NULL AND NEW.parent_item_id IS NOT NULL THEN
        RAISE EXCEPTION 'A root list item cannot point at a parent item' USING ERRCODE = '22023';
    END IF;
    IF v_parent_list IS NOT NULL AND NEW.parent_item_id IS NULL THEN
        RAISE EXCEPTION 'A nested list item must point at a parent item' USING ERRCODE = '22023';
    END IF;
    IF NEW.parent_item_id IS NOT NULL AND NOT EXISTS (
        SELECT 1 FROM public.list_d AS parent
        WHERE
            parent.item_id = NEW.parent_item_id
            AND parent.list_id = v_parent_list
            AND parent.parent_item_id IS NULL
            AND parent.tenant_id = NEW.tenant_id
            AND parent.user_id = NEW.user_id
    ) THEN
        RAISE EXCEPTION 'That parent item is not in the parent list' USING ERRCODE = '22023';
    END IF;
    RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS list_d_parent_guard ON public.list_d;
CREATE TRIGGER list_d_parent_guard
BEFORE INSERT OR UPDATE OF parent_item_id, list_id ON public.list_d
FOR EACH ROW EXECUTE FUNCTION public.list_d_parent_guard();

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
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    RETURN JSONB_BUILD_OBJECT(
        'attributes', (
            SELECT JSONB_AGG(
                JSONB_BUILD_OBJECT(
                    'slot', slot.n,
                    'field', 'attribute_' || slot.n,
                    'label', COALESCE(NULLIF(setting.label, ''), 'Attribute ' || slot.n),
                    'custom_label', setting.label,
                    'mode', CASE WHEN setting.list_id IS NULL THEN 'text' ELSE 'list' END,
                    'list_id', setting.list_id,
                    'list_name', bound.list_name,
                    'parent_list_id', bound.parent_list_id
                )
                ORDER BY slot.n
            )
            FROM GENERATE_SERIES(1, 3) AS slot (n)
            LEFT JOIN public.attribute_settings_d AS setting
                ON setting.tenant_id = v_tenant AND setting.user_id = v_user AND setting.slot = slot.n
            LEFT JOIN public.list_f AS bound ON bound.list_id = setting.list_id
        ),
        'lists', COALESCE(
            (
                SELECT JSONB_AGG(
                    JSONB_BUILD_OBJECT(
                        'list_id', list.list_id,
                        'list_name', list.list_name,
                        'parent_list_id', list.parent_list_id,
                        'slots', COALESCE(
                            (
                                SELECT JSONB_AGG(setting.slot ORDER BY setting.slot)
                                FROM public.attribute_settings_d AS setting
                                WHERE
                                    setting.list_id = list.list_id
                                    AND setting.tenant_id = v_tenant
                                    AND setting.user_id = v_user
                            ),
                            '[]'::JSONB
                        ),
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
                                            WHERE
                                                used.tenant_id = v_tenant
                                                AND used.user_id = v_user
                                                AND item.item_id IN (
                                                    used.attribute_1_item_id,
                                                    used.attribute_2_item_id,
                                                    used.attribute_3_item_id
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
                    ORDER BY list.parent_list_id NULLS FIRST, LOWER(list.list_name)
                )
                FROM public.list_f AS list
                WHERE list.tenant_id = v_tenant AND list.user_id = v_user
            ),
            '[]'::JSONB
        )
    );
END
$fn$;

CREATE OR REPLACE FUNCTION public.create_nested_list(p_parent_list_id BIGINT, p_list_name TEXT)
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
    IF NOT EXISTS (
        SELECT 1 FROM public.list_f AS parent
        WHERE
            parent.list_id = p_parent_list_id
            AND parent.tenant_id = v_tenant
            AND parent.user_id = v_user
            AND parent.parent_list_id IS NULL
    ) THEN
        RAISE EXCEPTION 'A nested list can only sit under a root list' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.list_f AS child
        WHERE child.parent_list_id = p_parent_list_id
    ) THEN
        RAISE EXCEPTION 'This list already has a nested list' USING ERRCODE = '23505';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.list_f AS list
        WHERE list.tenant_id = v_tenant AND list.user_id = v_user AND LOWER(list.list_name) = LOWER(v_name)
    ) THEN
        RAISE EXCEPTION 'A list named "%" already exists', v_name USING ERRCODE = '23505';
    END IF;
    IF (SELECT COUNT(*) FROM public.list_f AS list WHERE list.tenant_id = v_tenant AND list.user_id = v_user) >= 50 THEN
        RAISE EXCEPTION 'At most 50 lists per user' USING ERRCODE = '22023';
    END IF;
    INSERT INTO public.list_f (tenant_id, user_id, list_name, parent_list_id, created_by)
    VALUES (v_tenant, v_user, v_name, p_parent_list_id, v_user)
    RETURNING list_f.list_id, list_f.list_name, list_f.parent_list_id INTO v_list;
    RETURN JSONB_BUILD_OBJECT(
        'list_id', v_list.list_id,
        'list_name', v_list.list_name,
        'parent_list_id', v_list.parent_list_id
    );
END
$fn$;

DROP FUNCTION IF EXISTS public.list_item_ensure(UUID, UUID, BIGINT, TEXT);
CREATE FUNCTION public.list_item_ensure(
    p_tenant UUID,
    p_user UUID,
    p_list_id BIGINT,
    p_name TEXT,
    p_parent_item_id BIGINT DEFAULT NULL
) RETURNS BIGINT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_name TEXT := public.list_clean_name(p_name);
    v_item BIGINT;
BEGIN
    IF v_name IS NULL THEN
        RETURN NULL;
    END IF;
    IF LENGTH(v_name) > 500 THEN
        RAISE EXCEPTION 'An item name can have at most 500 characters' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1 FROM public.list_f AS list
        WHERE list.list_id = p_list_id AND list.tenant_id = p_tenant AND list.user_id = p_user
    ) THEN
        RAISE EXCEPTION 'list not found' USING ERRCODE = 'P0002';
    END IF;
    IF p_parent_item_id IS NULL THEN
        INSERT INTO public.list_d (list_id, tenant_id, user_id, item_name, created_by)
        VALUES (p_list_id, p_tenant, p_user, v_name, p_user)
        ON CONFLICT (list_id, (LOWER(item_name))) WHERE parent_item_id IS NULL DO NOTHING
        RETURNING list_d.item_id INTO v_item;
        IF v_item IS NULL THEN
            SELECT item.item_id INTO v_item
            FROM public.list_d AS item
            WHERE item.list_id = p_list_id AND item.parent_item_id IS NULL AND LOWER(item.item_name) = LOWER(v_name);
        END IF;
    ELSE
        INSERT INTO public.list_d (list_id, tenant_id, user_id, item_name, parent_item_id, created_by)
        VALUES (p_list_id, p_tenant, p_user, v_name, p_parent_item_id, p_user)
        ON CONFLICT (list_id, parent_item_id, (LOWER(item_name))) WHERE parent_item_id IS NOT NULL DO NOTHING
        RETURNING list_d.item_id INTO v_item;
        IF v_item IS NULL THEN
            SELECT item.item_id INTO v_item
            FROM public.list_d AS item
            WHERE
                item.list_id = p_list_id
                AND item.parent_item_id = p_parent_item_id
                AND LOWER(item.item_name) = LOWER(v_name);
        END IF;
    END IF;
    RETURN v_item;
END
$fn$;

CREATE OR REPLACE FUNCTION public.add_list_item(
    p_list_id BIGINT,
    p_item_name TEXT,
    p_parent_item_id BIGINT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_name TEXT := public.list_clean_name(p_item_name);
    v_item BIGINT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    IF v_name IS NULL OR LENGTH(v_name) > 500 THEN
        RAISE EXCEPTION 'An item name needs 1 to 500 characters' USING ERRCODE = '22023';
    END IF;
    IF p_parent_item_id IS NULL THEN
        RAISE EXCEPTION 'A sub-item needs a parent item' USING ERRCODE = '22023';
    END IF;
    IF (SELECT COUNT(*) FROM public.list_d AS item WHERE item.list_id = p_list_id) >= 1000 THEN
        RAISE EXCEPTION 'At most 1000 items per list' USING ERRCODE = '22023';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.list_d AS item
        WHERE
            item.list_id = p_list_id
            AND item.parent_item_id = p_parent_item_id
            AND LOWER(item.item_name) = LOWER(v_name)
    ) THEN
        RAISE EXCEPTION 'The parent item already has a sub-item named "%"', v_name USING ERRCODE = '23505';
    END IF;
    INSERT INTO public.list_d (list_id, tenant_id, user_id, item_name, parent_item_id, created_by)
    VALUES (p_list_id, v_tenant, v_user, v_name, p_parent_item_id, v_user)
    RETURNING list_d.item_id INTO v_item;
    RETURN (
        SELECT JSONB_BUILD_OBJECT(
            'item_id', item.item_id,
            'list_id', item.list_id,
            'item_name', item.item_name,
            'parent_item_id', item.parent_item_id
        )
        FROM public.list_d AS item
        WHERE item.item_id = v_item
    );
END
$fn$;

CREATE OR REPLACE FUNCTION public.rename_list_item(p_item_id BIGINT, p_item_name TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_name TEXT := public.list_clean_name(p_item_name);
    v_list BIGINT;
    v_parent BIGINT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    IF v_name IS NULL OR LENGTH(v_name) > 500 THEN
        RAISE EXCEPTION 'An item name needs 1 to 500 characters' USING ERRCODE = '22023';
    END IF;
    SELECT item.list_id, item.parent_item_id INTO v_list, v_parent
    FROM public.list_d AS item
    WHERE item.item_id = p_item_id AND item.tenant_id = v_tenant AND item.user_id = v_user;
    IF v_list IS NULL THEN
        RAISE EXCEPTION 'item not found' USING ERRCODE = 'P0002';
    END IF;
    IF EXISTS (
        SELECT 1 FROM public.list_d AS item
        WHERE
            item.list_id = v_list
            AND item.item_id <> p_item_id
            AND LOWER(item.item_name) = LOWER(v_name)
            AND item.parent_item_id IS NOT DISTINCT FROM v_parent
    ) THEN
        IF v_parent IS NULL THEN
            RAISE EXCEPTION 'The list already has an item named "%"', v_name USING ERRCODE = '23505';
        END IF;
        RAISE EXCEPTION 'The parent item already has a sub-item named "%"', v_name USING ERRCODE = '23505';
    END IF;
    UPDATE public.list_d
    SET item_name = v_name, updated_at = NOW(), updated_by = v_user
    WHERE item_id = p_item_id;
    RETURN JSONB_BUILD_OBJECT(
        'item_id', p_item_id,
        'list_id', v_list,
        'item_name', v_name,
        'parent_item_id', v_parent
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
    v_old BIGINT;
    v_parent_list BIGINT;
    v_table TEXT;
    v_converted BIGINT := 0;
    v_count BIGINT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    IF p_slot IS NULL OR p_slot NOT BETWEEN 1 AND 3 THEN
        RAISE EXCEPTION 'slot must be 1, 2 or 3' USING ERRCODE = '22023';
    END IF;
    IF COALESCE(LENGTH(v_label), 0) > 60 THEN
        RAISE EXCEPTION 'A label can have at most 60 characters' USING ERRCODE = '22023';
    END IF;
    v_parent_list := NULL;
    IF p_list_id IS NOT NULL THEN
        SELECT list.parent_list_id INTO v_parent_list
        FROM public.list_f AS list
        WHERE list.list_id = p_list_id AND list.tenant_id = v_tenant AND list.user_id = v_user;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'list not found' USING ERRCODE = 'P0002';
        END IF;
        IF v_parent_list IS NOT NULL AND p_slot = 1 THEN
            RAISE EXCEPTION 'Attribute 1 cannot be bound to a nested list' USING ERRCODE = '22023';
        END IF;
        IF v_parent_list IS NOT NULL AND NOT EXISTS (
            SELECT 1 FROM public.attribute_settings_d AS previous
            WHERE
                previous.tenant_id = v_tenant
                AND previous.user_id = v_user
                AND previous.slot = p_slot - 1
                AND previous.list_id = v_parent_list
        ) THEN
            RAISE EXCEPTION 'Bind the previous attribute to the parent list first' USING ERRCODE = '22023';
        END IF;
    END IF;

    SELECT setting.list_id INTO v_old
    FROM public.attribute_settings_d AS setting
    WHERE setting.tenant_id = v_tenant AND setting.user_id = v_user AND setting.slot = p_slot;

    INSERT INTO public.attribute_settings_d AS setting (tenant_id, user_id, slot, label, list_id, created_by)
    VALUES (v_tenant, v_user, p_slot, v_label, p_list_id, v_user)
    ON CONFLICT (tenant_id, user_id, slot) DO UPDATE
    SET label = EXCLUDED.label, list_id = EXCLUDED.list_id, updated_at = NOW(), updated_by = v_user;

    -- A nested list has no root items. Leave movement values until the person picks a parent item.
    FOREACH v_table IN ARRAY ARRAY['debit_d', 'credit_d', 'master_closed_aaccandass_d']
    LOOP
        IF p_list_id IS NOT NULL AND v_parent_list IS NULL THEN
            EXECUTE FORMAT(
                'INSERT INTO public.list_d (list_id, tenant_id, user_id, item_name, created_by)
                SELECT DISTINCT ON (LOWER(source.name)) $1, $2, $3, source.name, $3
                FROM (
                    SELECT public.list_clean_name(COALESCE(item.item_name, dim.attribute_%1$s)) AS name
                    FROM public.%2$I AS dim
                    LEFT JOIN public.list_d AS item ON item.item_id = dim.attribute_%1$s_item_id
                    WHERE
                        dim.tenant_id = $2 AND dim.user_id = $3
                        AND (
                            (dim.attribute_%1$s_item_id IS NULL AND dim.attribute_%1$s IS NOT NULL)
                            OR item.list_id <> $1
                        )
                ) AS source
                WHERE source.name IS NOT NULL
                ORDER BY LOWER(source.name), source.name COLLATE "C"
                ON CONFLICT (list_id, (LOWER(item_name))) WHERE parent_item_id IS NULL DO NOTHING',
                p_slot, v_table
            )
            USING p_list_id, v_tenant, v_user;
            EXECUTE FORMAT(
                'UPDATE public.%2$I AS dim
                SET
                    attribute_%1$s_item_id = target.item_id,
                    attribute_%1$s = NULL,
                    updated_at = NOW(),
                    updated_by = $3
                FROM public.%2$I AS old_dim
                LEFT JOIN public.list_d AS old_item ON old_item.item_id = old_dim.attribute_%1$s_item_id
                INNER JOIN public.list_d AS target
                    ON target.list_id = $1
                    AND target.parent_item_id IS NULL
                    AND LOWER(target.item_name) = LOWER(
                        public.list_clean_name(COALESCE(old_item.item_name, old_dim.attribute_%1$s))
                    )
                WHERE
                    old_dim.row_hash = dim.row_hash
                    AND dim.tenant_id = $2 AND dim.user_id = $3
                    AND (
                        (dim.attribute_%1$s_item_id IS NULL AND dim.attribute_%1$s IS NOT NULL)
                        OR old_item.list_id <> $1
                    )',
                p_slot, v_table
            )
            USING p_list_id, v_tenant, v_user;
            GET DIAGNOSTICS v_count = ROW_COUNT;
            v_converted := v_converted + v_count;
        ELSIF p_list_id IS NULL AND v_old IS NOT NULL THEN
            EXECUTE FORMAT(
                'UPDATE public.%2$I AS dim
                SET
                    attribute_%1$s = item.item_name,
                    attribute_%1$s_item_id = NULL,
                    updated_at = NOW(),
                    updated_by = $2
                FROM public.list_d AS item
                WHERE
                    item.item_id = dim.attribute_%1$s_item_id
                    AND dim.tenant_id = $1 AND dim.user_id = $2',
                p_slot, v_table
            )
            USING v_tenant, v_user;
            GET DIAGNOSTICS v_count = ROW_COUNT;
            v_converted := v_converted + v_count;
        END IF;
    END LOOP;

    RETURN JSONB_BUILD_OBJECT(
        'slot', p_slot,
        'label', v_label,
        'list_id', p_list_id,
        'mode', CASE WHEN p_list_id IS NULL THEN 'text' ELSE 'list' END,
        'converted', v_converted
    );
END
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
    v_key TEXT;
    v_value JSONB;
    v_list BIGINT;
    v_name TEXT;
    v_item BIGINT;
    v_keep BOOLEAN [] := ARRAY[TRUE, TRUE, TRUE];
    v_text TEXT [] := ARRAY[NULL, NULL, NULL]::TEXT [];
    v_items BIGINT [] := ARRAY[NULL, NULL, NULL]::BIGINT [];
    v_current BIGINT [] := ARRAY[NULL, NULL, NULL]::BIGINT [];
    v_cur1 BIGINT;
    v_cur2 BIGINT;
    v_cur3 BIGINT;
    v_parent_list BIGINT;
    v_prev BIGINT;
    v_chosen BIGINT;
    v_item_parent BIGINT;
    v_saved JSONB;
BEGIN
    IF p_values IS NULL OR JSONB_TYPEOF(p_values) <> 'object' THEN
        RAISE EXCEPTION 'values must be an object' USING ERRCODE = '22023';
    END IF;
    SELECT keys.kind, keys.account_id
    INTO v_kind, v_account
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
    EXECUTE FORMAT(
        'SELECT attribute_1_item_id, attribute_2_item_id, attribute_3_item_id
        FROM public.%I WHERE row_hash = $1 AND tenant_id = $2 AND user_id = $3',
        v_table
    )
    INTO v_cur1, v_cur2, v_cur3
    USING p_row_hash, p_tenant, p_user;
    v_current := ARRAY[v_cur1, v_cur2, v_cur3];

    FOR v_slot IN 1..3 LOOP
        v_key := 'attribute_' || v_slot;
        CONTINUE WHEN NOT p_values ? v_key;
        v_keep[v_slot] := FALSE;
        v_value := p_values -> v_key;
        SELECT setting.list_id INTO v_list
        FROM public.attribute_settings_d AS setting
        WHERE setting.tenant_id = p_tenant AND setting.user_id = p_user AND setting.slot = v_slot;

        v_item := NULL;
        v_name := NULL;
        IF v_value IS NULL OR JSONB_TYPEOF(v_value) = 'null' THEN
            CONTINUE;
        ELSIF JSONB_TYPEOF(v_value) = 'string' THEN
            v_name := v_value #>> '{}';
        ELSIF JSONB_TYPEOF(v_value) = 'object' THEN
            IF v_value ? 'item_id' AND JSONB_TYPEOF(v_value -> 'item_id') <> 'null' THEN
                IF v_list IS NULL THEN
                    RAISE EXCEPTION 'Attribute % is free text; bind it to a list first', v_slot
                    USING ERRCODE = '22023';
                END IF;
                BEGIN
                    v_item := (v_value ->> 'item_id')::BIGINT;
                EXCEPTION WHEN invalid_text_representation THEN
                    RAISE EXCEPTION 'item_id must be a number' USING ERRCODE = '22023';
                END;
                IF NOT EXISTS (
                    SELECT 1 FROM public.list_d AS item
                    WHERE item.item_id = v_item AND item.list_id = v_list
                        AND item.tenant_id = p_tenant AND item.user_id = p_user
                ) THEN
                    RAISE EXCEPTION 'That item is not in the list of attribute %', v_slot USING ERRCODE = '22023';
                END IF;
                v_items[v_slot] := v_item;
                CONTINUE;
            END IF;
            v_name := COALESCE(v_value ->> 'new_item', v_value ->> 'text');
        ELSE
            RAISE EXCEPTION 'attribute % must be text, null or an object', v_slot USING ERRCODE = '22023';
        END IF;

        IF v_list IS NULL THEN
            v_name := NULLIF(BTRIM(COALESCE(v_name, '')), '');
            IF LENGTH(v_name) > 500 THEN
                RAISE EXCEPTION 'Each attribute can have at most 500 characters' USING ERRCODE = '22023';
            END IF;
            v_text[v_slot] := v_name;
        ELSE
            SELECT list.parent_list_id INTO v_parent_list
            FROM public.list_f AS list
            WHERE list.list_id = v_list;
            IF v_parent_list IS NOT NULL THEN
                IF public.list_clean_name(v_name) IS NULL THEN
                    v_items[v_slot] := NULL;
                ELSE
                    v_prev := CASE
                        WHEN v_slot = 1 THEN NULL
                        WHEN v_keep[v_slot - 1] THEN v_current[v_slot - 1]
                        ELSE v_items[v_slot - 1]
                    END;
                    IF v_prev IS NULL THEN
                        RAISE EXCEPTION 'Choose the parent item before adding a sub-item' USING ERRCODE = '22023';
                    END IF;
                    v_items[v_slot] := public.list_item_ensure(p_tenant, p_user, v_list, v_name, v_prev);
                END IF;
            ELSE
                v_items[v_slot] := public.list_item_ensure(p_tenant, p_user, v_list, v_name);
            END IF;
        END IF;
    END LOOP;

    FOR v_slot IN 2..3 LOOP
        SELECT list.parent_list_id INTO v_parent_list
        FROM public.attribute_settings_d AS setting
        INNER JOIN public.list_f AS list ON list.list_id = setting.list_id
        WHERE setting.tenant_id = p_tenant AND setting.user_id = p_user AND setting.slot = v_slot;
        CONTINUE WHEN v_parent_list IS NULL;
        v_chosen := CASE WHEN v_keep[v_slot] THEN v_current[v_slot] ELSE v_items[v_slot] END;
        CONTINUE WHEN v_chosen IS NULL;
        v_prev := CASE WHEN v_keep[v_slot - 1] THEN v_current[v_slot - 1] ELSE v_items[v_slot - 1] END;
        SELECT item.parent_item_id INTO v_item_parent
        FROM public.list_d AS item
        WHERE item.item_id = v_chosen;
        IF v_item_parent IS DISTINCT FROM v_prev THEN
            RAISE EXCEPTION 'That sub-item does not belong to the selected parent item' USING ERRCODE = '22023';
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
            attribute_1_item_id = CASE WHEN $4[1] THEN target.attribute_1_item_id ELSE $6[1] END,
            attribute_2_item_id = CASE WHEN $4[2] THEN target.attribute_2_item_id ELSE $6[2] END,
            attribute_3_item_id = CASE WHEN $4[3] THEN target.attribute_3_item_id ELSE $6[3] END,
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
        'attribute_1_item_id', attrs.attribute_1_item_id,
        'attribute_2_item_id', attrs.attribute_2_item_id,
        'attribute_3_item_id', attrs.attribute_3_item_id,
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

REVOKE ALL ON FUNCTION public.list_f_nested_guard() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_d_parent_guard() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_item_ensure(UUID, UUID, BIGINT, TEXT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dimension_store(UUID, UUID, TEXT, JSONB) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.list_catalog() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.create_nested_list(BIGINT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.add_list_item(BIGINT, TEXT, BIGINT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.rename_list_item(BIGINT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_attribute_setting(INTEGER, TEXT, BIGINT) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.list_catalog() TO strm_app;
GRANT EXECUTE ON FUNCTION public.create_nested_list(BIGINT, TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.add_list_item(BIGINT, TEXT, BIGINT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.rename_list_item(BIGINT, TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.set_attribute_setting(INTEGER, TEXT, BIGINT) TO strm_app;
