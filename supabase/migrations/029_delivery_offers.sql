-- ============================================================
-- DIJO
-- Migration 029: Delivery Offers
-- ============================================================
--
-- PURPOSE
-- -------
-- Introduce a secure offer layer between nearby-driver
-- discovery and final delivery assignment.
--
-- FLOW
-- ----
-- Ready order
--   -> discover nearby drivers
--   -> create driver offers
--   -> driver accepts/rejects
--   -> first valid acceptance wins atomically
--   -> delivery becomes accepted
--   -> order becomes driver_assigned
--   -> remaining offers are cancelled
--
-- SECURITY / CONCURRENCY
-- ----------------------
-- 1. Direct client mutation is prohibited.
-- 2. Offer creation is business/admin controlled.
-- 3. Drivers can only accept/reject their own offers.
-- 4. Order row locking prevents two drivers winning one order.
-- 5. Driver row locking prevents one driver winning two jobs.
-- 6. Database unique indexes provide additional protection.
-- 7. Exact driver GPS coordinates are never stored in offers.
-- 8. Driver eligibility is revalidated when offers are created.
-- 9. Driver eligibility is revalidated again on acceptance.
-- 10. Migration 027 delivery history remains authoritative.
--
-- ============================================================


-- ============================================================
-- 1. DELIVERY OFFER STATUS ENUM
-- ============================================================

do $$
begin
    if not exists (
        select 1
        from pg_type t
        join pg_namespace n
          on n.oid = t.typnamespace
        where n.nspname = 'public'
          and t.typname = 'delivery_offer_status'
    ) then
        create type public.delivery_offer_status as enum (
            'pending',
            'accepted',
            'rejected',
            'expired',
            'cancelled'
        );
    end if;
end
$$;


-- ============================================================
-- 2. DELIVERY OFFERS TABLE
-- ============================================================

create table if not exists public.delivery_offers (
    id uuid primary key default gen_random_uuid(),

    order_id uuid not null,
    business_id uuid not null,

    driver_profile_id uuid not null,
    vehicle_id uuid not null,

    pickup_location_id uuid not null,

    status public.delivery_offer_status
        not null
        default 'pending'::public.delivery_offer_status,

    distance_metres double precision not null,

    offered_at timestamptz not null default now(),
    expires_at timestamptz not null,

    responded_at timestamptz null,

    created_by uuid null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint delivery_offers_order_business_fkey
        foreign key (order_id, business_id)
        references public.orders (id, business_id)
        on delete cascade,

    constraint delivery_offers_driver_fkey
        foreign key (driver_profile_id)
        references public.driver_profiles (profile_id)
        on delete cascade,

    constraint delivery_offers_vehicle_driver_fkey
        foreign key (vehicle_id, driver_profile_id)
        references public.driver_vehicles (id, driver_profile_id)
        on delete restrict,

    constraint delivery_offers_pickup_business_fkey
        foreign key (pickup_location_id, business_id)
        references public.business_locations (id, business_id)
        on delete restrict,

    constraint delivery_offers_created_by_fkey
        foreign key (created_by)
        references public.profiles (id)
        on delete set null,

    constraint delivery_offers_distance_nonnegative
        check (distance_metres >= 0),

    constraint delivery_offers_expiry_after_offer
        check (expires_at > offered_at)
);


-- ============================================================
-- 3. INDEXES
-- ============================================================

create index if not exists
delivery_offers_driver_status_expires_idx
on public.delivery_offers (
    driver_profile_id,
    status,
    expires_at
);


create index if not exists
delivery_offers_order_status_idx
on public.delivery_offers (
    order_id,
    status
);


create index if not exists
delivery_offers_business_created_idx
on public.delivery_offers (
    business_id,
    created_at desc
);


create index if not exists
delivery_offers_expires_idx
on public.delivery_offers (
    expires_at
)
where status = 'pending'::public.delivery_offer_status;


-- Only one currently-pending offer per driver per order.

create unique index if not exists
delivery_offers_one_pending_per_driver_order_idx
on public.delivery_offers (
    order_id,
    driver_profile_id
)
where status = 'pending'::public.delivery_offer_status;


-- Only one offer can ever be accepted for a particular order.

create unique index if not exists
delivery_offers_one_accepted_per_order_idx
on public.delivery_offers (
    order_id
)
where status = 'accepted'::public.delivery_offer_status;


-- Defense-in-depth:
-- a driver may only have one active delivery at a time.

