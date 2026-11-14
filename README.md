## Haskell Setup

1. If you haven't already, [install Stack](https://haskell-lang.org/get-started)
	* On POSIX systems, this is usually `curl -sSL https://get.haskellstack.org/ | sh`
2. Install the `yesod` command line tool: `stack install yesod-bin --install-ghc`
3. Build libraries: `stack build`

If you have trouble, refer to the [Yesod Quickstart guide](https://www.yesodweb.com/page/quickstart) for additional detail.

## PostgreSQL Setup

The application uses PostgreSQL through Persistent. Install PostgreSQL, including
the command-line tools, headers and client libraries (`libpq`). On Windows, add
the installation's `bin` directory to `PATH` and restart the terminal. Check that
`pg_config --version` works before building; the Haskell driver needs it.

Using `psql -U postgres`, create a login and separate development and test databases:

```sql
CREATE ROLE meu_crud WITH LOGIN;
\password meu_crud
CREATE DATABASE meu_crud OWNER meu_crud;
CREATE DATABASE meu_crud_test OWNER meu_crud;
```

The `\password` command prompts for a password without putting it in SQL history.
Set the same password in the terminal that will run the application or tests.
For PowerShell, use a masked prompt:

```powershell
$credential = Get-Credential -UserName meu_crud -Message 'PostgreSQL credentials'
$env:YESOD_PGPASS = $credential.GetNetworkCredential().Password
```

Connection defaults in `config/settings.yml` are `localhost:5432`, user `meu_crud`
and database `meu_crud`. Override them with `YESOD_PGHOST`, `YESOD_PGPORT`,
`YESOD_PGUSER`, `YESOD_PGPASS`, `YESOD_PGDATABASE` and `YESOD_PGPOOLSIZE`.
Do not commit passwords to configuration files.

Persistent creates and updates tables when the application starts; the database
and role must already exist. Existing SQLite data is not transferred automatically.

## Development

Start a development server with:

```
stack exec -- yesod devel
```

As your code changes, your site will be automatically recompiled and redeployed to localhost.

## Tests

Tests always use the `meu_crud_test` database, with the same host, port and
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
