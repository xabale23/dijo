-- ============================================================
-- DIJO Migration 015
-- Business locations and geospatial foundation
-- ============================================================


-- ============================================================
-- 1. BUSINESS LOCATIONS TABLE
-- ============================================================

create table if not exists public.business_locations (
    id uuid primary key default gen_random_uuid(),

    business_id uuid not null
        references public.businesses(id)
        on delete cascade,

    name text not null default 'Main Location',

    address text,
    city text,
    province text,
    postal_code text,

    latitude double precision,
    longitude double precision,

    coordinates geography(Point, 4326)
        generated always as (
            case
                when latitude is not null
                 and longitude is not null
                then
                    ST_SetSRID(
                        ST_MakePoint(longitude, latitude),
                        4326
                    )::geography
                else null
            end
        ) stored,

    is_primary boolean not null default false,
    is_pickup_enabled boolean not null default true,
    is_delivery_enabled boolean not null default true,
    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint business_locations_name_not_blank
        check (length(trim(name)) > 0),

    constraint business_locations_coordinate_pair_check
        check (
            (latitude is null and longitude is null)
            or
            (latitude is not null and longitude is not null)
        ),

    constraint business_locations_latitude_check
        check (
            latitude is null
            or latitude between -90 and 90
        ),

    constraint business_locations_longitude_check
        check (
            longitude is null
            or longitude between -180 and 180
        )
);


-- ============================================================
-- 2. INDEXES
-- ============================================================

create index if not exists business_locations_business_id_idx
    on public.business_locations(business_id);

create index if not exists business_locations_coordinates_gix
    on public.business_locations
    using gist(coordinates);


-- Only one primary location may exist per business.

create unique index if not exists
    business_locations_one_primary_per_business_idx
on public.business_locations(business_id)
where is_primary = true;


-- ============================================================
-- 3. UPDATED_AT TRIGGER
-- ============================================================

drop trigger if exists business_locations_set_updated_at
    on public.business_locations;

create trigger business_locations_set_updated_at
before update on public.business_locations
for each row
execute function public.set_updated_at();


-- ============================================================
-- 4. ENABLE ROW LEVEL SECURITY
-- ============================================================

alter table public.business_locations
enable row level security;


-- ============================================================
-- 5. REMOVE OLD POLICIES IF MIGRATION IS REPLAYED
-- ============================================================

drop policy if exists
    "Authenticated users can view active business locations"
on public.business_locations;

drop policy if exists
    "Members can view own business locations"
on public.business_locations;

drop policy if exists
    "Owners and managers can create business locations"
on public.business_locations;

drop policy if exists
    "Owners and managers can update business locations"
on public.business_locations;

drop policy if exists
    "Owners and managers can delete business locations"
on public.business_locations;


-- ============================================================
-- 6. CUSTOMER / AUTHENTICATED LOCATION VISIBILITY
-- ============================================================

create policy
    "Authenticated users can view active business locations"
on public.business_locations
for select
to authenticated
using (
    is_active = true
    and exists (
        select 1
        from public.businesses b
        where b.id = business_locations.business_id
          and b.is_active = true
    )
);


-- ============================================================
-- 7. BUSINESS MEMBERS CAN VIEW THEIR OWN LOCATIONS
-- ============================================================

create policy
    "Members can view own business locations"
on public.business_locations
for select
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = business_locations.business_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
    )
);


-- ============================================================
-- 8. OWNERS / MANAGERS CAN CREATE LOCATIONS
-- ============================================================

create policy
    "Owners and managers can create business locations"
on public.business_locations
for insert
to authenticated
with check (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = business_locations.business_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
);


-- ============================================================
-- 9. OWNERS / MANAGERS CAN UPDATE LOCATIONS
-- ============================================================

create policy
    "Owners and managers can update business locations"
on public.business_locations
for update
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = business_locations.business_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
)
with check (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = business_locations.business_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
);


-- ============================================================
-- 10. OWNERS / MANAGERS CAN DELETE LOCATIONS
-- ============================================================

create policy
    "Owners and managers can delete business locations"
on public.business_locations
for delete
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = business_locations.business_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
);


-- ============================================================
-- 11. TABLE PRIVILEGES
-- ============================================================

revoke all on table public.business_locations from anon;

grant select on table public.business_locations
to authenticated;

grant insert (
    business_id,
    name,
    address,
    city,
    province,
    postal_code,
    latitude,
    longitude,
    is_primary,
    is_pickup_enabled,
    is_delivery_enabled
)
on public.business_locations
to authenticated;

grant update (
    name,
    address,
    city,
    province,
    postal_code,
    latitude,
    longitude,
    is_primary,
    is_pickup_enabled,
    is_delivery_enabled
)
on public.business_locations
to authenticated;

grant delete on table public.business_locations
to authenticated;


-- ============================================================
-- 12. BACKFILL EXISTING BUSINESS LOCATION DATA
--
-- Keeps current businesses compatible while introducing
-- business_locations as DIJO's future canonical location model.
-- ============================================================

insert into public.business_locations (
    business_id,
    name,
    address,
    city,
    province,
    postal_code,
    latitude,
    longitude,
    is_primary,
    is_pickup_enabled,
    is_delivery_enabled,
    is_active
)
select
    b.id,
    'Main Location',
    b.address,
    b.city,
    b.province,
    b.postal_code,
    b.latitude,
    b.longitude,
    true,
    true,
    true,
    b.is_active
from public.businesses b
where
    (
        b.address is not null
        or b.city is not null
        or b.province is not null
        or b.postal_code is not null
        or (
            b.latitude is not null
            and b.longitude is not null
        )
    )
    and not exists (
        select 1
        from public.business_locations bl
        where bl.business_id = b.id
    );
