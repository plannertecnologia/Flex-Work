-- Flex Work: fase 3 + fundacao da fase 4. Executar UMA VEZ, apos setup_all.sql.
-- Sem DROP TABLE ou reset de dados. Usa functions SECURITY DEFINER estritamente validadas.
begin;

create or replace function public.flex_contract_init(p_client uuid, p_freelancer uuid, p_title text,
  p_amount bigint, p_days int, p_revisions int, p_service uuid default null,
  p_package uuid default null, p_proposal uuid default null, p_project uuid default null)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_contract uuid; v_conv uuid;
begin
  if p_client is null or p_freelancer is null or p_client = p_freelancer
     or p_amount < 500 or p_days not between 1 and 365 then
    raise exception 'Dados do contrato inválidos' using errcode='22023';
  end if;
  insert into public.contracts(client_id, freelancer_id, title, gross_amount_cents,
    commission_bps, commission_cents, revisions_allowed, due_at, service_id, package_id, proposal_id, project_id)
  values(p_client, p_freelancer, left(p_title,200), p_amount, null, 0, p_revisions,
    now() + make_interval(days=>p_days), p_service, p_package, p_proposal, p_project)
  returning id into v_contract;
  insert into public.contract_versions(contract_id, version, scope, amount_cents, delivery_days, revisions, created_by,
     accepted_by_client_at,accepted_by_freelancer_at)
  values(v_contract, 1, jsonb_build_object('title',p_title,'service_id',p_service,'package_id',p_package,'proposal_id',p_proposal),
    p_amount,p_days,p_revisions,p_client,now(),now());
  insert into public.contract_events(contract_id,event,to_status,actor_id)
    values(v_contract,'criado','aguardando_pagamento',p_client);
  insert into public.conversations(kind, contract_id) values('contrato',v_contract) returning id into v_conv;
  insert into public.conversation_participants(conversation_id,user_id)
    values(v_conv,p_client),(v_conv,p_freelancer);
  insert into public.notifications(user_id,kind,title,body,link)
    values(p_freelancer,'novo_contrato','Você recebeu um novo pedido',p_title,'/contrato/'||v_contract);
  return v_contract;
end $$;
-- Funcao auxiliar interna: impedir chamada do browser.
revoke all on function public.flex_contract_init(uuid,uuid,text,bigint,int,int,uuid,uuid,uuid,uuid) from public, anon, authenticated;

create or replace function public.flex_buy_package(p_package_id uuid)
returns uuid language plpgsql security definer set search_path = public as $$
declare v_user uuid := auth.uid(); v_p record; v_existing uuid;
begin
  if v_user is null then raise exception 'Entre na sua conta para contratar' using errcode='42501'; end if;
  select p.id package_id,p.price_cents,p.delivery_days,p.revisions,s.id service_id,s.title,
         s.freelancer_id, s.status, fp.approval_status, prof.status profile_status
    into v_p from public.service_packages p
    join public.services s on s.id=p.service_id
    join public.freelancer_profiles fp on fp.user_id=s.freelancer_id
    join public.profiles prof on prof.id=s.freelancer_id
    where p.id=p_package_id;
  if not found or v_p.status <> 'publicado' or v_p.approval_status <> 'aprovado'
     or v_p.profile_status <> 'ativo' or v_p.freelancer_id=v_user then
    raise exception 'Pacote indisponível para contratação' using errcode='22023';
  end if;
  if not exists(select 1 from public.profiles where id=v_user and status='ativo') then
    raise exception 'Seu perfil não está ativo' using errcode='42501';
  end if;
  select id into v_existing from public.contracts where client_id=v_user
    and package_id=p_package_id and status='aguardando_pagamento'
    and created_at>now()-interval '30 minutes' order by created_at desc limit 1;
  if v_existing is not null then return v_existing; end if;
  return public.flex_contract_init(v_user,v_p.freelancer_id,v_p.title,v_p.price_cents,
    v_p.delivery_days,v_p.revisions,v_p.service_id,v_p.package_id);
