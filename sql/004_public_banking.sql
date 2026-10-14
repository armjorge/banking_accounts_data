-- Database: neondb. Objects live in public.<table>.
-- cognito_users.users already exists (user_id UUID) and is not changed.
--
-- Re-running this file drops and recreates only the tables below.
-- Admin dimensions: plans_d, account_types_d, banks_d, bank_templates_f.
-- SaaS: tenants_d belongs to a plan. tenant_users ties a tenant to cognito_users.users.
-- bank_accounts_d and cutoff_date_f are tagged with that user.
-- bank_id, a_type_id, and tenant_id are part of the bank_accounts_d key,
-- so each account belongs to one bank, one account type, and one tenant.

DROP TABLE IF EXISTS public.cutoff_date_f;
DROP TABLE IF EXISTS public.bank_accounts_d;
DROP TABLE IF EXISTS public.bank_templates_f;
DROP TABLE IF EXISTS public.tenant_users;
DROP TABLE IF EXISTS public.tenants_d;
DROP TABLE IF EXISTS public.plans_d;
DROP TABLE IF EXISTS public.banks_d;
DROP TABLE IF EXISTS public.account_types_d;

CREATE TABLE public.plans_d (
    plan_code TEXT NOT NULL,
    display_name TEXT NOT NULL,
    local_storage_only BOOLEAN NOT NULL DEFAULT TRUE,
    snowflake_backup BOOLEAN NOT NULL DEFAULT FALSE,
    monthly_api_quota INTEGER NOT NULL DEFAULT 0,
    CONSTRAINT plans_d_pkey PRIMARY KEY (plan_code)
);

INSERT INTO public.plans_d (
    plan_code,
    display_name,
    local_storage_only,
    snowflake_backup,
    monthly_api_quota
)
VALUES
('entry', 'Entry', TRUE, FALSE, 0),
('plus', 'Plus', FALSE, TRUE, 1000),
('premium', 'Premium', FALSE, TRUE, 10000);

-- type_name is credit or debit. Cutoff dates match on that prefix.
CREATE TABLE public.account_types_d (
    a_type_id INTEGER NOT NULL,
    type_name TEXT NOT NULL,
    CONSTRAINT account_types_d_pkey PRIMARY KEY (a_type_id)
);

CREATE TABLE public.banks_d (
    bank_id INTEGER NOT NULL,
    bank_name TEXT,
    CONSTRAINT banks_d_pkey PRIMARY KEY (bank_id)
);

CREATE TABLE public.tenants_d (
    tenant_id UUID NOT NULL DEFAULT GEN_RANDOM_UUID(),
    tenant_name TEXT NOT NULL,
    plan_code TEXT NOT NULL,
    CONSTRAINT tenants_d_pkey PRIMARY KEY (tenant_id),
    CONSTRAINT tenants_d_plan_code_fkey
    FOREIGN KEY (plan_code) REFERENCES public.plans_d (plan_code)
);

CREATE TABLE public.tenant_users (
    tenant_id UUID NOT NULL,
    user_id UUID NOT NULL,
    CONSTRAINT tenant_users_pkey PRIMARY KEY (tenant_id, user_id),
    CONSTRAINT tenant_users_tenant_id_fkey
    FOREIGN KEY (tenant_id) REFERENCES public.tenants_d (tenant_id),
    CONSTRAINT tenant_users_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES cognito_users.users (user_id)
);

-- headers is a comma-separated list of lower-case column headers.
-- One template per bank and account type.
CREATE TABLE public.bank_templates_f (
    bank_id INTEGER NOT NULL,
    a_type_id INTEGER NOT NULL,
    headers TEXT,
    CONSTRAINT bank_templates_f_pkey PRIMARY KEY (bank_id, a_type_id),
    CONSTRAINT bank_templates_f_bank_id_fkey
    FOREIGN KEY (bank_id) REFERENCES public.banks_d (bank_id),
    CONSTRAINT bank_templates_f_a_type_id_fkey
    FOREIGN KEY (a_type_id) REFERENCES public.account_types_d (a_type_id)
);

CREATE TABLE public.bank_accounts_d (
    account_id INTEGER NOT NULL,
    bank_id INTEGER NOT NULL,
    user_id UUID NOT NULL,
    tenant_id UUID NOT NULL,
    a_type_id INTEGER NOT NULL,
    account_name TEXT NOT NULL,
    account_cutoff_day INTEGER,
    CONSTRAINT bank_accounts_d_pkey
    PRIMARY KEY (account_id, user_id, tenant_id, bank_id, a_type_id),
    CONSTRAINT bank_accounts_d_account_user_key UNIQUE (account_id, user_id),
    CONSTRAINT bank_accounts_d_bank_id_fkey
    FOREIGN KEY (bank_id) REFERENCES public.banks_d (bank_id),
    CONSTRAINT bank_accounts_d_user_id_fkey
    FOREIGN KEY (user_id) REFERENCES cognito_users.users (user_id),
    CONSTRAINT bank_accounts_d_tenant_user_fkey
    FOREIGN KEY (tenant_id, user_id) REFERENCES public.tenant_users (tenant_id, user_id),
    CONSTRAINT bank_accounts_d_a_type_id_fkey
    FOREIGN KEY (a_type_id) REFERENCES public.account_types_d (a_type_id)
);

CREATE UNIQUE INDEX bank_accounts_d_account_id_idx
ON public.bank_accounts_d (account_id);

-- Credit cutoff_date uses bank_accounts_d.account_cutoff_day.
-- Debit cutoff_date is the last day of cutoff_year / cutoff_month.
-- is_required is true from the current month forward.
CREATE TABLE public.cutoff_date_f (
    cutoff_id INTEGER NOT NULL,
    account_id INTEGER NOT NULL,
    user_id UUID NOT NULL,
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
