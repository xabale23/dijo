-- ============================================
-- DIJO Migration 008
-- Safe Profile Update Function
-- ============================================

create or replace function public.update_my_profile(
    p_full_name text default null,
    p_phone_number text default null,
    p_whatsapp_number text default null,
    p_avatar_url text default null,
    p_preferred_language text default null
)
returns public.profiles
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_profile public.profiles;
begin

    if auth.uid() is null then
        raise exception 'Authentication required';
    end if;

    update public.profiles
    set
        full_name = case
            when p_full_name is null then full_name
            else nullif(trim(p_full_name), '')
        end,

        phone_number = case
            when p_phone_number is null then phone_number
            else nullif(trim(p_phone_number), '')
        end,

        whatsapp_number = case
            when p_whatsapp_number is null then whatsapp_number
            else nullif(trim(p_whatsapp_number), '')
        end,

        avatar_url = case
            when p_avatar_url is null then avatar_url
            else nullif(trim(p_avatar_url), '')
        end,

        preferred_language = case
            when p_preferred_language is null then preferred_language
            else nullif(trim(p_preferred_language), '')
        end,

        updated_at = now()

    where id = auth.uid()

    returning * into v_profile;

    if v_profile.id is null then
        raise exception 'Profile not found';
    end if;

    return v_profile;

end;
$$;

revoke all
on function public.update_my_profile(
    text,
    text,
    text,
    text,
    text
)
from public;

grant execute
on function public.update_my_profile(
    text,
    text,
    text,
    text,
    text
)
to authenticated;