end $$;
revoke all on function public.flex_buy_package(uuid) from public, anon;
grant execute on function public.flex_buy_package(uuid) to authenticated;

create or replace function public.flex_send_proposal(p_project_id uuid,p_price_cents bigint,
  p_delivery_days int,p_message text,p_revisions int default 1)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_project record; v_proposal uuid;
begin
  if v_user is null then raise exception 'Faça login' using errcode='42501'; end if;
  select * into v_project from public.projects where id=p_project_id for update;
  if not found or v_project.status <> 'aberto' or v_project.client_id=v_user then
    raise exception 'Projeto indisponível' using errcode='22023'; end if;
  if not exists(select 1 from public.freelancer_profiles fp join public.profiles pr on pr.id=fp.user_id
        where fp.user_id=v_user and fp.approval_status='aprovado' and pr.status='ativo') then
    raise exception 'É necessário ser freelancer aprovado' using errcode='42501'; end if;
  if p_price_cents is null or p_delivery_days is null or p_revisions is null
     or p_price_cents not between 500 and 100000000 or p_delivery_days not between 1 and 365
     or p_revisions not between 0 and 20 or coalesce(length(trim(p_message)),0) < 10 then
    raise exception 'Dados da proposta inválidos' using errcode='22023'; end if;
  if exists(select 1 from public.proposals where project_id=p_project_id and freelancer_id=v_user and status in ('enviada','aceita','em_negociacao')) then
    raise exception 'Você já enviou uma proposta ativa' using errcode='23505'; end if;
  insert into public.proposals(kind,project_id,client_id,freelancer_id,price_cents,delivery_days,message,revisions,status)
    values('proposta',p_project_id,v_project.client_id,v_user,p_price_cents,p_delivery_days,left(p_message,4000),p_revisions,'enviada')
    returning id into v_proposal;
  update public.projects set proposals_count=proposals_count+1 where id=p_project_id;
  insert into public.notifications(user_id,kind,title,body,link)
    values(v_project.client_id,'proposta_recebida','Nova proposta recebida',v_project.title,'/projeto/'||p_project_id);
  return v_proposal;
end $$;
revoke all on function public.flex_send_proposal(uuid,bigint,int,text,int) from public, anon;
grant execute on function public.flex_send_proposal(uuid,bigint,int,text,int) to authenticated;

create or replace function public.flex_accept_proposal(p_proposal_id uuid)
returns uuid language plpgsql security definer set search_path=public as $$
declare v_user uuid:=auth.uid(); v_pr record; v_project record; v_c uuid;
begin
  if v_user is null then raise exception 'Faça login' using errcode='42501'; end if;
  select * into v_pr from public.proposals where id=p_proposal_id for update;
  if not found or v_pr.client_id<>v_user or v_pr.status<>'enviada' or v_pr.project_id is null then
    raise exception 'Proposta indisponível' using errcode='42501'; end if;
  select * into v_project from public.projects where id=v_pr.project_id for update;
  if v_project.client_id<>v_user or v_project.status<>'aberto' then
    raise exception 'Projeto não aceita contratação' using errcode='22023'; end if;
  if not exists(select 1 from public.freelancer_profiles where user_id=v_pr.freelancer_id and approval_status='aprovado') then
    raise exception 'O freelancer não está aprovado' using errcode='22023'; end if;
  v_c:=public.flex_contract_init(v_user,v_pr.freelancer_id,v_project.title,v_pr.price_cents,
    v_pr.delivery_days,v_pr.revisions,null,null,v_pr.id,v_project.id);
  update public.proposals set status='aceita' where id=v_pr.id;
  update public.proposals set status='recusada' where project_id=v_project.id and id<>v_pr.id and status='enviada';
  update public.projects set status='contratado' where id=v_project.id;
  return v_c;
end $$;
revoke all on function public.flex_accept_proposal(uuid) from public, anon;
grant execute on function public.flex_accept_proposal(uuid) to authenticated;

