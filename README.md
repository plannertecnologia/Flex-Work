# Flex Work — v0.2 (desenvolvimento)

Marketplace de serviços da DALI Tech: React + TypeScript + Vite, Supabase PostgreSQL/Auth/Storage e implantação no Cloudflare Workers/Pages.

**Esta versão é um ambiente de desenvolvimento. Ainda não está homologada para receber dinheiro real.** O checkout preparado usa exclusivamente **Asaas Sandbox SEM split**; não executa repasse. A comissão contratual de 12,5% fica registrada separadamente da tarifa do intermediador.

## Requisitos e publicação do site

- `npm install` / `npm run build` (ou Bun).
- Cloudflare (Worker com assets estáticos ou Pages): build `npm run build`, saída `dist`.
- Configurar variáveis de **build** `VITE_SUPABASE_URL` e `VITE_SUPABASE_ANON_KEY` com a URL e **chave pública** do projeto. Não colocar secrets com prefixo `VITE_`.
- Não criar `public/_redirects`: na configuração atual Cloudflare Worker, a regra `/* /index.html 200` causou o erro 100324. A SPA deve ser servida com `not_found_handling: single-page-application`.
- Após o deploy, configure o domínio final em Supabase Auth → URL Configuration → Redirect URLs.

## Atualização do Supabase (obrigatória antes de testar contratos)

No Supabase **SQL Editor**, após já ter executado `supabase/setup_all.sql` em etapa anterior, execute **somente**:

`supabase/migrations/202610120001_marketplace_flows.sql`

A migração cria funções transacionais seguras para contratar pacotes, enviar/aceitar propostas, enviar/aprovar entregas, pedir revisão e receber a confirmação de pagamento. As tabelas originais e os dados não são apagados.

**Não execute `setup_all.sql` novamente se o projeto já está configurado.** Antes de rodar SQL, faça backup dos dados importantes e revise as alterações. Para desenvolver em produção recomendamos migrações versionadas em vez de SQL manual repetido.

## Fluxos da aplicação

- `/projetos` — publicação de demanda; `/projeto/:id` — envio/aceite de propostas por freelancer aprovado.
- `/servico/:id` — contratação por pacote; `/comprar/:packageId` — confirmação da contratação.
- `/contratos` e `/contrato/:id` — status, timeline, mensagens, entrega, revisão e aprovação.
- `/admin` — protegido por `public.user_roles`, permite aprovação de freelancers, consulta de estatísticas, pagamentos e configurações (somente leitura das configurações nesta versão).

As mudanças de status e a comissão ficam no banco. O navegador não cria nem altera pagamentos diretamente. O app mostra os campos financeiros em valores separados e não promete custódia/escrow.

## Integração Asaas (SOMENTE SANDBOX)

A integração é opcional durante os testes dos outros fluxos e será habilitada **somente** ao configurar as Edge Functions e suas variáveis secretas.

1. Crie uma conta de teste no [Asaas Sandbox](https://sandbox.asaas.com/) e obtenha **somente** a API Key Sandbox (nunca envie pelo chat ou GitHub).
2. No Supabase **Edge Functions**, faça deploy das pastas:
   - `supabase/functions/create-asaas-checkout` (JWT obrigatório).
   - `supabase/functions/asaas-webhook` (**verify_jwt=false** apenas nessa função pública, pois o próprio webhook valida o token Asaas e consulta a API antes de conciliar).
3. Em Supabase → **Edge Function Secrets**, configure:

   | Variável | Uso |
   | --- | --- |
   | `ASAAS_ENVIRONMENT` | `sandbox` (produção bloqueada no código) |
   | `ASAAS_SANDBOX_API_KEY` | chave privada da conta Sandbox |
   | `ASAAS_WEBHOOK_TOKEN` | token aleatório único com 32–255 caracteres, sem espaços |
   | `FLEX_WORK_ORIGIN` | `https://flex-work-dali-tech.vandsusilvaa.workers.dev` (altere se usar outro domínio) |
   | `ALLOW_SANDBOX_NO_SPLIT` | `true` **somente durante testes** |

   `SUPABASE_URL`, `SUPABASE_ANON_KEY` e `SUPABASE_SERVICE_ROLE_KEY` são normalmente disponibilizadas no ambiente Supabase Functions; verifique no seu projeto. **Não copie a service_role para o front-end.**
4. Configure o webhook no **Asaas Sandbox** com URL:
   `https://SEU-PROJETO.supabase.co/functions/v1/asaas-webhook`
   e `authToken` idêntico a `ASAAS_WEBHOOK_TOKEN`. Selecione `PAYMENT_CONFIRMED`, `PAYMENT_RECEIVED`, `PAYMENT_REFUNDED`.
5. Teste com clientes e documentos fictícios apropriados ao sandbox. Crie um contrato, clique em **Gerar cobrança de teste**, pague no simulador e atualize a tela. Os eventos serão comparados com o Asaas antes de atualizar o banco.

**NÃO configure a chave de produção e NÃO reutilize esse endpoint para pagamentos reais.** Mesmo recebendo `PAYMENT_CONFIRMED`, o Asaas Sandbox não movimenta dinheiro. Esta versão não envia `split` ao provedor; comissões ficam marcadas como previstas até homologação de subcontas/carteiras e da tarifa real. Não se deve anunciar "pagamento protegido" nem "repasse automático" antes da homologação.

## Próximas etapas para operação comercial

- Vínculo seguro das wallets Asaas dos freelancers, conferência de custos de subconta e plano tarifário.
- Split financeiro confiável com comissão exata sobre valor bruto e taxas explicitamente atribuídas; testar valores líquidos e estornos.
- Moderação de mensagens, termos jurídicos e fluxo de disputa/reembolso.
- E-mails transacionais, recuperação de senha, testes automatizados de integração e monitoramento.
- Proteções adicionais para concorrência/idempotência de cobrança e reprocessamento de eventos.
- Backups e revisão de LGPD e contabilidade de receitas antes de habilitar produção.

## Segurança

Nunca publique `.env`, credenciais do Asaas, `service_role` nem connection string. O arquivo `.env.example` possui placeholders. **Exclua usuários de teste com senhas conhecidas**, caso tenha executado `test_users.sql` no banco destinado ao público, e altere qualquer senha compartilhada anteriormente.

## Status dos testes

- Inspeção estática de sintaxe TSX realizada; **a instalação das dependências e o build não puderam ser completados neste ambiente**.
- **Não** foi feita cobrança real ou em sandbox, pois não possuo suas chaves (e elas devem continuar privadas).
- Após enviar os arquivos ao GitHub, valide o build no Cloudflare e teste a migração preferencialmente em projeto Supabase de homologação.
