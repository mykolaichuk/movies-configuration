# movies-configuration

Ansible for the **Movies** demo: everything that happens *inside* the
machines after Terraform has created them.

| Repository | Tool | Answers the question |
| --- | --- | --- |
| [movies-infra](https://github.com/mykolaichuk/movies-infra) | Terraform | *What exists in Azure?* |
| **movies-configuration** (this one) | Ansible | *How is each VM configured?* |
| [movies-app](https://github.com/mykolaichuk/movies-app) | Node.js | *What does the application do?* |

To deploy your own copy, start with
[Reproducing the project](https://github.com/mykolaichuk/movies-infra#reproducing-the-project).

## Layout

```text
site.yml                 the playbook: preflight → database user → app VM
inventory/hosts.yml      one app VM; address and user come from Terraform outputs
inventory/group_vars/    values shared by several roles
roles/                   one role per concern (table below)
pipelines/               Azure Pipelines YAML (see pipelines/README.md)
ansible.cfg              SSH settings (host key trust on first use)
.ansible-lint            production profile
```

| Role | Runs on | What it does |
| --- | --- | --- |
| `sql_user` | agent | creates the contained database user for the app's managed identity and adds it to `db_datareader` / `db_datawriter` |
| `common` | app VM | base packages, unattended security upgrades, sshd hardening |
| `nodejs` | app VM | Node.js 24 from NodeSource (same major as the build agent) |
| `app_service` | app VM | `movies` system user, `/opt/movies`, non-secret env file, sandboxed systemd units `movies-web` and `movies-worker` |
| `certbot` | app VM | Let's Encrypt certificate via DNS-01 in Azure DNS with the VM's managed identity; renewal timer |
| `nginx` | app VM | TLS, security headers, reverse proxy, video cache in 1 MB slices, rate limit on `/auth/`, logs to syslog `local7` |

## Where the values come from

Nothing is copied by hand. The infra pipeline publishes the non-sensitive
Terraform outputs as the artifact `stack-outputs`; this repository's
pipeline downloads it and passes it to Ansible as
`--extra-vars @stack-outputs.json`. The first play stops with a clear
message if they are missing.

| Needed | Source |
| --- | --- |
| VM address, admin user | output `app_vm` |
| SSH private key | Key Vault secret `ansible-ssh-private-key`, read at run time |
| Identity for SQL and certbot | output `app_identity` |
| Database, storage, vault, Entra app, telemetry | outputs `sql`, `storage`, `key_vault`, `entra_app`, `monitoring` |
| DNS zone for DNS-01 | output `dns_zone` |

## Security decisions

- **No secrets on disk.** `/etc/movies/movies.env` holds only addresses and
  IDs. The app reads its secrets from Key Vault with its managed identity.
- **No passwords anywhere.** SQL uses Entra-only authentication: the agent
  is the Entra admin and creates the app user; the app signs in with its
  managed identity.
- **No directory rights for SQL.** `CREATE USER ... FROM EXTERNAL PROVIDER`
  (even `WITH OBJECT_ID`) makes the SQL server look the principal up in
  Entra ID with its own identity, which then needs the tenant-wide
  *Directory Readers* role. Instead the user is created from its SID
  (`WITH SID = <client ID as binary>, TYPE = E`). SQL does not validate the
  ID, so it comes only from Terraform outputs.
- **Least privilege in the database.** The app reads and writes data but
  cannot change the schema. Migrations run from the agent in the movies-app
  pipeline.
- **No DNS API token.** certbot proves domain ownership through Azure DNS
  with the VM's identity, which may change only the app's own zone
  (`domain_name` in movies-infra).
- **Two layers for SSH.** The NSG allows port 22 only from the agents
  subnet; sshd itself allows only key-based login of the Ansible user.
- **Sandboxed services.** The systemd units run as an unprivileged user with
  a read-only system, no new privileges and a syscall filter. The code is
  owned by root, so the app cannot modify itself.
- **Only one public host name.** HTTPS requests for any other name (a
  scanner hitting the IP) get no certificate: the handshake is rejected.

## Contract with movies-app

The configuration prepares the runtime; the movies-app pipeline deploys
the code into it.

| Item | Value |
| --- | --- |
| Release directory | `/opt/movies/releases/<build-id>`, owned by root |
| Active release | symlink `/opt/movies/current` |
| Entry points | `src/web.js` (HTTP on `127.0.0.1:3000`), `src/worker.js` |
| Restart | `sudo systemctl restart movies-web movies-worker` |
| Health check | `GET /healthz` (proxied by nginx, not logged) |
| Media URLs | `/media/...`: public, cached by nginx, must not set cookies |
| Sign-in URLs | `/auth/...`: rate-limited by nginx |
| Content-Security-Policy | set by the app (it knows its YouTube/TMDB sources) |

Until a release exists, the units are enabled but skipped
(`ConditionPathExists`) and nginx answers with a maintenance page.

## Running it

Only through `pipelines/configure.yml`: the app VM and the database are
reachable only from the agent in the hub VNet. Locally, run the linters:

```bash
ansible-lint
npx --yes markdownlint-cli2@0.23.3 "**/*.md"
```

## Conventions

- Code, comments and docs in English.
- `ansible-lint` (production profile), `gitleaks` and `markdownlint-cli2`
  must pass before merge.
- Every task is idempotent: a second run reports no changes.
