## Haskell Setup

1. If you haven't already, [install Stack](https://haskell-lang.org/get-started)
	* On POSIX systems, this is usually `curl -sSL https://get.haskellstack.org/ | sh`
2. Install the `yesod` command line tool: `stack install yesod-bin --install-ghc`
3. Build libraries: `stack build`

If you have trouble, refer to the [Yesod Quickstart guide](https://www.yesodweb.com/page/quickstart) for additional detail.

## PostgreSQL Setup

The application uses PostgreSQL through Persistent. Install PostgreSQL, including
the command-line tools, headers and client libraries (`libpq`). On Windows, add
the installation's `bin` directory to `PATH`. To update the current PowerShell
session without closing it, run:

```powershell
$env:Path = 'C:\Program Files\PostgreSQL\18\bin;' + $env:Path
```

Adjust the version directory to your installation. Check that `pg_config --version`
works before building; the Haskell driver needs it. This PATH must also be present
when running `yesod devel`, so GHC can load `libpq.dll` before the application starts.

Using `psql -U postgres`, create a login and separate development and test databases:

```sql
CREATE ROLE admin WITH LOGIN;
\password admin
CREATE DATABASE banco OWNER admin;
CREATE DATABASE banco_test OWNER admin;
```

The `\password` command prompts for a password without putting it in SQL history.
The role is an application login, not a PostgreSQL superuser. Skip creation if
the role and databases already exist.

## Local Environment

Configure the `.env` file in the project root. For a fresh checkout, use
`.env.example` as the template. Set the password locally:

```dotenv
YESOD_PGHOST=localhost
YESOD_PGPORT=5432
YESOD_PGUSER=admin
YESOD_PGPASS='your_local_password'
YESOD_PGDATABASE=banco
YESOD_PGPOOLSIZE=10
YESOD_HOST=127.0.0.1
YESOD_PORT=3000
```

The application and integration tests automatically load `.env` from the current
working directory before reading their YAML configuration. Run commands from the
project root. Existing environment variables take precedence over `.env`, which
takes precedence over YAML defaults. A missing `.env` is allowed for deployments
that supply environment variables directly. Dotenv is not loaded at compile time.

If an old password is already set in PowerShell, remove that override with
`Remove-Item Env:YESOD_PGPASS -ErrorAction SilentlyContinue` before starting.
After changing `.env`, stop and start the application again; no terminal restart
is needed. `YESOD_PORT` configures Warp; `yesod devel` controls its public proxy
port separately.

`.env` and `.env.*` are ignored by Git, except `.env.example`, which must never
contain real credentials. Do not commit passwords to YAML configuration either.

Persistent creates and updates tables when the application starts; the database
and role must already exist. Existing SQLite data is not transferred automatically.

## Domain Model

The equipment-lending domain uses seven entities, with English names in the code:

| Entity | Purpose |
| --- | --- |
| `User` (Usuario) | Existing authentication identity plus name, role, active flag and pickup address |
| `Category` (Categoria) | Equipment grouping, with a unique name |
| `Equipment` (Equipamento) | Item owned by a user and assigned to a category; identification is unique per owner |
| `LoanRequest` (Solicitacao) | Applicant, equipment, requested period, purpose and approval status |
| `Loan` (Emprestimo) | Checkout, deadline and optional return; one loan per request |
| `Inspection` (Inspecao) | Condition at checkout/return and responsible user; one inspection of each kind per loan |
| `Maintenance` (Manutencao) | Repair reason, start and optional completion/result |

`Email` and `Comment` remain as scaffold entities for compatibility; they do not
count toward the seven domain entities. Foreign keys prevent orphaned records.
Roles, request states, equipment conditions and inspection kinds use typed enums.
All domain timestamps use `UTCTime` and PostgreSQL `timestamp with time zone`;
Domain pages display local times in the explicit UTC-03:00 timezone.

Startup migrates existing accounts without changing IDs, login identifiers or
passwords. Their initial name comes from the login, role defaults to `Student`,
and accounts remain active. Address fields are optional so existing authentication
continues to work; a complete pickup address must be enforced when publishing
equipment in the later workflow. Existing-account creation times are initialized
at migration time, since the old schema did not record them.

The data model, accounts, ViaCEP profile lookup, equipment catalog, requests,
reservations, maintenance and checkout with initial inspection are implemented.
Return/final inspection, damage-triggered maintenance and account/equipment
deactivation are the next stages; checkout currently leaves the loan open.

## Accounts and Permissions

Use **Criar conta** (`/register`) to register and **Login** (`/auth/login`) to sign in.
Logins are unique and case-sensitive, with 3 to 100 ASCII letters, digits or
`._@-`. Passwords require 12 to 128 characters and confirmation. They are stored
as salted, iterated hashes using Yesod's password store (strength 19), never as
plaintext; Unicode passwords use UTF-8.

Public registration always creates an active `Student`. Neither registration nor
profile editing accepts changes to the account role, active flag or another user.
**Profile** (`/profile`) shows the current account and allows editing its name and
pickup address. Address fields remain optional until equipment publication; when
provided, CEP must have 8 digits and UF must be a valid uppercase Brazilian state.
The profile does not change the login or password.

Protected handlers share checks for active users, administrators and owners.
Being an administrator does not bypass an owner-only operation. Inactive users
cannot sign in or continue accessing protected pages with an existing session.
Forms and password login validate CSRF tokens; logout uses Yesod's protected POST
flow. Authentication/profile request bodies and SQL debug values are excluded
from application logs.

Legacy OpenID/Yahoo login has been removed; only local password login is offered.
Accounts without a password cannot sign in using only their login, and registering
again cannot overwrite an existing account. Dummy authentication is disabled by
default, including in development; only the test configuration enables it.
Never enable `auth-dummy-login` on an instance with real data.

### Creating an Administrator

First register a normal account through the application. An operator with local
access to the project and configured database can promote that account:

```powershell
stack build --flag meu-crud:dev
stack exec -- meu-crud promote-admin LOGIN
```

Replace `LOGIN` with the exact existing login. This command uses the same local
environment/database configuration as the server, requires an active account with
a password, and fails explicitly otherwise. It is safe to repeat and exposes no
public promotion route. Sign in with that account to see **Administrador** in the
profile and access category administration.

## Equipment Lending Workflow

1. An administrator creates categories at `/categories`. Used categories cannot
   be deleted; duplicate names are rejected.
2. An owner completes the pickup address and publishes equipment at
   `/publish-equipment`. `/my-equipment` provides editing and deletion of items
   without requests or maintenance history. Identification is unique per owner.
3. Authenticated users browse `/catalog`, with literal name/category filters and
   deterministic pagination (20 items per page). Details show approved periods;
   displayed availability is informational and is rechecked on every mutation.
4. Another student requests a future period using `YYYY-MM-DD HH:MM` in UTC-03:00.
   `/requests` and `/received-requests` list outgoing and incoming requests.
   Only the requester can edit/delete a pending request. Cancellation preserves
   history; approval and refusal belong exclusively to the owner.
5. Approval reserves a half-open interval `[start, end)`. Overlaps, inactive
   participants/equipment, open loans and open maintenance block approval.
   The requester sees the full pickup address only after approval/checkout.
   The owner's address is locked while an approved request or open loan exists.
6. Owners open, edit and complete maintenance from equipment details. Opening
   requires no approved reservations, open loan or other open maintenance.
   Completion requires a result and retains the record.
7. During an approved period, the owner confirms checkout and the initial
   condition/notes. Damaged condition requires notes. This atomically creates
   one loan and one initial inspection and marks the request as collected.
   `/loans` shows participant loans, deadlines and inspection history.

All mutations use POST and Yesod form CSRF protection. Delete/cancel buttons ask
for confirmation. Equipment operations lock participant user rows in ID order,
then the equipment row inside a PostgreSQL transaction. This coordinates
approval, cancellation, maintenance and checkout, including concurrent and
duplicate submissions. Profile edits use the same user lock. Failed composite
operations roll back completely; administrators cannot perform owner mutations
on someone else's equipment.

### ViaCEP Integration

On `/profile`, enter a CEP and select **Consultar CEP**. The backend removes
spaces/hyphens, validates eight ASCII digits, and calls only
`https://viacep.com.br/ws/{cep}/json/`, with a five-second total/response timeout and
redirects disabled. Street, neighborhood, city and state fill the profile form;
review them, supply the number/complement or missing fields, then select
**Confirmar e salvar perfil**. Lookup alone never changes the saved address.

Invalid/nonexistent CEPs and HTTP, timeout or JSON failures show explicit errors
without overwriting the previous profile. Manual entry remains available and is
identified in the interface. Automated tests simulate responses rather than
depending on ViaCEP uptime. A public CEP such as `01310-100` can be used for the
real integration demonstration; do not use personal data.

Workflow tests cover CRUD/authorization/CSRF, address privacy and locking,
half-open reservation limits, overlapping concurrent approvals, maintenance
conflicts, concurrent checkout, and rollback after an inspection insert failure.
The test executable uses `-threaded` so PostgreSQL concurrency tests can progress
while another connection is waiting for a row lock.

## Development

Start a development server with:

```
stack exec -- yesod devel
```

As your code changes, your site will be automatically recompiled and redeployed to localhost.

## Tests

Tests always use the `banco_test` database from `config/test-settings.yml`, with the same host, port and
credentials as the application. `YESOD_PGDATABASE` does not override this name.
Each test deletes application data from this database; never use it for real data.
When adding models, update the cleanup order in `test/TestImport.hs` as needed.

```
stack test --flag meu-crud:library-only --flag meu-crud:dev
```

(Because `yesod devel` passes the `library-only` and `dev` flags, matching those flags means you don't need to recompile between tests and development, and it disables optimization to speed up your test compile times).

## Documentation

* Read the [Yesod Book](https://www.yesodweb.com/book) online for free
* Check [Stackage](http://stackage.org/) for documentation on the packages in your LTS Haskell version, or [search it using Hoogle](https://www.stackage.org/lts/hoogle?q=). Tip: Your LTS version is in your `stack.yaml` file.
* For local documentation, use:
	* `stack haddock --open` to generate Haddock documentation for your dependencies, and open that documentation in a browser
	* `stack hoogle <function, module or type signature>` to generate a Hoogle database and search for your query
* The [Yesod cookbook](https://github.com/yesodweb/yesod-cookbook) has sample code for various needs

## Getting Help

* Ask questions on [Stack Overflow, using the Yesod or Haskell tags](https://stackoverflow.com/questions/tagged/yesod+haskell)
* Ask the [Yesod Google Group](https://groups.google.com/forum/#!forum/yesodweb)
* There are several chatrooms you can ask for help:
	* For IRC, try Freenode#yesod and Freenode#haskell
	* [Functional Programming Slack](https://fpchat-invite.herokuapp.com/), in the #haskell, #haskell-beginners, or #yesod channels.
