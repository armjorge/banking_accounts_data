-- Database: neondb
-- Schema: public
-- PostgreSQL qualifies these as public.<table> on a session connected to neondb:
--   neondb.public.account_types_d
--   neondb.public.banks_d
--   neondb.public.bank_templates_f
--   neondb.public.bank_accounts_d
--   neondb.public.cutoff_date_f
-- neondb.public.users_d already exists (user_id) and is not created here.
--
-- Admin-owned dimensions: account_types_d, banks_d, bank_templates_f.
-- user_id tags bank_accounts_d and cutoff_date_f for one user.
-- Identifiers are supplied by the loader. These columns are not identity columns.
--
-- Luna linked users_d.user_id to bank_accounts_d.account_id.
-- user_id is the user tag, so the foreign key is user_id -> users_d.user_id.

CREATE TABLE IF NOT EXISTS public.account_types_d (
    a_type_id INTEGER NOT NULL,
    type_name TEXT NOT NULL,
    CONSTRAINT account_types_d_pkey PRIMARY KEY (a_type_id)
);

CREATE TABLE IF NOT EXISTS public.banks_d (
    bank_id INTEGER NOT NULL,
    bank_name TEXT,
    CONSTRAINT banks_d_pkey PRIMARY KEY (bank_id)
);

-- headers is a comma-separated list of lower-case column headers.
-- One template per bank and account type (Luna left this primary key with no columns).
CREATE TABLE IF NOT EXISTS public.bank_templates_f (
    bank_id INTEGER NOT NULL,
    a_type_id INTEGER NOT NULL,
    headers TEXT,
    CONSTRAINT bank_templates_f_pkey PRIMARY KEY (bank_id, a_type_id),
    CONSTRAINT bank_templates_f_bank_id_fkey
    FOREIGN KEY (bank_id) REFERENCES public.banks_d (bank_id),
    CONSTRAINT bank_templates_f_a_type_id_fkey
    FOREIGN KEY (a_type_id) REFERENCES public.account_types_d (a_type_id)
);

CREATE TABLE IF NOT EXISTS public.bank_accounts_d (
    account_id INTEGER NOT NULL,
    bank_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    a_type_id INTEGER NOT NULL,
    account_name TEXT NOT NULL,
    account_cutoff_day INTEGER,
    CONSTRAINT bank_accounts_d_pkey PRIMARY KEY (account_id, user_id),
    CONSTRAINT bank_accounts_d_bank_id_fkey
    FOREIGN KEY (bank_id) REFERENCES public.banks_d (bank_id),
    CONSTRAINT bank_accounts_d_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES public.users_d (user_id),
    CONSTRAINT bank_accounts_d_a_type_id_fkey
    FOREIGN KEY (a_type_id) REFERENCES public.account_types_d (a_type_id)
);

CREATE UNIQUE INDEX IF NOT EXISTS bank_accounts_d_account_id_idx
ON public.bank_accounts_d (account_id);

-- Credit cutoff_date uses bank_accounts_d.account_cutoff_day.
-- Debit cutoff_date is the last day of cutoff_year / cutoff_month.
-- is_required is true from the current month forward.
CREATE TABLE IF NOT EXISTS public.cutoff_date_f (
    cutoff_id INTEGER NOT NULL,
    account_id INTEGER NOT NULL,
    user_id INTEGER NOT NULL,
    cutoff_month INTEGER NOT NULL,
    cutoff_year INTEGER NOT NULL,
    is_required BOOLEAN,
    cutoff_date DATE,
    CONSTRAINT cutoff_date_f_pkey
    PRIMARY KEY (cutoff_id, account_id, user_id, cutoff_month, cutoff_year),
    CONSTRAINT cutoff_date_f_account_id_user_id_fkey
    FOREIGN KEY (account_id, user_id)
    REFERENCES public.bank_accounts_d (account_id, user_id)
);
