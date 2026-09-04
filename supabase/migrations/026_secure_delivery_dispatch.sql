-- ============================================================
-- DIJO
-- Migration 026: Secure Delivery Dispatch
-- ============================================================
--
-- PURPOSE
-- -------
-- Secure the operational delivery lifecycle:
--
--   ready order
--      ↓
--   assigned
--      ↓
--   accepted
--      ↓
--   arrived_at_pickup
--      ↓
--   picked_up
--      ↓
--   on_the_way
--      ↓
--   completed
--
-- Order synchronization:
--
--   ready
--      ↓
--   driver_assigned
--      ↓
--   picked_up
--      ↓
--   on_the_way
--      ↓
--   delivered
--
-- SECURITY PRINCIPLES
-- -------------------
-- 1. No direct client mutation of deliveries.
-- 2. No direct client mutation of orders.
-- 3. No direct client mutation of order_status_history.
-- 4. auth.uid() determines the acting user.
-- 5. Only authorized business members/admins may dispatch.
-- 6. Only the assigned verified driver may progress a delivery.
-- 7. Driver, vehicle, business and order relationships are
--    validated server-side.
-- 8. Driver assignment is serialized with row locking.
-- 9. Order status changes and delivery changes occur atomically.
-- 10. Customer drop-off address comes from the order snapshot.
--
-- ============================================================


-- ============================================================
-- 1. ASSIGN A READY ORDER TO A DRIVER
-- ============================================================

