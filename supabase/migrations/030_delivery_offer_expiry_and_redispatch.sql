-- ============================================================
-- DIJO
-- Migration 030: Delivery Offer Expiry & Redispatch
-- ============================================================
--
-- PURPOSE
-- -------
-- Add a controlled dispatch-attempt layer around delivery
-- offers so DIJO can:
--
-- 1. Expire unanswered offers.
-- 2. Know when an order needs another dispatch attempt.
-- 3. Prevent overlapping dispatch batches for one order.
-- 4. Track dispatch attempt numbers.
-- 5. Increase search radius progressively.
-- 6. Avoid repeatedly offering the same order to the same
--    driver.
-- 7. Preserve historical offers and attempts.
-- 8. Let a future backend/WhatsApp worker safely request the
--    next batch of drivers.
--
-- IMPORTANT
-- ---------
-- This migration provides deterministic database primitives.
-- Actual timed execution/notification orchestration can later
-- be driven by DIJO's backend worker.
--
-- ============================================================


-- ============================================================
-- 1. DISPATCH ATTEMPT STATUS
-- ============================================================

do $$
begin
    if not exists (
        select 1
        from pg_type t
        join pg_namespace n
          on n.oid = t.typnamespace
        where n.nspname = 'public'
          and t.typname =
              'delivery_dispatch_attempt_status'
    ) then
        create type public.delivery_dispatch_attempt_status
        as enum (
            'active',
            'assigned',
            'exhausted',
            'cancelled'
        );
    end if;
end
$$;


-- ============================================================
-- 2. DELIVERY DISPATCH ATTEMPTS
-- ============================================================

create table if not exists
public.delivery_dispatch_attempts (
    id uuid primary key default gen_random_uuid(),

    order_id uuid not null,
    business_id uuid not null,
    pickup_location_id uuid not null,

    attempt_number integer not null,

    status public.delivery_dispatch_attempt_status
        not null
        default 'active'::public.delivery_dispatch_attempt_status,

    radius_metres double precision not null,

    max_drivers integer not null,

    offers_created integer not null default 0,

    offer_ttl_seconds integer not null,

    location_max_age_minutes integer not null,

    started_at timestamptz not null default now(),

    expires_at timestamptz null,

    completed_at timestamptz null,

    created_by uuid null,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint delivery_dispatch_attempts_order_business_fkey
        foreign key (
            order_id,
            business_id
        )
        references public.orders (
            id,
            business_id
        )
        on delete cascade,

    constraint delivery_dispatch_attempts_pickup_business_fkey
        foreign key (
            pickup_location_id,
            business_id
        )
        references public.business_locations (
            id,
            business_id
        )
        on delete restrict,

    constraint delivery_dispatch_attempts_created_by_fkey
        foreign key (created_by)
        references public.profiles (id)
        on delete set null,

    constraint delivery_dispatch_attempts_order_attempt_unique
        unique (
            order_id,
            attempt_number
        ),

    constraint delivery_dispatch_attempt_number_positive
        check (
            attempt_number >= 1
        ),

    constraint delivery_dispatch_radius_valid
        check (
            radius_metres > 0
            and radius_metres <= 50000
        ),

    constraint delivery_dispatch_max_drivers_valid
        check (
            max_drivers >= 1
            and max_drivers <= 20
        ),

    constraint delivery_dispatch_offers_created_valid
        check (
            offers_created >= 0
            and offers_created <= max_drivers
        ),

    constraint delivery_dispatch_ttl_valid
        check (
            offer_ttl_seconds >= 30
            and offer_ttl_seconds <= 600
        ),

    constraint delivery_dispatch_location_age_valid
        check (
            location_max_age_minutes >= 1
            and location_max_age_minutes <= 120
        )
);


-- ============================================================
-- 3. DISPATCH ATTEMPT INDEXES
-- ============================================================

create index if not exists
delivery_dispatch_attempts_order_idx
on public.delivery_dispatch_attempts (
    order_id,
    attempt_number desc
);


create index if not exists
delivery_dispatch_attempts_business_status_idx
on public.delivery_dispatch_attempts (
    business_id,
    status,
    started_at desc
);


create index if not exists
delivery_dispatch_attempts_status_expiry_idx
on public.delivery_dispatch_attempts (
    status,
    expires_at
);


-- Only one dispatch batch may be active for an order.

