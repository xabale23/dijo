-- ============================================
-- DIJO Migration 001
-- Required PostgreSQL Extensions
-- ============================================

create extension if not exists "pgcrypto";
create extension if not exists postgis;
create extension if not exists citext;
create extension if not exists "uuid-ossp";