create or replace function public.assign_ready_order_delivery(
    p_order_id uuid,
    p_driver_profile_id uuid,
    p_vehicle_id uuid,
    p_pickup_location_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_actor_id uuid;

    v_business_id uuid;
    v_order_status public.order_status;
    v_delivery_address text;

    v_is_business_member boolean := false;
    v_is_admin boolean := false;

    v_driver_verification public.driver_verification_status;
    v_driver_active boolean;
    v_driver_available boolean;
    v_driver_account_active boolean;

    v_vehicle_id uuid;

    v_pickup_location_id uuid;
    v_pickup_address text;

    v_delivery_id uuid;
    v_delivery_status public.delivery_status;

    v_existing_active_delivery uuid;
begin
    -- ========================================================
    -- AUTHENTICATION
    -- ========================================================

    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;

    if p_order_id is null then
        raise exception 'order_id is required';
    end if;

    if p_driver_profile_id is null then
        raise exception 'driver_profile_id is required';
    end if;


    -- ========================================================
    -- LOCK + LOAD ORDER
    -- ========================================================

    select
        o.business_id,
        o.status,
        o.delivery_address
    into
        v_business_id,
        v_order_status,
        v_delivery_address
    from public.orders o
    where o.id = p_order_id
    for update;

    if not found then
        raise exception 'Order not found';
    end if;

    if v_order_status <> 'ready'::public.order_status then
        raise exception
            'Order must be ready before driver assignment';
    end if;

    if v_delivery_address is null
       or btrim(v_delivery_address) = '' then
        raise exception
            'Order does not contain a delivery address';
    end if;


    -- ========================================================
    -- AUTHORIZE DISPATCH ACTOR
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
            'Not authorized to dispatch this order';
    end if;


    -- ========================================================
    -- LOCK + VALIDATE DRIVER
    -- ========================================================

    select
        dp.verification_status,
        dp.is_active,
        dp.is_available,
        p.is_active
    into
        v_driver_verification,
        v_driver_active,
        v_driver_available,
        v_driver_account_active
    from public.driver_profiles dp
    join public.profiles p
      on p.id = dp.profile_id
    where dp.profile_id = p_driver_profile_id
    for update of dp;

    if not found then
        raise exception 'Driver profile not found';
    end if;

    if v_driver_account_active is not true then
        raise exception 'Driver account is inactive';
    end if;

    if v_driver_verification <>
       'verified'::public.driver_verification_status then
        raise exception 'Driver is not verified';
    end if;

    if v_driver_active is not true then
        raise exception 'Driver profile is inactive';
    end if;

    if v_driver_available is not true then
        raise exception 'Driver is not available';
    end if;


    -- ========================================================
    -- PREVENT DOUBLE ASSIGNMENT
    -- ========================================================

    select d.id
    into v_existing_active_delivery
    from public.deliveries d
    where d.driver_profile_id = p_driver_profile_id
      and d.status in (
          'assigned'::public.delivery_status,
          'accepted'::public.delivery_status,
          'arrived_at_pickup'::public.delivery_status,
          'picked_up'::public.delivery_status,
          'on_the_way'::public.delivery_status
      )
    limit 1;

    if v_existing_active_delivery is not null then
        raise exception
            'Driver already has an active delivery';
    end if;


    -- ========================================================
    -- VALIDATE / RESOLVE VEHICLE
    -- ========================================================

    if p_vehicle_id is not null then

        select dv.id
        into v_vehicle_id
        from public.driver_vehicles dv
        where dv.id = p_vehicle_id
          and dv.driver_profile_id = p_driver_profile_id
          and dv.is_active is true
        for update;

        if not found then
            raise exception
                'Vehicle does not belong to this driver or is inactive';
        end if;

    else

        select dv.id
        into v_vehicle_id
        from public.driver_vehicles dv
        where dv.driver_profile_id = p_driver_profile_id
          and dv.is_active is true
        order by
            dv.is_primary desc,
            dv.created_at asc
        limit 1
        for update;

        if not found then
            raise exception
                'Driver does not have an active vehicle';
        end if;

    end if;


    -- ========================================================
    -- VALIDATE / RESOLVE PICKUP LOCATION
    -- ========================================================

    if p_pickup_location_id is not null then

        select
            bl.id,
            nullif(
                concat_ws(
                    ', ',
                    nullif(btrim(bl.address), ''),
                    nullif(btrim(bl.city), ''),
                    nullif(btrim(bl.province), ''),
                    nullif(btrim(bl.postal_code), '')
                ),
                ''
            )
        into
            v_pickup_location_id,
            v_pickup_address
        from public.business_locations bl
        where bl.id = p_pickup_location_id
          and bl.business_id = v_business_id
          and bl.is_active is true
          and bl.is_pickup_enabled is true;

        if not found then
            raise exception
                'Pickup location is invalid for this business';
        end if;

    else

        select
            bl.id,
            nullif(
                concat_ws(
                    ', ',
                    nullif(btrim(bl.address), ''),
                    nullif(btrim(bl.city), ''),
                    nullif(btrim(bl.province), ''),
                    nullif(btrim(bl.postal_code), '')
                ),
                ''
            )
        into
            v_pickup_location_id,
            v_pickup_address
        from public.business_locations bl
        where bl.business_id = v_business_id
          and bl.is_active is true
          and bl.is_pickup_enabled is true
        order by
            bl.is_primary desc,
            bl.created_at asc
        limit 1;

    end if;


    -- ========================================================
    -- LOAD EXISTING DELIVERY FOR THIS ORDER
    -- ========================================================

    select
        d.id,
        d.status
    into
        v_delivery_id,
        v_delivery_status
    from public.deliveries d
    where d.order_id = p_order_id
    for update;

    if found then

        if v_delivery_status <>
           'waiting'::public.delivery_status then
            raise exception
                'Delivery is not available for assignment';
        end if;

    else

        insert into public.deliveries (
            order_id,
            business_id,
            status,
            pickup_location_id,
            pickup_address,
            dropoff_address
        )
        values (
            p_order_id,
            v_business_id,
            'waiting'::public.delivery_status,
            v_pickup_location_id,
            v_pickup_address,
            v_delivery_address
        )
        returning id
        into v_delivery_id;

    end if;


    -- ========================================================
    -- ASSIGN DELIVERY
    -- ========================================================

    update public.deliveries
    set
        driver_profile_id = p_driver_profile_id,
        vehicle_id = v_vehicle_id,
        pickup_location_id = v_pickup_location_id,
        pickup_address = v_pickup_address,
        dropoff_address = v_delivery_address,
        status = 'assigned'::public.delivery_status,
        assigned_at = now(),
        accepted_at = null,
        arrived_at_pickup_at = null,
        picked_up_at = null,
        completed_at = null,
        cancelled_at = null
    where id = v_delivery_id;


    -- Driver becomes unavailable while assigned to a job.
    update public.driver_profiles
    set is_available = false
    where profile_id = p_driver_profile_id;


    -- ========================================================
    -- SYNCHRONIZE ORDER
    -- ========================================================

    update public.orders
    set status = 'driver_assigned'::public.order_status
    where id = p_order_id;

    insert into public.order_status_history (
        order_id,
        from_status,
        to_status,
        changed_by
    )
    values (
        p_order_id,
        'ready'::public.order_status,
        'driver_assigned'::public.order_status,
        v_actor_id
    );


    return v_delivery_id;
end;
$function$;



-- ============================================================
-- 2. ASSIGNED DRIVER ACCEPTS DELIVERY
-- ============================================================

create or replace function public.accept_my_delivery(
    p_delivery_id uuid
)
returns public.delivery_status
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_actor_id uuid;
    v_order_id uuid;
    v_assigned_driver uuid;
    v_delivery_status public.delivery_status;
    v_order_status public.order_status;
    v_driver_verified public.driver_verification_status;
    v_driver_active boolean;
    v_account_active boolean;
begin
    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;

    if p_delivery_id is null then
        raise exception 'delivery_id is required';
    end if;


    -- Discover order first so lock ordering remains consistent.
    select d.order_id
    into v_order_id
    from public.deliveries d
    where d.id = p_delivery_id;

    if not found then
        raise exception 'Delivery not found';
    end if;


    -- Lock order first.
    select o.status
    into v_order_status
    from public.orders o
    where o.id = v_order_id
    for update;

    if not found then
        raise exception 'Order not found';
    end if;


    -- Then lock delivery.
    select
        d.driver_profile_id,
        d.status
    into
        v_assigned_driver,
        v_delivery_status
    from public.deliveries d
    where d.id = p_delivery_id
      and d.order_id = v_order_id
    for update;

    if not found then
        raise exception 'Delivery not found';
    end if;

    if v_assigned_driver <> v_actor_id then
        raise exception
            'You are not assigned to this delivery';
    end if;


    select
        dp.verification_status,
        dp.is_active,
        p.is_active
    into
        v_driver_verified,
        v_driver_active,
        v_account_active
    from public.driver_profiles dp
    join public.profiles p
      on p.id = dp.profile_id
    where dp.profile_id = v_actor_id
    for update of dp;

    if not found then
        raise exception 'Driver profile not found';
    end if;

    if v_account_active is not true then
        raise exception 'Driver account is inactive';
    end if;

    if v_driver_verified <>
       'verified'::public.driver_verification_status then
        raise exception 'Driver is not verified';
    end if;

    if v_driver_active is not true then
        raise exception 'Driver profile is inactive';
    end if;

    if v_delivery_status <>
       'assigned'::public.delivery_status then
        raise exception
            'Delivery must be assigned before acceptance';
    end if;

    if v_order_status <>
       'driver_assigned'::public.order_status then
        raise exception
            'Order is not in driver_assigned status';
    end if;


    update public.deliveries
    set
        status = 'accepted'::public.delivery_status,
        accepted_at = now()
    where id = p_delivery_id;


    return 'accepted'::public.delivery_status;
end;
$function$;



-- ============================================================
-- 3. DRIVER ARRIVES AT PICKUP
-- ============================================================

create or replace function public.mark_my_delivery_arrived_at_pickup(
    p_delivery_id uuid
)
returns public.delivery_status
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_actor_id uuid;
    v_order_id uuid;
    v_assigned_driver uuid;
    v_delivery_status public.delivery_status;
    v_order_status public.order_status;
begin
    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;

    if p_delivery_id is null then
        raise exception 'delivery_id is required';
    end if;


    select d.order_id
    into v_order_id
    from public.deliveries d
    where d.id = p_delivery_id;

    if not found then
        raise exception 'Delivery not found';
    end if;


    select o.status
    into v_order_status
    from public.orders o
    where o.id = v_order_id
    for update;


    select
        d.driver_profile_id,
        d.status
    into
        v_assigned_driver,
        v_delivery_status
    from public.deliveries d
    where d.id = p_delivery_id
      and d.order_id = v_order_id
    for update;

    if v_assigned_driver <> v_actor_id then
        raise exception
            'You are not assigned to this delivery';
    end if;

    if v_delivery_status <>
       'accepted'::public.delivery_status then
        raise exception
            'Delivery must be accepted before arrival at pickup';
    end if;

    if v_order_status <>
       'driver_assigned'::public.order_status then
        raise exception
            'Order is not in driver_assigned status';
    end if;


    update public.deliveries
    set
        status = 'arrived_at_pickup'::public.delivery_status,
        arrived_at_pickup_at = now()
    where id = p_delivery_id;


    return 'arrived_at_pickup'::public.delivery_status;
end;
$function$;



-- ============================================================
-- 4. DRIVER CONFIRMS PICKUP
-- ============================================================

create or replace function public.mark_my_delivery_picked_up(
    p_delivery_id uuid
)
returns public.delivery_status
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_actor_id uuid;
    v_order_id uuid;
    v_assigned_driver uuid;
    v_delivery_status public.delivery_status;
    v_order_status public.order_status;
begin
    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;

    if p_delivery_id is null then
        raise exception 'delivery_id is required';
    end if;


    select d.order_id
    into v_order_id
    from public.deliveries d
    where d.id = p_delivery_id;

    if not found then
        raise exception 'Delivery not found';
    end if;


    select o.status
    into v_order_status
    from public.orders o
    where o.id = v_order_id
    for update;


    select
        d.driver_profile_id,
        d.status
    into
        v_assigned_driver,
        v_delivery_status
    from public.deliveries d
    where d.id = p_delivery_id
      and d.order_id = v_order_id
    for update;

    if v_assigned_driver <> v_actor_id then
        raise exception
            'You are not assigned to this delivery';
    end if;

    if v_delivery_status <>
       'arrived_at_pickup'::public.delivery_status then
        raise exception
            'Driver must arrive at pickup before confirming pickup';
    end if;

    if v_order_status <>
       'driver_assigned'::public.order_status then
        raise exception
            'Order is not in driver_assigned status';
    end if;


    update public.deliveries
    set
        status = 'picked_up'::public.delivery_status,
        picked_up_at = now()
    where id = p_delivery_id;


    update public.orders
    set status = 'picked_up'::public.order_status
    where id = v_order_id;


    insert into public.order_status_history (
        order_id,
        from_status,
        to_status,
        changed_by
    )
    values (
        v_order_id,
        'driver_assigned'::public.order_status,
        'picked_up'::public.order_status,
        v_actor_id
    );


    return 'picked_up'::public.delivery_status;
end;
$function$;



-- ============================================================
-- 5. DRIVER STARTS JOURNEY TO CUSTOMER
-- ============================================================

create or replace function public.mark_my_delivery_on_the_way(
    p_delivery_id uuid
)
returns public.delivery_status
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_actor_id uuid;
    v_order_id uuid;
    v_assigned_driver uuid;
    v_delivery_status public.delivery_status;
    v_order_status public.order_status;
begin
    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;

    if p_delivery_id is null then
        raise exception 'delivery_id is required';
    end if;


    select d.order_id
    into v_order_id
    from public.deliveries d
    where d.id = p_delivery_id;

    if not found then
        raise exception 'Delivery not found';
    end if;


    select o.status
    into v_order_status
    from public.orders o
    where o.id = v_order_id
    for update;


    select
        d.driver_profile_id,
        d.status
    into
        v_assigned_driver,
        v_delivery_status
    from public.deliveries d
    where d.id = p_delivery_id
      and d.order_id = v_order_id
    for update;

    if v_assigned_driver <> v_actor_id then
        raise exception
            'You are not assigned to this delivery';
    end if;

    if v_delivery_status <>
       'picked_up'::public.delivery_status then
        raise exception
            'Delivery must be picked up before going on the way';
    end if;

    if v_order_status <>
       'picked_up'::public.order_status then
        raise exception
            'Order is not in picked_up status';
    end if;


    update public.deliveries
    set status = 'on_the_way'::public.delivery_status
    where id = p_delivery_id;


    update public.orders
    set status = 'on_the_way'::public.order_status
    where id = v_order_id;


    insert into public.order_status_history (
        order_id,
        from_status,
        to_status,
        changed_by
    )
    values (
        v_order_id,
        'picked_up'::public.order_status,
        'on_the_way'::public.order_status,
        v_actor_id
    );


    return 'on_the_way'::public.delivery_status;
end;
$function$;



-- ============================================================
-- 6. DRIVER COMPLETES DELIVERY
-- ============================================================

create or replace function public.complete_my_delivery(
    p_delivery_id uuid
)
returns public.delivery_status
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_actor_id uuid;
    v_order_id uuid;
    v_assigned_driver uuid;
    v_delivery_status public.delivery_status;
    v_order_status public.order_status;
begin
    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;

    if p_delivery_id is null then
        raise exception 'delivery_id is required';
    end if;


    select d.order_id
    into v_order_id
    from public.deliveries d
    where d.id = p_delivery_id;

    if not found then
        raise exception 'Delivery not found';
    end if;


    select o.status
    into v_order_status
    from public.orders o
    where o.id = v_order_id
    for update;


    select
        d.driver_profile_id,
        d.status
    into
        v_assigned_driver,
        v_delivery_status
    from public.deliveries d
    where d.id = p_delivery_id
      and d.order_id = v_order_id
    for update;

    if v_assigned_driver <> v_actor_id then
        raise exception
            'You are not assigned to this delivery';
    end if;

    if v_delivery_status <>
       'on_the_way'::public.delivery_status then
        raise exception
            'Delivery must be on the way before completion';
    end if;

    if v_order_status <>
       'on_the_way'::public.order_status then
        raise exception
            'Order is not in on_the_way status';
    end if;


    update public.deliveries
    set
        status = 'completed'::public.delivery_status,
        completed_at = now()
    where id = p_delivery_id;


    update public.orders
    set status = 'delivered'::public.order_status
    where id = v_order_id;


    insert into public.order_status_history (
        order_id,
        from_status,
        to_status,
        changed_by
    )
    values (
        v_order_id,
        'on_the_way'::public.order_status,
        'delivered'::public.order_status,
        v_actor_id
    );


    -- Intentionally keep is_available = false.
    --
    -- MVP safety rule:
    -- completing a delivery does NOT silently put the driver
    -- back online. The driver explicitly chooses to become
    -- available again through set_my_driver_availability(true).


    return 'completed'::public.delivery_status;
end;
$function$;



-- ============================================================
-- 7. RELEASE AN ASSIGNMENT BEFORE PICKUP
-- ============================================================
--
-- May be performed by:
--   - assigned driver
--   - active business owner/manager/staff
--   - active DIJO admin
--
-- This does NOT cancel the customer order.
--
-- Delivery returns to:
--   waiting
--
-- Order returns to:
--   ready
--
-- Driver remains unavailable until they explicitly choose
-- to go online again.
--
-- Release is forbidden after pickup.
-- ============================================================

create or replace function public.release_delivery_assignment(
    p_delivery_id uuid
)
returns public.delivery_status
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_actor_id uuid;

    v_order_id uuid;
    v_business_id uuid;
    v_order_status public.order_status;

    v_assigned_driver uuid;
    v_delivery_status public.delivery_status;

    v_is_assigned_driver boolean := false;
    v_is_business_member boolean := false;
    v_is_admin boolean := false;
begin
    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;

    if p_delivery_id is null then
        raise exception 'delivery_id is required';
    end if;


    -- Discover order before acquiring locks.
    select d.order_id
    into v_order_id
    from public.deliveries d
    where d.id = p_delivery_id;

    if not found then
        raise exception 'Delivery not found';
    end if;


    -- Lock order first.
    select
        o.business_id,
        o.status
    into
        v_business_id,
        v_order_status
    from public.orders o
    where o.id = v_order_id
    for update;

    if not found then
        raise exception 'Order not found';
    end if;


    -- Lock delivery second.
    select
        d.driver_profile_id,
        d.status
    into
        v_assigned_driver,
        v_delivery_status
    from public.deliveries d
    where d.id = p_delivery_id
      and d.order_id = v_order_id
    for update;

    if not found then
        raise exception 'Delivery not found';
    end if;


    -- ========================================================
    -- AUTHORIZE ACTOR
    -- ========================================================

    v_is_assigned_driver :=
        (v_assigned_driver = v_actor_id);


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


    if not v_is_assigned_driver
       and not v_is_business_member
       and not v_is_admin then
        raise exception
            'Not authorized to release this delivery';
    end if;


    -- ========================================================
    -- STATE VALIDATION
    -- ========================================================

    if v_delivery_status not in (
        'assigned'::public.delivery_status,
        'accepted'::public.delivery_status,
        'arrived_at_pickup'::public.delivery_status
    ) then
        raise exception
            'Delivery can only be released before pickup';
    end if;


    if v_order_status <>
       'driver_assigned'::public.order_status then
        raise exception
            'Order is not in driver_assigned status';
    end if;


    -- ========================================================
    -- RETURN DELIVERY TO WAITING
    -- ========================================================

    update public.deliveries
    set
        driver_profile_id = null,
        vehicle_id = null,
        status = 'waiting'::public.delivery_status,
        assigned_at = null,
        accepted_at = null,
        arrived_at_pickup_at = null,
        picked_up_at = null,
        completed_at = null,
        cancelled_at = null
    where id = p_delivery_id;


    -- ========================================================
    -- RETURN ORDER TO READY
    -- ========================================================

    update public.orders
    set status = 'ready'::public.order_status
    where id = v_order_id;


    insert into public.order_status_history (
        order_id,
        from_status,
        to_status,
        changed_by
    )
    values (
        v_order_id,
        'driver_assigned'::public.order_status,
        'ready'::public.order_status,
        v_actor_id
    );


    return 'waiting'::public.delivery_status;
end;
$function$;



-- ============================================================
-- 8. FUNCTION EXECUTION PRIVILEGES
-- ============================================================

revoke all on function public.assign_ready_order_delivery(
    uuid,
    uuid,
    uuid,
    uuid
) from public;

revoke all on function public.assign_ready_order_delivery(
    uuid,
    uuid,
    uuid,
    uuid
) from anon;

grant execute on function public.assign_ready_order_delivery(
    uuid,
    uuid,
    uuid,
    uuid
) to authenticated;



revoke all on function public.accept_my_delivery(
    uuid
) from public;

revoke all on function public.accept_my_delivery(
    uuid
) from anon;

grant execute on function public.accept_my_delivery(
    uuid
) to authenticated;



revoke all on function public.mark_my_delivery_arrived_at_pickup(
    uuid
) from public;

revoke all on function public.mark_my_delivery_arrived_at_pickup(
    uuid
) from anon;

grant execute on function public.mark_my_delivery_arrived_at_pickup(
    uuid
) to authenticated;



revoke all on function public.mark_my_delivery_picked_up(
    uuid
) from public;

revoke all on function public.mark_my_delivery_picked_up(
    uuid
) from anon;

grant execute on function public.mark_my_delivery_picked_up(
    uuid
) to authenticated;



revoke all on function public.mark_my_delivery_on_the_way(
    uuid
) from public;

revoke all on function public.mark_my_delivery_on_the_way(
    uuid
) from anon;

grant execute on function public.mark_my_delivery_on_the_way(
    uuid
) to authenticated;



revoke all on function public.complete_my_delivery(
    uuid
) from public;

revoke all on function public.complete_my_delivery(
    uuid
) from anon;

grant execute on function public.complete_my_delivery(
    uuid
) to authenticated;



revoke all on function public.release_delivery_assignment(
    uuid
) from public;

revoke all on function public.release_delivery_assignment(
    uuid
) from anon;

grant execute on function public.release_delivery_assignment(
    uuid
) to authenticated;



-- ============================================================
-- 9. REASSERT DIRECT TABLE MUTATION BOUNDARIES
-- ============================================================

revoke insert, update, delete
on public.deliveries
from anon, authenticated;

revoke insert, update, delete
on public.orders
from anon, authenticated;

revoke insert, update, delete
on public.order_status_history
from anon, authenticated;



-- ============================================================
-- END MIGRATION 026
-- ============================================================