create unique index if not exists
delivery_dispatch_attempts_one_active_per_order_idx
on public.delivery_dispatch_attempts (
    order_id
)
where status =
    'active'::public.delivery_dispatch_attempt_status;


-- ============================================================
-- 4. LINK OFFERS TO DISPATCH ATTEMPTS
-- ============================================================

alter table public.delivery_offers
add column if not exists
dispatch_attempt_id uuid null;


do $$
begin
    if not exists (
        select 1
        from pg_constraint c
        where c.conrelid =
              'public.delivery_offers'::regclass
          and c.conname =
              'delivery_offers_dispatch_attempt_fkey'
    ) then

        alter table public.delivery_offers
        add constraint
        delivery_offers_dispatch_attempt_fkey
        foreign key (dispatch_attempt_id)
        references public.delivery_dispatch_attempts (id)
        on delete set null;

    end if;
end
$$;


create index if not exists
delivery_offers_dispatch_attempt_idx
on public.delivery_offers (
    dispatch_attempt_id,
    status
);


-- ============================================================
-- 5. RLS
-- ============================================================

alter table public.delivery_dispatch_attempts
enable row level security;


drop policy if exists
"Business members can view dispatch attempts"
on public.delivery_dispatch_attempts;


create policy
"Business members can view dispatch attempts"
on public.delivery_dispatch_attempts
for select
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id =
              delivery_dispatch_attempts.business_id
          and bm.profile_id = auth.uid()
          and bm.is_active is true
    )
);


drop policy if exists
"Admins can view all dispatch attempts"
on public.delivery_dispatch_attempts;


create policy
"Admins can view all dispatch attempts"
on public.delivery_dispatch_attempts
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
-- 6. TABLE PRIVILEGES
-- ============================================================

revoke all
on public.delivery_dispatch_attempts
from anon;


revoke insert, update, delete
on public.delivery_dispatch_attempts
from authenticated;


grant select
on public.delivery_dispatch_attempts
to authenticated;


-- ============================================================
-- 7. SYNCHRONIZE ATTEMPT STATE FROM OFFER STATUS
-- ============================================================

create or replace function
public.sync_delivery_dispatch_attempt_from_offer()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
begin

    if new.dispatch_attempt_id is null then
        return new;
    end if;


    -- --------------------------------------------------------
    -- A winning offer completes the batch successfully.
    -- --------------------------------------------------------

    if new.status =
       'accepted'::public.delivery_offer_status then

        update public.delivery_dispatch_attempts a
        set
            status =
                'assigned'::public.delivery_dispatch_attempt_status,
            completed_at = coalesce(
                a.completed_at,
                now()
            ),
            updated_at = now()
        where a.id = new.dispatch_attempt_id
          and a.status =
              'active'::public.delivery_dispatch_attempt_status;


        return new;

    end if;


    -- --------------------------------------------------------
    -- Rejected / expired / cancelled offers may exhaust the
    -- batch when no valid pending offer remains.
    -- --------------------------------------------------------

    if new.status in (
        'rejected'::public.delivery_offer_status,
        'expired'::public.delivery_offer_status,
        'cancelled'::public.delivery_offer_status
    ) then

        update public.delivery_dispatch_attempts a
        set
            status =
                'exhausted'::public.delivery_dispatch_attempt_status,
            completed_at = coalesce(
                a.completed_at,
                now()
            ),
            updated_at = now()

        where a.id = new.dispatch_attempt_id

          and a.status =
              'active'::public.delivery_dispatch_attempt_status

          and not exists (
              select 1
              from public.delivery_offers accepted_offer
              where accepted_offer.dispatch_attempt_id = a.id
                and accepted_offer.status =
                    'accepted'::public.delivery_offer_status
          )

          and not exists (
              select 1
              from public.delivery_offers live_offer
              where live_offer.dispatch_attempt_id = a.id
                and live_offer.status =
                    'pending'::public.delivery_offer_status
                and live_offer.expires_at > now()
          );

    end if;


    return new;

end;
$function$;


alter function
public.sync_delivery_dispatch_attempt_from_offer()
owner to postgres;


revoke all
on function
public.sync_delivery_dispatch_attempt_from_offer()
from public, anon, authenticated;


drop trigger if exists
delivery_offers_sync_dispatch_attempt
on public.delivery_offers;


create trigger
delivery_offers_sync_dispatch_attempt
after update of status
on public.delivery_offers
for each row
when (old.status is distinct from new.status)
execute function
public.sync_delivery_dispatch_attempt_from_offer();


