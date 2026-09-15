-- ============================================================
-- DIJO
-- Migration 032: Order & Delivery Notification Events
-- ============================================================
--
-- PURPOSE
-- -------
-- Extend DIJO's durable notification outbox across the order
-- and delivery lifecycle.
--
-- Notification events are generated from the immutable
-- status-history tables rather than being duplicated across
-- every order/delivery mutation RPC.
--
-- SOURCES
-- -------
-- public.order_status_history
-- public.delivery_status_history
--
-- OUTBOX
-- ------
-- public.enqueue_notification(...)
--
-- IMPORTANT
-- ---------
-- These database triggers create durable EVENTS only.
--
-- They do not:
--   - call Meta
--   - format final WhatsApp templates
--   - send messages directly
--
-- The backend notification worker introduced in Migration 031
-- remains responsible for delivery through WhatsApp.
--
-- PRIVACY
-- -------
-- Notification payloads contain operational identifiers and
-- statuses only.
--
-- Customer delivery addresses are NOT copied into the outbox.
--
-- ============================================================


-- ============================================================
-- EVENT TYPES INTRODUCED
-- ============================================================
--
-- CUSTOMER
-- --------
-- customer.order.accepted
-- customer.order.preparing
-- customer.order.ready
-- customer.order.driver_assigned
-- customer.order.picked_up
-- customer.order.on_the_way
-- customer.order.delivered
-- customer.order.cancelled
--
-- BUSINESS
-- --------
-- business.order.new
-- business.order.cancelled
-- business.order.driver_assigned
-- business.driver.arrived_at_pickup
--
-- DRIVER
-- ------
-- driver.delivery.assigned
-- driver.assignment.released
-- driver.delivery.cancelled
--
-- Existing Migration 031 event:
-- driver.delivery_offer.available
--
-- ============================================================


-- ============================================================
-- 1. ORDER STATUS HISTORY -> NOTIFICATION OUTBOX
-- ============================================================

create or replace function
public.enqueue_order_status_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_customer_id uuid;
    v_business_id uuid;
    v_order_number text;

    v_customer_event_type text;
    v_business_event_type text;

    v_business_recipient_id uuid;