create unique index if not exists
deliveries_one_active_per_driver_idx
on public.deliveries (
    driver_profile_id
)
where driver_profile_id is not null
  and status in (
      'assigned'::public.delivery_status,
      'accepted'::public.delivery_status,
      'arrived_at_pickup'::public.delivery_status,
      'picked_up'::public.delivery_status,
      'on_the_way'::public.delivery_status
  );


-- ============================================================
-- 4. ROW LEVEL SECURITY
-- ============================================================

alter table public.delivery_offers
enable row level security;


drop policy if exists
"Drivers can view own delivery offers"
on public.delivery_offers;

create policy
"Drivers can view own delivery offers"
on public.delivery_offers
for select
to authenticated
using (
    driver_profile_id = auth.uid()
);


drop policy if exists
"Business members can view business delivery offers"
on public.delivery_offers;

create policy
"Business members can view business delivery offers"
on public.delivery_offers
for select
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = delivery_offers.business_id
          and bm.profile_id = auth.uid()
          and bm.is_active is true
    )
);


drop policy if exists
"Admins can view all delivery offers"
on public.delivery_offers;

create policy
"Admins can view all delivery offers"
on public.delivery_offers
for select
to authenticated
using (
    exists (
        select 1
        from public.profiles p
        where p.id = auth.uid()
          and p.role = 'admin'::public.user_role
          and p.is_active is true
    )
);


-- ============================================================
-- 5. TABLE PRIVILEGES
-- ============================================================

revoke all
on public.delivery_offers
from anon;

revoke insert, update, delete
on public.delivery_offers
from authenticated;

grant select
on public.delivery_offers
to authenticated;


-- ============================================================
-- 6. AUTOMATICALLY CANCEL PENDING OFFERS WHEN AN ORDER
--    LEAVES READY STATUS
-- ============================================================
--
-- This also integrates Migration 029 with the existing
-- Migration 026 manual assignment workflow.
--
-- If Migration 026 assigns a driver manually:
--
-- ready -> driver_assigned
--
-- all outstanding offers automatically become cancelled.
--
-- During offer acceptance, the winning offer is changed to
-- accepted BEFORE the order leaves ready status, so this
-- trigger only cancels the remaining pending offers.
-- ============================================================

create or replace function
public.cancel_pending_delivery_offers_on_order_status_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin

    if old.status = 'ready'::public.order_status
       and new.status <> 'ready'::public.order_status then

        update public.delivery_offers o
        set
            status =
                'cancelled'::public.delivery_offer_status,
            updated_at = now()
        where o.order_id = new.id
          and o.status =
              'pending'::public.delivery_offer_status;

    end if;

    return new;
end;
$function$;


alter function
public.cancel_pending_delivery_offers_on_order_status_change()
owner to postgres;


revoke all
on function
public.cancel_pending_delivery_offers_on_order_status_change()
from public, anon, authenticated;


drop trigger if exists
orders_cancel_pending_delivery_offers
on public.orders;


create trigger
orders_cancel_pending_delivery_offers
after update of status
on public.orders
for each row
when (old.status is distinct from new.status)
execute function
public.cancel_pending_delivery_offers_on_order_status_change();


-- ============================================================
-- 7. CREATE DELIVERY OFFERS
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
-- 8. GET CURRENT DRIVER'S LIVE OFFERS
-- ============================================================

create or replace function public.get_my_delivery_offers(
    p_limit integer default 20
)
returns table (
    offer_id uuid,
    order_id uuid,
    order_number text,
    business_id uuid,
    pickup_location_id uuid,
    pickup_name text,
    pickup_address text,
    vehicle_id uuid,
    distance_metres double precision,
    offered_at timestamptz,
    expires_at timestamptz,
    seconds_remaining integer
)
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_actor_id uuid;
begin

    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;


    if p_limit is null
       or p_limit < 1 then
        raise exception
            'limit must be at least 1';
    end if;

    if p_limit > 50 then
        raise exception
            'limit cannot exceed 50';
    end if;


    if not exists (
        select 1
        from public.driver_profiles dp
        join public.profiles p
          on p.id = dp.profile_id
        where dp.profile_id = v_actor_id
          and dp.verification_status =
              'verified'::public.driver_verification_status
          and dp.is_active is true
          and p.is_active is true
          and p.role =
              'driver'::public.user_role
    ) then
        raise exception
            'Active verified driver required';
    end if;


    -- Mark this driver's old offers expired.

    update public.delivery_offers o
    set
        status = 'expired'::public.delivery_offer_status,
        updated_at = now()
    where o.driver_profile_id = v_actor_id
      and o.status =
          'pending'::public.delivery_offer_status
      and o.expires_at <= now();


    return query

    select
        o.id,
        o.order_id,
        ord.order_number,
        o.business_id,
        o.pickup_location_id,
        bl.name,
        bl.address,
        o.vehicle_id,
        o.distance_metres,
        o.offered_at,
        o.expires_at,

        greatest(
            0,
            floor(
                extract(
                    epoch from
                    (o.expires_at - now())
                )
            )::integer
        )

    from public.delivery_offers o

    join public.orders ord
      on ord.id = o.order_id

    join public.business_locations bl
      on bl.id = o.pickup_location_id

    where o.driver_profile_id = v_actor_id

      and o.status =
          'pending'::public.delivery_offer_status

      and o.expires_at > now()

      and ord.status =
          'ready'::public.order_status

    order by
        o.expires_at asc,
        o.created_at asc

    limit p_limit;

