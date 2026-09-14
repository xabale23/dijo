-- ============================================================
-- DIJO
-- Migration 029b: Fix Delivery Offer Acceptance Lock Order
-- ============================================================
--
-- PURPOSE
-- -------
-- Prevent a possible deadlock when two different drivers try
-- to accept different offers for the same order concurrently.
--
-- PREVIOUS LOCK ORDER
-- -------------------
-- Offer -> Order -> Driver
--
-- Two sessions could each hold a different offer row while
-- competing for the same order. After one won, the order-status
-- trigger could then attempt to cancel the other session's
-- locked offer, creating a lock cycle.
--
-- NEW LOCK ORDER
-- --------------
-- 1. Read offer identity without locking
-- 2. Verify caller owns that offer
-- 3. Lock ORDER
-- 4. Lock and revalidate OFFER
-- 5. Lock DRIVER
-- 6. Create/assign delivery
--
-- Competing acceptances now serialize on the ORDER row before
-- either transaction locks its offer row.
--
-- ============================================================


create or replace function public.accept_delivery_offer(
    p_offer_id uuid
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_actor_id uuid;

    -- Initial offer identity
    v_initial_order_id uuid;
    v_initial_business_id uuid;
    v_initial_driver_id uuid;

    -- Authoritative locked offer state
    v_order_id uuid;
    v_business_id uuid;
    v_offer_driver_id uuid;
    v_vehicle_id uuid;
    v_pickup_location_id uuid;
    v_offer_status public.delivery_offer_status;
    v_expires_at timestamptz;

    -- Locked order state
    v_order_status public.order_status;
    v_delivery_address text;

    -- Locked driver state
    v_driver_verification
        public.driver_verification_status;
    v_driver_active boolean;
    v_driver_available boolean;

    v_pickup_address text;

    v_delivery_id uuid;
    v_delivery_status public.delivery_status;
begin

    -- ========================================================
    -- 1. AUTHENTICATION
    -- ========================================================

    v_actor_id := auth.uid();

    if v_actor_id is null then
        raise exception 'Authentication required';
    end if;


    -- ========================================================
    -- 2. READ OFFER IDENTITY WITHOUT LOCKING
    --
    -- We intentionally do NOT lock the offer yet.
    --
    -- This gives us the order ID needed to acquire the shared
    -- concurrency lock point first.
    -- ========================================================

    select
        o.order_id,
        o.business_id,
        o.driver_profile_id
    into
        v_initial_order_id,
        v_initial_business_id,
        v_initial_driver_id
    from public.delivery_offers o
    where o.id = p_offer_id;


    if not found then
        raise exception 'Delivery offer not found';
    end if;


    if v_initial_driver_id <> v_actor_id then
        raise exception
            'You do not own this delivery offer';
    end if;


    -- ========================================================
    -- 3. LOCK ORDER FIRST
    --
    -- This is the global serialization point for all offers
    -- belonging to the same order.
    --
    -- Two drivers accepting different offers for the same
    -- order cannot proceed past this point simultaneously.
    -- ========================================================

    select
        o.status,
        o.delivery_address
    into
        v_order_status,
        v_delivery_address
    from public.orders o
    where o.id = v_initial_order_id
      and o.business_id = v_initial_business_id
    for update;


    if not found then
        raise exception 'Order not found';
    end if;


    if v_order_status <>
       'ready'::public.order_status then
        raise exception
            'Order is no longer available';
    end if;


    if v_delivery_address is null
       or btrim(v_delivery_address) = '' then
        raise exception
            'Order does not have a delivery address';
    end if;


    -- ========================================================
    -- 4. LOCK AND REVALIDATE OFFER
    --
    -- The offer may have changed while we were waiting for the
    -- order lock, so everything security-sensitive is checked
    -- again after obtaining the offer-row lock.
    -- ========================================================

    select
        o.order_id,
        o.business_id,
        o.driver_profile_id,
        o.vehicle_id,
        o.pickup_location_id,
        o.status,
        o.expires_at
    into
        v_order_id,
        v_business_id,
        v_offer_driver_id,
        v_vehicle_id,
        v_pickup_location_id,
        v_offer_status,
        v_expires_at
    from public.delivery_offers o
    where o.id = p_offer_id
    for update;


    if not found then
        raise exception 'Delivery offer not found';
    end if;


    if v_offer_driver_id <> v_actor_id then
        raise exception
            'You do not own this delivery offer';
    end if;


    -- Defense-in-depth:
    -- ensure offer still belongs to the order we locked.

    if v_order_id <> v_initial_order_id
       or v_business_id <> v_initial_business_id then
        raise exception
            'Delivery offer relationship changed';
    end if;


    if v_offer_status <>
       'pending'::public.delivery_offer_status then
        raise exception
            'Delivery offer is no longer pending';
    end if;


    if v_expires_at <= now() then
        raise exception
            'Delivery offer has expired';
    end if;


    -- ========================================================
    -- 5. LOCK AND REVALIDATE DRIVER
    -- ========================================================

    select
        dp.verification_status,
        dp.is_active,
        dp.is_available
    into
        v_driver_verification,
        v_driver_active,
        v_driver_available
    from public.driver_profiles dp
    where dp.profile_id = v_actor_id
    for update;


    if not found then
        raise exception
            'Driver profile not found';
    end if;


    if v_driver_verification <>
       'verified'::public.driver_verification_status then
        raise exception
            'Driver is not verified';
    end if;


    if v_driver_active is not true then
        raise exception
            'Driver profile is inactive';
    end if;


    if v_driver_available is not true then
        raise exception
            'Driver is no longer available';
    end if;


    if not exists (
        select 1
        from public.profiles p
        where p.id = v_actor_id
          and p.is_active is true
          and p.role =
              'driver'::public.user_role
    ) then
        raise exception
            'Active driver account required';
    end if;


    -- ========================================================
    -- 6. REVALIDATE OFFER VEHICLE
    -- ========================================================

    if not exists (
        select 1
        from public.driver_vehicles dv
        where dv.id = v_vehicle_id
          and dv.driver_profile_id = v_actor_id
          and dv.is_active is true
    ) then
        raise exception
            'Offer vehicle is no longer available';
    end if;


    -- ========================================================
    -- 7. REVALIDATE PICKUP LOCATION
    -- ========================================================

    select
        bl.address
    into
        v_pickup_address
    from public.business_locations bl
    where bl.id = v_pickup_location_id
      and bl.business_id = v_business_id
      and bl.is_active is true
      and bl.is_pickup_enabled is true;


    if not found then
        raise exception
            'Pickup location is unavailable';
    end if;


    -- ========================================================
    -- 8. DRIVER MUST NOT ALREADY HAVE ACTIVE DELIVERY
    -- ========================================================

    if exists (
        select 1
        from public.deliveries d
        where d.driver_profile_id = v_actor_id
          and d.status in (
              'assigned'::public.delivery_status,
              'accepted'::public.delivery_status,
              'arrived_at_pickup'::public.delivery_status,
              'picked_up'::public.delivery_status,
              'on_the_way'::public.delivery_status
          )
    ) then
        raise exception
            'Driver already has an active delivery';
    end if;


    -- ========================================================
    -- 9. MARK THIS AS THE WINNING OFFER
    --
    -- This happens before the order status change.
    --
    -- Therefore the order-status trigger will cancel only the
    -- OTHER offers that remain pending.
    -- ========================================================

    update public.delivery_offers o
    set
        status =
            'accepted'::public.delivery_offer_status,
        responded_at = now(),
        updated_at = now()
    where o.id = p_offer_id;


    -- ========================================================
    -- 10. LOCK EXISTING DELIVERY IF PRESENT
    -- ========================================================

    select
        d.id,
        d.status
    into
        v_delivery_id,
        v_delivery_status
    from public.deliveries d
    where d.order_id = v_order_id
    for update;


    -- ========================================================
    -- 11. CREATE OR REUSE DELIVERY
    -- ========================================================

    if not found then

        insert into public.deliveries (
            order_id,
            business_id,
            driver_profile_id,
            vehicle_id,
            status,
            pickup_location_id,
            pickup_address,
            dropoff_address,
            assigned_at
        )
        values (
            v_order_id,
            v_business_id,
            v_actor_id,
            v_vehicle_id,
            'assigned'::public.delivery_status,
            v_pickup_location_id,
            v_pickup_address,
            v_delivery_address,
            now()
        )
        returning id
        into v_delivery_id;

    else

        if v_delivery_status <>
           'waiting'::public.delivery_status then
            raise exception
                'Delivery is no longer available for assignment';
        end if;


        update public.deliveries d
        set
            driver_profile_id = v_actor_id,
            vehicle_id = v_vehicle_id,
            status =
                'assigned'::public.delivery_status,
            pickup_location_id =
                v_pickup_location_id,
            pickup_address =
                v_pickup_address,
            dropoff_address =
                v_delivery_address,
            assigned_at = now(),
            accepted_at = null,
            arrived_at_pickup_at = null,
            picked_up_at = null,
            completed_at = null,
            cancelled_at = null,
            updated_at = now()
        where d.id = v_delivery_id;

    end if;


    -- ========================================================
    -- 12. OFFER ACCEPTANCE ALSO COUNTS AS DRIVER ACCEPTANCE
    --
    -- assigned -> accepted
    --
    -- Migration 027 records delivery history automatically.
    -- ========================================================

    update public.deliveries d
    set
        status =
            'accepted'::public.delivery_status,
        accepted_at = now(),
        updated_at = now()
    where d.id = v_delivery_id;


    -- ========================================================
    -- 13. DRIVER BECOMES UNAVAILABLE
    -- ========================================================

    update public.driver_profiles dp
    set
        is_available = false,
        updated_at = now()
    where dp.profile_id = v_actor_id;


    -- ========================================================
    -- 14. ORDER READY -> DRIVER_ASSIGNED
    --
    -- The Migration 029 order trigger now cancels every other
    -- pending offer for this order.
    -- ========================================================

    update public.orders o
    set
        status =
            'driver_assigned'::public.order_status,
        updated_at = now()
    where o.id = v_order_id;


    -- ========================================================
    -- 15. ORDER AUDIT HISTORY
    -- ========================================================

    insert into public.order_status_history (
        order_id,
        from_status,
        to_status,
        changed_by
    )
    values (
        v_order_id,
        'ready'::public.order_status,
        'driver_assigned'::public.order_status,
        v_actor_id
    );


    return v_delivery_id;

end;
$function$;


-- ============================================================
-- OWNERSHIP
-- ============================================================

alter function public.accept_delivery_offer(uuid)
owner to postgres;


-- ============================================================
-- EXECUTION PRIVILEGES
-- ============================================================

revoke all
on function public.accept_delivery_offer(uuid)
from public, anon;


grant execute
on function public.accept_delivery_offer(uuid)
to authenticated;


-- ============================================================
-- END MIGRATION 029b
-- ============================================================
