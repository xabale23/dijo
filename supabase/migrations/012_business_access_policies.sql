-- ============================================
-- DIJO Migration 012
-- Business Access & Merchant Management Policies
-- ============================================


-- ============================================
-- BUSINESSES
-- ============================================

drop policy if exists "Members can view own businesses"
on public.businesses;

create policy "Members can view own businesses"
on public.businesses
for select
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = businesses.id
          and bm.profile_id = (select auth.uid())
          and bm.is_active = true
    )
);


drop policy if exists "Owners and managers can update business"
on public.businesses;

create policy "Owners and managers can update business"
on public.businesses
for update
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = businesses.id
          and bm.profile_id = (select auth.uid())
          and bm.role in ('owner', 'manager')
          and bm.is_active = true
    )
)
with check (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = businesses.id
          and bm.profile_id = (select auth.uid())
          and bm.role in ('owner', 'manager')
          and bm.is_active = true
    )
);


-- Restrict which business columns authenticated users
-- may modify directly.
--
-- Protected:
-- id
-- owner_id
-- business_type
-- verified
-- is_active
-- created_at
-- updated_at

revoke update
on public.businesses
from authenticated;

grant update (
    name,
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
    is_open
)
on public.businesses
to authenticated;


-- ============================================
-- CATEGORIES
-- ============================================

drop policy if exists "Members can view own business categories"
on public.categories;

create policy "Members can view own business categories"
on public.categories
for select
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = categories.business_id
          and bm.profile_id = (select auth.uid())
          and bm.is_active = true
    )
);


drop policy if exists "Owners and managers can create categories"
on public.categories;

create policy "Owners and managers can create categories"
on public.categories
for insert
to authenticated
with check (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = categories.business_id
          and bm.profile_id = (select auth.uid())
          and bm.role in ('owner', 'manager')
          and bm.is_active = true
    )
);


drop policy if exists "Owners and managers can update categories"
on public.categories;

create policy "Owners and managers can update categories"
on public.categories
for update
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = categories.business_id
          and bm.profile_id = (select auth.uid())
          and bm.role in ('owner', 'manager')
          and bm.is_active = true
    )
)
with check (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = categories.business_id
          and bm.profile_id = (select auth.uid())
          and bm.role in ('owner', 'manager')
          and bm.is_active = true
    )
);


drop policy if exists "Owners and managers can delete categories"
on public.categories;

create policy "Owners and managers can delete categories"
on public.categories
for delete
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = categories.business_id
          and bm.profile_id = (select auth.uid())
          and bm.role in ('owner', 'manager')
          and bm.is_active = true
    )
);


-- ============================================
-- PRODUCTS
-- ============================================

drop policy if exists "Members can view own business products"
on public.products;

create policy "Members can view own business products"
on public.products
for select
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = products.business_id
          and bm.profile_id = (select auth.uid())
          and bm.is_active = true
    )
);


drop policy if exists "Owners and managers can create products"
on public.products;

create policy "Owners and managers can create products"
on public.products
for insert
to authenticated
with check (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = products.business_id
          and bm.profile_id = (select auth.uid())
          and bm.role in ('owner', 'manager')
          and bm.is_active = true
    )
);


drop policy if exists "Owners and managers can update products"
on public.products;

create policy "Owners and managers can update products"
on public.products
for update
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = products.business_id
          and bm.profile_id = (select auth.uid())
          and bm.role in ('owner', 'manager')
          and bm.is_active = true
    )
)
with check (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = products.business_id
          and bm.profile_id = (select auth.uid())
          and bm.role in ('owner', 'manager')
          and bm.is_active = true
    )
);


drop policy if exists "Owners and managers can delete products"
on public.products;

create policy "Owners and managers can delete products"
on public.products
for delete
to authenticated
using (
    exists (
        select 1
        from public.business_members bm
        where bm.business_id = products.business_id
          and bm.profile_id = (select auth.uid())
          and bm.role in ('owner', 'manager')
          and bm.is_active = true
    )
);
