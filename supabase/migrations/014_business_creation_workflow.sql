-- ============================================================
-- DIJO Migration 014
-- Safe business creation workflow
-- ============================================================

create or replace function public.create_business(
    p_name text,
    p_business_type public.business_type,
    p_phone text default null,
    p_email text default null,
    p_description text default null,
    p_address text default null,
    p_city text default null,
    p_province text default null,
    p_postal_code text default null,
    p_latitude double precision default null,
    p_longitude double precision default null,
    p_logo_url text default null,
    p_cover_image_url text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid;
    v_business_id uuid;
begin
    -- --------------------------------------------------------
    -- 1. Require an authenticated Supabase user
    -- --------------------------------------------------------

    v_user_id := auth.uid();

    if v_user_id is null then
        raise exception 'Authentication required';
    end if;


    -- --------------------------------------------------------
    -- 2. Require an active DIJO profile
    -- --------------------------------------------------------

    if not exists (
        select 1
        from public.profiles
        where id = v_user_id
          and is_active = true
    ) then
        raise exception 'Active DIJO profile required';
    end if;


    -- --------------------------------------------------------
    -- 3. Validate required business name
    -- --------------------------------------------------------

    if p_name is null or length(trim(p_name)) = 0 then
        raise exception 'Business name is required';
    end if;


    -- --------------------------------------------------------
    -- 4. Validate coordinates when supplied
    -- --------------------------------------------------------

    if p_latitude is not null
       and (p_latitude < -90 or p_latitude > 90) then
        raise exception 'Latitude must be between -90 and 90';
    end if;

    if p_longitude is not null
       and (p_longitude < -180 or p_longitude > 180) then
        raise exception 'Longitude must be between -180 and 180';
    end if;


    -- --------------------------------------------------------
    -- 5. Create business
    --
    -- Protected fields are controlled by the database:
    -- owner_id  = authenticated user
    -- verified  = false
    -- is_active = true
    -- is_open   = true
    -- --------------------------------------------------------

    insert into public.businesses (
        owner_id,
        name,
        business_type,
        phone,
        email,
        description,
        address,
        city,
        province,
        postal_code,
        latitude,
        longitude,
        logo_url,
        cover_image_url,
        verified,
        is_open,
        is_active
    )
    values (
        v_user_id,
        trim(p_name),
        p_business_type,
        nullif(trim(p_phone), ''),
        nullif(trim(p_email), ''),
        nullif(trim(p_description), ''),
        nullif(trim(p_address), ''),
        nullif(trim(p_city), ''),
        nullif(trim(p_province), ''),
        nullif(trim(p_postal_code), ''),
        p_latitude,
        p_longitude,
        nullif(trim(p_logo_url), ''),
        nullif(trim(p_cover_image_url), ''),
        false,
        true,
        true
    )
    returning id into v_business_id;


    -- --------------------------------------------------------
    -- Migration 013's AFTER INSERT trigger on businesses
    -- automatically creates the owner membership.
    -- --------------------------------------------------------

    return v_business_id;
end;
$$;


-- ============================================================
-- EXECUTION PRIVILEGES
-- ============================================================

revoke all on function public.create_business(
    text,
    public.business_type,
    text,
    text,
    text,
    text,
    text,
    text,
    text,
    double precision,
    double precision,
    text,
    text
) from public;

revoke all on function public.create_business(
    text,
    public.business_type,
    text,
    text,
    text,
    text,
    text,
    text,
    text,
    double precision,
    double precision,
    text,
    text
) from anon;

grant execute on function public.create_business(
    text,
    public.business_type,
    text,
    text,
    text,
    text,
    text,
    text,
    text,
    double precision,
    double precision,
    text,
    text
) to authenticated;
