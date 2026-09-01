-- ============================================
-- DIJO Migration 004
-- Businesses
-- Pre-launch baseline
-- ============================================

create table if not exists public.businesses (
    id uuid primary key default gen_random_uuid(),

    owner_id uuid
        references public.profiles(id)
        on delete cascade,

    name text not null,

    business_type business_type not null,

    phone text,

    email text,

    description text,

    address text,

    city text,

    province text,

    postal_code text,

    latitude double precision,

    longitude double precision,

    logo_url text,

    cover_image_url text,

    verified boolean default false,

    is_open boolean default true,

    is_active boolean default true,

    created_at timestamptz default now(),

    updated_at timestamptz default now()
);

alter table public.businesses
enable row level security;
