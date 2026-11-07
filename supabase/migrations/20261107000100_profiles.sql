begin;

alter table cityquest.users alter column token_hash drop not null;

create table cityquest.profiles (
  user_id uuid primary key references cityquest.users (id) on delete cascade,
  username text not null unique check (username ~ '^[a-z0-9_]{3,24}$'),
  password_hash text not null,
  bio text not null default '' check (char_length(bio) <= 280)
);

create table cityquest.account_sessions (
  token_hash text primary key check (token_hash ~ '^[0-9a-f]{64}$'),
  user_id uuid not null references cityquest.profiles (user_id) on delete cascade,
  expires_at timestamptz not null default (now() + interval '720 hours')
);

create index account_sessions_user_idx on cityquest.account_sessions (user_id, expires_at);

create table cityquest.auth_rate_limits (
  key text primary key check (key ~ '^[0-9a-f]{64}$'),
  attempts integer not null check (attempts > 0),
  expires_at timestamptz not null
);

alter table cityquest.profiles enable row level security;
alter table cityquest.account_sessions enable row level security;
alter table cityquest.auth_rate_limits enable row level security;

commit;
