-- ============================================================
-- DIJO
-- Migration 024: Secure Driver Onboarding
--
-- Purpose:
--   1. Allow an authenticated user to submit a driver application.
--   2. Allow a driver applicant to register/manage their vehicles.
--   3. Allow admins to verify, reject or suspend drivers.
--   4. Prevent clients from directly controlling verification state.
--   5. Preserve driver_profiles / driver_vehicles as protected tables.
--
-- Important:
--   Delivery dispatch is NOT implemented in this migration.
-- ============================================================


-- ============================================================
-- 1. APPLY TO BECOME A DRIVER
-- ============================================================

create or replace function public.apply_to_be_driver()
returns public.driver_verification_status
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid;
    v_profile_active boolean;
    v_existing_status public.driver_verification_status;
begin
    v_user_id := auth.uid();

    if v_user_id is null then
        raise exception 'Authentication required';
    end if;

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


    -- Lock an existing driver application if one exists.
    select dp.verification_status
    into v_existing_status
    from public.driver_profiles dp
    where dp.profile_id = v_user_id
    for update;


    if found then

        if v_existing_status = 'pending'::public.driver_verification_status then
            return v_existing_status;
        end if;

        if v_existing_status = 'verified'::public.driver_verification_status then
            return v_existing_status;
        end if;

        if v_existing_status = 'suspended'::public.driver_verification_status then
            raise exception 'Driver account is suspended';
        end if;

        -- A rejected applicant may reapply.
        update public.driver_profiles
        set
            verification_status =
                'pending'::public.driver_verification_status,
            is_active = true,
            is_available = false
        where profile_id = v_user_id;

        return 'pending'::public.driver_verification_status;

    end if;


    insert into public.driver_profiles (
        profile_id,
        verification_status,
        is_active,
        is_available
    )
    values (
        v_user_id,
        'pending'::public.driver_verification_status,
        true,
        false
    );

    return 'pending'::public.driver_verification_status;
end;
$$;


alter function public.apply_to_be_driver()
owner to postgres;

revoke all on function public.apply_to_be_driver() from public;
revoke all on function public.apply_to_be_driver() from anon;
grant execute on function public.apply_to_be_driver() to authenticated;


-- ============================================================
-- 2. REGISTER A DRIVER VEHICLE
-- ============================================================

