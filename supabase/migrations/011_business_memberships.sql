-- ============================================
-- DIJO Migration 011
-- Business Memberships & Roles
-- ============================================

do $$
begin
    if not exists (
        select 1
        from pg_type
        where typname = 'business_member_role'
    ) then
        create type business_member_role as enum (
            'owner',
            'manager',
            'staff'
        );
    end if;
end
$$;


create table if not exists public.business_members (
    id uuid primary key default gen_random_uuid(),

    business_id uuid not null
        references public.businesses(id)
        on delete cascade,

    profile_id uuid not null
        references public.profiles(id)
        on delete cascade,

    role business_member_role not null default 'staff',

    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    unique (business_id, profile_id)
);


alter table public.business_members
enable row level security;


create index if not exists business_members_business_id_idx
on public.business_members (business_id);


create index if not exists business_members_profile_id_idx
on public.business_members (profile_id);


drop trigger if exists business_members_set_updated_at
on public.business_members;

create trigger business_members_set_updated_at
before update on public.business_members
for each row
execute function public.set_updated_at();


-- ============================================
-- Initial RLS
-- ============================================

create policy "Members can view own business memberships"
on public.business_members
for select
to authenticated
using (
    profile_id = (select auth.uid())
);
