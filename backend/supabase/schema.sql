create extension if not exists "pgcrypto";

create table if not exists organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists teams (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references organizations(id) on delete cascade,
  name text not null,
  created_at timestamptz not null default now()
);

create table if not exists athletes (
  id uuid primary key default gen_random_uuid(),
  team_id uuid references teams(id) on delete set null,
  external_ref text,
  first_name text,
  last_name text,
  created_at timestamptz not null default now()
);

create table if not exists sessions (
  id uuid primary key,
  athlete_id uuid not null references athletes(id) on delete cascade,
  sport text not null,
  started_at timestamptz not null,
  ended_at timestamptz not null,
  duration_sec double precision not null,
  distance_km double precision not null,
  active_calories double precision not null,
  total_calories double precision not null,
  average_speed_kmh double precision not null,
  max_speed_kmh double precision not null,
  average_pace_min_per_km double precision,
  high_speed_distance_km double precision not null,
  sprint_distance_km double precision not null,
  sprint_count integer not null,
  acceleration_count integer not null,
  deceleration_count integer not null,
  created_at timestamptz not null default now()
);

create table if not exists session_samples (
  id bigserial primary key,
  session_id uuid not null references sessions(id) on delete cascade,
  timestamp timestamptz not null,
  latitude double precision not null,
  longitude double precision not null,
  altitude_m double precision,
  speed_kmh double precision not null,
  horizontal_accuracy_m double precision,
  created_at timestamptz not null default now()
);

create index if not exists idx_sessions_athlete_started on sessions(athlete_id, started_at desc);
create index if not exists idx_session_samples_session_ts on session_samples(session_id, timestamp);