end;
$function$;


alter function public.get_my_delivery_offers(integer)
owner to postgres;


-- ============================================================
-- 9. REJECT DELIVERY OFFER
-- ============================================================

create or replace function public.reject_delivery_offer(
    p_offer_id uuid
)
returns public.delivery_offer_status
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_actor_id uuid;
    v_driver_profile_id uuid;
    v_status public.delivery_offer_status;
    v_expires_at timestamptz;
begin

    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;


    select
        o.driver_profile_id,
        o.status,
        o.expires_at
    into
        v_driver_profile_id,
        v_status,
        v_expires_at
    from public.delivery_offers o
    where o.id = p_offer_id
    for update;


    if not found then
        raise exception 'Delivery offer not found';
    end if;


    if v_driver_profile_id <> v_actor_id then
        raise exception
            'You do not own this delivery offer';
    end if;


    if v_status <>
       'pending'::public.delivery_offer_status then
        raise exception
            'Delivery offer is no longer pending';
    end if;


    if v_expires_at <= now() then

        update public.delivery_offers o
        set
            status =
                'expired'::public.delivery_offer_status,
            updated_at = now()
        where o.id = p_offer_id;

        return 'expired'::public.delivery_offer_status;

    end if;


    update public.delivery_offers o
    set
        status =
            'rejected'::public.delivery_offer_status,
        responded_at = now(),
        updated_at = now()
    where o.id = p_offer_id;


    return 'rejected'::public.delivery_offer_status;

end;
$function$;


alter function public.reject_delivery_offer(uuid)
owner to postgres;


-- ============================================================
-- 10. ACCEPT DELIVERY OFFER
-- ============================================================
--
-- IMPORTANT LOCKING ORDER
-- -----------------------
-- 1. Offer row
-- 2. Order row
-- 3. Driver profile row
-- 4. Existing delivery row, when present
--
-- The locked ORDER is the decisive concurrency control.
--
-- Two drivers accepting offers for the same order cannot both
-- pass the READY-order check.
--
-- The locked DRIVER PROFILE prevents the same driver from
-- accepting two different jobs concurrently.
-- ============================================================

