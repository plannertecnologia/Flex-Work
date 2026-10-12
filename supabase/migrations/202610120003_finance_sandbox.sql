-- Flex Work v0.4 | Contas de demonstração e pedidos de saque SIMULADOS
-- Não cria transferências bancárias, split ou disponibilização de saldo real.
-- Execute SOMENTE depois das migrações 0001 e 0002, faça backup antes.
begin;

create table if not exists public.flex_withdrawal_requests (
  id uuid primary key default gen_random_uuid(),
  freelancer_id uuid not null references public.freelancer_profiles(user_id) on delete restrict,
  amount_cents bigint not null check (amount_cents >= 1000),
  status text not null default 'solicitado' check (status in ('solicitado','simulado','rejeitado','cancelado')),
  -- nunca armazenar chave Pix, dados bancários nem credenciais neste fluxo de demonstração
  notes text check (notes is null or char_length(notes) <= 500),
  processed_by uuid references auth.users(id),
  processed_at timestamptz,
  created_at timestamptz not null default now()
);
create index if not exists flex_wr_user_date_idx on public.flex_withdrawal_requests(freelancer_id, created_at desc);
create index if not exists flex_wr_pending_idx on public.flex_withdrawal_requests(status,created_at desc);
alter table public.flex_withdrawal_requests enable row level security;
drop policy if exists flex_wr_read on public.flex_withdrawal_requests;
create policy flex_wr_read on public.flex_withdrawal_requests for select to authenticated
  using (freelancer_id = (select auth.uid()) or public.is_admin());
revoke insert, update, delete on public.flex_withdrawal_requests from public, anon, authenticated;
grant select on public.flex_withdrawal_requests to authenticated;

-- Nunca expor p_user escolhido pelo chamador. Helper privativo utilizado pelas RPCs abaixo.
create or replace function public.flex_test_earned_cents(p_user uuid)
returns bigint language sql stable security definer set search_path = public as $$
  select coalesce(sum(c.gross_amount_cents - c.commission_cents),0)::bigint
  from public.contracts c
  where c.freelancer_id = p_user and c.status='concluido'
    and exists (
      select 1 from public.commissions m
      join public.payments p on p.id = m.payment_id
      where m.contract_id=c.id and m.status in ('prevista','confirmada')
        and p.contract_id=c.id and p.provider='asaas'
        and p.status in ('recebido','confirmado')
    )
    and not exists (
      select 1 from public.refunds r
      where r.contract_id=c.id and r.status in ('solicitado','processando','concluido')
    )
    and not exists (
      select 1 from public.disputes d
      where d.contract_id=c.id and d.status in ('aberta','em_analise')
    );
$$;
revoke all on function public.flex_test_earned_cents(uuid) from public, anon, authenticated;

-- Resultado com nomes explícitos: todas as quantias são VIRTUAIS no sandbox.
create or replace function public.flex_finance_summary()
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
 v_uid uuid := auth.uid();
 v_earned bigint; v_reserved bigint; v_paid_demo bigint; v_gross bigint; v_comm bigint;
 v_provider_fee bigint; v_contracts int;
begin
 if v_uid is null then raise exception 'Login necessário' using errcode='42501'; end if;
 select public.flex_test_earned_cents(v_uid) into v_earned;
 select coalesce(sum(amount_cents) filter (where status='solicitado'),0),
        coalesce(sum(amount_cents) filter (where status='simulado'),0)
 into v_reserved,v_paid_demo
 from public.flex_withdrawal_requests where freelancer_id=v_uid;
 select coalesce(sum(c.gross_amount_cents),0)::bigint,
        coalesce(sum(c.commission_cents),0)::bigint,
        count(*)::int,
        coalesce(sum(coalesce(p.provider_fee_cents,0)),0)::bigint
 into v_gross,v_comm,v_contracts,v_provider_fee
 from public.contracts c
 left join lateral (
   select payment.provider_fee_cents from public.payments payment
   where payment.contract_id=c.id and payment.status in ('recebido','confirmado')
   order by payment.created_at desc limit 1
 ) p on true
 where c.freelancer_id=v_uid and c.status='concluido'
 and exists(select 1 from public.commissions m join public.payments pay on pay.id=m.payment_id
   where m.contract_id=c.id and m.status in ('prevista','confirmada')
   and pay.contract_id=c.id and pay.status in ('recebido','confirmado'))
 and not exists(select 1 from public.refunds r where r.contract_id=c.id and r.status in ('solicitado','processando','concluido'))
 and not exists(select 1 from public.disputes d where d.contract_id=c.id and d.status in ('aberta','em_analise'));
 return jsonb_build_object(
   'environment','sandbox',
   'gross_cents',v_gross, 'platform_commission_cents',v_comm,
   'provider_fees_cents',v_provider_fee,
   'earned_demo_cents',v_earned,
   'reserved_demo_cents',v_reserved,
   'withdrawn_demo_cents',v_paid_demo,
   'available_demo_cents',greatest(v_earned-v_reserved-v_paid_demo,0),
   'real_available_cents',0,
   'completed_paid_contracts',v_contracts
 );
end $$;
revoke all on function public.flex_finance_summary() from public,anon;
grant execute on function public.flex_finance_summary() to authenticated;

-- Histórico por contrato, RLS adicional pela identidade verificada dentro da função.
create or replace function public.flex_finance_statement()
returns table (contract_id uuid, title text, completed_at timestamptz,
 gross_cents bigint, platform_commission_cents bigint,
 freelancer_earnings_cents bigint, provider_fee_cents bigint)
