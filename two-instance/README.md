# Extension: two-instance Kargo add-on

Status: **manifests written, not yet run on a cluster**. Target: Kargo
**v1.12.4** on two local kind clusters first, then EKS. The single-Project
pipeline (`kargo/`, `../kind.sh`, cluster `kargo-quickstart`) is unchanged and
can keep running next to it.

This add-on implements the target design from `kargo-promotion-design.html`: a
**dev Kargo** and a **release Kargo** in separate clusters, linked only through
Git. Locally, each runs in its own kind cluster with its own Argo CD.

## Decisions

* **Approval and deployment are separate Stages.** Merging an approval PR only
  records the approval in `two-instance/versions/<env>.yaml`. Nothing reaches the
  cluster until an admin promotes the Freight to the deploy Stage.
* **Approve Stages are manual**: `staging-approve` and `prod-approve`.
* **Strict record check (option A)**: a deploy Stage deploys only the Freight that
  `two-instance/versions/<env>.yaml` on `main` names. Staging and prod
  **rollbacks also need a PR**: re-approve the older Freight, merge, then deploy.
* **Deployed record**: after prod verification, a `prod-deployed` Stage opens a PR
  updating `two-instance/versions/prod-deployed.yaml`. A record only, not part of
  the deploy check.
* **Image digest is carried through the handoff**, and both sides deploy by
  digest, so the approved image is exactly the deployed image.
* **Git names are prefixed** (`2i/...` branches, `2i-rc-`/`2i-rel-` tags,
  `two-instance/versions/`), because both pipelines share one GitHub repo.

## Clusters

| Cluster | Runs | Argo CD | Kargo | Apps |
|---|---|---|---|---|
| `kargo-quickstart` (`../kind.sh`) | single-Project pipeline | localhost:31080 | localhost:31081 | 32080 dev, 32081 staging, 32082 prod |
| `kargo-2i-dev` | dev Kargo: `dev`, `dev-handoff` | localhost:31180 | localhost:31181 | 32180 dev |
| `kargo-2i-release` | release Kargo: staging and prod | localhost:31280 | localhost:31281 | 32281 staging, 32282 prod |

Inside each cluster the NodePorts are the same as in the single-Project cluster
(31080, 31081, 32080 to 32082); `kind.sh` only maps them to different host
ports. The apps use the existing `stages/<env>` overlays and namespaces
(`guestbook-simple-<env>`) unchanged, because each environment now lives in a
different cluster from its single-Project twin.

| Piece | kind (this add-on) | EKS (later) |
|---|---|---|
| Dev Kargo | cluster `kargo-2i-dev` | dev cluster |
| Release Kargo | cluster `kargo-2i-release`, staging and prod as namespaces | prod cluster, plus a shard controller for the staging cluster |
| Link | Git branch `2i/handoff/dev` only | Same |
| GitHub credentials | a PAT per instance (can be the same PAT locally) | one GitHub App per instance |
| Users and roles | local `admin` only | SSO, Kargo roles per group |

## Flow

```text
DEV KARGO (kargo-2i-dev)                 | RELEASE KARGO (kargo-2i-release)
                                         |
image tag / main commit                  |
  -> dev            auto: render, deploy,|
                    smoke test           |
  -> dev-handoff    auto: write          |
                    release.yaml --------+-> 2i/handoff/dev -> Warehouse from-dev
                                         |
                                         |  staging-approve  MANUAL: PR on main, wait for merge
                                         |  staging          ADMIN: check record, render, push,
                                         |                   argocd-update, smoke test
                                         |  staging-rc       auto: git tag 2i-rc-...
                                         |  prod-approve     MANUAL: PR on main, wait for merge
                                         |  prod             ADMIN: check record, render, push,
                                         |                   argocd-update, smoke test
                                         |  prod-release     auto: git tag 2i-rel-...
                                         |  prod-deployed    auto: PR on main, prod-deployed.yaml
```

## Folder layout

