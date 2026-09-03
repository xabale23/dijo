-- ============================================================
-- DIJO Migration 017
-- Catalog hardening
-- ============================================================


-- ============================================================
-- 1. NORMALIZE LEGACY CATEGORY DATA
-- ============================================================

update public.categories
set
    sort_order = coalesce(sort_order, 0),
    is_active = coalesce(is_active, true),
    created_at = coalesce(created_at, now());


-- ============================================================
-- 2. HARDEN CATEGORY COLUMNS
-- ============================================================

alter table public.categories
    alter column sort_order set default 0,
    alter column sort_order set not null,

    alter column is_active set default true,
    alter column is_active set not null,

    alter column created_at set default now(),
    alter column created_at set not null;


-- Add updated_at if this legacy table does not already have it.

alter table public.categories
    add column if not exists updated_at timestamptz;

update public.categories
set updated_at = coalesce(updated_at, created_at, now());

alter table public.categories
    alter column updated_at set default now(),
    alter column updated_at set not null;


-- ============================================================
-- 3. CATEGORY CONSTRAINTS
-- ============================================================

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'categories_name_not_blank'
          and conrelid = 'public.categories'::regclass
    ) then
        alter table public.categories
            add constraint categories_name_not_blank
            check (length(trim(name)) > 0);
    end if;


    if not exists (
        select 1
        from pg_constraint
        where conname = 'categories_sort_order_check'
          and conrelid = 'public.categories'::regclass
    ) then
        alter table public.categories
            add constraint categories_sort_order_check
            check (sort_order >= 0);
    end if;


    -- Required for the composite product/category integrity FK below.
    if not exists (
        select 1
        from pg_constraint
        where conname = 'categories_id_business_id_key'
          and conrelid = 'public.categories'::regclass
    ) then
        alter table public.categories
            add constraint categories_id_business_id_key
            unique (id, business_id);
    end if;
end;
$$;


-- ============================================================
-- 4. NORMALIZE LEGACY PRODUCT DATA
-- ============================================================

update public.products
set
    is_available = coalesce(is_available, true),
    preparation_time = coalesce(preparation_time, 15),
    created_at = coalesce(created_at, now()),
    updated_at = coalesce(updated_at, created_at, now());


-- ============================================================
-- 5. HARDEN PRODUCT COLUMNS
-- ============================================================

alter table public.products
    alter column is_available set default true,
    alter column is_available set not null,

    alter column preparation_time set default 15,
    alter column preparation_time set not null,

    alter column created_at set default now(),
    alter column created_at set not null,

    alter column updated_at set default now(),
    alter column updated_at set not null;


-- ============================================================
-- 6. PRODUCT CONSTRAINTS
-- ============================================================

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'products_name_not_blank'
          and conrelid = 'public.products'::regclass
    ) then
        alter table public.products
            add constraint products_name_not_blank
            check (length(trim(name)) > 0);
    end if;


    if not exists (
        select 1
        from pg_constraint
        where conname = 'products_price_non_negative'
          and conrelid = 'public.products'::regclass
    ) then
        alter table public.products
            add constraint products_price_non_negative
            check (price >= 0);
    end if;


    if not exists (
        select 1
        from pg_constraint
        where conname = 'products_preparation_time_check'
          and conrelid = 'public.products'::regclass
    ) then
        alter table public.products
            add constraint products_preparation_time_check
            check (
                preparation_time >= 0
                and preparation_time <= 1440
            );
    end if;
end;
$$;


-- ============================================================
-- 7. PREVENT CROSS-BUSINESS CATEGORY ASSIGNMENT
--
-- A product may have no category.
--
-- But if category_id is supplied, that category must belong to
-- the SAME business as the product.
-- ============================================================

do $$
begin
    if not exists (
        select 1
        from pg_constraint
        where conname = 'products_category_business_fkey'
          and conrelid = 'public.products'::regclass
    ) then
        alter table public.products
            add constraint products_category_business_fkey
            foreign key (category_id, business_id)
            references public.categories(id, business_id)
            on delete restrict;
    end if;
end;
$$;


-- ============================================================
-- 8. INDEXES
-- ============================================================

create index if not exists categories_business_id_idx
    on public.categories(business_id);

create index if not exists
    categories_business_active_sort_idx
    on public.categories(
        business_id,
        is_active,
        sort_order
    );


create index if not exists products_business_id_idx
    on public.products(business_id);

create index if not exists products_category_id_idx
    on public.products(category_id);

create index if not exists
    products_business_available_idx
    on public.products(
        business_id,
        is_available
    );


-- ============================================================
-- 9. UPDATED_AT TRIGGER FOR CATEGORIES
-- ============================================================

drop trigger if exists categories_set_updated_at
    on public.categories;

create trigger categories_set_updated_at
before update on public.categories
for each row
execute function public.set_updated_at();


-- products_set_updated_at already exists from Migration 010.


-- ============================================================
-- 10. ROW LEVEL SECURITY
--
-- Existing catalog policies from Migrations 006 and 012 remain.
-- Ensure RLS itself remains enabled.
-- ============================================================

alter table public.categories
enable row level security;

alter table public.products
enable row level security;


-- ============================================================
-- 11. HARDEN SQL PRIVILEGES
--
-- RLS decides WHO may modify a business's catalog.
-- Column privileges decide WHAT those users may modify.
-- ============================================================

revoke all on table public.categories from anon;
revoke all on table public.products from anon;

revoke all on table public.categories from authenticated;
revoke all on table public.products from authenticated;


-- ------------------------------------------------------------
-- CATEGORY PRIVILEGES
-- ------------------------------------------------------------

grant select on table public.categories
to authenticated;

grant insert (
    business_id,
    name,
    description,
    sort_order
)
on public.categories
to authenticated;

grant update (
    name,
    description,
    sort_order,
    is_active
)
on public.categories
to authenticated;

grant delete on table public.categories
to authenticated;


-- ------------------------------------------------------------
-- PRODUCT PRIVILEGES
-- ------------------------------------------------------------

grant select on table public.products
to authenticated;

grant insert (
    business_id,
    category_id,
    name,
    description,
    price,
    image_url,
    is_available,
    preparation_time
)
on public.products
to authenticated;

grant update (
    category_id,
    name,
    description,
    price,
    image_url,
    is_available,
    preparation_time
)
on public.products
to authenticated;

grant delete on table public.products
to authenticated;
