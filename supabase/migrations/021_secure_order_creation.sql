-- Migration 021
-- Secure, server-authoritative order creation.
--
-- Clients provide only:
--   business_id
--   delivery address / notes
--   product ids
--   quantities
--   selected option ids
--
-- Prices, names, totals, customer identity, order number
-- and initial status are determined by the database.

create or replace function public.create_order(
    p_business_id uuid,
    p_items jsonb,
    p_delivery_address text default null,
    p_customer_notes text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
    v_customer_id uuid;
    v_order_id uuid;
    v_order_number text;

    v_item jsonb;
    v_product_id uuid;
    v_quantity integer;
    v_product_name text;
    v_product_price numeric;

    v_order_item_id uuid;

    v_option_id uuid;
    v_option_group_id uuid;
    v_option_group_name text;
    v_option_name text;
    v_option_price numeric;

    v_item_base_total numeric;
    v_item_modifier_total numeric;
    v_item_total numeric;

    v_subtotal numeric := 0;
    v_delivery_fee numeric := 0;
    v_service_fee numeric := 0;
    v_total numeric := 0;

    v_group record;
    v_selection_count integer;
begin
    -- ========================================================
    -- 1. AUTHENTICATION
    -- ========================================================

    v_customer_id := auth.uid();

    if v_customer_id is null then
        raise exception 'Authentication required';
    end if;

    if not exists (
        select 1
        from public.profiles p
        where p.id = v_customer_id
          and p.is_active is true
    ) then
        raise exception 'Active customer profile required';
    end if;

    -- ========================================================
    -- 2. BUSINESS VALIDATION
    -- ========================================================

    if not exists (
        select 1
        from public.businesses b
        where b.id = p_business_id
          and b.is_active is true
    ) then
        raise exception 'Business is unavailable';
    end if;

    -- ========================================================
    -- 3. REQUEST VALIDATION
    -- ========================================================

    if p_items is null
       or jsonb_typeof(p_items) <> 'array'
       or jsonb_array_length(p_items) = 0 then
        raise exception 'Order must contain at least one item';
    end if;

    -- ========================================================
    -- 4. CREATE PENDING ORDER
    -- ========================================================

    v_order_number :=
        'DIJO-' ||
        to_char(clock_timestamp(), 'YYYYMMDDHH24MISS') ||
        '-' ||
        upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

    insert into public.orders (
        customer_id,
        business_id,
        order_number,
        status,
        subtotal,
        delivery_fee,
        service_fee,
        total,
        delivery_address,
        customer_notes
    )
    values (
        v_customer_id,
        p_business_id,
        v_order_number,
        'pending'::public.order_status,
        0,
        0,
        0,
        0,
        nullif(trim(p_delivery_address), ''),
        nullif(trim(p_customer_notes), '')
    )
    returning id into v_order_id;

    -- ========================================================
    -- 5. VALIDATE + CREATE EACH ITEM
    -- ========================================================

    for v_item in
        select value
        from jsonb_array_elements(p_items)
    loop
        if jsonb_typeof(v_item) <> 'object' then
            raise exception 'Each order item must be an object';
        end if;

        begin
            v_product_id := (v_item ->> 'product_id')::uuid;
        exception
            when others then
                raise exception 'Invalid product_id';
        end;

        begin
            v_quantity := (v_item ->> 'quantity')::integer;
        exception
            when others then
                raise exception 'Invalid quantity';
        end;

        if v_product_id is null then
            raise exception 'product_id is required';
        end if;

        if v_quantity is null or v_quantity <= 0 then
            raise exception 'Quantity must be greater than zero';
        end if;

        -- Lock the product row while pricing the order.
        select
            p.name,
            p.price
        into
            v_product_name,
            v_product_price
        from public.products p
        where p.id = v_product_id
          and p.business_id = p_business_id
          and p.is_available is true
        for share;

        if not found then
            raise exception
                'Product % is unavailable for this business',
                v_product_id;
        end if;

        v_item_base_total := v_product_price * v_quantity;
        v_item_modifier_total := 0;

        -- ====================================================
        -- 6. VALIDATE OPTION PAYLOAD
        -- ====================================================

        if v_item ? 'option_ids'
           and jsonb_typeof(v_item -> 'option_ids') <> 'array' then
            raise exception 'option_ids must be an array';
        end if;

        -- Reject duplicate option IDs.
        if exists (
            select 1
            from (
                select value, count(*) as occurrences
                from jsonb_array_elements_text(
                    coalesce(v_item -> 'option_ids', '[]'::jsonb)
                )
                group by value
                having count(*) > 1
            ) duplicates
        ) then
            raise exception 'Duplicate product option selected';
        end if;

        -- Validate selection counts for EVERY active group
        -- belonging to this product.
        for v_group in
            select
                pog.id,
                pog.name,
                pog.min_selections,
                pog.max_selections
            from public.product_option_groups pog
            where pog.product_id = v_product_id
              and pog.is_active is true
        loop
            select count(*)
            into v_selection_count
            from jsonb_array_elements_text(
                coalesce(v_item -> 'option_ids', '[]'::jsonb)
            ) selected(raw_option_id)
            join public.product_options po
              on po.id = selected.raw_option_id::uuid
            where po.option_group_id = v_group.id
              and po.is_active is true;

            if v_selection_count < v_group.min_selections then
                raise exception
                    'Not enough selections for option group %',
                    v_group.name;
            end if;

            if v_selection_count > v_group.max_selections then
                raise exception
                    'Too many selections for option group %',
                    v_group.name;
            end if;
        end loop;

        -- ====================================================
        -- 7. CREATE ORDER ITEM
        -- ====================================================

        insert into public.order_items (
            order_id,
            product_id,
            business_id,
            product_name,
            quantity,
            unit_price,
            total_price
        )
        values (
            v_order_id,
            v_product_id,
            p_business_id,
            v_product_name,
            v_quantity,
            v_product_price,
            v_item_base_total
        )
        returning id into v_order_item_id;

        -- ====================================================
        -- 8. VALIDATE + SNAPSHOT SELECTED OPTIONS
        -- ====================================================

        for v_option_id in
            select value::uuid
            from jsonb_array_elements_text(
                coalesce(v_item -> 'option_ids', '[]'::jsonb)
            )
        loop
            select
                pog.id,
                pog.name,
                po.name,
                po.price_adjustment
            into
                v_option_group_id,
                v_option_group_name,
                v_option_name,
                v_option_price
            from public.product_options po
            join public.product_option_groups pog
              on pog.id = po.option_group_id
            where po.id = v_option_id
              and po.is_active is true
              and pog.is_active is true
              and pog.product_id = v_product_id
            for share of po, pog;

            if not found then
                raise exception
                    'Invalid or unavailable product option %',
                    v_option_id;
            end if;

            insert into public.order_item_options (
                order_item_id,
                option_group_id,
                option_id,
                option_group_name,
                option_name,
                price_adjustment,
                quantity,
                total_price
            )
            values (
                v_order_item_id,
                v_option_group_id,
                v_option_id,
                v_option_group_name,
                v_option_name,
                v_option_price,
                v_quantity,
                v_option_price * v_quantity
            );

            v_item_modifier_total :=
                v_item_modifier_total +
                (v_option_price * v_quantity);
        end loop;

        -- Store complete line total, including modifiers.
        v_item_total :=
            v_item_base_total +
            v_item_modifier_total;

        update public.order_items
        set total_price = v_item_total
        where id = v_order_item_id;

        v_subtotal := v_subtotal + v_item_total;
    end loop;

    -- ========================================================
    -- 9. AUTHORITATIVE ORDER TOTAL
    -- ========================================================

    v_total :=
        v_subtotal +
        v_delivery_fee +
        v_service_fee;

    update public.orders
    set
        subtotal = v_subtotal,
        delivery_fee = v_delivery_fee,
        service_fee = v_service_fee,
        total = v_total
    where id = v_order_id;

    return v_order_id;
end;
$$;

-- ============================================================
-- 10. FUNCTION OWNERSHIP + EXECUTION PRIVILEGES
-- ============================================================

alter function public.create_order(uuid, jsonb, text, text)
    owner to postgres;

revoke all
on function public.create_order(uuid, jsonb, text, text)
from public;

revoke all
on function public.create_order(uuid, jsonb, text, text)
from anon;

grant execute
on function public.create_order(uuid, jsonb, text, text)
to authenticated;