```text
two-instance/                    # add-on; kargo/ and the rest of the repo are unchanged
├── README.md                    # this document
├── kind.sh                      # creates kargo-2i-dev and kargo-2i-release
├── handoff/release.yaml         # template dev-handoff copies onto 2i/handoff/dev
├── versions/                    # release Kargo's records, changed only through PRs
│   ├── staging.yaml             # approved for staging
│   ├── prod.yaml                # approved for prod
│   └── prod-deployed.yaml       # running in prod and verified
├── argocd/
│   ├── dev/                     # kargo-2i-dev, applied to kargo-2i-dev
│   ├── staging/                 # kargo-2i-staging, applied to kargo-2i-release
│   └── prod/                    # kargo-2i-prod, applied to kargo-2i-release
├── kargo-dev/                   # Project kargo-2i-dev
│   ├── project.yaml, projectconfig.yaml, warehouse.yaml (guestbook)
│   ├── promotiontask.yaml       # deploy-direct
│   ├── stages.yaml              # dev, dev-handoff
│   └── analysistemplate.yaml    # smoke-test
└── kargo-release/               # Project kargo-2i-release
    ├── project.yaml, projectconfig.yaml, warehouse.yaml (from-dev)
    ├── promotiontasks.yaml      # approve, deploy, record-deployed
    ├── stages.yaml              # the 7 release Stages
    └── analysistemplate.yaml    # smoke-test

Branches: 2i/stage/dev  2i/stage/staging  2i/stage/prod  2i/handoff/dev
Tags:     2i-rc-<version>-...  2i-rel-<version>-...
```

**Shared with the single-Project pipeline**: `base/`, `components/`, `stages/`,
`release/version.yaml` and the ghcr.io image. A change to them creates Freight
in both pipelines.

**Never creates Freight**: `versions/` and `two-instance/`. The add-on's dev
Warehouse watches only `base`, `components`, `release` and `stages`; the
single-Project Warehouse doesn't watch `two-instance/`.

## Records

**Handoff file** `release.yaml` on branch `2i/handoff/dev`, written only by
`dev-handoff` (template: `handoff/release.yaml`). Each new commit becomes one
release Freight; handing off the same Freight again changes nothing and creates
no commit.

```yaml
devFreight: 94c871123fcd...      # dev Kargo Freight name, for tracing back
devAlias: iron-stoat
image: ghcr.io/kwu-qf/guestbook
tag: v0.0.5
digest: sha256:...               # what both sides deploy
configCommit: cccb02a2a90c...    # commit of main to render
```

**Approval records** `versions/staging.yaml` and `versions/prod.yaml`, changed
only by approval PRs. The deploy check compares `freight` with the Freight
being deployed.

```yaml
freight: 5d1e...                 # release Kargo Freight name (the check uses this)
devFreight: 94c871123fcd...
version: v0.1.0
configCommit: cccb02a2a90c...
images:
  guestbook:
    image: ghcr.io/kwu-qf/guestbook
    tag: v0.0.5
    digest: sha256:...
rcTag: 2i-rc-v0.1.0-cccb02a-<alias>-5d1e...   # prod.yaml also has releaseTag
```

**Deployed record** `versions/prod-deployed.yaml`, changed only by
`prod-deployed` PRs: the same fields plus `releaseTag`, and a `previous:` block
(Freight, version, tag) for what it replaced.

## Stages

| Instance | Stage | Sources | Promotion | Runs | Verification |
|---|---|---|---|---|---|
| dev | `dev` | Warehouse `guestbook` | auto | render `stages/dev` by digest, push `2i/stage/dev`, `argocd-update` | smoke test |
| dev | `dev-handoff` | `dev` | auto | copy the template, fill `release.yaml`, push `2i/handoff/dev` | none |
| release | `staging-approve` | Warehouse `from-dev` | **manual** | task `approve`: PR on `main` for `versions/staging.yaml`, wait for merge | none |
| release | `staging` | `staging-approve` | **admin** | task `deploy`: check record, render at `configCommit` by digest, push `2i/stage/staging`, `argocd-update` | smoke test |
| release | `staging-rc` | `staging` | auto | tag `2i-rc-...` on `configCommit` | none |
| release | `prod-approve` | `staging-rc` | **manual** | task `approve` for `versions/prod.yaml` | none |
| release | `prod` | `prod-approve` | **admin** | task `deploy` for prod | smoke test |
| release | `prod-release` | `prod` | auto | tag `2i-rel-...` on `configCommit` | none |
| release | `prod-deployed` | `prod` (`MatchUpstream`) | auto | task `record-deployed`: PR on `main` for `versions/prod-deployed.yaml` | none |

