-- =====================================================================
-- Metas de Ahorro — esquema para Supabase
-- Pégalo completo en: Supabase > SQL Editor > New query > Run
-- =====================================================================

-- Metas -----------------------------------------------------------------
create table if not exists public.goals (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 60),
  target      numeric(14,2) not null check (target > 0),
  created_at  timestamptz not null default now()
);
create index if not exists goals_user_idx on public.goals (user_id, created_at desc);

-- Movimientos (ingresos y gastos) ----------------------------------------
create table if not exists public.movements (
  id          uuid primary key default gen_random_uuid(),
  goal_id     uuid not null references public.goals (id) on delete cascade,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  type        text not null check (type in ('income', 'expense')),
  amount      numeric(14,2) not null check (amount > 0),
  concept     text not null default '' check (char_length(concept) <= 80),
  created_at  timestamptz not null default now()
);
create index if not exists movements_goal_idx on public.movements (goal_id, created_at desc);

-- División de la meta (porcentajes) --------------------------------------
create table if not exists public.allocations (
  id          uuid primary key default gen_random_uuid(),
  goal_id     uuid not null references public.goals (id) on delete cascade,
  user_id     uuid not null default auth.uid() references auth.users (id) on delete cascade,
  label       text not null check (char_length(label) between 1 and 40),
  percent     numeric(5,2) not null check (percent > 0 and percent <= 100),
  position    int not null default 0,
  created_at  timestamptz not null default now()
);
create index if not exists allocations_goal_idx on public.allocations (goal_id, position);

-- Seguridad: cada usuario solo ve y modifica lo suyo ---------------------
alter table public.goals       enable row level security;
alter table public.movements   enable row level security;
alter table public.allocations enable row level security;

drop policy if exists "goals propias" on public.goals;
create policy "goals propias" on public.goals
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists "movements propios" on public.movements;
create policy "movements propios" on public.movements
  for all using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and exists (select 1 from public.goals g where g.id = goal_id and g.user_id = auth.uid())
  );

drop policy if exists "allocations propias" on public.allocations;
create policy "allocations propias" on public.allocations
  for all using (auth.uid() = user_id)
  with check (
    auth.uid() = user_id
    and exists (select 1 from public.goals g where g.id = goal_id and g.user_id = auth.uid())
  );

-- Guardar la división completa en una sola operación ---------------------
-- La app llama: rpc('replace_allocations', { p_goal_id, p_items: [{label, percent, position}] })
create or replace function public.replace_allocations(p_goal_id uuid, p_items jsonb)
returns void
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_total numeric;
begin
  if not exists (select 1 from goals where id = p_goal_id and user_id = auth.uid()) then
    raise exception 'Meta no encontrada';
  end if;

  select coalesce(sum((i->>'percent')::numeric), 0) into v_total
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i;

  if v_total > 100 then
    raise exception 'La suma de porcentajes no puede pasar de 100%%';
  end if;

  delete from allocations where goal_id = p_goal_id;

  insert into allocations (goal_id, label, percent, position)
  select p_goal_id,
         trim(i->>'label'),
         (i->>'percent')::numeric,
         coalesce((i->>'position')::int, 0)
  from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) i;
end;
$$;

grant execute on function public.replace_allocations(uuid, jsonb) to authenticated;
