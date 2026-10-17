-- Execute once in the Supabase SQL Editor before deploying the updated HTML.
-- In Supabase Auth, enable "Allow new users to sign up" and email/password
-- sign-in, disable email confirmation (the login uses an internal,
-- non-deliverable email), set minimum password length to 6, and configure
-- sign-in rate limits.

begin;

create table if not exists public.empresas (
  id uuid primary key default gen_random_uuid(),
  cnpj text not null unique
    check (cnpj ~ '^[A-Z0-9]{12}[0-9]{2}$'),
  owner_id uuid unique references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.vendas
  add column if not exists empresa_id uuid;
alter table public.custos
  add column if not exists empresa_id uuid;

insert into public.empresas (cnpj)
values ('58271306000162')
on conflict (cnpj) do nothing;

update public.vendas
set empresa_id = (select id from public.empresas where cnpj = '58271306000162')
where empresa_id is null;

update public.custos
set empresa_id = (select id from public.empresas where cnpj = '58271306000162')
where empresa_id is null;

alter table public.vendas
  alter column empresa_id set not null;
alter table public.custos
  alter column empresa_id set not null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'vendas_empresa_id_fkey'
      and conrelid = 'public.vendas'::regclass
  ) then
    alter table public.vendas
      add constraint vendas_empresa_id_fkey
      foreign key (empresa_id) references public.empresas(id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'custos_empresa_id_fkey'
      and conrelid = 'public.custos'::regclass
  ) then
    alter table public.custos
      add constraint custos_empresa_id_fkey
      foreign key (empresa_id) references public.empresas(id);
  end if;
end
$$;

create index if not exists vendas_empresa_id_id_idx
  on public.vendas (empresa_id, id);
create index if not exists custos_empresa_id_id_idx
  on public.custos (empresa_id, id);

alter table public.empresas enable row level security;
alter table public.vendas enable row level security;
alter table public.custos enable row level security;

do $$
declare
  politica record;
begin
  for politica in
    select tablename, policyname
    from pg_policies
    where schemaname = 'public'
      and tablename in ('empresas', 'vendas', 'custos')
  loop
    execute format(
      'drop policy %I on public.%I',
      politica.policyname,
      politica.tablename
    );
  end loop;
end
$$;

revoke all on table public.empresas, public.vendas, public.custos
  from anon, authenticated;
grant select on table public.empresas to authenticated;
grant select, insert on table public.vendas, public.custos to authenticated;

do $$
declare
  nome_sequencia text;
begin
  nome_sequencia := pg_get_serial_sequence('public.vendas', 'id');
  if nome_sequencia is not null then
    execute format('grant usage, select on sequence %s to authenticated', nome_sequencia);
  end if;

  nome_sequencia := pg_get_serial_sequence('public.custos', 'id');
  if nome_sequencia is not null then
    execute format('grant usage, select on sequence %s to authenticated', nome_sequencia);
  end if;
end
$$;

create policy empresas_select_propria
  on public.empresas
  for select
  to authenticated
  using (owner_id = (select auth.uid()));

create policy vendas_select_proprias
  on public.vendas
  for select
  to authenticated
  using (
    empresa_id in (
      select id from public.empresas where owner_id = (select auth.uid())
    )
  );

create policy vendas_insert_proprias
  on public.vendas
  for insert
  to authenticated
  with check (
    empresa_id in (
      select id from public.empresas where owner_id = (select auth.uid())
    )
  );

create policy custos_select_proprios
  on public.custos
  for select
  to authenticated
  using (
    empresa_id in (
      select id from public.empresas where owner_id = (select auth.uid())
    )
  );

create policy custos_insert_proprios
  on public.custos
  for insert
  to authenticated
  with check (
    empresa_id in (
      select id from public.empresas where owner_id = (select auth.uid())
    )
  );

create or replace function public.registrar_empresa(p_cnpj text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  empresa_id_resultado uuid;
begin
  if auth.uid() is null then
    raise exception 'É necessário entrar para cadastrar um CNPJ.';
  end if;

  if p_cnpj is null or p_cnpj !~ '^[A-Z0-9]{12}[0-9]{2}$' then
    raise exception 'CNPJ inválido.';
  end if;

  insert into public.empresas (cnpj, owner_id)
  values (p_cnpj, auth.uid())
  on conflict (cnpj) do nothing;

  update public.empresas
  set owner_id = auth.uid()
  where cnpj = p_cnpj
    and owner_id is null
  returning id into empresa_id_resultado;

  if empresa_id_resultado is null then
    select id into empresa_id_resultado
    from public.empresas
    where cnpj = p_cnpj
      and owner_id = auth.uid();
  end if;

  if empresa_id_resultado is null then
    raise exception 'Este CNPJ já está cadastrado em outra conta.';
  end if;

  return empresa_id_resultado;
end;
$$;

revoke all on function public.registrar_empresa(text) from public, anon;
grant execute on function public.registrar_empresa(text) to authenticated;

commit;
