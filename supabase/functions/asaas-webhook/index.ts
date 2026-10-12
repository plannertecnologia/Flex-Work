// Flex Work — webhook Asaas sandbox, valida segredo + pagamento no Asaas e concilia via RPC transacional.
import { createClient } from 'npm:@supabase/supabase-js@2';
const env=(k:string)=>Deno.env.get(k)||'';
function json(data:unknown,status=200){return new Response(JSON.stringify(data),{status,headers:{'content-type':'application/json'}})}
function safeEqual(a:string,b:string){
  const enc=new TextEncoder();const aa=enc.encode(a),bb=enc.encode(b);
  let diff=aa.length^bb.length;for(let i=0;i<Math.max(aa.length,bb.length);i++)diff|=(aa[i]??0)^(bb[i]??0);
  return diff===0;
}
Deno.serve(async(req)=>{
  if(req.method!=='POST')return json({error:'Method not allowed'},405);
  const token=env('ASAAS_WEBHOOK_TOKEN');
  if(token.length<32 || !safeEqual(req.headers.get('asaas-access-token')||'',token)) return json({error:'Unauthorized'},401);
  if(env('ASAAS_ENVIRONMENT')!=='sandbox')return json({error:'Sandbox only'},503);
  let body:{id?:string;event?:string;payment?:{id?:string}};
  try {body=await req.json()}catch {return json({error:'Invalid JSON'},400)}
  if(!body.id || !body.payment?.id || !body.event)return json({error:'Missing fields'},400);
  const service=createClient(env('SUPABASE_URL'),env('SUPABASE_SERVICE_ROLE_KEY'),
    {auth:{persistSession:false,autoRefreshToken:false}});
  try{
    const {data:already}=await service.from('payment_webhook_events').select('id')
      .eq('provider','asaas').eq('event_id',body.id).maybeSingle();
    if(already)return json({ok:true,duplicate:true});
    const check=await fetch('https://api-sandbox.asaas.com/v3/payments/'+encodeURIComponent(body.payment.id),{
      headers:{'access_token':env('ASAAS_SANDBOX_API_KEY'),'User-Agent':'FlexWork/0.2 (sandbox)','accept':'application/json'}});
    if(!check.ok)return json({error:'Could not validate payment status'},502);
    const p=await check.json();
    // Nunca confiar apenas nos dados recebidos pelo webhook. Valida estado consultando o provedor.
    const type=body.event;
    const ok=(type==='PAYMENT_CONFIRMED' && ['CONFIRMED','RECEIVED'].includes(p.status)) ||
      (type==='PAYMENT_RECEIVED' && p.status==='RECEIVED') ||
      (type==='PAYMENT_REFUNDED' && p.status==='REFUNDED');
    if(!ok)return json({ok:true,ignored:'state not confirmed'});
    const {data:local}=await service.from('payments').select('contract_id,gross_cents')
      .eq('provider','asaas').eq('external_id',p.id).maybeSingle();
    if(!local)return json({error:'Unknown payment; retry later'},409);
    if(p.externalReference!==`flexwork-${local.contract_id}`)return json({error:'Reference mismatch'},409);
    const cents=(n:unknown)=>typeof n==='number' && Number.isFinite(n)?Math.round(n*100):-1;
    const gross=cents(p.value),net=cents(p.netValue);
    if(gross!==local.gross_cents || net<0 || net>gross)return json({error:'Amount mismatch'},409);
    const {data,error}=await service.rpc('flex_apply_asaas_event',{
      p_event_id:body.id,p_event_type:type,p_external_id:p.id,p_value_cents:gross,
      p_net_cents:net,p_event_payload:{id:body.id,event:type,payment:{id:p.id,status:p.status}}});
    if(error){console.error('Falha ao conciliar evento',error.message);return json({error:'Database conflict'},500)}
    return json({ok:true,result:data});
  }catch(err){console.error('Webhook processing error',err instanceof Error?err.message:'unknown');return json({error:'Unexpected failure'},500)}
});
