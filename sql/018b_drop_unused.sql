-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- sql/018b: drop tables nothing uses any more. Run by hand, after sql/018, once the list
-- below is confirmed. Not part of apply_banking_ddl and never needed by the app.
--
-- Live row counts (Neon, read-only count, 2026-11-13) and why each one is unused:
--   open_debit_f           0 rows  sql/004 open-period table, replaced by master_debit_open_f
--                                  (sql/011). No function, view, Lambda, API or web code reads it.
--   open_credit_f          0 rows  Same, replaced by master_credit_open_f (sql/011).
--   credit_plan_closed_f   3 rows  Installment plan copy from sql/006; since sql/011 plans are
--                                  expanded into master_credit_future_f. Nothing reads it;
--                                  delete_statement_upload only clears it. NOTE: the 3 rows
--                                  come from one old installment upload that was never
--                                  expanded (0 future rows carry its file_id), so dropping
--                                  loses that plan's rate / monthly payment. Left commented:
--                                  re-upload that MSI file first if you still need it.
--   movement_dimensions_d  504 rows  Row registry from sql/006. Attributes live in debit_d /
--                                  credit_d since sql/015; sql/018 stopped writing it.
--                                  Only apply_row_hash_remap touches it (guarded with TO_REGCLASS).
--   bank_templates_f       1 row   Old admin header text (bank + account type). Column maps
--                                  live in aaccandass_templates_d (sql/017) and the upload
--                                  wizard (sql/018). The /admin Lambda that wrote this table
--                                  is gone.
-- No foreign key points at any of these tables (checked on live).
DO $do$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'master_debit_closed_f' AND column_name = 'cutoff_id'
    ) THEN
        RAISE EXCEPTION 'apply sql/018_standard_masters_balances_banks.sql first';
    END IF;
END
$do$;

DROP TABLE IF EXISTS public.open_debit_f;
DROP TABLE IF EXISTS public.open_credit_f;
-- DROP TABLE IF EXISTS public.credit_plan_closed_f;
DROP TABLE IF EXISTS public.movement_dimensions_d;
DROP TABLE IF EXISTS public.bank_templates_f;
