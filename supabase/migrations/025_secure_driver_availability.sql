-- ============================================================
-- DIJO
-- Migration 025: Secure Driver Availability
--
-- Purpose:
--   1. Allow only verified, active drivers to go online.
--   2. Allow drivers to go offline securely.
--   3. Allow verified, active drivers to update their own
--      last-known location.
--   4. Keep direct client mutation of driver_profiles blocked.
--
-- Dispatch and delivery assignment are NOT implemented here.
-- ============================================================


-- ============================================================
-- 1. SET DRIVER AVAILABILITY
-- ============================================================

create or replace function public.set_my_driver_availability(
    p_is_available boolean
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid;
    v_profile_active boolean;
    v_driver_active boolean;
    v_driver_status public.driver_verification_status;
begin
    v_user_id := auth.uid();

    if v_user_id is null then
        raise exception 'Authentication required';
    end if;

    if p_is_available is null then
        raise exception 'Availability state is required';
    end if;


    -- Lock the profile and verify the overall DIJO account is active.
    select p.is_active
    into v_profile_active
    from public.profiles p
    where p.id = v_user_id
    for update;

    if not found then
        raise exception 'Profile not found';
    end if;

    if v_profile_active is not true then
        raise exception 'Account is inactive';
    end if;


    -- Lock the driver's operational profile.
    select
        dp.verification_status,
        dp.is_active
    into
        v_driver_status,
        v_driver_active
    from public.driver_profiles dp
    where dp.profile_id = v_user_id
    for update;

    if not found then
        raise exception 'Driver profile not found';
    end if;


    -- Going ONLINE requires a fully verified, active driver.
    if p_is_available is true then

        if v_driver_status <> 'verified'::public.driver_verification_status then
            raise exception 'Driver is not verified';
        end if;

        if v_driver_active is not true then
            raise exception 'Driver profile is inactive';
        end if;

    end if;


    -- Going OFFLINE is always allowed for an existing driver
    -- whose main DIJO account is active.
    update public.driver_profiles
    set is_available = p_is_available
    where profile_id = v_user_id;

    return p_is_available;
end;
$$;


alter function public.set_my_driver_availability(boolean)
owner to postgres;

revoke all on function public.set_my_driver_availability(boolean)
from public;

revoke all on function public.set_my_driver_availability(boolean)
from anon;

grant execute on function public.set_my_driver_availability(boolean)
to authenticated;


-- ============================================================
-- 2. UPDATE DRIVER LOCATION
-- ============================================================

create or replace function public.update_my_driver_location(
    p_latitude double precision,
    p_longitude double precision
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid;
    v_profile_active boolean;
    v_driver_active boolean;
    v_driver_status public.driver_verification_status;
begin
    v_user_id := auth.uid();

    if v_user_id is null then
        raise exception 'Authentication required';
    end if;


    -- Both coordinates are required.
    if p_latitude is null or p_longitude is null then
        raise exception 'Latitude and longitude are required';
    end if;


    -- Explicit validation before touching the row.
    if p_latitude < -90 or p_latitude > 90 then
        raise exception 'Latitude is out of range';
    end if;

    if p_longitude < -180 or p_longitude > 180 then
        raise exception 'Longitude is out of range';
    end if;


    -- Confirm the main DIJO account is active.
    select p.is_active
    into v_profile_active
    from public.profiles p
    where p.id = v_user_id;

    if not found then
        raise exception 'Profile not found';
    end if;

    if v_profile_active is not true then
        raise exception 'Account is inactive';
    end if;


    -- Lock and verify driver state.
    select
        dp.verification_status,
        dp.is_active
    into
        v_driver_status,
        v_driver_active
    from public.driver_profiles dp
    where dp.profile_id = v_user_id
    for update;

    if not found then
        raise exception 'Driver profile not found';
    end if;

    if v_driver_status <> 'verified'::public.driver_verification_status then
        raise exception 'Driver is not verified';
    end if;

    if v_driver_active is not true then
        raise exception 'Driver profile is inactive';
    end if;


    update public.driver_profiles
    set
        last_known_latitude = p_latitude,
        last_known_longitude = p_longitude,
        location_updated_at = now()
    where profile_id = v_user_id;
end;
$$;


alter function public.update_my_driver_location(
    double precision,
    double precision
)
owner to postgres;

revoke all on function public.update_my_driver_location(
    double precision,
    double precision
) from public;

revoke all on function public.update_my_driver_location(
    double precision,
    double precision
) from anon;

grant execute on function public.update_my_driver_location(
    double precision,
    double precision
) to authenticated;


-- ============================================================
-- 3. SECURITY BOUNDARY
--
-- Keep direct client mutation disabled.
-- All supported operational driver mutations must pass through
-- the RPCs above.
-- ============================================================

revoke insert, update, delete
on table public.driver_profiles
from anon, authenticated;
