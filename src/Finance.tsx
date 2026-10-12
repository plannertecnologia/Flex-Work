import React, {useCallback, useEffect, useState} from 'react';
import {Link, Navigate} from 'react-router-dom';
import type {Session, SupabaseClient} from '@supabase/supabase-js';
import {Wallet, ReceiptText, ShieldAlert, ArrowDownToLine, Clock3, CheckCircle2} from 'lucide-react';

type Props={db:SupabaseClient|null;session:Session|null};
type Summary={environment:string;gross_cents:number;platform_commission_cents:number;provider_fees_cents:number;earned_demo_cents:number;reserved_demo_cents:number;withdrawn_demo_cents:number;available_demo_cents:number;real_available_cents:number;completed_paid_contracts:number};
type Statement={contract_id:string;title:string;completed_at:string;gross_cents:number;platform_commission_cents:number;freelancer_earnings_cents:number;provider_fee_cents:number};
type Withdrawal={id:string;freelancer_id:string;amount_cents:number;status:string;created_at:string;processed_at:string|null;notes:string|null};
const money=(c:number|null|undefined)=>new Intl.NumberFormat('pt-BR',{style:'currency',currency:'BRL'}).format((c||0)/100);
const date=(s:string)=>new Date(s).toLocaleDateString('pt-BR');
function errorText(e:unknown){if(e instanceof Error)return e.message;if(e&&typeof e==='object'&&'message'in e)return String((e as {message:unknown}).message);return 'Não foi possível concluir a operação.'}

export function Finance({db,session}:Props){
 const [summary,setSummary]=useState<Summary|null>(null),[statement,setStatement]=useState<Statement[]>([]),[withdrawals,setWithdrawals]=useState<Withdrawal[]>([]),[amount,setAmount]=useState(''),[busy,setBusy]=useState(false),[loading,setLoading]=useState(true),[feedback,setFeedback]=useState('');
 const load=useCallback(async()=>{
   if(!db||!session)return;
   setLoading(true);
   const [s,h,w]=await Promise.all([
    db.rpc('flex_finance_summary'),
    db.rpc('flex_finance_statement'),
    db.from('flex_withdrawal_requests').select('*').eq('freelancer_id',session.user.id).order('created_at',{ascending:false}).limit(50)
   ]);
   if(s.error||h.error||w.error)setFeedback(errorText(s.error||h.error||w.error));
   else {setSummary(s.data as Summary);setStatement((h.data||[]) as Statement[]);setWithdrawals((w.data||[]) as Withdrawal[])}
   setLoading(false);
 },[db,session?.user.id]);
 useEffect(()=>{void load()},[load]);
 if(!session)return <Navigate to="/entrar"/>;
 async function request(e:React.FormEvent){
   e.preventDefault();if(!db||!summary)return;
   const raw=amount.trim().replace(/\s/g,'');
   const normalized=raw.includes(',')?raw.replace(/\./g,'').replace(',','.') : raw;
   if(!/^\d+(\.\d{1,2})?$/.test(normalized)){setFeedback('Informe um valor como 10,00.');return}
   const cents=Math.round(Number(normalized)*100);
   if(cents<1000||cents>summary.available_demo_cents){setFeedback('Informe um valor entre R$ 10,00 e o saldo simulado disponível.');return}
   setBusy(true);setFeedback('');
   const {error}=await db.rpc('flex_request_test_withdrawal',{p_amount_cents:cents});
   setBusy(false);
   if(error)setFeedback(errorText(error));else{setFeedback('Solicitação de TESTE registrada. Nenhuma transferência bancária foi feita.');setAmount('');await load()}
 }
 async function cancel(id:string){if(!db)return;setBusy(true);setFeedback('');const{error}=await db.rpc('flex_cancel_test_withdrawal',{p_id:id});setBusy(false);setFeedback(error?errorText(error):'Solicitação cancelada.');if(!error)await load()}
 const labels:Record<string,string>={solicitado:'Em análise (teste)',simulado:'Saque simulado',rejeitado:'Rejeitado',cancelado:'Cancelado'};
 return <main className="shell pad fw-finance-screen">
  <div className="fw-finance-head"><div><span className="overline">Flex Work · Área freelancer</span><h1 className="pageTitle">Meu financeiro</h1><p className="muted">Extrato de serviços concluídos, comissão de 12,5% e simulação de solicitações de saque.</p></div><Link className="fw-secondary" to="/contratos">Ver contratos</Link></div>
  <div className="fw-sandbox-alert" role="status"><ShieldAlert size={20}/><div><strong>Ambiente demonstrativo — sem dinheiro disponível para saque</strong><p>O Asaas Sandbox não guarda valores reais. Todos os saldos e saques abaixo são simulações para validar o processo. O saldo real disponível para retirada é R$ 0,00. Nenhuma transferência é executada.</p></div></div>
  {loading?<p>Carregando extrato...</p>:<>
  <div className="fw-finance-stats">
   <div className="panel fw-finance-metric"><span><Wallet size={17}/> Ganhos simulados do freelancer</span><strong>{money(summary?.earned_demo_cents)}</strong><small>Valor de serviços concluídos, após comissão da plataforma</small></div>
   <div className="panel fw-finance-metric"><span><CheckCircle2 size={17}/> Disponível para teste</span><strong>{money(summary?.available_demo_cents)}</strong><small>Saldo virtual após solicitações e saques simulados</small></div>
   <div className="panel fw-finance-metric"><span><Clock3 size={17}/> Reservado para teste</span><strong>{money(summary?.reserved_demo_cents)}</strong><small>Solicitações aguardando revisão administrativa</small></div>
   <div className="panel fw-finance-metric"><span><ReceiptText size={17}/> Comissão Flex Work</span><strong>{money(summary?.platform_commission_cents)}</strong><small>12,5% sobre o valor bruto dos contratos elegíveis</small></div>
  </div>
  <div className="fw-finance-grid">
    <section className="panel fw-card"><h2><ReceiptText size={20}/> Extrato de contratos</h2><p className="muted">Somente contratos concluídos com pagamento confirmado e sem disputa ou reembolso pendente.</p>
      {statement.length? <div className="fw-finance-list">{statement.map(s=><div className="fw-finance-line" key={s.contract_id}><div><Link to={'/contrato/'+s.contract_id}><b>{s.title}</b></Link><small>{date(s.completed_at)} · Bruto {money(s.gross_cents)} · Comissão {money(s.platform_commission_cents)}</small><small>Tarifa Asaas: {money(s.provider_fee_cents)} (exibida separadamente; política final em homologação)</small></div><strong>{money(s.freelancer_earnings_cents)}</strong></div>)}</div>:<div className="empty tiny">Sem contratos elegíveis ainda.</div>}
      <p className="muted">Total bruto elegível: {money(summary?.gross_cents)} · Tarifas informativas do Asaas: {money(summary?.provider_fees_cents)}</p>
    </section>
    <aside className="panel fw-card fw-withdraw-card"><h2><ArrowDownToLine size={20}/> Solicitar saque de teste</h2><p className="muted">Para simular a etapa de saque e conferir o processo de aprovação pelo administrador. Não peça nem informe sua chave Pix nesta versão.</p>
     <form onSubmit={request} className="fields"><label>Valor a simular (R$)<input value={amount} onChange={e=>setAmount(e.target.value)} placeholder="Ex.: 50,00" inputMode="decimal" required/></label><button className="button wide" disabled={busy||!summary||summary.available_demo_cents<1000}>{busy?'Registrando...':'Solicitar saque (simulação)'}</button></form>
     <p className="fw-warning">Saques reais estão bloqueados até homologação do split, identificação do recebedor, regras de disponibilidade, antifraude e integração com transferências Asaas.</p>
    </aside>
  </div>
  <section className="panel fw-card fw-history"><h2><Clock3 size={20}/> Histórico de solicitações</h2>
    {withdrawals.length?withdrawals.map(w=><div className="fw-finance-line" key={w.id}><div><b>{money(w.amount_cents)}</b><small>{date(w.created_at)} · {labels[w.status]||w.status}</small></div>{w.status==='solicitado'?<button className="fw-secondary" disabled={busy} onClick={()=>cancel(w.id)}>Cancelar</button>:<span className="muted">{w.status==='simulado'?'Sem repasse real':''}</span>}</div>):<p className="muted">Nenhuma solicitação registrada.</p>}
  </section>
  </>}
  {feedback&&<p className="formMessage" role="status">{feedback}</p>}
 </main>;
}

