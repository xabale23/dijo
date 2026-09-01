-- ============================================
-- DIJO Migration 006
-- Initial Row Level Security Policies
-- ============================================

-- ============================================
-- PROFILES
-- ============================================

create policy "Users can view own profile"
on public.profiles
for select
to authenticated
using (
    id = (select auth.uid())
);


-- ============================================
-- BUSINESSES
-- ============================================

create policy "Authenticated users can view active businesses"
on public.businesses
for select
to authenticated
using (
    is_active = true
);


-- ============================================
-- CATEGORIES
-- ============================================

create policy "Authenticated users can view active categories"
on public.categories
for select
to authenticated
using (
    is_active = true
    and exists (
        select 1
        from public.businesses b
        where b.id = categories.business_id
          and b.is_active = true
    )
);


-- ============================================
-- PRODUCTS
-- ============================================

create policy "Authenticated users can view available products"
on public.products
for select
to authenticated
using (
    is_available = true
    and exists (
        select 1
        from public.businesses b
        where b.id = products.business_id
          and b.is_active = true
    )
);


-- ============================================
-- ORDERS
-- ============================================

create policy "Customers can view own orders"
on public.orders
for select
to authenticated
using (
    customer_id = (select auth.uid())
);


-- ============================================
-- ORDER ITEMS
-- ============================================

create policy "Customers can view own order items"
on public.order_items
for select
to authenticated
using (
    exists (
        select 1
        from public.orders o
        where o.id = order_items.order_id
          and o.customer_id = (select auth.uid())
    )
);
