begin;

create schema cityquest;
revoke all on schema cityquest from public;

create table cityquest.users (
  id uuid primary key default gen_random_uuid(),
  display_name text not null check (char_length(btrim(display_name)) between 1 and 40),
  token_hash text not null unique check (token_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default now()
);

create table cityquest.activities (
  id uuid primary key default gen_random_uuid(),
  creator_id uuid not null references cityquest.users (id),
  title text not null check (char_length(btrim(title)) between 1 and 100),
  description text not null default '' check (char_length(description) <= 500),
  category text not null check (char_length(btrim(category)) between 1 and 30),
  location text not null check (char_length(btrim(location)) between 1 and 150),
  starts_at timestamptz not null,
  max_participants integer not null check (max_participants between 2 and 100),
  created_at timestamptz not null default now(),
  cancelled_at timestamptz
);

create index activities_upcoming_idx on cityquest.activities (starts_at) where cancelled_at is null;

create table cityquest.activity_participants (
  activity_id uuid not null references cityquest.activities (id) on delete cascade,
  user_id uuid not null references cityquest.users (id),
  joined_at timestamptz not null default now(),
  primary key (activity_id, user_id)
);

create index activity_participants_user_idx on cityquest.activity_participants (user_id, activity_id);

create table cityquest.games (
  id uuid primary key default gen_random_uuid(),
  activity_id uuid not null unique references cityquest.activities (id) on delete cascade,
  join_code text not null unique check (join_code ~ '^[A-Z0-9]{6}$'),
  status text not null default 'lobby' check (status in ('lobby', 'active', 'finished')),
  unique (id, activity_id)
);

create table cityquest.teams (
  id uuid primary key default gen_random_uuid(),
  game_id uuid not null references cityquest.games (id) on delete cascade,
  name text not null check (char_length(btrim(name)) between 1 and 40),
  unique (id, game_id)
);

create unique index teams_name_idx on cityquest.teams (game_id, lower(name));

create table cityquest.team_members (
  game_id uuid not null,
  activity_id uuid not null,
  team_id uuid not null,
  user_id uuid not null,
  joined_at timestamptz not null default now(),
  primary key (game_id, user_id),
  foreign key (team_id, game_id) references cityquest.teams (id, game_id) on delete cascade,
  foreign key (game_id, activity_id) references cityquest.games (id, activity_id) on delete cascade,
  foreign key (activity_id, user_id) references cityquest.activity_participants (activity_id, user_id) on delete cascade
);

create index team_members_team_idx on cityquest.team_members (team_id);

create table cityquest.challenges (
  id integer primary key,
  title text not null,
  description text not null,
  category text not null check (category in ('exploration', 'social', 'team')),
  points integer not null check (points > 0)
);

create table cityquest.challenge_completions (
  team_id uuid not null references cityquest.teams (id) on delete cascade,
  challenge_id integer not null references cityquest.challenges (id),
  completed_at timestamptz not null default now(),
  primary key (team_id, challenge_id)
);

alter table cityquest.users enable row level security;
alter table cityquest.activities enable row level security;
alter table cityquest.activity_participants enable row level security;
alter table cityquest.games enable row level security;
alter table cityquest.teams enable row level security;
alter table cityquest.team_members enable row level security;
alter table cityquest.challenges enable row level security;
alter table cityquest.challenge_completions enable row level security;

insert into cityquest.challenges (id, title, description, category, points) values
  (1, 'Hidden in plain sight', 'Find a quiet public corner your team has never visited. Take a photo of a detail that makes it worth a second look.', 'exploration', 100),
  (2, 'Statue safari', 'Find an unusual statue or sculpture. Compare what each teammate noticed first and take a picture of your favourite detail.', 'exploration', 100),
  (3, 'City from above', 'Find a public viewpoint and pick one feature of the skyline you can all recognise from there.', 'exploration', 200),
  (4, 'A date in stone', 'Find a historic building with a date or plaque on it. Read it together and share one fact you learned.', 'exploration', 200),
  (5, 'A local lead', 'Ask someone who is happy to chat to recommend a public place that visitors often miss. Find it together if it is nearby.', 'social', 300),
  (6, 'Say it like a local', 'Ask a willing local to teach you an everyday expression. Practise saying it with your team and learn when to use it.', 'social', 300),
  (7, 'Favourite spot', 'Ask someone who is happy to chat about their favourite place in the city and what makes it special to them.', 'social', 300),
  (8, 'A street of recommendations', 'Swap ideas for a public place to visit with another team or a willing passerby. Each teammate picks one idea to try later.', 'social', 300),
  (9, 'Strike a pose', 'Recreate the pose of a statue as a team. Take a picture if everyone in the frame consents.', 'team', 200),
  (10, 'Five shades of the city', 'Find objects in five different colours. Each teammate has to spot at least one of them.', 'team', 100),
  (11, 'Three clues, one story', 'Pick three objects you spot along the way. Take turns adding a sentence to a short story that features all three.', 'team', 200),
  (12, 'The team postcard', 'Choose a backdrop that sums up your route and take a team photo if everyone in the frame consents.', 'team', 200);

commit;
