-- ============================================================
-- DIJO
-- Migration: 023_driver_delivery_core.sql
--
-- Purpose:
-- Establish the core driver and physical-delivery data model.
--
-- This migration intentionally DOES NOT implement:
--   - driver dispatch
--   - delivery acceptance
--   - live GPS tracking
--   - delivery lifecycle mutation RPCs
--   - driver payouts
--
-- Those workflows will be added only after this foundation
-- has been verified and hardened.
-- ============================================================


-- ============================================================
-- 1. DRIVER VERIFICATION STATUS
-- ============================================================

do $$
begin
    if not exists (
        select 1
        from pg_type t
        join pg_namespace n
          on n.oid = t.typnamespace
        where n.nspname = 'public'
          and t.typname = 'driver_verification_status'
    ) then
        create type public.driver_verification_status as enum (
            'pending',
            'verified',
            'rejected',
            'suspended'
        );
    end if;
end;
$$;


-- ============================================================
-- 2. VEHICLE TYPE
-- ============================================================

do $$
begin
    if not exists (
        select 1
        from pg_type t
        join pg_namespace n
          on n.oid = t.typnamespace
        where n.nspname = 'public'
          and t.typname = 'vehicle_type'
    ) then
        create type public.vehicle_type as enum (
            'bicycle',
            'motorcycle',
            'car',
            'van'
        );
    end if;
end;
$$;


-- ============================================================
-- 3. DRIVER PROFILES
-- ============================================================
--
-- Authentication and basic identity remain in public.profiles.
-- This table contains DRIVER-SPECIFIC operational information.
-- ============================================================

create table if not exists public.driver_profiles (
    profile_id uuid primary key
        references public.profiles(id)
        on delete cascade,

    verification_status public.driver_verification_status
        not null
        default 'pending',

    is_active boolean
        not null
        default true,

    is_available boolean
        not null
        default false,

    last_known_latitude double precision,
    last_known_longitude double precision,

    last_known_location geography(Point, 4326)
        generated always as (
            case
                when last_known_latitude is not null
                 and last_known_longitude is not null
                then
                    ST_SetSRID(
                        ST_MakePoint(
                            last_known_longitude,
                            last_known_latitude
                        ),
                        4326
                    )::geography
                else null
            end
        ) stored,

    location_updated_at timestamptz,

    created_at timestamptz
        not null
        default now(),

    updated_at timestamptz
        not null
        default now(),

    constraint driver_profiles_coordinate_pair
        check (
            (
                last_known_latitude is null
                and last_known_longitude is null
            )
            or
            (
                last_known_latitude is not null
                and last_known_longitude is not null
            )
        ),

    constraint driver_profiles_latitude_range
        check (
            last_known_latitude is null
            or last_known_latitude between -90 and 90
        ),

    constraint driver_profiles_longitude_range
        check (
            last_known_longitude is null
            or last_known_longitude between -180 and 180
        )
);


-- ============================================================
-- 4. DRIVER VEHICLES
-- ============================================================

create table if not exists public.driver_vehicles (
    id uuid primary key
        default gen_random_uuid(),

    driver_profile_id uuid
        not null
        references public.driver_profiles(profile_id)
        on delete cascade,

    vehicle_type public.vehicle_type
        not null,

    make text,
    model text,
    registration_number text,
    colour text,

    is_primary boolean
        not null
        default false,

    is_active boolean
        not null
        default true,

    created_at timestamptz
        not null
        default now(),

    updated_at timestamptz
        not null
        default now(),

    constraint driver_vehicles_make_nonblank
        check (
            make is null
            or btrim(make) <> ''
        ),

    constraint driver_vehicles_model_nonblank
        check (
            model is null
            or btrim(model) <> ''
        ),

    constraint driver_vehicles_registration_nonblank
        check (
            registration_number is null
            or btrim(registration_number) <> ''
        ),

    constraint driver_vehicles_colour_nonblank
        check (
            colour is null
            or btrim(colour) <> ''
        )
);


-- ============================================================
-- 5. DELIVERIES
-- ============================================================
--
-- Order = commercial transaction.
-- Delivery = physical fulfilment job.
--
-- business_id is intentionally duplicated here so that the
-- composite FK can enforce:
--
-- deliveries(order_id, business_id)
--     -> orders(id, business_id)
--
-- This prevents cross-business delivery corruption.
-- ============================================================

