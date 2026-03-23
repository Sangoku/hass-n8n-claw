-- Required PostgreSQL roles and extensions
-- This file runs before 001_schema.sql (alphabetical order in docker-entrypoint-initdb.d)

-- Supabase postgres image references supabase_admin in extension control files.
-- This role must exist before CREATE EXTENSION works.
DO $$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_admin') THEN
    CREATE ROLE supabase_admin LOGIN SUPERUSER;
  END IF;
END
$$;

-- n8n migrations need uuid_generate_v4() from uuid-ossp
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
