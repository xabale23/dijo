-- ============================================================
-- DIJO
-- Migration 023a: Delivery Relationship Integrity
--
-- Purpose:
-- 1. Ensure an assigned vehicle belongs to the assigned driver.
-- 2. Ensure a pickup location belongs to the delivery business.
--
-- This migration hardens relationships discovered during
-- controlled integrity testing of Migration 023.
-- ============================================================


-- ============================================================
-- 1. DRIVER VEHICLE OWNERSHIP INTEGRITY
-- ============================================================

-- A composite foreign key needs a UNIQUE/PRIMARY target.
-- This makes (vehicle id, driver owner) a valid FK target.

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'driver_vehicles_id_driver_profile_id_key'
          and conrelid = 'public.driver_vehicles'::regclass
    ) then
        alter table public.driver_vehicles
            add constraint driver_vehicles_id_driver_profile_id_key
            unique (id, driver_profile_id);
    end if;
end
$$;


-- Remove the old vehicle-only foreign key.
--
-- That FK proved only that the vehicle existed.
-- It did NOT prove that the vehicle belonged to the
-- driver assigned to the delivery.

alter table public.deliveries
    drop constraint if exists deliveries_vehicle_id_fkey;


-- Create the stronger relationship:
--
-- delivery.vehicle_id + delivery.driver_profile_id
-- must match an actual vehicle + its owner.
--
-- If a vehicle is deleted, only vehicle_id is cleared.
-- The delivery may remain assigned to the driver.

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'deliveries_vehicle_driver_fkey'
          and conrelid = 'public.deliveries'::regclass
    ) then
        alter table public.deliveries
            add constraint deliveries_vehicle_driver_fkey
            foreign key (
                vehicle_id,
                driver_profile_id
            )
            references public.driver_vehicles (
                id,
                driver_profile_id
            )
            on delete set null (vehicle_id);
    end if;
end
$$;


-- ============================================================
-- 2. PICKUP LOCATION BUSINESS INTEGRITY
-- ============================================================

-- A composite foreign key requires a UNIQUE/PRIMARY target.

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'business_locations_id_business_id_key'
          and conrelid = 'public.business_locations'::regclass
    ) then
        alter table public.business_locations
            add constraint business_locations_id_business_id_key
            unique (id, business_id);
    end if;
end
$$;


-- Remove the old location-only FK.
--
-- It proved that a location existed, but did not prove
-- that it belonged to the same business as the delivery.

alter table public.deliveries
    drop constraint if exists deliveries_pickup_location_id_fkey;


-- Require pickup location and delivery to belong
-- to exactly the same business.

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'deliveries_pickup_location_business_fkey'
          and conrelid = 'public.deliveries'::regclass
    ) then
        alter table public.deliveries
            add constraint deliveries_pickup_location_business_fkey
            foreign key (
                pickup_location_id,
                business_id
            )
            references public.business_locations (
                id,
                business_id
            )
            on delete restrict;
    end if;
end
$$;