create or replace function public.accept_delivery_offer(
    p_offer_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_actor_id uuid;

    v_order_id uuid;
    v_business_id uuid;
    v_offer_driver_id uuid;
    v_vehicle_id uuid;
    v_pickup_location_id uuid;
    v_offer_status public.delivery_offer_status;
    v_expires_at timestamptz;

    v_order_status public.order_status;
    v_delivery_address text;

    v_driver_verification
        public.driver_verification_status;
    v_driver_active boolean;
    v_driver_available boolean;

    v_pickup_address text;

    v_delivery_id uuid;
    v_delivery_status public.delivery_status;
begin

    -- ========================================================
    -- AUTHENTICATION
    -- ========================================================

    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;


    -- ========================================================
    -- LOCK OFFER
    -- ========================================================

    select
        o.order_id,
        o.business_id,
        o.driver_profile_id,
        o.vehicle_id,
        o.pickup_location_id,
        o.status,
        o.expires_at

    into
        v_order_id,
        v_business_id,
        v_offer_driver_id,
        v_vehicle_id,
        v_pickup_location_id,
        v_offer_status,
        v_expires_at

    from public.delivery_offers o
    where o.id = p_offer_id
    for update;


    if not found then
        raise exception 'Delivery offer not found';
    end if;


    if v_offer_driver_id <> v_actor_id then
        raise exception
            'You do not own this delivery offer';
    end if;


    if v_offer_status <>
       'pending'::public.delivery_offer_status then
        raise exception
            'Delivery offer is no longer pending';
    end if;


    if v_expires_at <= now() then
        raise exception
            'Delivery offer has expired';
    end if;


    -- ========================================================
    -- LOCK ORDER
    --
    -- This is what serializes competing driver acceptances.
    -- ========================================================

    select
        o.status,
        o.delivery_address

    into
        v_order_status,
        v_delivery_address

    from public.orders o

    where o.id = v_order_id
      and o.business_id = v_business_id

    for update;


    if not found then
        raise exception 'Order not found';
    end if;


    if v_order_status <>
       'ready'::public.order_status then
        raise exception
            'Order is no longer available';
    end if;


    if v_delivery_address is null
       or btrim(v_delivery_address) = '' then
        raise exception
            'Order does not have a delivery address';
    end if;


    -- ========================================================
    -- LOCK AND REVALIDATE DRIVER
    -- ========================================================

    select
        dp.verification_status,
        dp.is_active,
        dp.is_available

    into
        v_driver_verification,
        v_driver_active,
        v_driver_available

    from public.driver_profiles dp

    where dp.profile_id = v_actor_id

    for update;


    if not found then
        raise exception
            'Driver profile not found';
    end if;


    if v_driver_verification <>
       'verified'::public.driver_verification_status then
        raise exception
            'Driver is not verified';
    end if;


    if v_driver_active is not true then
        raise exception
            'Driver profile is inactive';
    end if;


    if v_driver_available is not true then
        raise exception
            'Driver is no longer available';
    end if;


    if not exists (
        select 1
        from public.profiles p
        where p.id = v_actor_id
          and p.is_active is true
          and p.role =
              'driver'::public.user_role
    ) then
        raise exception
            'Active driver account required';
    end if;


    -- ========================================================
    -- REVALIDATE OFFER VEHICLE
    -- ========================================================

    if not exists (
        select 1
        from public.driver_vehicles dv
        where dv.id = v_vehicle_id
          and dv.driver_profile_id = v_actor_id
          and dv.is_active is true
    ) then
        raise exception
            'Offer vehicle is no longer available';
    end if;


    -- ========================================================
    -- REVALIDATE PICKUP LOCATION
    -- ========================================================

    select
        bl.address

    into
        v_pickup_address

    from public.business_locations bl

    where bl.id = v_pickup_location_id
      and bl.business_id = v_business_id
      and bl.is_active is true
      and bl.is_pickup_enabled is true;


    if not found then
        raise exception
            'Pickup location is unavailable';
    end if;


    -- ========================================================
    -- DRIVER MUST NOT HAVE ANOTHER ACTIVE DELIVERY
    -- ========================================================

    if exists (
        select 1
        from public.deliveries d
        where d.driver_profile_id = v_actor_id
          and d.status in (
              'assigned'::public.delivery_status,
              'accepted'::public.delivery_status,
              'arrived_at_pickup'::public.delivery_status,
              'picked_up'::public.delivery_status,
              'on_the_way'::public.delivery_status
          )
    ) then
        raise exception
            'Driver already has an active delivery';
    end if;


    -- ========================================================
    -- WINNING OFFER
    -- ========================================================

    update public.delivery_offers o
    set
        status =
            'accepted'::public.delivery_offer_status,
        responded_at = now(),
        updated_at = now()
    where o.id = p_offer_id;


    -- ========================================================
    -- LOCK EXISTING DELIVERY IF PRESENT
    -- ========================================================

    select
        d.id,
        d.status

    into
        v_delivery_id,
        v_delivery_status

    from public.deliveries d

    where d.order_id = v_order_id

    for update;


    -- ========================================================
    -- CREATE OR REUSE DELIVERY
    -- ========================================================

    if not found then

        insert into public.deliveries (
            order_id,
            business_id,
            driver_profile_id,
            vehicle_id,
            status,
            pickup_location_id,
            pickup_address,
            dropoff_address,
            assigned_at
        )
        values (
            v_order_id,
            v_business_id,
            v_actor_id,
            v_vehicle_id,
            'assigned'::public.delivery_status,
            v_pickup_location_id,
            v_pickup_address,
            v_delivery_address,
            now()
        )
        returning id
        into v_delivery_id;


    else

        if v_delivery_status <>
           'waiting'::public.delivery_status then
            raise exception
                'Delivery is no longer available for assignment';
        end if;


        update public.deliveries d
        set
            driver_profile_id = v_actor_id,
            vehicle_id = v_vehicle_id,
            status =
                'assigned'::public.delivery_status,
            pickup_location_id =
                v_pickup_location_id,
            pickup_address =
                v_pickup_address,
            dropoff_address =
                v_delivery_address,
            assigned_at = now(),
            accepted_at = null,
            arrived_at_pickup_at = null,
            picked_up_at = null,
            completed_at = null,
            cancelled_at = null,
            updated_at = now()
        where d.id = v_delivery_id;

    end if;


    -- ========================================================
    -- OFFER ACCEPTANCE ALSO COUNTS AS DELIVERY ACCEPTANCE
    --
    -- assigned -> accepted
    --
    -- Migration 027 automatically records both delivery
    -- status changes.
    -- ========================================================

    update public.deliveries d
    set
        status =
            'accepted'::public.delivery_status,
        accepted_at = now(),
        updated_at = now()
    where d.id = v_delivery_id;


    -- ========================================================
    -- DRIVER BECOMES UNAVAILABLE
    -- ========================================================

    update public.driver_profiles dp
    set
        is_available = false,
        updated_at = now()
    where dp.profile_id = v_actor_id;


    -- ========================================================
    -- ORDER READY -> DRIVER_ASSIGNED
    --
    -- Order trigger automatically cancels all remaining
    -- pending offers.
    -- ========================================================

    update public.orders o
    set
        status =
            'driver_assigned'::public.order_status,
        updated_at = now()
    where o.id = v_order_id;


    insert into public.order_status_history (
        order_id,
        from_status,
        to_status,
        changed_by
    )
    values (
        v_order_id,
        'ready'::public.order_status,
        'driver_assigned'::public.order_status,
        v_actor_id
    );


    return v_delivery_id;

end;
$function$;


alter function public.accept_delivery_offer(uuid)
owner to postgres;


-- ============================================================
-- 11. BUSINESS / ADMIN OFFER CANCELLATION
-- ============================================================

create or replace function
public.cancel_delivery_offers_for_order(
    p_order_id uuid
)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_actor_id uuid;
    v_business_id uuid;

    v_is_business_member boolean := false;
    v_is_admin boolean := false;

    v_cancelled_count integer;
begin

    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;


    select
        o.business_id
    into
        v_business_id
    from public.orders o
    where o.id = p_order_id;


    if not found then
        raise exception 'Order not found';
    end if;


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
          and p.role =
              'admin'::public.user_role
          and p.is_active is true
    )
    into v_is_admin;


    if not v_is_business_member
       and not v_is_admin then
        raise exception
            'Not authorized to cancel delivery offers';
    end if;


    update public.delivery_offers o
    set
        status =
            'cancelled'::public.delivery_offer_status,
        updated_at = now()
    where o.order_id = p_order_id
      and o.status =
          'pending'::public.delivery_offer_status;


    get diagnostics
        v_cancelled_count = row_count;


    return v_cancelled_count;

