-- ============================================================
-- DIJO Migration 018
-- Product modifiers and option groups
-- ============================================================


-- ============================================================
-- 1. PRODUCT OPTION GROUPS
--
-- Example:
-- "Choose a size"
-- "Add extras"
-- "Choose your drink"
-- ============================================================

create table if not exists public.product_option_groups (
    id uuid primary key default gen_random_uuid(),

    product_id uuid not null
        references public.products(id)
        on delete cascade,

    name text not null,

    min_selections integer not null default 0,
    max_selections integer not null default 1,

    sort_order integer not null default 0,
    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint product_option_groups_name_not_blank
        check (length(trim(name)) > 0),

    constraint product_option_groups_min_selections_check
        check (min_selections >= 0),

    constraint product_option_groups_max_selections_check
        check (max_selections >= 1),

    constraint product_option_groups_selection_range_check
        check (min_selections <= max_selections),

    constraint product_option_groups_sort_order_check
        check (sort_order >= 0)
);


-- ============================================================
-- 2. PRODUCT OPTIONS
--
-- Example:
-- Extra cheese +R10
-- Large +R20
-- No onions +R0
-- ============================================================

create table if not exists public.product_options (
    id uuid primary key default gen_random_uuid(),

    option_group_id uuid not null
        references public.product_option_groups(id)
        on delete cascade,

    name text not null,

    price_adjustment numeric not null default 0,

    sort_order integer not null default 0,
    is_active boolean not null default true,

    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),

    constraint product_options_name_not_blank
        check (length(trim(name)) > 0),

    constraint product_options_price_adjustment_check
        check (price_adjustment >= 0),

    constraint product_options_sort_order_check
        check (sort_order >= 0)
);


-- ============================================================
-- 3. INDEXES
-- ============================================================

create index if not exists product_option_groups_product_id_idx
    on public.product_option_groups(product_id);

create index if not exists
    product_option_groups_product_active_sort_idx
    on public.product_option_groups(
        product_id,
        is_active,
        sort_order
    );

create index if not exists product_options_option_group_id_idx
    on public.product_options(option_group_id);

create index if not exists
    product_options_group_active_sort_idx
    on public.product_options(
        option_group_id,
        is_active,
        sort_order
    );


-- ============================================================
-- 4. UPDATED_AT TRIGGERS
-- ============================================================

drop trigger if exists product_option_groups_set_updated_at
    on public.product_option_groups;

create trigger product_option_groups_set_updated_at
before update on public.product_option_groups
for each row
execute function public.set_updated_at();


drop trigger if exists product_options_set_updated_at
    on public.product_options;

create trigger product_options_set_updated_at
before update on public.product_options
for each row
execute function public.set_updated_at();


-- ============================================================
-- 5. ENABLE ROW LEVEL SECURITY
-- ============================================================

alter table public.product_option_groups
enable row level security;

alter table public.product_options
enable row level security;


-- ============================================================
-- 6. DROP POLICIES IF REPLAYED
-- ============================================================

drop policy if exists
    "Authenticated users can view active option groups"
on public.product_option_groups;

drop policy if exists
    "Members can view own product option groups"
on public.product_option_groups;

drop policy if exists
    "Owners and managers can create option groups"
on public.product_option_groups;

drop policy if exists
    "Owners and managers can update option groups"
on public.product_option_groups;

drop policy if exists
    "Owners and managers can delete option groups"
on public.product_option_groups;


drop policy if exists
    "Authenticated users can view active product options"
on public.product_options;

drop policy if exists
    "Members can view own product options"
on public.product_options;

drop policy if exists
    "Owners and managers can create product options"
on public.product_options;

drop policy if exists
    "Owners and managers can update product options"
on public.product_options;

drop policy if exists
    "Owners and managers can delete product options"
on public.product_options;


-- ============================================================
-- 7. OPTION GROUP SELECT POLICIES
-- ============================================================

create policy
    "Authenticated users can view active option groups"
on public.product_option_groups
for select
to authenticated
using (
    is_active = true
    and exists (
        select 1
        from public.products p
        join public.businesses b
          on b.id = p.business_id
        where p.id = product_option_groups.product_id
          and p.is_available = true
          and b.is_active = true
    )
);


create policy
    "Members can view own product option groups"
on public.product_option_groups
for select
to authenticated
using (
    exists (
        select 1
        from public.products p
        join public.business_members bm
          on bm.business_id = p.business_id
        where p.id = product_option_groups.product_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
    )
);