Stages without verification count Freight as verified once their Promotion
succeeds, so a merged approval PR is what makes Freight deployable.

On the release side, `commitFrom(repoURL)` is the **handoff commit**, not a commit
of `main`. Every step that needs app config, `release/version.yaml` or a tag
target clones `configCommit` from `release.yaml` instead.

The record check in task `deploy` (`kargo-release/promotiontasks.yaml`):

```yaml
- uses: yaml-parse
  as: approved
  config:
    path: ./main/two-instance/versions/${{ vars.env }}.yaml
    outputs:
    - name: freight
      fromExpression: freight
- uses: fail
  if: ${{ vars.requireRecord == 'true' && task.outputs.approved.freight != ctx.targetFreight.name }}
  config:
    message: "Freight ... is not the approved record in two-instance/versions/<env>.yaml ..."
```

`requireRecord` stays `"true"` under option A.

## Runbook: two-instance kind environment

Run these from the repo root in your own terminal. Steps 2 to 6 assume the add-on
files are on `main` on GitHub.

### 0. Before you start

* The same tools as the main runbook: Docker Desktop, `kind`, `kubectl`, `helm`,
  `kargo` CLI v1.12.4, and a classic GitHub PAT (`repo`, plus `read:packages` if
  the image is private).
* Each cluster runs Argo CD, Argo Rollouts, cert-manager and Kargo. Give Docker
  Desktop enough memory for three clusters, or delete `kargo-quickstart` while
  you use the add-on (`kind delete cluster --name kargo-quickstart`).
* The `kargo` CLI is logged in to one server at a time. Run `kargo login` again
  when you switch between the dev Kargo (31181) and the release Kargo (31281).

### 1. Push the add-on to GitHub

Both Kargo instances read `main` from GitHub. `dev-handoff` copies
`two-instance/handoff/release.yaml` from the Freight's commit, so Freight from a
commit before the add-on was merged can't be handed off.

```shell
git add two-instance .github/CODEOWNERS README.md
git commit -m "two-instance Kargo add-on"
git push
```

### 2. Create the two clusters

```shell
sh two-instance/kind.sh            # or: sh two-instance/kind.sh dev / release
kind get clusters                  # kargo-2i-dev, kargo-2i-release (and kargo-quickstart if kept)
helm list -n kargo --kube-context kind-kargo-2i-dev        # APP VERSION v1.12.4
helm list -n kargo --kube-context kind-kargo-2i-release    # APP VERSION v1.12.4
```

### 3. Argo CD Applications

```shell
kubectl --context kind-kargo-2i-dev     apply -f two-instance/argocd/dev/
kubectl --context kind-kargo-2i-release apply -f two-instance/argocd/staging/ -f two-instance/argocd/prod/
```

Each shows an error until its first deploy creates its `2i/stage/<env>` branch.
If the guestbook package is private, create the `ghcr-pull` Secret (main runbook,
step 3b) in `guestbook-simple-dev` on `kind-kargo-2i-dev`, and in
`guestbook-simple-staging` and `guestbook-simple-prod` on `kind-kargo-2i-release`.

### 4. Dev Kargo

```shell
kargo login http://localhost:31181 --admin --password admin
kargo apply -f two-instance/kargo-dev/project.yaml

export GH_PAT=ghp_xxx
kargo create repo-credentials github-creds --project kargo-2i-dev --git \
  --username <yourgithubusername> --password "$GH_PAT" \
  --repo-url https://github.com/<yourgithubusername>/kargo-simple.git
# only if the image is private
kargo create repo-credentials ghcr-creds --project kargo-2i-dev --image \
  --username <yourgithubusername> --password "$GH_PAT" \
  --repo-url ghcr.io/<yourgithubusername>/guestbook

kargo apply -f two-instance/kargo-dev/
# if kargo apply rejects the AnalysisTemplate:
kubectl --context kind-kargo-2i-dev apply -f two-instance/kargo-dev/analysistemplate.yaml

kargo get stages --project kargo-2i-dev          # dev, dev-handoff
kargo refresh warehouse guestbook --project kargo-2i-dev
kargo get promotions --project kargo-2i-dev      # dev starts, then dev-handoff
```

