-- Flex Work v0.3: avaliações verificadas, ranking público e notificação financeira.
-- Executar DEPOIS de setup_all.sql e 202610120001_marketplace_flows.sql.
-- Não altera pagamentos/splits, não apaga dados e não cria avaliações fictícias.
begin;

-- Apenas o cliente de um contrato realmente concluído poderá avaliar uma vez.
-- Não há INSERT/UPDATE direto para o navegador na tabela reviews: tudo passa por esta RPC.
create or replace function public.flex_submit_review(
  p_contract_id uuid,
  p_quality integer,
  p_communication integer,
  p_deadline integer,
  p_scope integer,
  p_comment text default ''
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_contract public.contracts%rowtype;
  v_review_id uuid;
  v_overall smallint;
begin
  if auth.uid() is null then
    raise exception 'Faça login para avaliar' using errcode = '42501';
  end if;
  select * into v_contract from public.contracts where id = p_contract_id for update;
  if not found or v_contract.client_id <> auth.uid()
     or v_contract.status <> 'concluido' or v_contract.completed_at is null then
    raise exception 'Só o cliente pode avaliar um contrato concluído' using errcode = '42501';
  end if;
  if p_quality not between 1 and 5 or p_communication not between 1 and 5
     or p_deadline not between 1 and 5 or p_scope not between 1 and 5
     or p_quality is null or p_communication is null or p_deadline is null or p_scope is null then
    raise exception 'As notas devem estar entre 1 e 5' using errcode = '22023';
  end if;
  if char_length(coalesce(p_comment, '')) > 2000 then
    raise exception 'Comentário limitado a 2000 caracteres' using errcode = '22023';
  end if;
  if exists(select 1 from public.reviews where contract_id = p_contract_id) then
    raise exception 'Este contrato já foi avaliado' using errcode = '23505';
  end if;
  v_overall := round((p_quality + p_communication + p_deadline + p_scope) / 4.0)::smallint;
  insert into public.reviews(contract_id, reviewer_id, freelancer_id, service_id,
       quality, communication, deadline, scope, overall, comment, status)
  values (p_contract_id, auth.uid(), v_contract.freelancer_id, v_contract.service_id,
       p_quality, p_communication, p_deadline, p_scope, v_overall,
       nullif(trim(coalesce(p_comment, '')), ''), 'publicada')
  returning id into v_review_id;

  insert into public.notifications(user_id, kind, title, body, link)
  values (v_contract.freelancer_id, 'avaliacao_recebida',
          'Seu trabalho recebeu uma avaliação',
          'Uma avaliação verificada foi registrada para um contrato concluído.',
          '/contrato/' || p_contract_id::text);
  return v_review_id;
end;
$$;
revoke all on function public.flex_submit_review(uuid, integer, integer, integer, integer, text) from public, anon;
grant execute on function public.flex_submit_review(uuid, integer, integer, integer, integer, text) to authenticated;

-- Ranking com agregados calculados diretamente de contratos concluídos e avaliações publicadas.
-- A função expõe SOMENTE metadados públicos; contratos, clientes e emails não são retornados.
-- Para evitar distorções, um score só é atribuído após 3 avaliações verificadas.
-- Fórmula: média bayesiana (prior 4/5 com peso 5) em 80 pontos + até 20 pontos por histórico concluído.
create or replace function public.flex_public_rankings()
returns table (
  user_id uuid, full_name text, professional_title text, bio text, avatar_url text,
  rating_avg numeric, rating_count bigint, completed_projects bigint,
  score numeric, is_new_talent boolean
)
language sql stable security definer set search_path = '' as $$
  select fp.user_id, p.full_name, fp.professional_title, fp.bio, p.avatar_url,
         coalesce(r.average, 0::numeric) as rating_avg,
         coalesce(r.qty, 0::bigint) as rating_count,
         coalesce(c.qty, 0::bigint) as completed_projects,
         case when coalesce(r.qty, 0) >= 3 then
           round((((coalesce(r.sum_stars, 0)::numeric + 20) / (r.qty + 5)) * 16
             + least(coalesce(c.qty, 0), 20)), 2)
         else null end as score,
         coalesce(r.qty, 0) < 3 as is_new_talent
  from public.freelancer_profiles fp
  join public.profiles p on p.id = fp.user_id
  left join lateral (
     select count(*) as qty, sum(rv.overall)::numeric as sum_stars,
            round(avg(rv.overall)::numeric, 2) as average
     from public.reviews rv
     where rv.freelancer_id = fp.user_id and rv.status = 'publicada'
  ) r on true
  left join lateral (
     select count(*) as qty
     from public.contracts ct
     where ct.freelancer_id = fp.user_id and ct.status = 'concluido'
  ) c on true
  where fp.approval_status = 'aprovado' and p.status = 'ativo'
  order by score desc nulls last, completed_projects desc, rating_count desc, p.full_name asc
  limit 50;
$$;
revoke all on function public.flex_public_rankings() from public;
grant execute on function public.flex_public_rankings() to anon, authenticated;

-- Cards de serviços exibem notas VERIFICADAS calculadas diretamente de avaliações públicas.
-- Não altera colunas protegidas de services/freelancer_profiles e respeita o RLS de origem.
create index if not exists flex_reviews_published_service_idx
  on public.reviews(service_id) where status = 'publicada';
create or replace view public.flex_service_cards with (security_invoker = true) as
  select sc.*,
         coalesce(rv.rating_avg, 0::numeric) as verified_rating_avg,
         coalesce(rv.rating_count, 0::bigint) as verified_rating_count
  from public.service_cards sc
  left join lateral (
    select round(avg(r.overall)::numeric, 2) as rating_avg, count(*) as rating_count
    from public.reviews r
    where r.service_id = sc.id and r.status = 'publicada'
  ) rv on true;
grant select on public.flex_service_cards to anon, authenticated;

-- A confirmação via webhook já gera contract_events: agora avisamos os dois participantes.
create or replace function public.flex_notify_paid_event()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_contract public.contracts%rowtype;
begin
  if new.event <> 'pagamento_confirmado' then return new; end if;
  select * into v_contract from public.contracts where id = new.contract_id;
  if found then
    insert into public.notifications(user_id, kind, title, body, link)
    values
      (v_contract.client_id, 'pagamento_confirmado', 'Pagamento confirmado',
       'Seu pagamento foi reconhecido. O profissional já pode começar.', '/contrato/' || new.contract_id::text),
      (v_contract.freelancer_id, 'pagamento_confirmado', 'Novo pagamento confirmado',
       'Uma contratação foi paga e está pronta para execução.', '/contrato/' || new.contract_id::text);
  end if;
  return new;
end;
$$;
revoke all on function public.flex_notify_paid_event() from public, anon, authenticated;
drop trigger if exists trg_flex_notify_paid_event on public.contract_events;
create trigger trg_flex_notify_paid_event
  after insert on public.contract_events
  for each row when (new.event = 'pagamento_confirmado')
  execute function public.flex_notify_paid_event();

commit;