export function WithdrawalAdmin({db,session}:Props){
 const[rows,setRows]=useState<Withdrawal[]>([]),[busy,setBusy]=useState(false),[info,setInfo]=useState('');
 const load=useCallback(async()=>{if(!db||!session)return;const{data,error}=await db.from('flex_withdrawal_requests').select('*').order('created_at',{ascending:false}).limit(50);if(error)setInfo(errorText(error));else setRows((data||[]) as Withdrawal[])},[db,session?.user.id]);
 useEffect(()=>{void load()},[load]);
 async function review(id:string,approve:boolean){if(!db||!session)return;setBusy(true);setInfo('');const{error}=await db.rpc('flex_admin_review_test_withdrawal',{p_id:id,p_approve:approve,p_notes:approve?'Fluxo testado no sandbox. Sem transferência bancária.':'Rejeitado no ambiente de testes.'});setBusy(false);setInfo(error?errorText(error):approve?'Pedido marcado como simulado. Nenhuma transferência realizada.':'Pedido rejeitado.');if(!error)await load()}
 return <section className="panel fw-card fw-history"><h2><Wallet size={20}/> Solicitações de saque · Sandbox</h2><p className="fw-warning">Aprovar aqui registra uma simulação contábil; não envia Pix nem transfere recursos.</p>
  {rows.length?rows.map(w=><div className="fw-finance-line" key={w.id}><div><b>{money(w.amount_cents)}</b><small>Profissional {w.freelancer_id.slice(0,8)} · {date(w.created_at)} · {w.status}</small></div>{w.status==='solicitado'?<div className="fw-actions"><button className="fw-secondary" disabled={busy} onClick={()=>review(w.id,true)}>Simular aprovação</button><button className="fw-secondary" disabled={busy} onClick={()=>review(w.id,false)}>Rejeitar</button></div>:<span className="muted">{w.status}</span>}</div>):<p className="muted">Nenhuma solicitação de teste.</p>}
  {info&&<p className="formMessage" role="status">{info}</p>}
 </section>
}
