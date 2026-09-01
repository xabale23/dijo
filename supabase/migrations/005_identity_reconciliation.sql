-- ============================================
-- DIJO Migration 005
-- Identity Architecture Reconciliation
-- ============================================

begin;

-- Move business ownership from the legacy
-- public.users table to Supabase-backed profiles.
alter table public.businesses
drop constraint if exists businesses_owner_id_fkey;

alter table public.businesses
add constraint businesses_owner_id_fkey
foreign key (owner_id)
references public.profiles(id)
on delete cascade;


-- Move order customers from the legacy
-- public.users table to Supabase-backed profiles.
alter table public.orders
drop constraint if exists orders_customer_id_fkey;

alter table public.orders
add constraint orders_customer_id_fkey
foreign key (customer_id)
references public.profiles(id);


-- The legacy identity table is no longer required.
drop table if exists public.users;

commit;