-- ============================================================
-- 8. SYNCHRONIZE LATEST ATTEMPT WHEN ORDER LEAVES READY
-- ============================================================
--
-- This also covers manual assignment through Migration 026.
--
-- Only the latest attempt is modified. Older exhausted
-- attempts remain historical records.
-- ============================================================

create or replace function
public.sync_delivery_dispatch_attempt_from_order()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_latest_attempt_id uuid;
begin

    if old.status = 'ready'::public.order_status
       and new.status <> 'ready'::public.order_status then

        select a.id
        into v_latest_attempt_id
        from public.delivery_dispatch_attempts a
        where a.order_id = new.id
        order by a.attempt_number desc
        limit 1;


        if v_latest_attempt_id is not null then

            update public.delivery_dispatch_attempts a
            set
                status =
                    case
                        when new.status =
                             'driver_assigned'::public.order_status
                        then
                            'assigned'::public.delivery_dispatch_attempt_status

                        else
                            'cancelled'::public.delivery_dispatch_attempt_status
                    end,

                completed_at = coalesce(
                    a.completed_at,
                    now()
                ),

                updated_at = now()

            where a.id = v_latest_attempt_id

              and a.status in (
                  'active'::public.delivery_dispatch_attempt_status,
                  'exhausted'::public.delivery_dispatch_attempt_status
              );

        end if;

    end if;


    return new;

end;
$function$;


alter function
public.sync_delivery_dispatch_attempt_from_order()
owner to postgres;


revoke all
on function
public.sync_delivery_dispatch_attempt_from_order()
from public, anon, authenticated;


drop trigger if exists
orders_sync_delivery_dispatch_attempt
on public.orders;


create trigger
orders_sync_delivery_dispatch_attempt
after update of status
on public.orders
for each row
when (old.status is distinct from new.status)
execute function
public.sync_delivery_dispatch_attempt_from_order();


-- ============================================================
-- 9. EXPIRE OLD OFFERS FOR ONE ORDER
-- ============================================================

create or replace function
public.expire_delivery_offers_for_order(
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

    v_expired_count integer;
begin

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


    -- Serialize against assignment / redispatch.

    select
        o.business_id
    into
        v_business_id
    from public.orders o
    where o.id = p_order_id
    for update;


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
          and p.role = 'admin'::public.user_role
          and p.is_active is true
    )
    into v_is_admin;


    if not v_is_business_member
       and not v_is_admin then
        raise exception
            'Not authorized to expire delivery offers';
    end if;


    update public.delivery_offers o
    set
        status =
            'expired'::public.delivery_offer_status,
        updated_at = now()
    where o.order_id = p_order_id
      and o.status =
          'pending'::public.delivery_offer_status
      and o.expires_at <= now();


    get diagnostics
        v_expired_count = row_count;


    -- Defense-in-depth for an active attempt whose offers have
    -- all ceased to be live.

    update public.delivery_dispatch_attempts a
    set
        status =
            'exhausted'::public.delivery_dispatch_attempt_status,
        completed_at = coalesce(
            a.completed_at,
            now()
        ),
        updated_at = now()

    where a.order_id = p_order_id

      and a.status =
          'active'::public.delivery_dispatch_attempt_status

      and not exists (
          select 1
          from public.delivery_offers live_offer
          where live_offer.dispatch_attempt_id = a.id
            and live_offer.status =
                'pending'::public.delivery_offer_status
            and live_offer.expires_at > now()
      )

      and not exists (
          select 1
          from public.delivery_offers accepted_offer
          where accepted_offer.dispatch_attempt_id = a.id
            and accepted_offer.status =
                'accepted'::public.delivery_offer_status
      );


    return v_expired_count;

end;
$function$;


alter function
public.expire_delivery_offers_for_order(uuid)
owner to postgres;


-- ============================================================
-- 10. FIND READY ORDERS THAT NEED DISPATCH
-- ============================================================

create or replace function
public.get_ready_orders_needing_dispatch(
    p_business_id uuid,
    p_limit integer default 20
)
returns table (
    order_id uuid,
    order_number text,
    dispatch_attempts_count integer,
    last_attempt_at timestamptz,
    suggested_radius_metres double precision
)
language plpgsql
security definer
stable
set search_path = ''
as $function$

#variable_conflict use_column

