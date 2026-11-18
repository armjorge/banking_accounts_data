-- sql/024: every master fact table has the same columns. The asset masters drop
-- source_line (the CSV line of an uploaded row) and reported_balance (a copy of the typed
-- balance on an adjustment row; the balance itself stays in aaccandass_checks_f).

DO $patch$
DECLARE
    v_edit RECORD;
    v_def TEXT;
    v_next TEXT;
BEGIN
    FOR v_edit IN
        SELECT * FROM (VALUES
            ('public.ingest_aaccandass_upload(integer, text, text, text, jsonb, text, text)',
             'entry_source, created_by, source_line', 'entry_source, created_by'),
            ('public.ingest_aaccandass_upload(integer, text, text, text, jsonb, text, text)',
             '''upload'', v_user, tmp.line_no', '''upload'', v_user'),
            ('public.aaccandass_store_row(uuid, uuid, integer, date, text, numeric, numeric, text, text, numeric)',
             'entry_source, note, created_by, reported_balance', 'entry_source, note, created_by'),
            ('public.aaccandass_store_row(uuid, uuid, integer, date, text, numeric, numeric, text, text, numeric)',
             E'p_user,\n        ROUND(p_reported, 2)', 'p_user'),
            ('public.aaccandass_rows(integer, date, date, text, integer, integer)',
             E'            movement.source_line,\n            movement.reported_balance,\n', '')
        ) AS edit (fn, old_text, new_text)
    LOOP
        v_def := PG_GET_FUNCTIONDEF(v_edit.fn::REGPROCEDURE);
        CONTINUE WHEN POSITION(v_edit.old_text IN v_def) = 0
            AND POSITION('source_line' IN v_def) = 0
            AND POSITION('reported_balance' IN v_def) = 0;
        v_next := REPLACE(v_def, v_edit.old_text, v_edit.new_text);
        IF v_next = v_def THEN
            RAISE EXCEPTION 'sql/024: % has an unexpected body', v_edit.fn;
        END IF;
        EXECUTE v_next;
    END LOOP;
END
$patch$;

ALTER TABLE public.master_closed_aaccandass_f DROP COLUMN IF EXISTS source_line;
ALTER TABLE public.master_closed_aaccandass_f DROP COLUMN IF EXISTS reported_balance;
ALTER TABLE public.master_open_aaccandass_f DROP COLUMN IF EXISTS source_line;
ALTER TABLE public.master_open_aaccandass_f DROP COLUMN IF EXISTS reported_balance;
