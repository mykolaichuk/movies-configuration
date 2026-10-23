# Pipelines

| File | What | Triggered by |
| --- | --- | --- |
| `configure.yml` | static checks → Preview (`--check --diff`) → Configure (approval: `movies-config`) | push to `main` that is not a docs change; every successful `infra` run on `main` |
| `validate.yml` | static checks only | push to `main` touching docs; every PR via branch policy |
| `templates/static-checks.yml` | gitleaks, ansible-lint, markdownlint | included by both pipelines |
| `templates/run-playbook.yml` | downloads `stack-outputs`, reads the SSH key from Key Vault, runs `site.yml` | included twice by `configure.yml` |

All of them run in the self-hosted pool `movies-pool`.

## First run

1. Make sure the infra pipeline has run on `main` **after** the `dns_zone`
   output was added: its `stack-outputs` artifact must contain `dns_zone`.
2. *Pipelines → New pipeline → Azure Repos Git → movies-configuration →
   Existing YAML file → `/pipelines/configure.yml`*. Save it as
   **`configure`**.
3. `resources.pipelines[0].source` in `configure.yml` must be the exact name
   of the movies-infra pipeline in Azure DevOps (`infra`). If yours has a
   different name, change it there.
4. Run. Expect two pauses on the first run:
   - *"This pipeline needs permission to access a resource"* for
     `sc-movies-azure` (and, if listed, the `movies-config` environment)
     → **Permit**;
   - the approval of the `movies-config` environment → read the Preview
     log, then **Approve**.
5. Add `validate.yml` the same way (name: `configure-validate`).

The first Preview of a fresh VM shows warnings: a dry run cannot install
packages, so tasks that depend on them fail "on paper". The step is marked
*continue on error*; the approved run is the one that counts. From the
second run on, Preview shows the real difference, and an unchanged VM
reports `changed=0`.

## Pull request validation

*Repos → Branches → main → ⋮ → Branch policies → Build validation → +*:
pipeline `configure-validate`, no path filter, required. Preview runs on PR branches
too, but Configure runs only on `main`.

## After the app VM was replaced

SSH trusts a host key on first use and refuses it if it changes. After
`terraform apply` recreated the VM, run `configure` once with
**Forget the app VM SSH host key** ticked.

## Design rules

- Every job runs on the agent in the hub: SSH to the app VM and SQL are
  reachable only from there.
- The SSH private key exists only in Key Vault and, during a job, in the
  agent's temp directory (owner-only, shredded on exit).
- Azure access uses the `sc-movies-azure` service connection (workload
  identity federation), authorised per pipeline. `sqlcmd` uses the agent's
  managed identity, which is the SQL Entra admin.
- Approval before anything changes on the VM; the same playbook ran as a
  dry run first, so the approver sees the diff.