create or replace function public.flex_submit_delivery(p_contract_id uuid,p_notes text,p_links text[] default '{}')
returns uuid language plpgsql security definer set search_path=public as $$
declare v_c record; v_next int; v_id uuid;
begin
  select * into v_c from public.contracts where id=p_contract_id for update;
  if not found or auth.uid()<>v_c.freelancer_id or v_c.status not in
    ('pagamento_confirmado','em_execucao','revisao_solicitada') then
    raise exception 'Entrega não permitida neste contrato' using errcode='42501'; end if;
  if length(trim(coalesce(p_notes,'')))<5 then raise exception 'Descreva a entrega' using errcode='22023'; end if;
  if cardinality(p_links)>10 or exists(select 1 from unnest(p_links) u where u !~ '^https://') then
    raise exception 'Use até 10 links HTTPS' using errcode='22023'; end if;
  select coalesce(max(version),0)+1 into v_next from public.deliverables where contract_id=p_contract_id;
  insert into public.deliverables(contract_id,version,notes,links,submitted_by)
    values(p_contract_id,v_next,left(p_notes,3000),p_links,auth.uid()) returning id into v_id;
  update public.contracts set status='aguardando_analise', delivered_at=now() where id=p_contract_id;
  insert into public.contract_events(contract_id,event,from_status,to_status,actor_id)
    values(p_contract_id,'entrega_enviada',v_c.status,'aguardando_analise',auth.uid());
  insert into public.notifications(user_id,kind,title,body,link)
    values(v_c.client_id,'entrega_recebida','Nova entrega aguardando aprovação',v_c.title,'/contrato/'||p_contract_id);
  return v_id;
end $$;
revoke all on function public.flex_submit_delivery(uuid,text,text[]) from public, anon;
grant execute on function public.flex_submit_delivery(uuid,text,text[]) to authenticated;

create or replace function public.flex_request_revision(p_contract_id uuid,p_reason text)
returns void language plpgsql security definer set search_path=public as $$
declare v_c record; v_d uuid;
begin
  select * into v_c from public.contracts where id=p_contract_id for update;
  if not found or v_c.client_id<>auth.uid() or v_c.status<>'aguardando_analise' then
    raise exception 'Revisão não permitida' using errcode='42501'; end if;
  if v_c.revisions_used>=v_c.revisions_allowed or length(trim(p_reason))<8 then
    raise exception 'Limite de revisões ou motivo insuficiente' using errcode='22023'; end if;
  select id into v_d from public.deliverables where contract_id=p_contract_id order by version desc limit 1;
  insert into public.revisions(contract_id,deliverable_id,requested_by,reason)
    values(p_contract_id,v_d,auth.uid(),left(p_reason,2000));
  update public.deliverables set status='revisao_solicitada' where id=v_d;
  update public.contracts set status='revisao_solicitada',revisions_used=revisions_used+1 where id=p_contract_id;
  insert into public.contract_events(contract_id,event,from_status,to_status,actor_id)
    values(p_contract_id,'revisao_solicitada','aguardando_analise','revisao_solicitada',auth.uid());
  insert into public.notifications(user_id,kind,title,body,link)
    values(v_c.freelancer_id,'revisao_solicitada','Cliente solicitou revisão',left(p_reason,160),'/contrato/'||p_contract_id);
end $$;
revoke all on function public.flex_request_revision(uuid,text) from public, anon;
grant execute on function public.flex_request_revision(uuid,text) to authenticated;

create or replace function public.flex_approve_delivery(p_contract_id uuid)
returns void language plpgsql security definer set search_path=public as $$
declare v_c record; v_d uuid;
begin
  select * into v_c from public.contracts where id=p_contract_id for update;
  if not found or v_c.client_id<>auth.uid() or v_c.status<>'aguardando_analise' then
    raise exception 'Aprovação não permitida' using errcode='42501'; end if;
  select id into v_d from public.deliverables where contract_id=p_contract_id order by version desc limit 1;
  update public.deliverables set status='aprovada' where id=v_d;
  update public.contracts set status='concluido',approved_at=now(),completed_at=now() where id=p_contract_id;
  insert into public.contract_events(contract_id,event,from_status,to_status,actor_id)
    values(p_contract_id,'entrega_aprovada','aguardando_analise','concluido',auth.uid());
  insert into public.notifications(user_id,kind,title,body,link)
    values(v_c.freelancer_id,'projeto_concluido','Entrega aprovada',v_c.title,'/contrato/'||p_contract_id);
