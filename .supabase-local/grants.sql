-- Restore the grants Supabase normally applies to its API roles.
-- Applying the migrations as `postgres` via docker exec creates tables owned by
-- postgres WITHOUT the privileges PostgREST's roles need, so every Atlas server
-- read failed with 42501 "permission denied". RLS still governs anon/authenticated;
-- service_role bypasses RLS by design, which is what Atlas's server client uses.
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL TABLES     IN SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL SEQUENCES  IN SCHEMA public TO anon, authenticated, service_role;
GRANT ALL ON ALL FUNCTIONS  IN SCHEMA public TO anon, authenticated, service_role;
-- And for anything created later.
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES    TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO anon, authenticated, service_role;
