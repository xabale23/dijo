-- ============================================
-- DIJO Migration 007
-- Safe Authentication / Profile Onboarding
-- ============================================

-- Authentication and profile completion are separate
-- lifecycle stages. A profile may initially be incomplete.

alter table public.profiles
    alter column full_name drop not null,
    alter column phone_number drop not null,
    alter column whatsapp_number drop not null;


-- ============================================
-- AUTH USER -> DIJO PROFILE
-- ============================================

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin

    insert into public.profiles (
        id,
        full_name,
        phone_number,
        whatsapp_number,
        role,
        is_verified,
        is_active
    )
    values (
        new.id,

        nullif(
            trim(coalesce(new.raw_user_meta_data ->> 'full_name', '')),
            ''
        ),

        nullif(
            trim(coalesce(new.phone, '')),
            ''
        ),

        nullif(
            trim(coalesce(new.phone, '')),
            ''
        ),

        'customer'::public.user_role,
        false,
        true
    )
    on conflict (id) do nothing;

    return new;

end;
$$;


-- ============================================
-- AUTH SIGNUP TRIGGER
-- ============================================

drop trigger if exists on_auth_user_created
on auth.users;

create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();