begin

    -- ========================================================
    -- RESOLVE AUTHORITATIVE ORDER RELATIONSHIPS
    --
    -- order_status_history intentionally does not duplicate
    -- business_id/customer_id/order_number.
    -- ========================================================

    select
        o.customer_id,
        o.business_id,
        o.order_number
    into
        v_customer_id,
        v_business_id,
        v_order_number
    from public.orders o
    where o.id = new.order_id;


    if not found then
        raise exception
            'Order referenced by status history does not exist';
    end if;


    -- ========================================================
    -- CUSTOMER EVENT MAPPING
    -- ========================================================

    v_customer_event_type :=
        case new.to_status

            when 'accepted'::public.order_status
                then 'customer.order.accepted'

            when 'preparing'::public.order_status
                then 'customer.order.preparing'

            when 'ready'::public.order_status
                then 'customer.order.ready'

            when 'driver_assigned'::public.order_status
                then 'customer.order.driver_assigned'

            when 'picked_up'::public.order_status
                then 'customer.order.picked_up'

            when 'on_the_way'::public.order_status
                then 'customer.order.on_the_way'

            when 'delivered'::public.order_status
                then 'customer.order.delivered'

            when 'cancelled'::public.order_status
                then 'customer.order.cancelled'

            else null
        end;


    -- ========================================================
    -- CUSTOMER NOTIFICATION
    -- ========================================================
    --
    -- Skip inactive/missing profiles instead of allowing a
    -- notification problem to block the underlying order
    -- transaction.
    -- ========================================================

    if v_customer_event_type is not null
       and exists (
           select 1
           from public.profiles p
           where p.id = v_customer_id
             and p.is_active is true
       ) then

        perform public.enqueue_notification(
            v_customer_id,

            v_customer_event_type,

            jsonb_build_object(
                'history_id',
                new.id,

                'order_id',
                new.order_id,

                'order_number',
                v_order_number,

                'business_id',
                v_business_id,

                'from_status',
                case
                    when new.from_status is null
                        then null
                    else new.from_status::text
                end,

                'to_status',
                new.to_status::text,

                'changed_by',
                new.changed_by,

                'event_created_at',
                new.created_at
            ),

            'order_history:'
                || new.id::text
                || ':customer:'
                || v_customer_id::text
                || ':'
                || v_customer_event_type,

            'order_status_history',

            new.id,

            now(),

            5
        );

    end if;


    -- ========================================================
    -- BUSINESS EVENT MAPPING
    -- ========================================================

    v_business_event_type := null;


    -- Initial order creation.
    if new.from_status is null
       and new.to_status =
           'pending'::public.order_status then

        v_business_event_type :=
            'business.order.new';


    -- Cancellation.
    elsif new.to_status =
          'cancelled'::public.order_status then

        v_business_event_type :=
            'business.order.cancelled';


    -- Driver assigned / reassigned.
    elsif new.to_status =
          'driver_assigned'::public.order_status then

        v_business_event_type :=
            'business.order.driver_assigned';

    end if;


    -- ========================================================
    -- BUSINESS MEMBER NOTIFICATIONS
    -- ========================================================
    --
    -- Notify active:
    --   owner
    --   manager
    --   staff
    --
    -- Each recipient receives a separate durable outbox job.
    -- ========================================================

    if v_business_event_type is not null then

        for v_business_recipient_id in

            select distinct
                bm.profile_id

            from public.business_members bm

            join public.profiles p
              on p.id = bm.profile_id

            where bm.business_id = v_business_id

              and bm.is_active is true

              and p.is_active is true

              and bm.role in (
                  'owner'::public.business_member_role,
                  'manager'::public.business_member_role,
                  'staff'::public.business_member_role
              )

        loop

            perform public.enqueue_notification(
                v_business_recipient_id,

                v_business_event_type,

                jsonb_build_object(
                    'history_id',
                    new.id,

                    'order_id',
                    new.order_id,

                    'order_number',
                    v_order_number,

                    'business_id',
                    v_business_id,

                    'from_status',
                    case
                        when new.from_status is null
                            then null
                        else new.from_status::text
                    end,

                    'to_status',
                    new.to_status::text,

                    'changed_by',
                    new.changed_by,

                    'event_created_at',
                    new.created_at
                ),

                'order_history:'
                    || new.id::text
                    || ':business:'
                    || v_business_recipient_id::text
                    || ':'
                    || v_business_event_type,

                'order_status_history',

                new.id,

                now(),

                5
            );

        end loop;

    end if;


    return new;

end;
$function$;


alter function
public.enqueue_order_status_notifications()
owner to postgres;


revoke all
on function
public.enqueue_order_status_notifications()
from public, anon, authenticated, service_role;


-- ============================================================
-- 2. ORDER HISTORY TRIGGER
-- ============================================================

drop trigger if exists
order_history_enqueue_notifications
on public.order_status_history;


create trigger
order_history_enqueue_notifications
after insert
on public.order_status_history
for each row
execute function
public.enqueue_order_status_notifications();


-- ============================================================
-- 3. DELIVERY STATUS HISTORY -> NOTIFICATION OUTBOX
-- ============================================================

create or replace function
public.enqueue_delivery_status_notifications()
returns trigger
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_order_number text;

    v_business_event_type text;
    v_driver_event_type text;

    v_business_recipient_id uuid;