end $$;
revoke all on function public.flex_approve_delivery(uuid) from public, anon;
grant execute on function public.flex_approve_delivery(uuid) to authenticated;

-- Apenas chave service_role pode conciliar pagamentos confirmados por consulta direta ao Asaas.
create or replace function public.flex_apply_asaas_event(p_event_id text,p_event_type text,
  p_external_id text,p_value_cents bigint,p_net_cents bigint,p_event_payload jsonb)
returns text language plpgsql security definer set search_path=public as $$
declare v_payment public.payments%rowtype; v_event bigint; v_status text; v_fee bigint;
begin
  if auth.role() <> 'service_role' then raise exception 'Acesso negado' using errcode='42501'; end if;
  if length(p_event_id)<3 or length(p_external_id)<3 or p_value_cents<=0 or p_net_cents<0
     or p_net_cents>p_value_cents then raise exception 'Evento financeiro inválido' using errcode='22023'; end if;
  select * into v_payment from public.payments where provider='asaas' and external_id=p_external_id for update;
  if not found or v_payment.gross_cents<>p_value_cents then
    raise exception 'Pagamento não localizado ou valores divergentes' using errcode='22023'; end if;
  if exists(select 1 from public.payment_webhook_events where provider='asaas' and event_id=p_event_id) then
    return 'duplicate'; end if;
  insert into public.payment_webhook_events(provider,event_id,event_type,payload,status)
    values('asaas',p_event_id,p_event_type,p_event_payload,'recebido') returning id into v_event;
  if p_event_type in ('PAYMENT_CONFIRMED','PAYMENT_RECEIVED') then
    v_status:=case when p_event_type='PAYMENT_RECEIVED' then 'recebido' else 'confirmado' end;
    v_fee:=p_value_cents-p_net_cents;
    update public.payments set status=v_status,net_cents=p_net_cents,provider_fee_cents=v_fee,
      paid_at=coalesce(paid_at,now()), settled_at=case when v_status='recebido' then now() else settled_at end,
      reconciliation_status='pendente' where id=v_payment.id;
    update public.contracts set status='pagamento_confirmado',started_at=coalesce(started_at,now())
      where id=v_payment.contract_id and status='aguardando_pagamento';
    if found then
      insert into public.contract_events(contract_id,event,from_status,to_status)
        values(v_payment.contract_id,'pagamento_confirmado','aguardando_pagamento','pagamento_confirmado');
    end if;
    insert into public.commissions(contract_id,payment_id,rate_bps,gross_cents,commission_cents,
      provider_fee_cents,freelancer_gross_cents,status)
      select c.id,v_payment.id,c.commission_bps,c.gross_amount_cents,c.commission_cents,v_fee,
         c.gross_amount_cents-c.commission_cents,'prevista'
      from public.contracts c where c.id=v_payment.contract_id
      and not exists(select 1 from public.commissions where payment_id=v_payment.id);
  elsif p_event_type in ('PAYMENT_REFUNDED','PAYMENT_CHARGEBACK_REQUESTED') then
    update public.payments set status=case when p_event_type='PAYMENT_REFUNDED' then 'reembolsado' else 'chargeback' end
      where id=v_payment.id;
    update public.commissions set status='estornada' where payment_id=v_payment.id;
    update public.contracts set status=case when p_event_type='PAYMENT_REFUNDED' then 'reembolsado' else 'chargeback' end
      where id=v_payment.contract_id;
  end if;
  update public.payment_webhook_events set status='processado',processed_at=now() where id=v_event;
  return 'processed';
end $$;
revoke all on function public.flex_apply_asaas_event(text,text,text,bigint,bigint,jsonb) from public, anon, authenticated;
grant execute on function public.flex_apply_asaas_event(text,text,text,bigint,bigint,jsonb) to service_role;

commit;
