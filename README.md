# Emprestimo de equipamentos entre alunos

Aplicacao para compartilhar equipamentos em estudos e projetos. Alunos publicam
itens, solicitam periodos e acompanham aprovacao, retirada, devolucao e manutencao.

- **Aplicacao:** <https://crud-yesod.onrender.com/>
- **Repositorio:** <https://github.com/Strack-The-Goblin/crud-yesod>
- **Trabalho individual:** Ruan Santos ([@Ruan6400](https://github.com/Ruan6400)).
- **Contribuicoes:** modelo e persistencia, autenticacao/permissoes, CRUD,
  integracao ViaCEP, regras transacionais, interface, testes e implantacao.

## Tecnologias e funcionalidades

Arquitetura monolitica com **Haskell/Yesod**, **Hamlet/Lucius**, **Persistent e
PostgreSQL**, Stack (snapshot LTS 20.26, GHC 9.2.8) e Docker para o Render.

- Cadastro/login, perfil e endereco de retirada.
- CRUD de categorias, equipamentos e solicitacoes pendentes.
- Aprovacao, recusa e cancelamento; bloqueio de reservas sobrepostas.
- Retirada/devolucao com inspecoes, atrasos e manutencao automatica em caso de dano.
- Exclusao sem vinculos ou desativacao com historico, sem compromissos ativos.
- Suporte administrativo, validacao de formularios e transacoes com rollback.

## Executar localmente

**Dependencias:** Git, [Stack](https://docs.haskellstack.org/en/stable/install_and_upgrade/)
atualizado e PostgreSQL com bibliotecas/headers de `libpq`. Stack instala o GHC
do snapshot. No Debian/Ubuntu, instale `build-essential libpq-dev libgmp-dev
zlib1g-dev libncurses-dev`. No Windows, inclua o `bin` do PostgreSQL no PATH:

```powershell
$env:Path = 'C:\Program Files\PostgreSQL\18\bin;' + $env:Path
pg_config --version
git clone https://github.com/Strack-The-Goblin/crud-yesod.git
Set-Location crud-yesod
```

Adapte o caminho a sua instalacao. Como administrador do PostgreSQL, execute
`psql -U postgres` e crie usuario e bancos separados:

```sql
CREATE ROLE admin WITH LOGIN;
\password admin
CREATE DATABASE banco OWNER admin;
CREATE DATABASE banco_test OWNER admin;
```

O comando `\password` solicita a senha sem grava-la no historico SQL.
Copie o exemplo e preencha **somente as credenciais locais**:

```powershell
Copy-Item .env.example .env
```

```dotenv
YESOD_PGHOST=localhost
YESOD_PGPORT=5432
YESOD_PGUSER=admin
YESOD_PGPASS='SUA_SENHA_LOCAL'
YESOD_PGDATABASE=banco
YESOD_PGPOOLSIZE=10
YESOD_HOST=127.0.0.1
YESOD_PORT=3000
```

Na raiz do projeto:

```powershell
stack build
stack exec -- meu-crud
```

Acesse <http://127.0.0.1:3000/>. O banco deve existir; as tabelas/migracoes e a
chave local de sessao sao criadas automaticamente ao iniciar. Variaveis definidas
no terminal prevalecem sobre o `.env`; reinicie a aplicacao apos alteracoes.
Nunca versione `.env`, senhas ou `config/client_session_key.aes`.

## Contas e primeiro administrador

Todo cadastro publico cria um **aluno ativo**. Login e compartilhado pelos dois
perfis; nao existe formulario publico para escolher administrador.

1. Cadastre uma conta pelo site.
2. Com o ambiente conectado ao banco dessa conta, execute:

```powershell
stack exec -- meu-crud promote-admin LOGIN
```

Substitua `LOGIN` pelo login exato existente. O comando exige conta ativa com
senha e tambem executa migracoes. Entre novamente para acessar categorias e
administracao. Admins consultam historicos e desativam registros, mas nao podem
aprovar, retirar, devolver ou manter equipamentos de outro proprietario.

Sem shell no Render, execute esse comando no computador usando **hostname
externo**, usuario, senha e database fornecidos pelo Render, com
`$env:PGSSLMODE = 'require'` no mesmo PowerShell. `YESOD_PGHOST` recebe so o
hostname, nunca a URL `postgresql://...`. Autorize seu IP no banco se necessario.
Depois restaure a configuracao local; nunca rode testes contra o banco publicado.

## Docker / Render

Crie um **Web Service / Docker** conectado ao repositorio, usando [Dockerfile](Dockerfile)
na raiz, e PostgreSQL na mesma regiao. Configure **no Web Service**:

| Variavel | Valor |
| --- | --- |
| `YESOD_PGHOST` | Hostname interno do banco Render |
| `YESOD_PGPORT` | `5432` |
| `YESOD_PGUSER` / `YESOD_PGPASS` | Usuario / senha do Render |
| `YESOD_PGDATABASE` | Nome do banco Render |
| `YESOD_PGPOOLSIZE` | `5`, respeitando o limite do banco |
| `YESOD_SESSION_KEY_BASE64` | Chave de sessao binaria codificada em Base64 |

`DATABASE_URL` sozinha nao e consumida. A imagem Linux amd64 usa Stack 3.11.1,
build de producao e usuario sem privilegios; escuta em `0.0.0.0` na `PORT` do
Render. Configure health check `/api/health`; HTTPS e gerenciado pelo Render.

**Chave de sessao:** se ja iniciou localmente, copie a chave existente:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes((Resolve-Path config\client_session_key.aes).Path)) | Set-Clipboard
```

Para uma primeira implantacao sem chave local, gere uma chave de 96 bytes no
PowerShell e copie apenas sua representacao Base64:

```powershell
$bytes = New-Object byte[] 96
$rng = [Security.Cryptography.RandomNumberGenerator]::Create()
try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
[Convert]::ToBase64String($bytes) | Set-Clipboard
Remove-Variable bytes, rng
```

Cole em **Environment Variables**, como `YESOD_SESSION_KEY_BASE64`, nao em
Secret Files. Base64 continua sendo segredo: nao publique nem compartilhe.
Mantenha a chave entre deploys/replicas; troca-la invalida sessoes anteriores.

Para Docker Desktop com PostgreSQL no computador, configure `host.docker.internal`
como host do banco e `YESOD_SESSION_KEY_BASE64` no ambiente local:

```powershell
docker build -t meu-crud .
docker run --rm -p 3000:3000 --env-file .env --env YESOD_HOST=0.0.0.0 --env YESOD_PORT=3000 meu-crud
```

O primeiro build pode demorar. O plano gratuito do Render pode hibernar;
abra o site antes da demonstracao. Confira tambem a validade do banco gratuito.

## Estrutura do banco e API externa

As sete entidades relevantes estao em [models](config/models.persistentmodels):

| Tabela | Finalidade e relacoes |
| --- | --- |
| `User` | Conta, perfil, papel e endereco |
| `Category` | Classificacao dos equipamentos |
| `Equipment` | Equipamento ligado ao proprietario e categoria |
| `LoanRequest` | Solicitante, equipamento, periodo e estado do pedido |
| `Loan` | Retirada, prazo e devolucao de uma solicitacao |
| `Inspection` | Inspecao inicial/final ligada ao emprestimo e responsavel |
| `Maintenance` | Motivo, abertura e conclusao por equipamento |

Chaves estrangeiras e unicidades preservam integridade; datas usam `UTCTime`.
`Email` e `Comment` sao auxiliares herdadas, nao contam entre as sete entidades.
Exclusao de categorias/equipamentos/contas exige ausencia de vinculos; historicos
de emprestimos, inspecoes e manutencoes sao preservados.

**ViaCEP:** no perfil, consulte um CEP, confira os campos, complete o numero e
confirme o salvamento. O backend consome `https://viacep.com.br/ws/{cep}/json/`;
os dados sao persistidos e usados como ponto de retirada. O solicitante so ve
o endereco depois da aprovacao. CEP invalido/inexistente, timeout e falhas da API
geram erro explicito; consulta nao salva automaticamente.

## Testes, demonstracao e entrega

Com PostgreSQL **local** e `banco_test` criado:

```powershell
stack test --flag meu-crud:dev
```

**Os testes apagam dados de `banco_test` no host configurado.** O nome do banco
de testes e fixado em [test-settings.yml](config/test-settings.yml); nao use
credenciais/host de producao. Ultima validacao local em 25/11/2026:
**64 testes passando**, build de producao e layout desktop/mobile verificados.

Roteiro: crie categoria como admin; complete o endereco via ViaCEP e publique
equipamento; outra conta solicita periodo futuro; proprietario aprova e demonstra
bloqueio de sobreposicao; durante o periodo aprovado, registra retirada e
devolucao com inspecoes; em caso de dano, conclui manutencao. Mostre CRUD sem
vinculos, historico e persistencia apos reiniciar.

Codigo e commits estao publicados no GitHub. Entregue os links do repositorio e
da aplicacao acima e confirme o acesso do professor. Para a arguicao, prepare-se
para explicar [rotas](config/routes.yesodroutes), [handlers](src/Handler/),
[templates](templates/), [modelo](config/models.persistentmodels),
[transacoes](src/Lending.hs) e [ViaCEP](src/ViaCEP.hs).
