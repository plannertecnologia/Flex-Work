// Flex Work — cobrança SOMENTE sandbox. Não habilitar produção sem split auditado.
import { createClient } from 'npm:@supabase/supabase-js@2';
const asaas = 'https://api-sandbox.asaas.com/v3';
const env = (name: string) => Deno.env.get(name) || '';
function reply(data: unknown, status = 200, origin = '*') {
  return new Response(JSON.stringify(data), { status, headers: {
    'content-type':'application/json', 'access-control-allow-origin':origin,
    'access-control-allow-headers':'authorization, apikey, content-type',
    'access-control-allow-methods':'POST, OPTIONS', 'vary':'Origin' } });
}
function money(cents: number) { return Number((cents / 100).toFixed(2)); }
async function requestAsaas(path: string, method = 'GET', body?: object) {
  const resp = await fetch(`${asaas}/${path}`, { method, headers: {
    'accept':'application/json','content-type':'application/json',
    'access_token': env('ASAAS_SANDBOX_API_KEY'), 'User-Agent':'FlexWork/0.2 (sandbox)' },
    body: body ? JSON.stringify(body) : undefined });
  const result = await resp.json().catch(() => ({}));
  if (!resp.ok) throw new Error(`Asaas ${resp.status}: ${JSON.stringify(result).slice(0,250)}`);
  return result;
}
Deno.serve(async (req) => {
  const expectedOrigin = env('FLEX_WORK_ORIGIN');
  const origin = req.headers.get('origin') || '';
  const allow = expectedOrigin && origin === expectedOrigin ? expectedOrigin : expectedOrigin || '';
  if (req.method === 'OPTIONS') return reply({}, 200, allow);
  if (req.method !== 'POST' || !expectedOrigin || origin !== expectedOrigin)
    return reply({error:'Origem ou método não permitido.'},403,allow);
  if (env('ASAAS_ENVIRONMENT') !== 'sandbox' || env('ALLOW_SANDBOX_NO_SPLIT') !== 'true' || !env('ASAAS_SANDBOX_API_KEY'))
    return reply({error:'Checkout de teste não foi habilitado pelo administrador.'},503,allow);
  const supabaseUrl=env('SUPABASE_URL'), anonKey=env('SUPABASE_ANON_KEY'),serviceKey=env('SUPABASE_SERVICE_ROLE_KEY');
  if(!supabaseUrl || !anonKey || !serviceKey) return reply({error:'Configuração do Supabase incompleta.'},503,allow);
  const bearer=req.headers.get('authorization')||'';
  if(!bearer.startsWith('Bearer ')) return reply({error:'Sessão necessária.'},401,allow);
  const client=createClient(supabaseUrl,anonKey,{global:{headers:{Authorization:bearer}}});
  const {data:identity,error:authErr}=await client.auth.getUser(bearer.slice(7));
  if(authErr || !identity.user) return reply({error:'Sessão inválida.'},401,allow);
  const user=identity.user;
  let input:{contract_id?:string;client_document?:string};
  try { input=await req.json(); } catch {return reply({error:'Requisição inválida.'},400,allow);}
  const contractId=input.contract_id;
  const cpfCnpj=(input.client_document||'').replace(/\D/g,'');
  if(!contractId || !/^[a-f\d-]{36}$/i.test(contractId) || ![11,14].includes(cpfCnpj.length))
    return reply({error:'Contrato e CPF/CNPJ válidos são obrigatórios.'},400,allow);
  const admin=createClient(supabaseUrl,serviceKey,{auth:{persistSession:false,autoRefreshToken:false}});
  const {data:contract,error:cErr}=await admin.from('contracts').select('id,title,client_id,freelancer_id,gross_amount_cents,commission_cents,status')
     .eq('id',contractId).eq('client_id',user.id).maybeSingle();
  if(cErr || !contract || contract.status!=='aguardando_pagamento')
    return reply({error:'Contrato não está disponível para pagamento.'},409,allow);
  const {data:profile}=await admin.from('profiles').select('full_name,status').eq('id',user.id).maybeSingle();
  if(profile?.status!=='ativo') return reply({error:'Perfil bloqueado.'},403,allow);
  // Cobrança sem split APENAS no sandbox, sem transferência ao freelancer.
  // A comissão de 12,5% fica registrada no contrato, não se converte aqui em payout real.
  const reference=`flexwork-${contract.id}`;
  const key=`contract-${contract.id}`;
  try {
    const {data:found,error:findError}=await admin.from('payments').select('id,external_id,gross_cents')
      .eq('idempotency_key',key).maybeSingle();
    if(findError) throw findError;
    if(found && found.gross_cents!==contract.gross_amount_cents) throw new Error('Valor de cobrança divergente.');
    if(!found){
      const {error:insError}=await admin.from('payments').insert({contract_id:contract.id,idempotency_key:key,provider:'asaas',
        gross_cents:contract.gross_amount_cents,status:'pendente',method:null});
      if(insError && insError.code!=='23505') throw insError;
    }
    // Recupera operação existente mesmo após timeout, sem gerar cobrança duplicada.
    let payment;
    const search=await requestAsaas('payments?externalReference='+encodeURIComponent(reference)+'&limit=10');
    payment=search.data?.find((p:{id:string,externalReference?:string})=>p.externalReference===reference);
    if(!payment){
      let customer;
      const customerResult=await requestAsaas('customers?externalReference='+encodeURIComponent(user.id)+'&limit=10');
      customer=customerResult.data?.find((c:{id:string,externalReference?:string})=>c.externalReference===user.id);
      if(!customer){
        customer=await requestAsaas('customers','POST',{name:profile.full_name||user.email||'Cliente Flex Work',
          cpfCnpj,email:user.email,externalReference:user.id,notificationDisabled:true});
      }
      const due=new Date();due.setDate(due.getDate()+3);
      payment=await requestAsaas('payments','POST',{customer:customer.id,billingType:'UNDEFINED',
        value:money(contract.gross_amount_cents),dueDate:due.toISOString().slice(0,10),
        description:`Flex Work • ${contract.title}`.slice(0,255),externalReference:reference});
    }
    if(!payment.id || !payment.invoiceUrl) throw new Error('Cobrança sem link retornado pelo Asaas.');
    const link=new URL(payment.invoiceUrl);
    if(link.protocol!=='https:' || !(link.hostname==='asaas.com'||link.hostname.endsWith('.asaas.com')))
      throw new Error('Link de cobrança não reconhecido.');
    const {error:upError}=await admin.from('payments').update({external_id:payment.id,status:'aguardando_pagamento'})
      .eq('idempotency_key',key);
    if(upError)throw upError;
    return reply({invoice_url:link.toString(),environment:'sandbox',split_enabled:false,
      commission_cents:contract.commission_cents,gross_cents:contract.gross_amount_cents,
      warning:'Pagamento de teste. Nenhum repasse ao freelancer é realizado.'},200,allow);
  } catch (err) {
    // Não incluir CPF, API key ou credenciais na resposta e logs.
    console.error('Erro gerando cobrança Asaas Sandbox', err instanceof Error ? err.message.replace(/\$aact_[^\s"']+/g,'[REDACTED]') : 'erro');
    return reply({error:'Falha ao criar/recuperar cobrança no Asaas Sandbox. Confira a configuração e tente novamente.'},502,allow);
  }
});
