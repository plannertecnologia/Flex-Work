# Flex Work — Marketplace de freelancers

MVP React + TypeScript + Vite, utilizando Supabase (Auth, PostgreSQL e Storage).

## Recursos implementados

- Home responsiva, catálogo de serviços e filtro por categoria/palavra-chave
- Vitrine de freelancers aprovados
- Cadastro e autenticação via Supabase Auth
- Painel de usuário com perfil, ativação como freelancer, serviços com pacote Básico e portfólio
- Serviço publicado condicionado às regras existentes no Supabase

**Não implementados nesta versão:** Asaas/pagamento, contratação, chat, ranking, moderação/admin completo. A aplicação não está pronta para processar transações.

## Executar localmente

1. Instale Node.js 20+ e execute `npm install`.
2. Copie `.env.example` para `.env`, preenchendo a Project URL e a chave pública `anon`/publishable do Supabase. **Nunca coloque `service_role`, senha do banco ou token Asaas no front-end.**
3. Execute `npm run dev` e abra `http://localhost:5173`.
4. Faça `npm run build` para testar a compilação.

## Publicação Cloudflare Pages

- Conecte o repositório GitHub ao Cloudflare Pages.
- Preset: Vite; build command: `npm run build`; output directory: `dist`.
- Configure `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY` e `VITE_SITE_URL` nas variáveis do Pages.
- Em Supabase > Authentication > URL Configuration, ajuste Site URL para a URL do Pages e inclua-a nas Redirect URLs.
- `public/_redirects` garante fallback das rotas para `index.html`.

## Banco

O arquivo `supabase/setup_all.sql` foi recuperado do Emergent e **não deve ser aplicado novamente sem revisão e backup**. Ele contém estruturas também de fases ainda não implementadas.

**Segurança:** se você executou `test_users.sql`, existem usuários de demonstração com senhas conhecidas; remova-os antes de qualquer lançamento público. Revise as políticas RLS e funções SQL antes de produção.

## Limitações de validação

O código foi montado a partir de uma base de trabalho; a instalação de dependências e o build não puderam ser concluídos no ambiente de criação. Faça os testes antes de produção.
