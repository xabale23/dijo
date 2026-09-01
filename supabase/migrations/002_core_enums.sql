-- ============================================
-- DIJO Migration 002
-- Core Platform Enums
-- ============================================

DO $$
BEGIN

    IF NOT EXISTS (
        SELECT 1 FROM pg_type WHERE typname = 'user_role'
    ) THEN
        CREATE TYPE user_role AS ENUM (
            'customer',
            'vendor',
            'driver',
            'admin'
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_type WHERE typname = 'business_type'
    ) THEN
        CREATE TYPE business_type AS ENUM (
            'restaurant',
            'takeaway',
            'kota_shop',
            'braai_spot',
            'spaza_shop',
            'grocery',
            'bakery',
            'butchery',
            'pharmacy',
            'florist',
            'other'
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_type WHERE typname = 'order_status'
    ) THEN
        CREATE TYPE order_status AS ENUM (
            'pending',
            'accepted',
            'preparing',
            'ready_for_pickup',
            'picked_up',
            'on_the_way',
            'delivered',
            'cancelled',
            'refunded'
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_type WHERE typname = 'delivery_status'
    ) THEN
        CREATE TYPE delivery_status AS ENUM (
            'waiting',
            'assigned',
            'accepted',
            'arrived_at_pickup',
            'picked_up',
            'on_the_way',
            'completed',
            'cancelled'
        );
    END IF;

    IF NOT EXISTS (
        SELECT 1 FROM pg_type WHERE typname = 'payment_status'
    ) THEN
        CREATE TYPE payment_status AS ENUM (
            'pending',
            'paid',
            'failed',
            'refunded'
        );
    END IF;

END
$$;