-- ============================================================
-- 8. OPTION GROUP WRITE POLICIES
-- ============================================================

create policy
    "Owners and managers can create option groups"
on public.product_option_groups
for insert
to authenticated
with check (
    exists (
        select 1
        from public.products p
        join public.business_members bm
          on bm.business_id = p.business_id
        where p.id = product_option_groups.product_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
);


create policy
    "Owners and managers can update option groups"
on public.product_option_groups
for update
to authenticated
using (
    exists (
        select 1
        from public.products p
        join public.business_members bm
          on bm.business_id = p.business_id
        where p.id = product_option_groups.product_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
)
with check (
    exists (
        select 1
        from public.products p
        join public.business_members bm
          on bm.business_id = p.business_id
        where p.id = product_option_groups.product_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
);


create policy
    "Owners and managers can delete option groups"
on public.product_option_groups
for delete
to authenticated
using (
    exists (
        select 1
        from public.products p
        join public.business_members bm
          on bm.business_id = p.business_id
        where p.id = product_option_groups.product_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
);


-- ============================================================
-- 9. PRODUCT OPTION SELECT POLICIES
-- ============================================================

create policy
    "Authenticated users can view active product options"
on public.product_options
for select
to authenticated
using (
    is_active = true
    and exists (
        select 1
        from public.product_option_groups pog
        join public.products p
          on p.id = pog.product_id
        join public.businesses b
          on b.id = p.business_id
        where pog.id = product_options.option_group_id
          and pog.is_active = true
          and p.is_available = true
          and b.is_active = true
    )
);


create policy
    "Members can view own product options"
on public.product_options
for select
to authenticated
using (
    exists (
        select 1
        from public.product_option_groups pog
        join public.products p
          on p.id = pog.product_id
        join public.business_members bm
          on bm.business_id = p.business_id
        where pog.id = product_options.option_group_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
    )
);


-- ============================================================
-- 10. PRODUCT OPTION WRITE POLICIES
-- ============================================================

create policy
    "Owners and managers can create product options"
on public.product_options
for insert
to authenticated
with check (
    exists (
        select 1
        from public.product_option_groups pog
        join public.products p
          on p.id = pog.product_id
        join public.business_members bm
          on bm.business_id = p.business_id
        where pog.id = product_options.option_group_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
);


create policy
    "Owners and managers can update product options"
on public.product_options
for update
to authenticated
using (
    exists (
        select 1
        from public.product_option_groups pog
        join public.products p
          on p.id = pog.product_id
        join public.business_members bm
          on bm.business_id = p.business_id
        where pog.id = product_options.option_group_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
)
with check (
    exists (
        select 1
        from public.product_option_groups pog
        join public.products p
          on p.id = pog.product_id
        join public.business_members bm
          on bm.business_id = p.business_id
        where pog.id = product_options.option_group_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
);


create policy
    "Owners and managers can delete product options"
on public.product_options
for delete
to authenticated
using (
    exists (
        select 1
        from public.product_option_groups pog
        join public.products p
          on p.id = pog.product_id
        join public.business_members bm
          on bm.business_id = p.business_id
        where pog.id = product_options.option_group_id
          and bm.profile_id = auth.uid()
          and bm.is_active = true
          and bm.role in ('owner', 'manager')
    )
);


-- ============================================================
-- 11. SQL PRIVILEGES
-- ============================================================

revoke all on table public.product_option_groups from anon;
revoke all on table public.product_options from anon;

revoke all on table public.product_option_groups from authenticated;
revoke all on table public.product_options from authenticated;


-- OPTION GROUPS

grant select on table public.product_option_groups
to authenticated;

grant insert (
    product_id,
    name,
    min_selections,
    max_selections,
    sort_order,
    is_active
)
on public.product_option_groups
to authenticated;

grant update (
    name,
    min_selections,
    max_selections,
    sort_order,
    is_active
)
on public.product_option_groups
to authenticated;

grant delete on table public.product_option_groups
to authenticated;


-- OPTIONS

grant select on table public.product_options
to authenticated;

grant insert (
    option_group_id,
    name,
    price_adjustment,
    sort_order,
    is_active
)
on public.product_options
to authenticated;

grant update (
    name,
    price_adjustment,
    sort_order,
    is_active
)
on public.product_options
to authenticated;

grant delete on table public.product_options
to authenticated;
