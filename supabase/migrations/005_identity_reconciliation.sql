-- ============================================
-- DIJO Migration 005
-- Legacy Identity Reconciliation Record
-- ============================================

-- Historical note:
--
-- During pre-launch development, DIJO originally used
-- public.users as its application identity table.
--
-- The live development database was reconciled so that:
--
--   businesses.owner_id -> public.profiles(id)
--   orders.customer_id  -> public.profiles(id)
--
-- The legacy public.users table was then removed.
--
-- The corrected pre-launch baseline migrations now create
-- these relationships directly against public.profiles.
--
-- Therefore no database operation is required here.

select 1;