create or replace function public.register_driver_vehicle(
    p_vehicle_type public.vehicle_type,
    p_make text default null,
    p_model text default null,
    p_registration_number text default null,
    p_colour text default null,
    p_is_primary boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid;
    v_driver_status public.driver_verification_status;
    v_driver_active boolean;
    v_vehicle_id uuid;
begin
    v_user_id := auth.uid();

    if v_user_id is null then
        raise exception 'Authentication required';
    end if;

    if p_vehicle_type is null then
        raise exception 'Vehicle type is required';
    end if;


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
        raise exception 'Driver application required';
    end if;

    if v_driver_active is not true then
        raise exception 'Driver profile is inactive';
    end if;

    if v_driver_status = 'rejected'::public.driver_verification_status then
        raise exception 'Driver application has been rejected';
    end if;

    if v_driver_status = 'suspended'::public.driver_verification_status then
        raise exception 'Driver account is suspended';
    end if;


    -- If this vehicle becomes primary, demote any existing
    -- active primary vehicle owned by this driver.
    if coalesce(p_is_primary, false) then
        update public.driver_vehicles
        set is_primary = false
        where driver_profile_id = v_user_id
          and is_active is true
          and is_primary is true;
    end if;


    insert into public.driver_vehicles (
        driver_profile_id,
        vehicle_type,
        make,
        model,
        registration_number,
        colour,
        is_primary,
        is_active
    )
    values (
        v_user_id,
        p_vehicle_type,

        nullif(trim(coalesce(p_make, '')), ''),
        nullif(trim(coalesce(p_model, '')), ''),
        nullif(trim(coalesce(p_registration_number, '')), ''),
        nullif(trim(coalesce(p_colour, '')), ''),

        coalesce(p_is_primary, false),
        true
    )
    returning id into v_vehicle_id;


    return v_vehicle_id;
end;
$$;


alter function public.register_driver_vehicle(
    public.vehicle_type,
    text,
    text,
    text,
    text,
    boolean
)
owner to postgres;

revoke all on function public.register_driver_vehicle(
    public.vehicle_type,
    text,
    text,
    text,
    text,
    boolean
) from public;

revoke all on function public.register_driver_vehicle(
    public.vehicle_type,
    text,
    text,
    text,
    text,
    boolean
) from anon;

grant execute on function public.register_driver_vehicle(
    public.vehicle_type,
    text,
    text,
    text,
    text,
    boolean
) to authenticated;


-- ============================================================
-- 3. UPDATE OWN DRIVER VEHICLE
-- ============================================================

create or replace function public.update_my_driver_vehicle(
    p_vehicle_id uuid,
    p_vehicle_type public.vehicle_type,
    p_make text default null,
    p_model text default null,
    p_registration_number text default null,
    p_colour text default null,
    p_is_primary boolean default false
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid;
    v_vehicle_owner uuid;
begin
    v_user_id := auth.uid();

    if v_user_id is null then
        raise exception 'Authentication required';
    end if;

    if p_vehicle_id is null then
        raise exception 'Vehicle ID is required';
    end if;

    if p_vehicle_type is null then
        raise exception 'Vehicle type is required';
    end if;


    select dv.driver_profile_id
    into v_vehicle_owner
    from public.driver_vehicles dv
    where dv.id = p_vehicle_id
    for update;


    if not found then
        raise exception 'Vehicle not found';
    end if;

    if v_vehicle_owner <> v_user_id then
        raise exception 'Not authorized to update this vehicle';
    end if;


    if coalesce(p_is_primary, false) then
        update public.driver_vehicles
        set is_primary = false
        where driver_profile_id = v_user_id
          and id <> p_vehicle_id
          and is_active is true
          and is_primary is true;
    end if;


    update public.driver_vehicles
    set
        vehicle_type = p_vehicle_type,

        make =
            nullif(trim(coalesce(p_make, '')), ''),

        model =
            nullif(trim(coalesce(p_model, '')), ''),

        registration_number =
            nullif(trim(coalesce(p_registration_number, '')), ''),

        colour =
            nullif(trim(coalesce(p_colour, '')), ''),

        is_primary = coalesce(p_is_primary, false)

    where id = p_vehicle_id;
end;
$$;


alter function public.update_my_driver_vehicle(
    uuid,
    public.vehicle_type,
    text,
    text,
    text,
    text,
    boolean
)
owner to postgres;

revoke all on function public.update_my_driver_vehicle(
    uuid,
    public.vehicle_type,
    text,
    text,
    text,
    text,
    boolean
) from public;

revoke all on function public.update_my_driver_vehicle(
    uuid,
    public.vehicle_type,
    text,
    text,
    text,
    text,
    boolean
) from anon;

grant execute on function public.update_my_driver_vehicle(
    uuid,
    public.vehicle_type,
    text,
    text,
    text,
    text,
    boolean
) to authenticated;


-- ============================================================
-- 4. SET OWN VEHICLE ACTIVE / INACTIVE
-- ============================================================

create or replace function public.set_my_driver_vehicle_active(
    p_vehicle_id uuid,
    p_is_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_user_id uuid;
    v_vehicle_owner uuid;
begin
    v_user_id := auth.uid();

    if v_user_id is null then
        raise exception 'Authentication required';
    end if;

    if p_vehicle_id is null then
        raise exception 'Vehicle ID is required';
    end if;

    if p_is_active is null then
        raise exception 'Active state is required';
    end if;


    select dv.driver_profile_id
    into v_vehicle_owner
    from public.driver_vehicles dv
    where dv.id = p_vehicle_id
    for update;


    if not found then
        raise exception 'Vehicle not found';
    end if;

    if v_vehicle_owner <> v_user_id then
        raise exception 'Not authorized to update this vehicle';
    end if;


    update public.driver_vehicles
    set
        is_active = p_is_active,

        -- An inactive vehicle cannot remain primary.
        is_primary =
            case
                when p_is_active is false then false
                else is_primary
            end

    where id = p_vehicle_id;
end;
$$;


alter function public.set_my_driver_vehicle_active(uuid, boolean)
owner to postgres;

revoke all on function public.set_my_driver_vehicle_active(uuid, boolean)
from public;

revoke all on function public.set_my_driver_vehicle_active(uuid, boolean)
from anon;

grant execute on function public.set_my_driver_vehicle_active(uuid, boolean)
to authenticated;


-- ============================================================
-- 5. ADMIN DRIVER VERIFICATION / STATUS MANAGEMENT
-- ============================================================

create or replace function public.set_driver_verification_status(
    p_driver_profile_id uuid,
    p_status public.driver_verification_status
)
returns public.driver_verification_status
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_admin_id uuid;
    v_admin_role public.user_role;
    v_admin_active boolean;
    v_driver_exists boolean;
begin
    v_admin_id := auth.uid();

    if v_admin_id is null then
        raise exception 'Authentication required';
    end if;

    if p_driver_profile_id is null then
        raise exception 'Driver profile ID is required';
    end if;

    if p_status is null then
        raise exception 'Verification status is required';
    end if;


    select
        p.role,
        p.is_active
    into
        v_admin_role,
        v_admin_active
    from public.profiles p
    where p.id = v_admin_id;


    if not found
       or v_admin_active is not true
       or v_admin_role <> 'admin'::public.user_role then
        raise exception 'Admin authorization required';
    end if;


    select exists (
        select 1
        from public.driver_profiles dp
        where dp.profile_id = p_driver_profile_id
    )
    into v_driver_exists;


    if not v_driver_exists then
        raise exception 'Driver profile not found';
    end if;


    -- Lock the driver row before changing verification state.
    perform 1
    from public.driver_profiles dp
    where dp.profile_id = p_driver_profile_id
    for update;


    update public.driver_profiles
    set
        verification_status = p_status,

        is_active =
            case
                when p_status in (
                    'rejected'::public.driver_verification_status,
                    'suspended'::public.driver_verification_status
                )
                then false
                else true
            end,

        is_available =
            case
                when p_status =
                     'verified'::public.driver_verification_status
                then is_available
                else false
            end

    where profile_id = p_driver_profile_id;


    -- profiles.role is the MVP primary/default platform role.
    -- Customer ordering remains identity-based and therefore
    -- still works for verified drivers.
    --
    -- We only promote to driver on verification.
    -- We deliberately do not automatically demote a driver
    -- on rejection/suspension because future multi-role identity
    -- handling will be addressed separately.
    if p_status = 'verified'::public.driver_verification_status then

        update public.profiles
        set role = 'driver'::public.user_role
        where id = p_driver_profile_id;

    end if;


    return p_status;
end;
$$;


alter function public.set_driver_verification_status(
    uuid,
    public.driver_verification_status
)
owner to postgres;

revoke all on function public.set_driver_verification_status(
    uuid,
    public.driver_verification_status
) from public;

revoke all on function public.set_driver_verification_status(
    uuid,
    public.driver_verification_status
) from anon;

grant execute on function public.set_driver_verification_status(
    uuid,
    public.driver_verification_status
) to authenticated;


-- ============================================================
-- 6. SECURITY BOUNDARY
--
-- Keep direct client mutation disabled.
-- All supported mutations must pass through the RPCs above.
-- ============================================================

revoke insert, update, delete
on table public.driver_profiles
from anon, authenticated;

revoke insert, update, delete
on table public.driver_vehicles
from anon, authenticated;