end;
$function$;


alter function
public.cancel_delivery_offers_for_order(uuid)
owner to postgres;


-- ============================================================
-- 12. RPC EXECUTION PRIVILEGES
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


revoke all
on function public.get_my_delivery_offers(integer)
from public, anon;


grant execute
on function public.get_my_delivery_offers(integer)
to authenticated;


revoke all
on function public.reject_delivery_offer(uuid)
from public, anon;


grant execute
on function public.reject_delivery_offer(uuid)
to authenticated;


revoke all
on function public.accept_delivery_offer(uuid)
from public, anon;


grant execute
on function public.accept_delivery_offer(uuid)
to authenticated;


revoke all
on function
public.cancel_delivery_offers_for_order(uuid)
from public, anon;


grant execute
on function
public.cancel_delivery_offers_for_order(uuid)
to authenticated;


-- ============================================================
-- 13. REASSERT SENSITIVE WRITE BOUNDARIES
-- ============================================================

revoke insert, update, delete
on public.delivery_offers
from anon, authenticated;

revoke insert, update, delete
on public.deliveries
from anon, authenticated;

revoke insert, update, delete
on public.driver_profiles
from anon, authenticated;

revoke insert, update, delete
on public.driver_vehicles
from anon, authenticated;


-- ============================================================
-- END MIGRATION 029
-- ============================================================
