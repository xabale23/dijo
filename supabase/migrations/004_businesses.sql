-- ============================================
-- DIJO Migration 004
-- Businesses
-- ============================================

create table if not exists public.businesses (

    id uuid primary key default gen_random_uuid(),

    owner_id uuid not null
        references public.profiles(id)
        on delete cascade,

    business_name text not null,

    business_slug text unique,

    business_type business_type not null,

    description text,

    phone_number text,

    whatsapp_number text,

    email text,

    logo_url text,

    cover_image_url text,

    address text,

    city text,

    province text,

    postal_code text,

    latitude double precision,

    longitude double precision,

    delivery_radius_km numeric(5,2) default 5,

    opening_time time,

    closing_time time,

    is_open boolean default false,

    is_verified boolean default false,

    verification_level text default 'bronze',

    accepts_cash boolean default true,

    accepts_card boolean default true,

    accepts_wallet boolean default false,

    average_rating numeric(3,2) default 0,

    total_reviews integer default 0,

    is_active boolean default true,

    created_at timestamptz default now(),

    updated_at timestamptz default now()

);

alter table public.businesses
enable row level security;