create table if not exists public.deliveries (
    id uuid primary key
        default gen_random_uuid(),

    order_id uuid
        not null,

    business_id uuid
        not null,

    driver_profile_id uuid
        references public.driver_profiles(profile_id)
        on delete set null,

    vehicle_id uuid
        references public.driver_vehicles(id)
        on delete set null,

    status public.delivery_status
        not null
        default 'waiting',

    pickup_location_id uuid
        references public.business_locations(id)
        on delete restrict,

    pickup_address text,

    dropoff_address text
        not null,

    pickup_latitude double precision,
    pickup_longitude double precision,

    dropoff_latitude double precision,
    dropoff_longitude double precision,

    pickup_coordinates geography(Point, 4326)
        generated always as (
            case
                when pickup_latitude is not null
                 and pickup_longitude is not null
                then
                    ST_SetSRID(
                        ST_MakePoint(
                            pickup_longitude,
                            pickup_latitude
                        ),
                        4326
                    )::geography
                else null
            end
        ) stored,

    dropoff_coordinates geography(Point, 4326)
        generated always as (
            case
                when dropoff_latitude is not null
                 and dropoff_longitude is not null
                then
                    ST_SetSRID(
                        ST_MakePoint(
                            dropoff_longitude,
                            dropoff_latitude
                        ),
                        4326
                    )::geography
                else null
            end
        ) stored,

    assigned_at timestamptz,
    accepted_at timestamptz,
    arrived_at_pickup_at timestamptz,
    picked_up_at timestamptz,
    completed_at timestamptz,
    cancelled_at timestamptz,

    created_at timestamptz
        not null
        default now(),

    updated_at timestamptz
        not null
        default now(),

    constraint deliveries_order_business_fkey
        foreign key (
            order_id,
            business_id
        )
        references public.orders(
            id,
            business_id
        )
        on delete cascade,

    constraint deliveries_order_unique
        unique (order_id),

    constraint deliveries_dropoff_address_nonblank
        check (
            btrim(dropoff_address) <> ''
        ),

    constraint deliveries_pickup_address_nonblank
        check (
            pickup_address is null
            or btrim(pickup_address) <> ''
        ),

    constraint deliveries_pickup_coordinate_pair
        check (
            (
                pickup_latitude is null
                and pickup_longitude is null
            )
            or
            (
                pickup_latitude is not null
                and pickup_longitude is not null
            )
        ),

    constraint deliveries_dropoff_coordinate_pair
        check (
            (
                dropoff_latitude is null
                and dropoff_longitude is null
            )
            or
            (
                dropoff_latitude is not null
                and dropoff_longitude is not null
            )
        ),

    constraint deliveries_pickup_latitude_range
        check (
            pickup_latitude is null
            or pickup_latitude between -90 and 90
        ),

    constraint deliveries_pickup_longitude_range
        check (
            pickup_longitude is null
            or pickup_longitude between -180 and 180
        ),

    constraint deliveries_dropoff_latitude_range
        check (
            dropoff_latitude is null
            or dropoff_latitude between -90 and 90
        ),

    constraint deliveries_dropoff_longitude_range
        check (
            dropoff_longitude is null
            or dropoff_longitude between -180 and 180
        )
);


-- ============================================================
-- 6. INDEXES
-- ============================================================

create index if not exists
    driver_profiles_verification_status_idx
on public.driver_profiles (
    verification_status
);

create index if not exists
    driver_profiles_available_idx
on public.driver_profiles (
    is_available,
    is_active
);

create index if not exists
    driver_profiles_last_known_location_idx
on public.driver_profiles
using gist (
    last_known_location
);


create index if not exists
    driver_vehicles_driver_profile_id_idx
on public.driver_vehicles (
    driver_profile_id
);

create unique index if not exists
    driver_vehicles_one_primary_per_driver_idx
on public.driver_vehicles (
    driver_profile_id
)
where is_primary is true
  and is_active is true;


create index if not exists
    deliveries_business_id_idx
on public.deliveries (
    business_id
);

create index if not exists
    deliveries_driver_profile_id_idx
on public.deliveries (
    driver_profile_id
);

