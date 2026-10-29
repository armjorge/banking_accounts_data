-- sqlfluff:exclude_rules: JJ01,LT02,CP02,CP03,CP05,RF04,RF06
-- Applied on database {{NEON_DATABASE}}.
-- Identity: {{NEON_USERS_SCHEMA}}.users  |  App model: {{NEON_DB_SCHEMA}}
CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA public;
