-- ============================================================
-- DIJO
-- Migration 029a: Fix Delivery Offer ON CONFLICT Ambiguity
-- ============================================================
--
-- PURPOSE
-- -------
-- Fix PL/pgSQL name ambiguity inside create_delivery_offers().
--
-- The function RETURNS TABLE with an output variable named
-- driver_profile_id. PostgreSQL therefore treated the
-- driver_profile_id reference inside ON CONFLICT as ambiguous
-- between:
--
--   1. the delivery_offers table column
--   2. the PL/pgSQL output variable
--
-- #variable_conflict use_column instructs PL/pgSQL to prefer
-- table columns when an unqualified name is ambiguous.
--
-- No delivery-offer architecture or security rules change.
--
-- ============================================================


create or replace function public.create_delivery_offers(
    p_order_id uuid,
    p_pickup_location_id uuid,
    p_driver_profile_ids uuid[],
    p_offer_ttl_seconds integer default 120,
    p_location_max_age_minutes integer default 10,
    p_max_distance_metres double precision default 5000
)
returns table (
    offer_id uuid,
    driver_profile_id uuid,
    vehicle_id uuid,
    distance_metres double precision,
    expires_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $function$

#variable_conflict use_column

declare
    v_actor_id uuid;

    v_business_id uuid;
    v_order_status public.order_status;
    v_delivery_address text;

    v_pickup_coordinates public.geography;

    v_is_business_member boolean := false;
    v_is_admin boolean := false;

    v_driver_id uuid;
    v_vehicle_id uuid;
    v_distance_metres double precision;

    v_requested_count integer;
    v_unique_count integer;
begin

    -- ========================================================
    -- AUTHENTICATION
    -- ========================================================

    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;


    if not exists (
        select 1
        from public.profiles p
        where p.id = v_actor_id
          and p.is_active is true
    ) then
        raise exception 'Active profile required';
    end if;


    -- ========================================================
    -- INPUT VALIDATION
    -- ========================================================

    if p_order_id is null then
        raise exception 'order_id is required';
    end if;

    if p_pickup_location_id is null then
        raise exception 'pickup_location_id is required';
    end if;

    if p_driver_profile_ids is null
       or cardinality(p_driver_profile_ids) = 0 then
        raise exception
            'At least one driver is required';
    end if;

    if cardinality(p_driver_profile_ids) > 20 then
        raise exception
            'A maximum of 20 drivers may be offered a delivery';
    end if;

    if exists (
        select 1
        from unnest(p_driver_profile_ids) x
        where x is null
    ) then
        raise exception
            'Driver list cannot contain null values';
    end if;


    select
        cardinality(p_driver_profile_ids),
        count(distinct x)::integer
    into
        v_requested_count,
        v_unique_count
    from unnest(p_driver_profile_ids) x;


    if v_requested_count <> v_unique_count then
        raise exception
            'Driver list cannot contain duplicates';
    end if;


    if p_offer_ttl_seconds is null
       or p_offer_ttl_seconds < 30 then
        raise exception
            'Offer TTL must be at least 30 seconds';
    end if;

    if p_offer_ttl_seconds > 600 then
        raise exception
            'Offer TTL cannot exceed 600 seconds';
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


    if p_max_distance_metres is null
       or p_max_distance_metres <= 0 then
        raise exception
            'Maximum distance must be greater than zero';
    end if;

    if p_max_distance_metres > 50000 then
        raise exception
            'Maximum distance cannot exceed 50000 metres';
    end if;


    -- ========================================================
    -- LOCK AND LOAD ORDER
    -- ========================================================

    select
        o.business_id,
        o.status,
        o.delivery_address
    into
        v_business_id,
        v_order_status,
        v_delivery_address
    from public.orders o
    where o.id = p_order_id
    for update;


    if not found then
        raise exception 'Order not found';
    end if;


    if v_order_status <> 'ready'::public.order_status then
        raise exception
            'Only ready orders can be offered to drivers';
    end if;


    if v_delivery_address is null
       or btrim(v_delivery_address) = '' then
        raise exception
            'Order does not have a delivery address';
    end if;


    -- ========================================================
    -- AUTHORIZE BUSINESS DISPATCHER / ADMIN
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
            'Not authorized to create delivery offers';
    end if;


    -- ========================================================
    -- VALIDATE PICKUP LOCATION
    -- ========================================================

    select
        bl.coordinates
    into
        v_pickup_coordinates
    from public.business_locations bl
    where bl.id = p_pickup_location_id
      and bl.business_id = v_business_id
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
    -- ORDER MUST NOT ALREADY HAVE AN ACTIVE DELIVERY
    -- ========================================================

    if exists (
        select 1
        from public.deliveries d
        where d.order_id = p_order_id
          and (
              d.driver_profile_id is not null
              or d.status <>
                 'waiting'::public.delivery_status
          )
    ) then
        raise exception
            'Order already has an active delivery';
    end if;


    -- ========================================================
    -- EXPIRE OLD PENDING OFFERS FOR THIS ORDER
    -- ========================================================

    update public.delivery_offers o
    set
        status = 'expired'::public.delivery_offer_status,
        updated_at = now()
    where o.order_id = p_order_id
      and o.status =
          'pending'::public.delivery_offer_status
      and o.expires_at <= now();


    -- ========================================================
    -- VALIDATE EACH DRIVER AND CREATE OFFER
    -- ========================================================

    for v_driver_id in
        select distinct x
        from unnest(p_driver_profile_ids) x
    loop

        v_vehicle_id := null;
        v_distance_metres := null;


        select
            selected_vehicle.id,

            public.st_distance(
                dp.last_known_location,
                v_pickup_coordinates
            )::double precision

        into
            v_vehicle_id,
            v_distance_metres

        from public.driver_profiles dp

        join public.profiles p
          on p.id = dp.profile_id

        join lateral (
            select
                dv.id
            from public.driver_vehicles dv
            where dv.driver_profile_id =
                  dp.profile_id
              and dv.is_active is true
            order by
                dv.is_primary desc,
                dv.created_at asc
            limit 1
        ) selected_vehicle
          on true

        where dp.profile_id = v_driver_id

          and dp.verification_status =
              'verified'::public.driver_verification_status

          and dp.is_active is true

          and dp.is_available is true

          and p.is_active is true

          and p.role =
              'driver'::public.user_role

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
              p_max_distance_metres
          )

          and not exists (
              select 1
              from public.deliveries d
              where d.driver_profile_id =
                    dp.profile_id
                and d.status in (
                    'assigned'::public.delivery_status,
                    'accepted'::public.delivery_status,
                    'arrived_at_pickup'::public.delivery_status,
                    'picked_up'::public.delivery_status,
                    'on_the_way'::public.delivery_status
                )
          );


        if v_vehicle_id is null then
            raise exception
                'Driver % is not eligible for this delivery offer',
                v_driver_id;
        end if;


        return query

        insert into public.delivery_offers (
            order_id,
            business_id,
            driver_profile_id,
            vehicle_id,
            pickup_location_id,
            status,
            distance_metres,
            offered_at,
            expires_at,
            created_by,
            created_at,
            updated_at
        )
        values (
            p_order_id,
            v_business_id,
            v_driver_id,
            v_vehicle_id,
            p_pickup_location_id,
            'pending'::public.delivery_offer_status,
            v_distance_metres,
            now(),
            now() +
                (
                    p_offer_ttl_seconds
                    * interval '1 second'
                ),
            v_actor_id,
            now(),
            now()
        )

        on conflict (
            order_id,
            driver_profile_id
        )
        where status =
              'pending'::public.delivery_offer_status

        do update set
            vehicle_id = excluded.vehicle_id,
            pickup_location_id =
                excluded.pickup_location_id,
            distance_metres =
                excluded.distance_metres,
            offered_at = excluded.offered_at,
            expires_at = excluded.expires_at,
            created_by = excluded.created_by,
            updated_at = now()

        returning
            delivery_offers.id,
            delivery_offers.driver_profile_id,
            delivery_offers.vehicle_id,
            delivery_offers.distance_metres,
            delivery_offers.expires_at;

    end loop;

end;
$function$;


-- ============================================================
-- OWNERSHIP
-- ============================================================

alter function public.create_delivery_offers(
    uuid,
    uuid,
    uuid[],
    integer,
    integer,
    double precision
)
owner to postgres;


-- ============================================================
-- EXECUTION PRIVILEGES
-- ============================================================

revoke all
on function public.create_delivery_offers(
    uuid,
    uuid,
    uuid[],
    integer,
    integer,
    double precision
)
from public, anon;


grant execute
on function public.create_delivery_offers(
    uuid,
    uuid,
    uuid[],
    integer,
    integer,
    double precision
)
to authenticated;


-- ============================================================
-- END MIGRATION 029a
-- ============================================================