begin

    -- ========================================================
    -- RESOLVE ORDER NUMBER
    -- ========================================================

    select
        o.order_number
    into
        v_order_number
    from public.orders o
    where o.id = new.order_id
      and o.business_id = new.business_id;


    if not found then
        raise exception
            'Order referenced by delivery history does not exist';
    end if;


    -- ========================================================
    -- BUSINESS DELIVERY EVENT MAPPING
    -- ========================================================

    v_business_event_type := null;


    if new.to_status =
       'arrived_at_pickup'::public.delivery_status then

        v_business_event_type :=
            'business.driver.arrived_at_pickup';

    end if;


    -- ========================================================
    -- BUSINESS DELIVERY NOTIFICATIONS
    -- ========================================================

    if v_business_event_type is not null then

        for v_business_recipient_id in

            select distinct
                bm.profile_id

            from public.business_members bm

            join public.profiles p
              on p.id = bm.profile_id

            where bm.business_id = new.business_id

              and bm.is_active is true

              and p.is_active is true

              and bm.role in (
                  'owner'::public.business_member_role,
                  'manager'::public.business_member_role,
                  'staff'::public.business_member_role
              )

        loop

            perform public.enqueue_notification(
                v_business_recipient_id,

                v_business_event_type,

                jsonb_build_object(
                    'history_id',
                    new.id,

                    'delivery_id',
                    new.delivery_id,

                    'order_id',
                    new.order_id,

                    'order_number',
                    v_order_number,

                    'business_id',
                    new.business_id,

                    'driver_profile_id',
                    new.driver_profile_id,

                    'from_status',
                    case
                        when new.from_status is null
                            then null
                        else new.from_status::text
                    end,

                    'to_status',
                    new.to_status::text,

                    'changed_by',
                    new.changed_by,

                    'event_created_at',
                    new.created_at
                ),

                'delivery_history:'
                    || new.id::text
                    || ':business:'
                    || v_business_recipient_id::text
                    || ':'
                    || v_business_event_type,

                'delivery_status_history',

                new.id,

                now(),

                5
            );

        end loop;

    end if;


    -- ========================================================
    -- DRIVER EVENT MAPPING
    -- ========================================================

    v_driver_event_type := null;


    -- Driver has been assigned.
    if new.to_status =
       'assigned'::public.delivery_status

       and new.driver_profile_id is not null then

        v_driver_event_type :=
            'driver.delivery.assigned';


    -- Assignment released before pickup.
    elsif new.to_status =
          'waiting'::public.delivery_status

          and new.driver_profile_id is not null

          and new.from_status in (
              'assigned'::public.delivery_status,
              'accepted'::public.delivery_status,
              'arrived_at_pickup'::public.delivery_status
          ) then

        v_driver_event_type :=
            'driver.assignment.released';


    -- Delivery explicitly cancelled.
    elsif new.to_status =
          'cancelled'::public.delivery_status

          and new.driver_profile_id is not null then

        v_driver_event_type :=
            'driver.delivery.cancelled';

    end if;


    -- ========================================================
    -- DRIVER NOTIFICATION
    -- ========================================================

    if v_driver_event_type is not null
       and exists (
           select 1
           from public.profiles p
           where p.id = new.driver_profile_id
             and p.is_active is true
       ) then

        perform public.enqueue_notification(
            new.driver_profile_id,

            v_driver_event_type,

            jsonb_build_object(
                'history_id',
                new.id,

                'delivery_id',
                new.delivery_id,

                'order_id',
                new.order_id,

                'order_number',
                v_order_number,

                'business_id',
                new.business_id,

                'driver_profile_id',
                new.driver_profile_id,

                'from_status',
                case
                    when new.from_status is null
                        then null
                    else new.from_status::text
                end,

                'to_status',
                new.to_status::text,

                'changed_by',
                new.changed_by,

                'event_created_at',
                new.created_at
            ),

            'delivery_history:'
                || new.id::text
                || ':driver:'
                || new.driver_profile_id::text
                || ':'
                || v_driver_event_type,

            'delivery_status_history',

            new.id,

            now(),

            5
        );

    end if;


    return new;

end;
$function$;


alter function
public.enqueue_delivery_status_notifications()
owner to postgres;


revoke all
on function
public.enqueue_delivery_status_notifications()
from public, anon, authenticated, service_role;


-- ============================================================
-- 4. DELIVERY HISTORY TRIGGER
-- ============================================================

drop trigger if exists
delivery_history_enqueue_notifications
on public.delivery_status_history;


create trigger
delivery_history_enqueue_notifications
after insert
on public.delivery_status_history
for each row
execute function
public.enqueue_delivery_status_notifications();


-- ============================================================
-- 5. REASSERT INTERNAL FUNCTION SECURITY
-- ============================================================

revoke all
on function
public.enqueue_order_status_notifications()
from public, anon, authenticated, service_role;


revoke all
on function
public.enqueue_delivery_status_notifications()
from public, anon, authenticated, service_role;


-- ============================================================
-- END MIGRATION 032
-- ============================================================
