-- ============================================
-- DIJO Migration 004A
-- Commerce Core
-- Pre-launch baseline
-- ============================================

-- Categories
create table if not exists public.categories (
    id uuid primary key default gen_random_uuid(),

    business_id uuid not null
        references public.businesses(id)
        on delete cascade,

    name text not null,
    description text,
    sort_order integer default 0,
    is_active boolean default true,
    created_at timestamptz default now()
);

alter table public.categories
enable row level security;


-- Products
create table if not exists public.products (
    id uuid primary key default gen_random_uuid(),

    business_id uuid not null
        references public.businesses(id)
        on delete cascade,

    category_id uuid
        references public.categories(id)
        on delete set null,

    name text not null,
    description text,
    price numeric not null,
    image_url text,
    is_available boolean default true,
    preparation_time integer default 15,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

alter table public.products
enable row level security;


-- Orders
create table if not exists public.orders (
    id uuid primary key default gen_random_uuid(),

    customer_id uuid not null
        references public.profiles(id),

    business_id uuid not null
        references public.businesses(id),

    order_number text not null unique,

    status order_status default 'pending',

    subtotal numeric not null default 0,
    delivery_fee numeric not null default 0,
    service_fee numeric not null default 0,
    total numeric not null default 0,

    delivery_address text,
    customer_notes text,

    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

alter table public.orders
enable row level security;


-- Order Items
create table if not exists public.order_items (
    id uuid primary key default gen_random_uuid(),

    order_id uuid not null
        references public.orders(id)
        on delete cascade,

    product_id uuid not null
        references public.products(id),

    product_name text not null,

    quantity integer not null
        check (quantity > 0),

    unit_price numeric not null,
    total_price numeric not null,

    special_instructions text,

    created_at timestamptz default now()
);

alter table public.order_items
enable row level security;