declare
    v_actor_id uuid;
    v_is_business_member boolean := false;
    v_is_admin boolean := false;
begin

    v_actor_id := auth.uid();


    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;


    if p_business_id is null then
        raise exception 'business_id is required';
    end if;


    if p_limit is null
       or p_limit < 1 then
        raise exception
            'limit must be at least 1';
    end if;


    if p_limit > 100 then
        raise exception
            'limit cannot exceed 100';
    end if;


    select exists (
        select 1
        from public.business_members bm
        where bm.business_id = p_business_id
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
            'Not authorized to view dispatchable orders';
    end if;


    return query

    select
        ord.id,
        ord.order_number,

        coalesce(
            attempt_stats.attempt_count,
            0
        )::integer,

        attempt_stats.last_attempt_at,

        (
            case
                when coalesce(
                    attempt_stats.attempt_count,
                    0
                ) + 1 = 1
                    then 3000

                when coalesce(
                    attempt_stats.attempt_count,
                    0
                ) + 1 = 2
                    then 5000

                when coalesce(
                    attempt_stats.attempt_count,
                    0
                ) + 1 = 3
                    then 8000

                when coalesce(
                    attempt_stats.attempt_count,
                    0
                ) + 1 = 4
                    then 12000

                when coalesce(
                    attempt_stats.attempt_count,
                    0
                ) + 1 = 5
                    then 20000

                when coalesce(
                    attempt_stats.attempt_count,
                    0
                ) + 1 = 6
                    then 30000

                else 50000
            end
        )::double precision

    from public.orders ord

    left join lateral (
        select
            count(*)::integer as attempt_count,
            max(a.started_at) as last_attempt_at
        from public.delivery_dispatch_attempts a
        where a.order_id = ord.id
    ) attempt_stats
      on true

    where ord.business_id = p_business_id

      and ord.status =
          'ready'::public.order_status

      and ord.delivery_address is not null

      and btrim(ord.delivery_address) <> ''

      -- No currently-live offer.
      and not exists (
          select 1
          from public.delivery_offers live_offer
          where live_offer.order_id = ord.id
            and live_offer.status =
                'pending'::public.delivery_offer_status
            and live_offer.expires_at > now()
      )

      -- No already-active delivery.
      and not exists (
          select 1
          from public.deliveries d
          where d.order_id = ord.id
            and (
                d.driver_profile_id is not null
                or d.status <>
                   'waiting'::public.delivery_status
            )
      )

    order by
        ord.created_at asc

    limit p_limit;

end;
$function$;


alter function
public.get_ready_orders_needing_dispatch(
    uuid,
    integer
)
owner to postgres;


-- ============================================================
-- 11. CREATE NEXT DISPATCH BATCH
-- ============================================================
--
-- DEFAULT RADIUS PROGRESSION
-- --------------------------
-- Attempt 1 =  3 km
-- Attempt 2 =  5 km
-- Attempt 3 =  8 km
-- Attempt 4 = 12 km
-- Attempt 5 = 20 km
-- Attempt 6 = 30 km
-- Attempt 7+ = 50 km
--
-- A caller may explicitly supply p_radius_metres to override
-- the automatic radius for that attempt.
--
-- Drivers already offered this specific order are excluded
-- from subsequent batches.
--
-- ============================================================

create or replace function
public.create_next_delivery_dispatch_batch(
    p_order_id uuid,
    p_pickup_location_id uuid,
    p_max_drivers integer default 5,
    p_offer_ttl_seconds integer default 120,
    p_location_max_age_minutes integer default 10,
    p_radius_metres double precision default null
)
returns table (
    dispatch_attempt_id uuid,
    attempt_number integer,
    radius_metres double precision,
    offers_created integer,
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

    v_attempt_id uuid;
    v_attempt_number integer;

    v_radius_metres double precision;

    v_driver_ids uuid[];

    v_offer_ids uuid[];
    v_offers_created integer := 0;
    v_batch_expires_at timestamptz;
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


    if p_max_drivers is null
       or p_max_drivers < 1 then
        raise exception
            'max_drivers must be at least 1';
    end if;


    if p_max_drivers > 20 then
        raise exception
            'max_drivers cannot exceed 20';
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


    if p_radius_metres is not null
       and (
           p_radius_metres <= 0
           or p_radius_metres > 50000
       ) then
        raise exception
            'Radius must be greater than zero and no more than 50000 metres';
    end if;


    -- ========================================================
    -- LOCK ORDER
    --
    -- All competing dispatch / assignment actions for this
    -- order serialize through this row.
    -- ========================================================

    select
        ord.business_id,
        ord.status,
        ord.delivery_address
    into
        v_business_id,
        v_order_status,
        v_delivery_address
    from public.orders ord
    where ord.id = p_order_id
    for update;


    if not found then
        raise exception 'Order not found';
    end if;


    if v_order_status <>
       'ready'::public.order_status then
        raise exception
            'Only ready orders can be dispatched';
    end if;


    if v_delivery_address is null
       or btrim(v_delivery_address) = '' then
        raise exception
            'Order does not have a delivery address';
    end if;


    -- ========================================================
    -- AUTHORIZATION
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
            'Not authorized to create dispatch batches';
    end if;


    -- ========================================================
    -- PICKUP LOCATION
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
    -- EXPIRE OLD PENDING OFFERS
    -- ========================================================

    update public.delivery_offers existing_offer
    set
        status =
            'expired'::public.delivery_offer_status,
        updated_at = now()
    where existing_offer.order_id = p_order_id
      and existing_offer.status =
          'pending'::public.delivery_offer_status
      and existing_offer.expires_at <= now();


    -- ========================================================
    -- CLOSE STALE ACTIVE ATTEMPT
    -- ========================================================

    update public.delivery_dispatch_attempts a
    set
        status =
            'exhausted'::public.delivery_dispatch_attempt_status,
        completed_at = coalesce(
            a.completed_at,
            now()
        ),
        updated_at = now()

    where a.order_id = p_order_id

      and a.status =
          'active'::public.delivery_dispatch_attempt_status

      and not exists (
          select 1
          from public.delivery_offers live_offer
          where live_offer.dispatch_attempt_id = a.id
            and live_offer.status =
                'pending'::public.delivery_offer_status
            and live_offer.expires_at > now()
      )

      and not exists (
          select 1
          from public.delivery_offers accepted_offer
          where accepted_offer.dispatch_attempt_id = a.id
            and accepted_offer.status =
                'accepted'::public.delivery_offer_status
      );


    -- ========================================================
    -- DO NOT CREATE OVERLAPPING LIVE BATCH
    -- ========================================================

    if exists (
        select 1
        from public.delivery_offers live_offer
        where live_offer.order_id = p_order_id
          and live_offer.status =
              'pending'::public.delivery_offer_status
          and live_offer.expires_at > now()
    ) then
        raise exception
            'Order already has live delivery offers';
    end if;


    -- ========================================================
    -- ORDER MUST NOT ALREADY HAVE ACTIVE DELIVERY
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
    -- NEXT ATTEMPT NUMBER
    -- ========================================================

    select
        coalesce(
            max(a.attempt_number),
            0
        ) + 1
    into
        v_attempt_number
    from public.delivery_dispatch_attempts a
    where a.order_id = p_order_id;


    -- ========================================================
    -- SEARCH RADIUS
    -- ========================================================

    if p_radius_metres is not null then

        v_radius_metres := p_radius_metres;

    else

        v_radius_metres :=
            case
                when v_attempt_number = 1 then 3000
                when v_attempt_number = 2 then 5000
                when v_attempt_number = 3 then 8000
                when v_attempt_number = 4 then 12000
                when v_attempt_number = 5 then 20000
                when v_attempt_number = 6 then 30000
                else 50000
            end;

    end if;


    -- ========================================================
    -- CREATE ATTEMPT
    -- ========================================================

    insert into public.delivery_dispatch_attempts (
        order_id,
        business_id,
        pickup_location_id,
        attempt_number,
        status,
        radius_metres,
        max_drivers,
        offers_created,
        offer_ttl_seconds,
        location_max_age_minutes,
        started_at,
        expires_at,
        created_by,
        created_at,
        updated_at
    )
    values (
        p_order_id,
        v_business_id,
        p_pickup_location_id,
        v_attempt_number,
        'active'::public.delivery_dispatch_attempt_status,
        v_radius_metres,
        p_max_drivers,
        0,
        p_offer_ttl_seconds,
        p_location_max_age_minutes,
        now(),
        null,
        v_actor_id,
        now(),
        now()
    )
    returning id
    into v_attempt_id;


    -- ========================================================
    -- DISCOVER CANDIDATES
    --
    -- Request up to 50 from Migration 028, then remove drivers
    -- who have already received an offer for this order.
    --
    -- Finally choose the nearest p_max_drivers.
    -- ========================================================

    select
        array_agg(
            candidate.driver_profile_id
            order by candidate.distance_metres
        )
    into
        v_driver_ids
    from (
        select
            discovered.driver_profile_id,
            discovered.distance_metres

        from public.find_available_drivers(
            p_pickup_location_id,
            v_radius_metres,
            50,
            p_location_max_age_minutes
        ) discovered

        where not exists (
            select 1
            from public.delivery_offers previous_offer
            where previous_offer.order_id = p_order_id
              and previous_offer.driver_profile_id =
                  discovered.driver_profile_id
        )

        order by discovered.distance_metres

        limit p_max_drivers
    ) candidate;


    -- ========================================================
    -- NO ELIGIBLE NEW DRIVER
    -- ========================================================

    if v_driver_ids is null
       or cardinality(v_driver_ids) = 0 then

        update public.delivery_dispatch_attempts a
        set
            status =
                'exhausted'::public.delivery_dispatch_attempt_status,
            completed_at = now(),
            updated_at = now()
        where a.id = v_attempt_id;


        return query

        select
            a.id,
            a.attempt_number,
            a.radius_metres,
            a.offers_created,
            a.expires_at
        from public.delivery_dispatch_attempts a
        where a.id = v_attempt_id;


        return;

    end if;


    -- ========================================================
    -- CREATE OFFERS USING MIGRATION 029
    -- ========================================================

    select
        array_agg(created.offer_id),
        count(*)::integer,
        max(created.expires_at)

    into
        v_offer_ids,
        v_offers_created,
        v_batch_expires_at

    from public.create_delivery_offers(
        p_order_id,
        p_pickup_location_id,
        v_driver_ids,
        p_offer_ttl_seconds,
        p_location_max_age_minutes,
        v_radius_metres
    ) created;


    -- ========================================================
    -- LINK OFFERS TO THIS ATTEMPT
    -- ========================================================

    update public.delivery_offers o
    set
        dispatch_attempt_id = v_attempt_id,
        updated_at = now()
    where o.id = any(v_offer_ids)
      and o.order_id = p_order_id;


    -- ========================================================
    -- FINALIZE ATTEMPT METADATA
    -- ========================================================

    update public.delivery_dispatch_attempts a
    set
        offers_created = v_offers_created,
        expires_at = v_batch_expires_at,
        updated_at = now()
    where a.id = v_attempt_id;


    -- ========================================================
    -- RETURN BATCH
    -- ========================================================

    return query

    select
        a.id,
        a.attempt_number,
        a.radius_metres,
        a.offers_created,
        a.expires_at
    from public.delivery_dispatch_attempts a
    where a.id = v_attempt_id;

end;
$function$;


alter function
public.create_next_delivery_dispatch_batch(
    uuid,
    uuid,
    integer,
    integer,
    integer,
    double precision
)
owner to postgres;


-- ============================================================
-- 12. FUNCTION PRIVILEGES
-- ============================================================

revoke all
on function
public.expire_delivery_offers_for_order(uuid)
from public, anon;


grant execute
on function
public.expire_delivery_offers_for_order(uuid)
to authenticated;


revoke all
on function
public.get_ready_orders_needing_dispatch(
    uuid,
    integer
)
from public, anon;


grant execute
on function
public.get_ready_orders_needing_dispatch(
    uuid,
    integer
)
to authenticated;


revoke all
on function
public.create_next_delivery_dispatch_batch(
    uuid,
    uuid,
    integer,
    integer,
    integer,
    double precision
)
from public, anon;


grant execute
on function
public.create_next_delivery_dispatch_batch(
    uuid,
    uuid,
    integer,
    integer,
    integer,
    double precision
)
to authenticated;


-- ============================================================
-- 13. REASSERT SENSITIVE WRITE BOUNDARIES
-- ============================================================

revoke insert, update, delete
on public.delivery_dispatch_attempts
from anon, authenticated;


revoke insert, update, delete
on public.delivery_offers
from anon, authenticated;


revoke insert, update, delete
on public.deliveries
from anon, authenticated;


revoke insert, update, delete
on public.driver_profiles
from anon, authenticated;


-- ============================================================
-- END MIGRATION 030
-- ============================================================
