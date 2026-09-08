-- ============================================================
-- DIJO
-- Migration 028: Available Driver Discovery
-- ============================================================
--
-- PURPOSE
-- -------
-- Allow an authorized business dispatcher or DIJO admin to
-- securely discover verified, active, available drivers near
-- a business pickup location.
--
-- SECURITY PRINCIPLES
-- -------------------
-- 1. Drivers' exact GPS coordinates are NOT returned.
-- 2. Only authorized business members/admins may search.
-- 3. Only verified + active + available drivers are returned.
-- 4. Driver location must be recent.
-- 5. Drivers with an active delivery are excluded.
-- 6. Only active vehicles are returned.
-- 7. Search radius and result size are bounded.
-- 8. Assignment remains authoritative in Migration 026.
--
-- ============================================================


-- ============================================================
-- 1. LOCATION FRESHNESS INDEX
-- ============================================================
--
-- Complements the existing GIST driver-location index.
-- ============================================================

create index if not exists
driver_profiles_location_updated_at_idx
on public.driver_profiles (
    location_updated_at desc
)
where location_updated_at is not null;


-- ============================================================
-- 2. SECURE AVAILABLE DRIVER DISCOVERY RPC
-- ============================================================

create or replace function public.find_available_drivers(
    p_pickup_location_id uuid,
    p_radius_metres double precision default 5000,
    p_max_results integer default 20,
    p_location_max_age_minutes integer default 10
)
returns table (
    driver_profile_id uuid,
    vehicle_id uuid,
    vehicle_type public.vehicle_type,
    is_primary_vehicle boolean,
    distance_metres double precision,
    location_updated_at timestamptz
)
language plpgsql
security definer
stable
set search_path = ''
as $function$
declare
    v_actor_id uuid;

    v_business_id uuid;
    v_pickup_coordinates geography;

    v_is_business_member boolean := false;
    v_is_admin boolean := false;
begin
    -- ========================================================
    -- AUTHENTICATION
    -- ========================================================

    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;


    -- ========================================================
    -- REQUEST VALIDATION
    -- ========================================================

    if p_pickup_location_id is null then
        raise exception 'pickup_location_id is required';
    end if;

    if p_radius_metres is null
       or p_radius_metres <= 0 then
        raise exception
            'Search radius must be greater than zero';
    end if;

    if p_radius_metres > 50000 then
        raise exception
            'Search radius cannot exceed 50000 metres';
    end if;

    if p_max_results is null
       or p_max_results < 1 then
        raise exception
            'max_results must be at least 1';
    end if;

    if p_max_results > 50 then
        raise exception
            'max_results cannot exceed 50';
    end if;

    if p_location_max_age_minutes is null
       or p_location_max_age_minutes < 1 then
        raise exception
            'Location maximum age must be at least 1 minute';
    end if;

    if p_location_max_age_minutes > 120 then
        raise exception
            'Location maximum age cannot exceed 120 minutes';
    end if;


    -- ========================================================
    -- LOAD PICKUP LOCATION
    -- ========================================================

    select
        bl.business_id,
        bl.coordinates
    into
        v_business_id,
        v_pickup_coordinates
    from public.business_locations bl
    where bl.id = p_pickup_location_id
      and bl.is_active is true
      and bl.is_pickup_enabled is true;

    if not found then
        raise exception
            'Pickup location is unavailable';
    end if;

    if v_pickup_coordinates is null then
        raise exception
            'Pickup location does not have coordinates';
    end if;


    -- ========================================================
    -- AUTHORIZE ACTOR
    -- ========================================================

    select exists (
        select 1
        from public.business_members bm
        where bm.business_id = v_business_id
          and bm.profile_id = v_actor_id
          and bm.is_active is true
          and bm.role in (
              'owner'::public.business_member_role,
              'manager'::public.business_member_role,
              'staff'::public.business_member_role
          )
    )
    into v_is_business_member;


    select exists (
        select 1
        from public.profiles p
        where p.id = v_actor_id
          and p.role = 'admin'::public.user_role
          and p.is_active is true
    )
    into v_is_admin;


    if not v_is_business_member
       and not v_is_admin then
        raise exception
            'Not authorized to discover drivers for this location';
    end if;


    -- ========================================================
    -- FIND ELIGIBLE NEARBY DRIVERS
    -- ========================================================
    --
    -- Exact driver coordinates are intentionally NOT returned.
    --
    -- The LATERAL join chooses:
    --   1. active primary vehicle when available
    --   2. otherwise the driver's oldest active vehicle
    --
    -- A driver with no active vehicle is excluded.
    --
    -- Active-delivery exclusion is defense-in-depth.
    -- Normally assignment already sets is_available = false,
    -- but we do not rely on that flag alone.
    -- ========================================================

    return query

    select
        dp.profile_id,

        selected_vehicle.id,

        selected_vehicle.vehicle_type,

        selected_vehicle.is_primary,

        public.st_distance(
            dp.last_known_location,
            v_pickup_coordinates
        )::double precision,

        dp.location_updated_at

    from public.driver_profiles dp

    join public.profiles p
      on p.id = dp.profile_id

    join lateral (
        select
            dv.id,
            dv.vehicle_type,
            dv.is_primary
        from public.driver_vehicles dv
        where dv.driver_profile_id = dp.profile_id
          and dv.is_active is true
        order by
            dv.is_primary desc,
            dv.created_at asc
        limit 1
    ) selected_vehicle
      on true

    where dp.verification_status =
          'verified'::public.driver_verification_status

      and dp.is_active is true

      and dp.is_available is true

      and p.is_active is true

      and p.role = 'driver'::public.user_role

      and dp.last_known_location is not null

      and dp.location_updated_at is not null

      and dp.location_updated_at >=
          now() -
          (
              p_location_max_age_minutes
              * interval '1 minute'
          )

      and public.st_dwithin(
          dp.last_known_location,
          v_pickup_coordinates,
          p_radius_metres
      )

      and not exists (
          select 1
          from public.deliveries d
          where d.driver_profile_id = dp.profile_id
            and d.status in (
                'assigned'::public.delivery_status,
                'accepted'::public.delivery_status,
                'arrived_at_pickup'::public.delivery_status,
                'picked_up'::public.delivery_status,
                'on_the_way'::public.delivery_status
            )
      )

    order by
        public.st_distance(
            dp.last_known_location,
            v_pickup_coordinates
        ) asc

    limit p_max_results;

end;
$function$;


-- ============================================================
-- 3. FUNCTION OWNERSHIP
-- ============================================================

alter function public.find_available_drivers(
    uuid,
    double precision,
    integer,
    integer
)
owner to postgres;


-- ============================================================
-- 4. EXECUTION PRIVILEGES
-- ============================================================

revoke all
on function public.find_available_drivers(
    uuid,
    double precision,
    integer,
    integer
)
from public;


revoke all
on function public.find_available_drivers(
    uuid,
    double precision,
    integer,
    integer
)
from anon;


grant execute
on function public.find_available_drivers(
    uuid,
    double precision,
    integer,
    integer
)
to authenticated;


-- ============================================================
-- 5. REASSERT DRIVER DATA WRITE BOUNDARY
-- ============================================================

revoke insert, update, delete
on public.driver_profiles
from anon, authenticated;

revoke insert, update, delete
on public.driver_vehicles
from anon, authenticated;


-- ============================================================
-- END MIGRATION 028
-- ============================================================
