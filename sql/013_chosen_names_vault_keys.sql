-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- Keep the file name the user chose, and make the curated vault readable and self-describing.
--
--   * statement_uploads_f.chosen_filename: the exact name of the file the user picked
--     (browser file.name). original_filename keeps its existing meaning: the working
--     CSV name ingest stores. Rows loaded before 013 get chosen_filename =
--     original_filename with chosen_filename_source = 'legacy'.
--   * Vault object names (curated_standard_key is the one definition; mirrored by
--     apps/statements/curated.py standard_object_key):
--         curated/{tenant}/{YYYY-MM}_{account}_{Bank}[_msi][_vN].{csv|pdf}
--     YYYY-MM is the period_end of the upload's period, account is
--     bank_accounts_d.account_number (the number the page shows next to the account
--     name), Bank is banks_d.bank_name, _msi marks the installment (MSI) file, and _vN
--     (N >= 2) is added when the same name was already used: the vault is write-once,
--     so a replaced open-period file, a re-upload after a delete or a later closed
--     statement gets the next version instead of overwriting.
--   * curated_vault_keys_d is the append-only registry of every vault name handed out
--     (rows stay when the upload is deleted, so a name is never reused).
--   * Each vault object gets S3 metadata (original filename, bank, account, period,
--     dataset, upload id; percent-encoded UTF-8) and a manifest object
--         curated/{tenant}/manifest/{object file name}.json
--     with everything needed to rebuild the database rows from the bucket alone.
--     A delete in the app writes curated/{tenant}/manifest/{object file name}.deleted.json.
--   * curated_key_migration_plan / apply_curated_key_migration: dry-run and bookkeeping
--     for copying pre-013 objects (curated/{tenant}/{upload_id}.{ext}) to a backup key
--     and to the new name (scripts/curated_key_migration.py). Nothing here touches S3,
--     and old objects stay where they are (Object Lock, delete denied on curated/*).
--
-- Safe to run more than once. Apply on Neon by hand after 011 and 012.

-- =============================================================================
-- 1. Columns and backfill
-- =============================================================================
ALTER TABLE public.statement_uploads_f
ADD COLUMN IF NOT EXISTS chosen_filename TEXT,
ADD COLUMN IF NOT EXISTS chosen_filename_source TEXT,
ADD COLUMN IF NOT EXISTS curated_legacy_s3_key TEXT,
ADD COLUMN IF NOT EXISTS curated_backup_s3_key TEXT;

COMMENT ON COLUMN public.statement_uploads_f.chosen_filename IS
'Name of the file the user picked (browser file.name). Legacy rows: copy of original_filename.';
COMMENT ON COLUMN public.statement_uploads_f.chosen_filename_source IS
'chosen = stored from the upload; legacy = backfilled from original_filename by sql/013.';
COMMENT ON COLUMN public.statement_uploads_f.original_filename IS
'Working CSV name stored by ingest (Bank_Account_YYYY-MM.csv for spreadsheets and unnamed exports).';
COMMENT ON COLUMN public.statement_uploads_f.curated_legacy_s3_key IS
'Vault key before the standard-name migration (the object is kept there).';
COMMENT ON COLUMN public.statement_uploads_f.curated_backup_s3_key IS
'Backup copy written by the standard-name migration.';

UPDATE public.statement_uploads_f
SET
    chosen_filename = original_filename,
    chosen_filename_source = 'legacy'
WHERE chosen_filename IS NULL;

-- Direct calls of the pre-013 ingest functions do not pass a chosen name.
CREATE OR REPLACE FUNCTION public.statement_uploads_chosen_default()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $fn$
BEGIN
    IF NEW.chosen_filename IS NULL OR BTRIM(NEW.chosen_filename) = '' THEN
        NEW.chosen_filename := NEW.original_filename;
        NEW.chosen_filename_source := 'legacy';
    ELSIF NEW.chosen_filename_source IS NULL THEN
        NEW.chosen_filename_source := 'chosen';
    END IF;
    RETURN NEW;
END
$fn$;

DROP TRIGGER IF EXISTS statement_uploads_f_chosen_default ON public.statement_uploads_f;
CREATE TRIGGER statement_uploads_f_chosen_default
BEFORE INSERT OR UPDATE OF chosen_filename, original_filename ON public.statement_uploads_f
FOR EACH ROW
EXECUTE FUNCTION public.statement_uploads_chosen_default();

ALTER TABLE public.statement_uploads_f
ALTER COLUMN chosen_filename SET NOT NULL,
ALTER COLUMN chosen_filename_source SET NOT NULL;

ALTER TABLE public.statement_uploads_f
DROP CONSTRAINT IF EXISTS statement_uploads_f_chosen_source_check;
ALTER TABLE public.statement_uploads_f
ADD CONSTRAINT statement_uploads_f_chosen_source_check
CHECK (chosen_filename_source IN ('chosen', 'legacy'));


-- =============================================================================
-- 2. Vault names
-- =============================================================================
-- Same rule as strmStoredUploadFilename: runs of characters outside [A-Za-z0-9_.-]
-- become one '_', repeated '_' collapse, and leading/trailing '_' are dropped.
CREATE OR REPLACE FUNCTION public.curated_name_part(p_value TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT COALESCE(
        NULLIF(
            REGEXP_REPLACE(
                REGEXP_REPLACE(
                    REGEXP_REPLACE(COALESCE(p_value, ''), '[^A-Za-z0-9_.-]+', '_', 'g'),
                    '_+',
                    '_',
                    'g'
                ),
                '^_|_$',
                '',
                'g'
            ),
            ''
        ),
        'x'
    )
$fn$;

CREATE OR REPLACE FUNCTION public.upload_slot(p_dataset TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT CASE p_dataset
        WHEN 'credit_plan' THEN 'installment'
        WHEN 'pdf' THEN 'pdf'
        ELSE 'statement'
    END
$fn$;

-- {YYYY-MM}_{account}_{Bank}[_msi]
CREATE OR REPLACE FUNCTION public.curated_vault_base(
    p_bank_name TEXT,
    p_account_number TEXT,
    p_period_end DATE,
    p_slot TEXT
) RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
BEGIN
    IF p_slot IS NULL OR p_slot NOT IN ('statement', 'installment', 'pdf') THEN
        RAISE EXCEPTION 'slot must be statement, installment or pdf' USING ERRCODE = '22023';
    END IF;
    IF p_period_end IS NULL THEN
        RAISE EXCEPTION 'a period is required for a vault name' USING ERRCODE = '22023';
    END IF;
    RETURN FORMAT(
        '%s_%s_%s%s',
        TO_CHAR(p_period_end, 'YYYY-MM'),
        public.curated_name_part(p_account_number),
        public.curated_name_part(p_bank_name),
        CASE WHEN p_slot = 'installment' THEN '_msi' ELSE '' END
    );
END
$fn$;

-- curated/{tenant}/{YYYY-MM}_{account}_{Bank}[_msi][_vN].{csv|pdf}
CREATE OR REPLACE FUNCTION public.curated_standard_key(
    p_tenant_id UUID,
    p_bank_name TEXT,
    p_account_number TEXT,
    p_period_end DATE,
    p_slot TEXT,
    p_version INTEGER DEFAULT 1
) RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
BEGIN
    IF p_tenant_id IS NULL THEN
        RAISE EXCEPTION 'a tenant is required for a vault name' USING ERRCODE = '22023';
    END IF;
    IF p_version IS NULL OR p_version < 1 THEN
        RAISE EXCEPTION 'vault version must be 1 or more' USING ERRCODE = '22023';
    END IF;
    RETURN FORMAT(
        'curated/%s/%s%s.%s',
        p_tenant_id,
        public.curated_vault_base(p_bank_name, p_account_number, p_period_end, p_slot),
        CASE WHEN p_version > 1 THEN '_v' || p_version ELSE '' END,
        CASE WHEN p_slot = 'pdf' THEN 'pdf' ELSE 'csv' END
    );
END
$fn$;

-- Append-only registry of vault names. No foreign key to statement_uploads_f on
-- purpose: the row (and the name) outlives a deleted upload, because the object does.
CREATE TABLE IF NOT EXISTS public.curated_vault_keys_d (
    vault_key TEXT NOT NULL,
    tenant_id UUID NOT NULL,
    upload_id UUID NOT NULL,
    base_name TEXT NOT NULL,
    extension TEXT NOT NULL,
    version INTEGER NOT NULL,
    reserved_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    CONSTRAINT curated_vault_keys_d_pkey PRIMARY KEY (vault_key),
    CONSTRAINT curated_vault_keys_d_upload_key UNIQUE (upload_id),
    CONSTRAINT curated_vault_keys_d_version_key UNIQUE (tenant_id, base_name, extension, version),
    CONSTRAINT curated_vault_keys_d_version_check CHECK (version >= 1),
    CONSTRAINT curated_vault_keys_d_extension_check CHECK (extension IN ('csv', 'pdf'))
);
ALTER TABLE public.curated_vault_keys_d ENABLE ROW LEVEL SECURITY;
COMMENT ON TABLE public.curated_vault_keys_d IS
'Every vault object name handed out (append-only; kept after the upload is deleted).';

-- Naming inputs of one stored upload (internal helper: no session check).
CREATE OR REPLACE FUNCTION public.upload_vault_parts(p_upload_id UUID)
RETURNS TABLE (
    tenant_id UUID,
    base_name TEXT,
    extension TEXT,
    legacy_key TEXT,
    reserved_key TEXT
)
LANGUAGE sql
STABLE
AS $fn$
    SELECT
        upload.tenant_id,
        public.curated_vault_base(
            bank.bank_name,
            account.account_number,
            cutoff.period_end,
            public.upload_slot(upload.dataset)
        ),
        CASE WHEN upload.dataset = 'pdf' THEN 'pdf' ELSE 'csv' END,
        FORMAT(
            'curated/%s/%s.%s',
            upload.tenant_id,
            upload.upload_id,
            CASE WHEN upload.dataset = 'pdf' THEN 'pdf' ELSE 'csv' END
        ),
        registry.vault_key
    FROM public.statement_uploads_f AS upload
    INNER JOIN public.bank_accounts_d AS account ON account.account_id = upload.account_id
    INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
    INNER JOIN public.cutoff_date_f AS cutoff ON cutoff.cutoff_id = upload.cutoff_id
    LEFT JOIN public.curated_vault_keys_d AS registry ON registry.upload_id = upload.upload_id
    WHERE upload.upload_id = p_upload_id
$fn$;

-- Hands out the next free name for an upload (idempotent: an upload keeps its name).
CREATE OR REPLACE FUNCTION public.reserve_vault_key(p_upload_id UUID)
RETURNS TEXT
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_parts RECORD;
    v_version INTEGER;
    v_key TEXT;
BEGIN
    SELECT * INTO v_parts FROM public.upload_vault_parts(p_upload_id);
    IF v_parts.tenant_id IS NULL THEN
        RAISE EXCEPTION 'file not found' USING ERRCODE = 'P0002';
    END IF;
    IF v_parts.reserved_key IS NOT NULL THEN
        RETURN v_parts.reserved_key;
    END IF;
    PERFORM PG_ADVISORY_XACT_LOCK(
        HASHTEXT(v_parts.tenant_id::TEXT || '/' || v_parts.base_name || '.' || v_parts.extension)
    );
    SELECT COALESCE(MAX(registry.version), 0) + 1
    INTO v_version
    FROM public.curated_vault_keys_d AS registry
    WHERE
        registry.tenant_id = v_parts.tenant_id
        AND registry.base_name = v_parts.base_name
        AND registry.extension = v_parts.extension;
    v_key := FORMAT(
        'curated/%s/%s%s.%s',
        v_parts.tenant_id,
        v_parts.base_name,
        CASE WHEN v_version > 1 THEN '_v' || v_version ELSE '' END,
        v_parts.extension
    );
    INSERT INTO public.curated_vault_keys_d (vault_key, tenant_id, upload_id, base_name, extension, version)
    VALUES (v_key, v_parts.tenant_id, p_upload_id, v_parts.base_name, v_parts.extension, v_version);
    RETURN v_key;
END
$fn$;

-- S3 user metadata must be ASCII: UTF-8 bytes outside [A-Za-z0-9._~-] become %XX
-- (same as Python urllib.parse.quote(value, safe="-_.~")). Long names are cut to 120
-- characters here (the full name is in the manifest) to stay under the 2 KB limit.
CREATE OR REPLACE FUNCTION public.curated_meta_value(p_value TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
DECLARE
    v_bytes BYTEA := CONVERT_TO(LEFT(COALESCE(p_value, ''), 120), 'UTF8');
    v_out TEXT := '';
    v_byte INTEGER;
    v_index INTEGER;
BEGIN
    FOR v_index IN 0..OCTET_LENGTH(v_bytes) - 1 LOOP
        v_byte := GET_BYTE(v_bytes, v_index);
        IF (v_byte BETWEEN 48 AND 57) OR (v_byte BETWEEN 65 AND 90) OR (v_byte BETWEEN 97 AND 122)
            OR v_byte IN (45, 46, 95, 126)
        THEN
            v_out := v_out || CHR(v_byte);
        ELSE
            v_out := v_out || '%' || UPPER(LPAD(TO_HEX(v_byte), 2, '0'));
        END IF;
    END LOOP;
    RETURN v_out;
END
$fn$;

-- curated/{tenant}/manifest/{object file name}.json
CREATE OR REPLACE FUNCTION public.vault_manifest_key(p_vault_key TEXT, p_suffix TEXT DEFAULT 'json')
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT
        SUBSTRING(p_vault_key FROM '^(curated/[^/]+/)')
        || 'manifest/'
        || SUBSTRING(p_vault_key FROM '([^/]+)$')
        || '.'
        || p_suffix
$fn$;

-- Everything needed to rebuild the upload's account, period and upload rows.
CREATE OR REPLACE FUNCTION public.vault_manifest(p_upload_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $fn$
    SELECT JSONB_BUILD_OBJECT(
        'schema', 'bankstream-vault-manifest/1',
        'vault_key', parts.reserved_key,
        'legacy_key', CASE
            WHEN upload.curated_s3_key IS DISTINCT FROM parts.reserved_key THEN upload.curated_s3_key
            ELSE upload.curated_legacy_s3_key
        END,
        'tenant_id', upload.tenant_id,
        'upload_id', upload.upload_id,
        'uploaded_at', upload.created_at,
        'chosen_filename', upload.chosen_filename,
        'stored_filename', upload.original_filename,
        'dataset', upload.dataset,
        'slot', public.upload_slot(upload.dataset),
        'ledger_state', upload.ledger_state,
        'content_sha256', upload.content_sha256,
        'byte_size', upload.byte_size,
        'row_count', upload.row_count,
        'source_profile', upload.source_profile,
        'bank_name', bank.bank_name,
        'account', JSONB_BUILD_OBJECT(
            'account_number', account.account_number,
            'account_name', account.account_name,
            'account_type', kind.type_name,
            'ledger_kind', kind.ledger_kind,
            'allows_cutoff', kind.allows_cutoff,
            'cutoff_day', account.account_cutoff_day,
            'credit_days', account.credit_days
        ),
        'period', JSONB_BUILD_OBJECT(
            'period', TO_CHAR(cutoff.period_end, 'YYYY-MM'),
            'period_start', cutoff.period_start,
            'period_end', cutoff.period_end,
            'cutoff_date', cutoff.cutoff_date
        )
    )
    FROM public.statement_uploads_f AS upload
    CROSS JOIN LATERAL public.upload_vault_parts(upload.upload_id) AS parts
    INNER JOIN public.bank_accounts_d AS account ON account.account_id = upload.account_id
    INNER JOIN public.account_types_d AS kind ON kind.a_type_id = account.a_type_id
    INNER JOIN public.banks_d AS bank ON bank.bank_id = account.bank_id
    INNER JOIN public.cutoff_date_f AS cutoff ON cutoff.cutoff_id = upload.cutoff_id
    WHERE upload.upload_id = p_upload_id
$fn$;

-- S3 user metadata (x-amz-meta-*) for the vault object; values are ASCII.
CREATE OR REPLACE FUNCTION public.vault_metadata(p_upload_id UUID)
RETURNS JSONB
LANGUAGE sql
STABLE
AS $fn$
    SELECT JSONB_BUILD_OBJECT(
        'original-filename', public.curated_meta_value(manifest ->> 'chosen_filename'),
        'value-encoding', 'percent-utf8',
        'bank', public.curated_meta_value(manifest ->> 'bank_name'),
        'account', public.curated_meta_value(manifest #>> '{account,account_number}'),
        'period', manifest #>> '{period,period}',
        'period-start', manifest #>> '{period,period_start}',
        'period-end', manifest #>> '{period,period_end}',
        'dataset', manifest ->> 'dataset',
        'upload-id', manifest ->> 'upload_id',
        'content-sha256', manifest ->> 'content_sha256'
    )
    FROM (SELECT public.vault_manifest(p_upload_id) AS manifest) AS built
$fn$;

-- =============================================================================
-- 3. Ingest wrappers that keep the chosen name and hand out the vault name
-- =============================================================================
CREATE OR REPLACE FUNCTION public.clean_chosen_filename(p_name TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $fn$
    SELECT NULLIF(LEFT(BTRIM(REGEXP_REPLACE(COALESCE(p_name, ''), '[[:cntrl:]]', '', 'g')), 255), '')
$fn$;

CREATE OR REPLACE FUNCTION public.remember_chosen_filename(
    p_result JSONB,
    p_chosen_filename TEXT
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_upload_id UUID := (p_result ->> 'upload_id')::UUID;
    v_chosen TEXT;
    v_stored TEXT;
    v_key TEXT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;

    UPDATE public.statement_uploads_f
    SET
        chosen_filename = public.clean_chosen_filename(p_chosen_filename),
        chosen_filename_source = CASE
            WHEN public.clean_chosen_filename(p_chosen_filename) IS NULL THEN NULL
            ELSE 'chosen'
        END
    WHERE
        upload_id = v_upload_id
        AND tenant_id = v_tenant
        AND user_id = v_user
    RETURNING chosen_filename, original_filename
    INTO v_chosen, v_stored;
    IF v_chosen IS NULL THEN
        RAISE EXCEPTION 'file not found' USING ERRCODE = 'P0002';
    END IF;

    -- Only plans with the curated vault get a vault name (and use up a version).
    IF COALESCE((p_result ->> 'curated_csv_backup')::BOOLEAN, FALSE) THEN
        v_key := public.reserve_vault_key(v_upload_id);
        RETURN p_result || JSONB_BUILD_OBJECT(
            'chosen_filename', v_chosen,
            'stored_filename', v_stored,
            'vault_key', v_key,
            'vault_metadata', public.vault_metadata(v_upload_id),
            'vault_manifest_key', public.vault_manifest_key(v_key),
            'vault_manifest', public.vault_manifest(v_upload_id)
        );
    END IF;
    RETURN p_result || JSONB_BUILD_OBJECT(
        'chosen_filename', v_chosen,
        'stored_filename', v_stored,
        'vault_key', NULL
    );
END
$fn$;

-- p_filename is the working name ingest stores in original_filename (the browser may
-- still send its Bank_Account_YYYY-MM.csv form); p_chosen_filename is file.name as
-- picked. When p_filename is empty the chosen name is used for both.
CREATE OR REPLACE FUNCTION public.ingest_statement_upload(
    p_account_id INTEGER,
    p_cutoff_id INTEGER,
    p_slot TEXT,
    p_filename TEXT,
    p_chosen_filename TEXT,
    p_csv TEXT,
    p_as_of DATE,
    p_encoding TEXT DEFAULT NULL,
    p_delimiter TEXT DEFAULT NULL
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
    RETURN public.remember_chosen_filename(
        public.ingest_statement_csv(
            p_account_id,
            p_cutoff_id,
            p_slot,
            COALESCE(NULLIF(BTRIM(COALESCE(p_filename, '')), ''), public.clean_chosen_filename(p_chosen_filename)),
            p_csv,
            p_as_of,
            p_encoding,
            p_delimiter
        ),
        COALESCE(public.clean_chosen_filename(p_chosen_filename), p_filename)
    );
END
$fn$;

CREATE OR REPLACE FUNCTION public.ingest_period_pdf_upload(
    p_account_id INTEGER,
    p_cutoff_id INTEGER,
    p_filename TEXT,
    p_chosen_filename TEXT,
    p_base64 TEXT,
    p_as_of DATE
) RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
    RETURN public.remember_chosen_filename(
        public.ingest_period_pdf(
            p_account_id,
            p_cutoff_id,
            COALESCE(NULLIF(BTRIM(COALESCE(p_filename, '')), ''), public.clean_chosen_filename(p_chosen_filename)),
            p_base64,
            p_as_of
        ),
        COALESCE(public.clean_chosen_filename(p_chosen_filename), p_filename)
    );
END
$fn$;

-- =============================================================================
-- 4. Vault key check on attach, and the delete marker
-- =============================================================================
CREATE OR REPLACE FUNCTION public.attach_curated_backup(p_upload_id UUID, p_key TEXT)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_parts RECORD;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    IF p_key IS NULL OR p_key NOT LIKE 'curated/%' THEN
        RAISE EXCEPTION 'curated key must stay under the curated prefix' USING ERRCODE = '22023';
    END IF;
    IF NOT EXISTS (
        SELECT 1
        FROM public.statement_uploads_f AS upload
        WHERE
            upload.upload_id = p_upload_id
            AND upload.tenant_id = v_tenant
            AND upload.user_id = v_user
    ) THEN
        RAISE EXCEPTION 'file not found' USING ERRCODE = 'P0002';
    END IF;
    SELECT * INTO v_parts FROM public.upload_vault_parts(p_upload_id);
    -- The legacy key stays accepted so a Lambda deployed before 013 keeps working.
    IF p_key IS DISTINCT FROM v_parts.reserved_key AND p_key IS DISTINCT FROM v_parts.legacy_key THEN
        RAISE EXCEPTION 'curated key does not match the vault name of this file' USING ERRCODE = '22023';
    END IF;
    UPDATE public.statement_uploads_f
    SET
        curated_s3_key = p_key,
        storage_mode = 'curated'
    WHERE
        upload_id = p_upload_id
        AND tenant_id = v_tenant
        AND user_id = v_user;
END
$fn$;

-- Called by the API before delete_statement_upload: the marker object
-- curated/{tenant}/manifest/{object file name}.deleted.json tells a rebuild that the
-- file was removed in the app (the vault object itself stays). NULL when the upload
-- has no vault object.
CREATE OR REPLACE FUNCTION public.vault_delete_marker(p_upload_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
    v_tenant UUID;
    v_user UUID;
    v_key TEXT;
BEGIN
    SELECT session_row.tenant_id, session_row.user_id
    INTO v_tenant, v_user
    FROM public.require_session() AS session_row;
    SELECT upload.curated_s3_key
    INTO v_key
    FROM public.statement_uploads_f AS upload
    WHERE
        upload.upload_id = p_upload_id
        AND upload.tenant_id = v_tenant
        AND upload.user_id = v_user;
    IF v_key IS NULL THEN
        RETURN NULL;
    END IF;
    RETURN JSONB_BUILD_OBJECT(
        'key', public.vault_manifest_key(v_key, 'deleted.json'),
        'body', JSONB_BUILD_OBJECT(
            'schema', 'bankstream-vault-delete/1',
            'vault_key', v_key,
            'upload_id', p_upload_id,
            'tenant_id', v_tenant,
            'deleted_at', NOW()
        )
    );
END
$fn$;

-- =============================================================================
-- 5. Existing vault objects: dry-run plan and bookkeeping (owner only, no S3 here)
-- =============================================================================
-- backup_key keeps the old object name under curated/backup-{batch}/ so it stays inside
-- the delete-denied curated/* prefix and never collides with a tenant folder.
CREATE OR REPLACE FUNCTION public.curated_backup_key(p_current_key TEXT, p_batch TEXT)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $fn$
BEGIN
    IF p_batch IS NULL OR p_batch !~ '^[A-Za-z0-9_-]{1,40}$' THEN
        RAISE EXCEPTION 'batch must be 1-40 letters, digits, _ or -' USING ERRCODE = '22023';
    END IF;
    IF p_current_key IS NULL OR p_current_key NOT LIKE 'curated/%' THEN
        RAISE EXCEPTION 'current key must be under curated/' USING ERRCODE = '22023';
    END IF;
    RETURN 'curated/backup-' || p_batch || '/' || SUBSTRING(p_current_key FROM 9);
END
$fn$;

-- new_key is the reserved name, or the name the upload would get (versions follow
-- upload time within the same {period}_{account}_{bank} name). Nothing is reserved here.
CREATE OR REPLACE FUNCTION public.curated_key_migration_plan(p_batch TEXT)
RETURNS TABLE (
    upload_id UUID,
    tenant_id UUID,
    dataset TEXT,
    chosen_filename TEXT,
    current_key TEXT,
    backup_key TEXT,
    new_key TEXT,
    manifest_key TEXT,
    action TEXT
)
LANGUAGE sql
STABLE
AS $fn$
    WITH vaulted AS (
        SELECT upload.*, parts.base_name, parts.extension, parts.reserved_key
        FROM public.statement_uploads_f AS upload
        CROSS JOIN LATERAL public.upload_vault_parts(upload.upload_id) AS parts
        WHERE upload.curated_s3_key IS NOT NULL
    ),
    planned AS (
        SELECT
            vaulted.*,
            COALESCE(
                vaulted.reserved_key,
                FORMAT(
                    'curated/%s/%s%s.%s',
                    vaulted.tenant_id,
                    vaulted.base_name,
                    CASE
                        WHEN next_version.version > 1 THEN '_v' || next_version.version
                        ELSE ''
                    END,
                    vaulted.extension
                )
            ) AS planned_key
        FROM vaulted
        CROSS JOIN LATERAL (
            SELECT
                COALESCE((
                    SELECT MAX(registry.version)
                    FROM public.curated_vault_keys_d AS registry
                    WHERE
                        registry.tenant_id = vaulted.tenant_id
                        AND registry.base_name = vaulted.base_name
                        AND registry.extension = vaulted.extension
                ), 0)
                + (
                    SELECT COUNT(*)
                    FROM vaulted AS earlier
                    WHERE
                        earlier.reserved_key IS NULL
                        AND earlier.tenant_id = vaulted.tenant_id
                        AND earlier.base_name = vaulted.base_name
                        AND earlier.extension = vaulted.extension
                        AND (earlier.created_at, earlier.upload_id) <= (vaulted.created_at, vaulted.upload_id)
                ) AS version
        ) AS next_version
    )
    SELECT
        planned.upload_id,
        planned.tenant_id,
        planned.dataset,
        planned.chosen_filename,
        planned.curated_s3_key,
        CASE
            WHEN planned.curated_s3_key = planned.planned_key THEN NULL
            ELSE public.curated_backup_key(planned.curated_s3_key, p_batch)
        END,
        planned.planned_key,
        public.vault_manifest_key(planned.planned_key),
        CASE
            WHEN planned.curated_s3_key = planned.planned_key THEN 'already_standard'
            ELSE 'copy'
        END
    FROM planned
    ORDER BY planned.tenant_id, planned.created_at, planned.upload_id
$fn$;

-- Called by the migration script only after both copies and the manifest exist.
CREATE OR REPLACE FUNCTION public.apply_curated_key_migration(
    p_upload_id UUID,
    p_expected_key TEXT,
    p_backup_key TEXT,
    p_new_key TEXT
) RETURNS BOOLEAN
LANGUAGE plpgsql
AS $fn$
DECLARE
    v_reserved TEXT;
BEGIN
    SELECT parts.reserved_key
    INTO v_reserved
    FROM public.upload_vault_parts(p_upload_id) AS parts;
    IF v_reserved IS NULL OR p_new_key IS DISTINCT FROM v_reserved THEN
        RAISE EXCEPTION 'new key does not match the vault name of this file' USING ERRCODE = '22023';
    END IF;
    IF p_backup_key IS DISTINCT FROM public.curated_backup_key(
        p_expected_key,
        SPLIT_PART(SUBSTRING(p_backup_key FROM 16), '/', 1)
    ) THEN
        RAISE EXCEPTION 'backup key does not match the current key' USING ERRCODE = '22023';
    END IF;
    UPDATE public.statement_uploads_f
    SET
        curated_legacy_s3_key = curated_s3_key,
        curated_backup_s3_key = p_backup_key,
        curated_s3_key = p_new_key
    WHERE
        upload_id = p_upload_id
        AND curated_s3_key = p_expected_key;
    RETURN FOUND;
END
$fn$;

-- =============================================================================
-- 6. Home: *_filename is the chosen name; *_stored_filename and *_vault_key added
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
                    'statement_filename', statement_file.chosen_filename,
                    'statement_stored_filename', statement_file.original_filename,
                    'statement_vault_key', statement_file.curated_s3_key,
                    'statement_row_count', statement_file.row_count,
                    'statement_source_profile', statement_file.source_profile,
                    'statement_ledger_state', statement_file.ledger_state,
                    'installment_upload_id', installment_file.upload_id,
                    'installment_filename', installment_file.chosen_filename,
                    'installment_stored_filename', installment_file.original_filename,
                    'installment_vault_key', installment_file.curated_s3_key,
                    'installment_row_count', installment_file.row_count,
                    'installment_source_profile', installment_file.source_profile,
                    'installment_ledger_state', installment_file.ledger_state,
                    'pdf_upload_id', pdf_file.upload_id,
                    'pdf_filename', pdf_file.chosen_filename,
                    'pdf_stored_filename', pdf_file.original_filename,
                    'pdf_vault_key', pdf_file.curated_s3_key,
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
-- 7. Grants
-- =============================================================================
-- The 013 draft before Nov 12 had curated_standard_key(..., UUID) and
-- upload_curated_keys(UUID); drop them if a test database still has them.
DROP FUNCTION IF EXISTS public.curated_standard_key(UUID, TEXT, TEXT, DATE, TEXT, UUID);
DROP FUNCTION IF EXISTS public.upload_curated_keys(UUID);

REVOKE ALL ON FUNCTION public.remember_chosen_filename(JSONB, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ingest_statement_upload(INTEGER, INTEGER, TEXT, TEXT, TEXT, TEXT, DATE, TEXT, TEXT)
FROM PUBLIC;
REVOKE ALL ON FUNCTION public.ingest_period_pdf_upload(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.attach_curated_backup(UUID, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vault_delete_marker(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.reserve_vault_key(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upload_vault_parts(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vault_manifest(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.vault_metadata(UUID) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.curated_key_migration_plan(TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.apply_curated_key_migration(UUID, TEXT, TEXT, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.statement_home(DATE) FROM PUBLIC;
REVOKE ALL ON public.curated_vault_keys_d FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.ingest_statement_upload(INTEGER, INTEGER, TEXT, TEXT, TEXT, TEXT, DATE, TEXT, TEXT)
TO strm_app;
GRANT EXECUTE ON FUNCTION public.ingest_period_pdf_upload(INTEGER, INTEGER, TEXT, TEXT, TEXT, DATE) TO strm_app;
GRANT EXECUTE ON FUNCTION public.attach_curated_backup(UUID, TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.vault_delete_marker(UUID) TO strm_app;
GRANT EXECUTE ON FUNCTION public.curated_standard_key(UUID, TEXT, TEXT, DATE, TEXT, INTEGER) TO strm_app;
GRANT EXECUTE ON FUNCTION public.curated_name_part(TEXT) TO strm_app;
GRANT EXECUTE ON FUNCTION public.statement_home(DATE) TO strm_app;
-- reserve_vault_key, vault_manifest, vault_metadata, the registry table, the migration
-- plan and apply_curated_key_migration are reached through the functions above or by
-- the database owner (migration script); strm_app gets no direct grant.