language plpgsql stable security definer set search_path = public as $$
begin
 if auth.uid() is null then raise exception 'Login necessário' using errcode='42501'; end if;
 return query select c.id,c.title,c.completed_at,c.gross_amount_cents,c.commission_cents,
         (c.gross_amount_cents-c.commission_cents)::bigint,coalesce(p.provider_fee_cents,0)::bigint
 from public.contracts c
 left join lateral (
   select pay.provider_fee_cents from public.payments pay
   where pay.contract_id=c.id and pay.status in ('recebido','confirmado')
   order by pay.created_at desc limit 1
 ) p on true
 where c.freelancer_id=auth.uid() and c.status='concluido'
 and exists(select 1 from public.commissions m join public.payments pay on pay.id=m.payment_id
   where m.contract_id=c.id and m.status in ('prevista','confirmada')
    and pay.contract_id=c.id and pay.status in ('recebido','confirmado'))
 and not exists(select 1 from public.refunds r where r.contract_id=c.id and r.status in ('solicitado','processando','concluido'))
 and not exists(select 1 from public.disputes d where d.contract_id=c.id and d.status in ('aberta','em_analise'))
 order by c.completed_at desc;
end $$;
revoke all on function public.flex_finance_statement() from public,anon;
grant execute on function public.flex_finance_statement() to authenticated;

-- Reserva virtual atômica. Bloqueia a linha do perfil para serializar pedidos simultâneos.
create or replace function public.flex_request_test_withdrawal(p_amount_cents bigint)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();v_earned bigint;v_used bigint;v_id uuid;
begin
 if v_uid is null then raise exception 'Login necessário' using errcode='42501'; end if;
 if not exists (select 1 from public.platform_settings
   where key='payment_environment' and value #>> '{}'='sandbox') then
   raise exception 'Pedidos simulados indisponíveis fora do sandbox' using errcode='42501';
 end if;
 if p_amount_cents is null or p_amount_cents < 1000 or p_amount_cents > 100000000 then
   raise exception 'Informe valor entre R$ 10 e R$ 1.000.000' using errcode='22023';
 end if;
 -- Evita corrida de dois pedidos simultâneos do mesmo profissional.
 perform 1 from public.freelancer_profiles where user_id=v_uid for update;
 if not found then raise exception 'Perfil freelancer necessário' using errcode='42501'; end if;
 select public.flex_test_earned_cents(v_uid) into v_earned;
 select coalesce(sum(amount_cents),0) into v_used from public.flex_withdrawal_requests
 where freelancer_id=v_uid and status in ('solicitado','simulado');
 if p_amount_cents > greatest(v_earned-v_used,0) then
    raise exception 'Saldo de teste insuficiente' using errcode='22023';
 end if;
 insert into public.flex_withdrawal_requests(freelancer_id,amount_cents)
 values(v_uid,p_amount_cents) returning id into v_id;
 insert into public.notifications(user_id,kind,title,body,link)
 select ur.user_id,'saque_teste','Solicitação de saque simulado',
        'Um freelancer solicitou um saque de teste.','/admin'
 from public.user_roles ur where ur.role='admin';
 return v_id;
end $$;
revoke all on function public.flex_request_test_withdrawal(bigint) from public,anon;
grant execute on function public.flex_request_test_withdrawal(bigint) to authenticated;

create or replace function public.flex_cancel_test_withdrawal(p_id uuid)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid();
begin
 if v_uid is null then raise exception 'Login necessário' using errcode='42501'; end if;
 update public.flex_withdrawal_requests set status='cancelado',processed_at=now()
 where id=p_id and freelancer_id=v_uid and status='solicitado';
 if not found then raise exception 'Solicitação não pode ser cancelada' using errcode='42501'; end if;
end $$;
revoke all on function public.flex_cancel_test_withdrawal(uuid) from public,anon;
grant execute on function public.flex_cancel_test_withdrawal(uuid) to authenticated;

create or replace function public.flex_admin_review_test_withdrawal(p_id uuid,p_approve boolean,p_notes text default null)
returns void language plpgsql security definer set search_path = public as $$
declare v_uid uuid := auth.uid(); v_owner uuid; v_status text;
begin
 if v_uid is null or not public.is_admin() then
    raise exception 'Somente administrador' using errcode='42501'; end if;
 if not exists(select 1 from public.platform_settings
   where key='payment_environment' and value #>> '{}'='sandbox') then
   raise exception 'Saques simulados são exclusivos do sandbox' using errcode='42501'; end if;
 select freelancer_id,status into v_owner,v_status from public.flex_withdrawal_requests
 where id=p_id for update;
 if not found or v_status<>'solicitado' then
    raise exception 'Solicitação já processada' using errcode='22023'; end if;
 update public.flex_withdrawal_requests
 set status=case when p_approve then 'simulado' else 'rejeitado' end,
     processed_at=now(),processed_by=v_uid,notes=left(p_notes,500)
 where id=p_id;
 insert into public.notifications(user_id,kind,title,body,link)
 values(v_owner,'saque_teste',case when p_approve then 'Saque simulado aprovado' else 'Saque de teste rejeitado' end,
    'Nenhum dinheiro real foi transferido.','/financeiro');
end $$;
revoke all on function public.flex_admin_review_test_withdrawal(uuid,boolean,text) from public,anon;
grant execute on function public.flex_admin_review_test_withdrawal(uuid,boolean,text) to authenticated;

commit;