Check the handoff once `dev-handoff` succeeds:

```shell
git fetch origin 2i/handoff/dev
git show origin/2i/handoff/dev:release.yaml
```

### 5. Release Kargo

The release Kargo only needs Git credentials: it never reads the registry.

```shell
kargo login http://localhost:31281 --admin --password admin
kargo apply -f two-instance/kargo-release/project.yaml
kargo create repo-credentials github-creds --project kargo-2i-release --git \
  --username <yourgithubusername> --password "$GH_PAT" \
  --repo-url https://github.com/<yourgithubusername>/kargo-simple.git
kargo apply -f two-instance/kargo-release/
kubectl --context kind-kargo-2i-release apply -f two-instance/kargo-release/analysistemplate.yaml   # if needed

kargo get stages --project kargo-2i-release      # 7 Stages
kargo refresh warehouse from-dev --project kargo-2i-release
kargo get freight --project kargo-2i-release     # one Freight per handoff commit
```

Until the first handoff exists, the `from-dev` Warehouse reports that branch
`2i/handoff/dev` is missing. That is expected.

### 6. A release, end to end

```shell
# release Kargo (kargo login http://localhost:31281 ...)
kargo promote --project kargo-2i-release --freight <freight> --stage staging-approve
# merge the "[2i] Approve ... for staging" PR on GitHub
kargo promote --project kargo-2i-release --freight <freight> --stage staging      # admin
# http://localhost:32281 ; staging-rc tags 2i-rc-... after the smoke test
kargo promote --project kargo-2i-release --freight <freight> --stage prod-approve
# merge the "[2i] Approve ... for prod" PR
kargo promote --project kargo-2i-release --freight <freight> --stage prod         # admin
# http://localhost:32282 ; prod-release tags 2i-rel-..., prod-deployed opens a record PR: merge it
```

The Kargo UI does the same by dragging Freight onto each Stage.

### 7. Rollback (staging or prod)

1. Drag the older Freight onto `<env>-approve` (it is still available there),
   and merge the PR it opens (old → new is shown in the PR).
2. Promote it to `<env>`.
3. For prod, merge the `prod-deployed` record PR.

If a newer approval PR is still open, close it first: one Promotion runs per
Stage at a time.

### 8. When a deploy is refused

`Freight <name> is not the approved record in two-instance/versions/<env>.yaml`
means the record names a different Freight: a newer approval replaced it, or it
was never approved. Approve it through `<env>-approve`, then deploy again.

### 9. Tear down

```shell
kind delete cluster --name kargo-2i-dev
kind delete cluster --name kargo-2i-release
```

What stays in Git: the `2i/*` branches, the `2i-rc-`/`2i-rel-` tags and the
records under `two-instance/versions/`. After a rebuild the records still name
Freight from the old clusters, so the first deploy of each environment needs a
fresh approval PR, which is the normal flow anyway. Optional full reset:

```shell
git push origin --delete 2i/stage/dev 2i/stage/staging 2i/stage/prod 2i/handoff/dev
git tag -l '2i-*' | xargs -n1 -I{} git push origin :refs/tags/{}   # tags too, if you want
```

## Workflows: regular cases

| # | Case | Who does what | Result |
|---|---|---|---|
| R1 | Normal release | Runbook step 6 | ✅ |
| R2 | Config-only change | A merge to `base/` or `stages/` creates dev Freight with the same image → new handoff commit with a new `configCommit` → same as R1 | ✅ |
| R3 | Version bump | `release/version.yaml` is read at `configCommit` by `approve`, `record-deployed` and the tag Stages | ✅ |
| R4 | Two approvals before a deploy | F2 approved, then F3 approved: the record says F3, so only F3 can be deployed | ✅ newer approval replaces older |
| R5 | Redeploy the same Freight | Check passes, nothing to commit, Argo CD re-syncs, smoke test re-runs | ✅ |
| R6 | Staging rollback | Runbook step 7 | ✅ PR required |
| R7 | Prod rollback | Runbook step 7; `prod-deployed` records it (`MatchUpstream`) | ✅ PR required |

## Workflows: non-regular cases