create index if not exists
    deliveries_status_created_idx
on public.deliveries (
    status,
    created_at
);

create index if not exists
    deliveries_business_status_created_idx
on public.deliveries (
    business_id,
    status,
    created_at
);

create index if not exists
    deliveries_driver_status_created_idx
on public.deliveries (
    driver_profile_id,
    status,
    created_at
);

create index if not exists
    deliveries_pickup_coordinates_idx
on public.deliveries
using gist (
    pickup_coordinates
);

create index if not exists
    deliveries_dropoff_coordinates_idx
on public.deliveries
using gist (
    dropoff_coordinates
);


-- ============================================================
-- 7. UPDATED_AT TRIGGERS
-- ============================================================

drop trigger if exists
    driver_profiles_set_updated_at
on public.driver_profiles;

create trigger driver_profiles_set_updated_at
before update
on public.driver_profiles
for each row
execute function public.set_updated_at();


drop trigger if exists
    driver_vehicles_set_updated_at
on public.driver_vehicles;

create trigger driver_vehicles_set_updated_at
before update
on public.driver_vehicles
for each row
execute function public.set_updated_at();


drop trigger if exists
    deliveries_set_updated_at
on public.deliveries;

create trigger deliveries_set_updated_at
before update
on public.deliveries
for each row
execute function public.set_updated_at();


-- ============================================================
-- 8. ROW LEVEL SECURITY
-- ============================================================

alter table public.driver_profiles
    enable row level security;

alter table public.driver_vehicles
    enable row level security;

alter table public.deliveries
    enable row level security;


-- ============================================================
-- 9. DRIVER PROFILE SELECT POLICY
-- ============================================================

drop policy if exists
    "Drivers can view own driver profile"
on public.driver_profiles;

create policy
    "Drivers can view own driver profile"
on public.driver_profiles
for select
to authenticated
using (
    profile_id = auth.uid()
);


-- ============================================================
-- 10. DRIVER VEHICLE SELECT POLICY
-- ============================================================

drop policy if exists
    "Drivers can view own vehicles"
on public.driver_vehicles;

create policy
    "Drivers can view own vehicles"
on public.driver_vehicles
for select
to authenticated
using (
    driver_profile_id = auth.uid()
);


-- ============================================================
-- 11. DELIVERY CUSTOMER SELECT POLICY
-- ============================================================

drop policy if exists
    "Customers can view own deliveries"
on public.deliveries;

create policy
    "Customers can view own deliveries"
on public.deliveries
for select
to authenticated
using (
    exists (
        select 1
        from public.orders o
        where o.id = deliveries.order_id
          and o.customer_id = auth.uid()
    )
);


-- ============================================================
-- 12. DELIVERY BUSINESS MEMBER SELECT POLICY
-- ============================================================

drop policy if exists
    "Business members can view own deliveries"
on public.deliveries;

create policy
    "Business members can view own deliveries"
on public.deliveries
for select
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = deliveries.business_id
          and bm.profile_id = auth.uid()
          and bm.is_active is true
    )
);


-- ============================================================
-- 13. ASSIGNED DRIVER SELECT POLICY
-- ============================================================

drop policy if exists
    "Assigned drivers can view own deliveries"
on public.deliveries;

create policy
    "Assigned drivers can view own deliveries"
on public.deliveries
for select
to authenticated
using (
    driver_profile_id = auth.uid()
);


-- ============================================================
-- 14. PRIVILEGE HARDENING
-- ============================================================
--
-- For now all delivery/driver writes remain server-controlled.
--
-- Future secure RPCs will explicitly handle:
--   driver onboarding
--   vehicle registration
--   availability
--   assignment
--   delivery lifecycle transitions
-- ============================================================

revoke all
on table public.driver_profiles
from anon;

revoke all
on table public.driver_vehicles
from anon;

revoke all
on table public.deliveries
from anon;


revoke insert, update, delete
on table public.driver_profiles
from authenticated;

revoke insert, update, delete
on table public.driver_vehicles
from authenticated;

revoke insert, update, delete
on table public.deliveries
from authenticated;


grant select
on table public.driver_profiles
to authenticated;

grant select
on table public.driver_vehicles
to authenticated;

grant select
on table public.deliveries
to authenticated;
