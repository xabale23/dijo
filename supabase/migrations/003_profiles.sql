-- ============================================
-- DIJO Migration 003
-- Profiles
-- ============================================

create table if not exists public.profiles (
    id uuid primary key references auth.users(id) on delete cascade,
    full_name text not null,
    phone_number text unique not null,
    whatsapp_number text unique not null,
    role user_role not null default 'customer',
    avatar_url text,
    preferred_language text default 'en',
    is_verified boolean default false,
    is_active boolean default true,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

alter table public.profiles
enable row level security;