| # | Case | What happens | Handling |
|---|---|---|---|
| N1 | Approval PR rejected | The approve Promotion fails; the Freight never reaches the deploy Stage | ✅ Drag it to the approve Stage again to retry |
| N2 | Approval PR left open | That Promotion keeps running; later approvals queue behind it | ⚠️ Merge, close or abort it (`kargo promote --project kargo-2i-release --name <promotion> --abort`) |
| N3 | Network drops after the PR opened | The Promotion fails and the PR stays open; a retry opens a second PR with the same change | ⚠️ Merge one, close the other |
| N4 | Network drops after the merge | A retry finds no change, skips the PR and succeeds | ✅ |
| N5 | Someone edits `two-instance/versions/` by hand | The check compares against bad data | ⚠️ CODEOWNERS (added) plus, later, a CI check on the record files |
| N6 | Approval withdrawn | Revert the approval PR on `main`; deploys of that Freight are blocked | ✅ |
| N7 | Smoke test fails after a deploy | The environment runs the bad Freight until a rollback PR is merged and an admin deploys | ⚠️ Accepted trade-off of PR-only rollbacks; agree fast-track reviewers |
| N8 | Deploy fails after the push | `2i/stage/<env>` has the new render, the cluster runs the old one | ✅ Promote the same Freight again |
| N9 | Someone clicks Sync or Rollback in Argo CD | Sync deploys the branch head (the last Kargo deploy); an Argo CD rollback bypasses Kargo | ⚠️ Allow sync and rollback in Argo CD only for admins |
| N10 | Admin promotes two Freight quickly | Both queue; the one that doesn't match the record fails the check | ✅ |
| N11 | Image tag re-pushed with different contents | Both sides deploy the digest from the Freight / handoff | ✅ |
| N12 | Rollback target is old | Release Freight may be garbage-collected; handoff commits beyond `discoveryLimit` (50 here) can't be rediscovered | ⚠️ Roll forward, or raise the limits |
| N13 | Urgent prod hotfix | Assemble Freight in the **dev** Kargo (hotfix image + prod's `configCommit`), approve it for `dev-handoff`; in the release Kargo, approve the new Freight for `prod-approve` → PR → admin deploy | ⚠️ No `2i-rc-` tag exists for it; say so in the PR |
| N14 | Dev re-hands off an older dev Freight | A new handoff commit creates a new release Freight with the same content | ⚠️ Harmless; trace it through `devFreight` |
| N15 | Same dev Freight handed off twice | No change, no commit, no new release Freight | ✅ |
| N16 | Dev cluster down | No new handoffs; staging and prod keep working, rollbacks still work | ✅ |
| N17 | `prod-deployed` PR left unmerged | The next record update queues behind it | ⚠️ Merge it promptly, or auto-merge Kargo-bot PRs that touch only `prod-deployed.yaml` |
| N18 | A rollback redeploy fails its new smoke test | The Freight passed before, so `prod-deployed` may record it anyway | ⚠️ Check the Stage's verification after a rollback |
| N19 | A developer tries to deploy to staging or prod | Must be blocked by Kargo roles (`promote` on `staging` and `prod` for admins only) | ⚠️ Can't be tested with the single local `admin` user |
| N20 | Both pipelines run at the same time | Different clusters, host ports, branches, tags and records | ✅ |
| N21 | Clusters rebuilt | Records name Freight from the old clusters | ✅ First deploy needs a fresh approval (runbook step 9) |

## To verify on the first run

These Kargo v1.12.4 details couldn't be checked against the source while writing:

* the `fail` step's `message` field;
* the `copy` step (`inPath`, `outPath`) used by `dev-handoff`;
* `kustomize-set-image` with `digest:`, and `imageFrom(...).Digest`;
* `discoveryLimit` on a Git subscription;
* `selectionPolicy: MatchUpstream` on `prod-deployed`;
* task variables without a default (`env`) being supplied by the Stage;
* yaml-parse on the empty records (`""` values) on the first approval.

If a step is rejected, `kargo apply` or the first Promotion's error names the
field.

## What kind can't show (check on EKS)

* The shard controller that lets the release Kargo update only the staging cluster's Argo CD Applications (staging and prod share one cluster here).
* The network path from the prod cluster to the staging app for the staging smoke test.
* Separate GitHub Apps, SSO and Kargo roles per team.
* ECR access through EKS Pod Identity or IRSA.
