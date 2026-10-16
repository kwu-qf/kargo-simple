# Kargo Simple Example

This is a GitOps repository of a simple Kargo example for getting started.

### Features:

* A Warehouse which monitors a container repository for new images and `main`
  for config changes (Freight = image tag + commit of `main`)
* Three Stage (dev, staging, prod) deploy pipeline
* Each Stage renders its own overlay at the Freight's commit and pushes the
  rendered YAML to a `stage/<stage>` branch
* dev is auto-promoted and deploys directly
* staging is auto-promoted after dev verification; prod is promoted by hand
* staging and prod deploy only after a Kargo PR on `main` that updates
  `versions/<stage>.yaml` is approved and merged
* A release version in `release/version.yaml`, bumped by people through a PR
* Two tag-only Stages that deploy nothing: `staging-rc` tags staging-verified
  Freight `rc-<version>-<shortSHA>-<alias>-<freightShort>` (prod only accepts Freight
  from it), and `prod-release` tags prod-verified Freight
  `rel-<version>-<freightShort>`

Each Stage is deployed by an Argo CD Application in `argocd/<stage>/` that
tracks the root of the `stage/<stage>` branch. Kargo's `argocd-update` step
syncs it after each promotion.

To bring the whole environment up (or back after a teardown), follow the
[Runbook](#runbook-local-kind-environment).

## Repo layout and branches

```
main (protected, PRs only)
├── base/            # shared config; flows dev → staging → prod
│   ├── namespace.yaml
│   ├── configmap.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── kustomization.yaml
├── components/      # optional shared, opt-in features
├── release/
│   └── version.yaml # release version; people bump it via PR
├── stages/          # env-specific values only; written by people
│   ├── dev/         # replicas: 1, debug logging
│   ├── staging/     # replicas: 2
│   └── prod/        # replicas: 4, HPA, PDB, larger resources
├── versions/        # Kargo's record, changed only through Kargo PRs
│   ├── staging.yaml
│   └── prod.yaml
├── argocd/          # one Argo CD Application per Stage, tracking stage/<stage>
│   ├── dev/
│   ├── staging/
│   └── prod/
└── kargo/           # Kargo Project, Warehouse, Stages, PromotionTask

stage/dev  stage/staging  stage/prod   # rendered YAML; only Kargo pushes
```

| Location | Answers | Written by | Edit by hand |
|---|---|---|---|
| `base/`, `components/` | What every environment runs | People, via PR | Yes |
| `stages/<stage>/` | How this environment differs | People, via PR | Yes |
| `release/version.yaml` | Which release version `main` is building | People, via PR | Yes |
| `versions/<stage>.yaml` | Which version was approved for this environment | Kargo, via PR | No |
| `argocd/<stage>/` | Which Argo CD Application deploys this environment | People, via PR | Yes |
| `stage/<stage>` branch | Exactly what was deployed | Kargo | No (overwritten each promotion) |

Image tags are never committed to `main`: Kargo sets the tag at render time.
The `stage/<stage>` branches are created by Kargo on the first promotion.

The Warehouse watches `argocd/`, `base/`, `components/`, `release/` and `stages/`
on `main` and excludes `versions/`, so merging a Kargo PR never creates new Freight.

`versions/<stage>.yaml` records the Freight, `version`, `configCommit`, the
image tag of each service under `images:`, and the git tag names: `rcTag`
(staging and prod) and `releaseTag` (prod only). Kargo writes the tag names in
the promotion PR, before the tag Stages create them, so a name in the record
whose verification later failed has no matching tag. Together with the tag
messages, this keeps every Freight resolvable from git after its Kargo object
is gone.

### Branch protection

* `main`: PRs required, required status checks, CODEOWNERS
  (`.github/CODEOWNERS`: `stages/prod/` → prod owners, `stages/staging/` →
  staging owners).
* `stage/*`: push restricted to the Kargo GitHub App (or the token in
  `github-creds`).
* Turn on "automatically delete head branches" so Kargo's temporary PR
  branches are cleaned up.

## Runbook: local kind environment

Everything below is repeatable: tear the cluster down and come back by running
the steps again. Run them in your own terminal (not through an AI assistant),
so tokens stay out of transcripts.

| URL | What | Login |
|---|---|---|
| http://localhost:31080 | Argo CD | `admin` / `admin` |
| http://localhost:31081 | Kargo | `admin` |
| http://localhost:32080 / 32081 / 32082 | guestbook dev / staging / prod | — |

### Requirements

* Docker Desktop (running), `kind`, `kubectl`, `helm`, `kargo` CLI **v1.12.4** (must match the server: v1.12 removed the old API, so a v1.11 CLI fails against it), `git`
* A **classic** GitHub PAT (`ghp_...`). Fine-grained tokens (`github_pat_...`)
  do not work with ghcr.io. Scopes:
  * `repo`: Kargo pushes `stage/*` branches and opens PRs on `main`
  * `write:packages`: you push images to ghcr.io (includes `read:packages`,
    which Kargo needs if the package is private)
* Never store the PAT in a file in this repo or in plain-text notes.

### Kargo v1.12 notes

The manifests in `kargo/` target Kargo v1.12.4:

* Auto-promotion is set in `kargo/projectconfig.yaml` (`ProjectConfig`), not on the Project.
* Warehouse subscriptions are named (`guestbook-image`, `gitops-config`), and
  `includePaths`/`excludePaths` are exact paths (prefix `glob:` or `regex:` for patterns).
* `git-open-pr` outputs `pr.id`; it no longer accepts `createTargetBranch`.
* `git-commit` no longer accepts `author`; set it on `git-clone` if needed.
* `git-push` now rebases, or merges if a rebase isn't possible (`RebaseOrMerge`),
  when the remote branch moved.

### 0. One-time setup (skip on rebuild)

1. Fork this repo, clone your fork, personalize and push:

   ```shell
   ./personalize.sh <yourgithubusername>
   git commit -a -m "personalize manifests"
   git push
   ```

2. Log in to ghcr.io and create the first image tag:

   ```shell
   export GH_PAT=ghp_xxx
   echo "$GH_PAT" | docker login ghcr.io -u <yourgithubusername> --password-stdin

   docker buildx imagetools create \
     ghcr.io/akuity/guestbook:latest \
     -t ghcr.io/<yourgithubusername>/guestbook:v0.0.1
   ```

   Confirm the tag exists (an empty list or `NAME_UNKNOWN` means the push did
   not happen):

   ```shell
   T=$(curl -s -u <yourgithubusername>:"$GH_PAT" \
     "https://ghcr.io/token?scope=repository:<yourgithubusername>/guestbook:pull&service=ghcr.io" \
     | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
   curl -s -H "Authorization: Bearer $T" https://ghcr.io/v2/<yourgithubusername>/guestbook/tags/list
   # expect: {"name":"<yourgithubusername>/guestbook","tags":["v0.0.1"]}
   ```

   A `403 ... does not match expected scopes` error means the token is
   fine-grained or lacks `write:packages`. Check with
   `curl -sI -H "Authorization: Bearer $GH_PAT" https://api.github.com/user | grep -i x-oauth-scopes`.
   If the scopes are right, `docker logout ghcr.io` and log in again.

3. Optional: make the `guestbook` package public (Package settings →
   visibility) so Kargo needs no image credentials.

   ![change-package-visibility](docs/change-package-visibility.png)

4. Install the Kargo CLI v1.12.4 and check it:

   ```shell
   ./download-cli.sh /usr/local/bin/kargo v1.12.4   # or: brew upgrade kargo
   kargo version --client
   ```

### 1. Create the cluster (Argo CD, Argo Rollouts, cert-manager, Kargo)

Uses the [Kargo quickstart](https://docs.kargo.io/quickstart) script. It creates
a kind cluster named `kargo-quickstart` with hard-coded local-only passwords.

```shell
curl -fsSLo kind.sh https://raw.githubusercontent.com/akuity/kargo/main/hack/quickstart/kind.sh
# Pin Kargo to v1.12.4 (the script installs the latest chart otherwise)
sed -i.bak 's#oci://ghcr.io/akuity/kargo-charts/kargo \\#oci://ghcr.io/akuity/kargo-charts/kargo --version 1.12.4 \\#' kind.sh
grep -n 'kargo-charts/kargo' kind.sh     # expect: ... --version 1.12.4 \
sh kind.sh
helm list -n kargo                       # expect: APP VERSION v1.12.4
kubectl config current-context    # expect: kind-kargo-quickstart
```

### 2. Make sure GitHub has the current repo

Argo CD and Kargo read this repo from GitHub, not from your laptop.

```shell
git status
git push
```

### 3. Create the Argo CD Applications

```shell
kubectl apply -R -f argocd/
kubectl get applications -n argocd
```

Each Application shows an error until its first promotion: Kargo creates the
`stage/<stage>` branch it points at. If the repo is private, also add it in
Argo CD (Settings → Repositories) with the PAT.

### 3b. Image pull secret (only if the guestbook package is private)

Kargo's `ghcr-creds` only lets Kargo list tags. The cluster pulls the image
itself and needs its own credentials in each app namespace, or pods fail with
`ErrImagePull ... failed to fetch anonymous token ... 401 Unauthorized`.
Skip this step if the package is public.

```shell
export GH_PAT=ghp_xxx    # classic PAT with read:packages
for ns in guestbook-simple-dev guestbook-simple-staging guestbook-simple-prod; do
  kubectl create namespace $ns --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret docker-registry ghcr-pull -n $ns \
    --docker-server=ghcr.io \
    --docker-username=<yourgithubusername> \
    --docker-password="$GH_PAT" \
    --dry-run=client -o yaml | kubectl apply -f -
done
```

`base/deployment.yaml` references `ghcr-pull` through `imagePullSecrets`. The
Secret is not in Git and Argo CD doesn't manage it, so it is lost on teardown;
re-run this step when you bring the cluster back. (In a real cluster, create it
with External Secrets instead.)

### 4. Deploy Kargo (`kargo/`)

Kargo runs in the cluster from step 1. This step loads the pipeline into it.

| File | Creates | Purpose |
|---|---|---|
| `kargo/project.yaml` | Project `kargo-simple` | Namespace that holds everything below |
| `kargo/projectconfig.yaml` | ProjectConfig `kargo-simple` | Auto-promotion for `dev`, `staging`, `staging-rc` and `prod-release` (prod is manual) |
| `kargo/warehouse.yaml` | Warehouse `guestbook` | Watches ghcr.io tags and `main` (`argocd`, `base`, `components`, `release`, `stages`) and creates Freight |
| `kargo/promotiontask.yaml` | PromotionTask `promote` | Renders `stages/<stage>`, opens the `versions/<stage>.yaml` PR (staging, prod) with the version, image tags and planned git tag names, pushes `stage/<stage>`, syncs the Argo CD app |
| `kargo/stages.yaml` | Stages `dev`, `staging`, `staging-rc`, `prod`, `prod-release` | The pipeline dev → staging → staging-rc → prod → prod-release. dev, staging and prod deploy and run a smoke-test verification; `staging-rc` and `prod-release` only push the `rc-`/`rel-` git tags |
| `kargo/analysistemplate.yaml` | AnalysisTemplate `smoke-test` | `curl` to `http://guestbook-simple.<namespace>.svc.cluster.local/info` after each deploy |

Prerequisites: steps 2 and 3 are done (`main` on GitHub has this layout and the
Argo CD Applications exist), and the `kargo` CLI is v1.12.4.

**4a. Log in**

```shell
kargo login http://localhost:31081 --admin --password admin
kargo config set-project kargo-simple     # default project for later commands
```

**4b. Create the Project first, then the credentials**

Creating the credentials before the Warehouse lets it discover Freight on its
first try instead of erroring.

```shell
kargo apply -f kargo/project.yaml

export GH_PAT=ghp_xxx    # classic PAT: repo (+ read:packages if the image is private)

# Git: Warehouse reads main; promotions push stage/* branches and open PRs
kargo create repo-credentials github-creds --project kargo-simple --git \
  --username <yourgithubusername> --password "$GH_PAT" \
  --repo-url https://github.com/<yourgithubusername>/kargo-simple.git

# Image: only needed if the guestbook package is private
kargo create repo-credentials ghcr-creds --project kargo-simple --image \
  --username <yourgithubusername> --password "$GH_PAT" \
  --repo-url ghcr.io/<yourgithubusername>/guestbook

kargo get repo-credentials --project kargo-simple
```

**4c. Apply the rest of `kargo/`**

```shell
kargo apply -f kargo/
# If kargo apply rejects the AnalysisTemplate (an Argo Rollouts kind), apply it with kubectl:
kubectl apply -f kargo/analysistemplate.yaml
```

Re-applying the whole folder is safe; `project.yaml` is unchanged.

**4d. Verify**

```shell
kargo get projectconfig --project kargo-simple
kargo get warehouses --project kargo-simple
kargo get stages --project kargo-simple                 # dev, staging, staging-rc, prod, prod-release
kubectl get promotiontasks -n kargo-simple              # promote
kubectl get analysistemplates -n kargo-simple           # smoke-test
kargo refresh warehouse guestbook --project kargo-simple
kargo get freight --project kargo-simple                # expect at least one Freight
kargo get promotions --project kargo-simple             # dev should start automatically
```

Then check the Kargo UI (http://localhost:31081 → `kargo-simple`) and Argo CD
(http://localhost:31080 → `kargo-simple-dev` should be Synced and Healthy).

If no Freight appears, `kubectl describe warehouse guestbook -n kargo-simple`
shows the error (usually credentials or a wrong `repoURL`).

**Changing `kargo/` later**

Edit the file, commit and push (keep Git as the record), then re-apply:

```shell
kargo apply -f kargo/
```

To remove the pipeline but keep the cluster:

```shell
kargo delete project kargo-simple     # deletes everything in the Project, including credentials
```

### 5. Promote

![pipeline](docs/pipeline.png)

* **dev**: automatic (`kargo/projectconfig.yaml`). Every new Freight is
  promoted to dev: Kargo renders `stages/dev`, pushes `stage/dev` and syncs
  `kargo-simple-dev`. Open http://localhost:32080. Watch it with
  `kargo get promotions --project kargo-simple`.
* **staging**: automatic once the Freight passes dev verification. Kargo
  opens a PR on `main` updating `versions/staging.yaml` and waits. Merge it to
  deploy; close it to cancel. Then open http://localhost:32081.
* **staging-rc**: automatic once the Freight passes staging verification.
  Deploys nothing: pushes the git tag `rc-<version>-<shortSHA>-<alias>-<freightShort>`
  on the Freight's commit of `main` (`<version>` from `release/version.yaml`
  at that commit, `<shortSHA>` = config commit, `<alias>` = the Freight's
  alias in the Kargo UI, e.g. `dapper-coral`, `<freightShort>` = first 7
  characters of the Freight name). prod only accepts Freight from this Stage.
  Aliases can be renamed in the UI; don't rename a Freight between its staging
  PR and its RC tag, or `rcTag` in `versions/*.yaml` won't match the tag (see
  [Freight aliases can't be locked](#freight-aliases-cant-be-locked)).
* **prod**: manual. Promote the release-candidate Freight in the UI (or
  `kargo promote --project kargo-simple --freight <freight> --stage prod`).
  Kargo opens the prod PR the same way. Then open http://localhost:32082.
* **prod-release**: automatic once the Freight passes prod verification.
  Pushes the git tag `rel-<version>-<freightShort>`. Each Freight gets its own
  tag, so one version can have several releases (e.g. a config fix without a
  version bump).

Each tag's message records the version, image tag, config commit, Freight
name and alias. List and inspect them with:

```shell
git fetch --tags
git tag -l 'rc-*' 'rel-*'
git show --no-patch rel-v0.1.0-ce8e911    # example tag name
```

After each deploy, the Stage runs the `smoke-test` verification (a `curl`
Job). Only Freight that passes is verified and can be promoted to the next
Stage.

See [Viewing verification results and logs](#viewing-verification-results-and-logs).

![promotion](docs/promotion.gif)

### Freight aliases can't be locked

Kargo has no setting to disable renaming a Freight alias in the UI or CLI.
The alias is used only in the `rc-` tag name for readability; the tag stays
unique and traceable through `<freightShort>` and the full Freight name in the
tag message. To reduce the risk:

* Don't rename a Freight once it has been promoted to staging.
* Limit who can rename. Renaming is a write on the `freights` resource in the
  Project, so users who only promote should get the `kargo-promoter` role, not
  `kargo-admin`. Check what a role allows with
  `kargo get role kargo-promoter --as-kubernetes-resources -o yaml --project kargo-simple`.
  The local `admin` user in this runbook is a system admin and can always rename.
* If a rename happened anyway, the tag is the source of truth:
  `git tag -l 'rc-*-<freightShort>'` finds it regardless of the alias.

### Cutting a release

1. Bump `release/version.yaml` (e.g. `v0.1.0` → `v0.2.0`) in a PR and merge it.
   The Warehouse creates Freight with the new version.
2. dev promotes it, staging opens its PR (title `Promote v0.2.0 to staging: ...`).
   Merge it.
3. After staging verification, `staging-rc` pushes `rc-v0.2.0-<shortSHA>-<alias>-<freightShort>`
   (e.g. `rc-v0.2.0-a640d14-dapper-coral-ce8e911`).
4. Promote that Freight to prod and merge the prod PR. It records `rcTag` and
   the planned `releaseTag` in `versions/prod.yaml`.
5. After prod verification, `prod-release` pushes `rel-v0.2.0-<freightShort>`.

Freight created from a commit before `release/version.yaml` existed cannot be
promoted to staging, staging-rc, prod or prod-release: reading the version
file fails. Promote Freight from a later commit.

### After merging a staging/prod PR

The staging/prod Promotion sits in the `git-wait-for-pr` step, phase
**Running**, until the PR is **merged**. Approving the PR is not enough;
closing it without merging fails the Promotion (nothing is deployed).

Kargo checks the PR every **10s** (`pollInterval` in
`kargo/promotiontask.yaml`; Kargo's default is 30s and the minimum is 10s).
For an immediate pickup, set up the GitHub webhook with **Pull requests**
events (see [Later: instant Freight detection with webhooks](#later-instant-freight-detection-with-webhooks)).

Where to see it:

```shell
# Phase and the step it is on
kargo get promotions --project kargo-simple --stage staging
kargo get promotion <promotion-name> --project kargo-simple -o yaml | grep -A40 '^status:'
# status.currentStep: index of the running step (git-wait-for-pr while the PR is open)
# status.stepExecutionMetadata: per-step status, startedAt/finishedAt, error messages
# status.phase: Running -> Succeeded after the merge

# Watch it move
kubectl get promotions -n kargo-simple -w

# Controller logs for that Promotion
kubectl get deploy -n kargo
kubectl logs -n kargo deploy/kargo-controller -f | grep <promotion-name>
```

The Kargo UI shows the same per-step view: Stage `staging` → Promotions → the
Promotion → steps.

The controller does not necessarily log every PR check at the default `INFO`
level. To see each poll, raise the controller log level (`ERROR`, `INFO`,
`DEBUG`, `TRACE`), and set it back afterwards:

```shell
helm upgrade kargo oci://ghcr.io/akuity/kargo-charts/kargo -n kargo \
  --version 1.12.4 --reuse-values --set controller.logLevel=DEBUG
# back to normal
helm upgrade kargo oci://ghcr.io/akuity/kargo-charts/kargo -n kargo \
  --version 1.12.4 --reuse-values --set controller.logLevel=INFO
```

After the merge, the remaining steps run (push `stage/staging`, sync
`kargo-simple-staging`), then the staging smoke test starts.

### Viewing verification results and logs

Each verification is an Argo Rollouts **AnalysisRun** in the `kargo-simple`
namespace. Its `http-check` metric runs a Kubernetes **Job** (the `curl` pod)
in the same namespace.

**1. Result (pass/fail)**

```shell
kargo get stages dev --project kargo-simple -o yaml | grep -A8 verification   # current Freight's verification
kubectl get analysisruns -n kargo-simple --sort-by=.metadata.creationTimestamp
# PHASE: Running / Successful / Failed / Error

kubectl get analysisrun <analysisrun-name> -n kargo-simple \
  -o jsonpath='{.status.phase}{"\n"}{range .status.metricResults[*]}{.name}: {.phase} {.message}{"\n"}{range .measurements[*]}  {.phase} {.message}{"\n"}{end}{end}'
```

**2. curl output (Job pod logs)**

```shell
kubectl get jobs -n kargo-simple --sort-by=.metadata.creationTimestamp
kubectl logs -n kargo-simple job/<job-name>
# success: "redis not enabled <- /info OK"
# failure: curl: (22) ... or curl: (7) Failed to connect ...

# or follow the newest Job's pod while it runs
kubectl logs -n kargo-simple -f \
  $(kubectl get pods -n kargo-simple -l job-name -o name --sort-by=.metadata.creationTimestamp | tail -1)

kubectl describe analysisrun <analysisrun-name> -n kargo-simple   # events, if the Job never started
```

The Job and its pod are kept with the AnalysisRun, so the logs stay available
until Kargo cleans up old AnalysisRuns.

**3. Kargo UI / `kargo logs`**

The UI's log view and `kargo logs <analysisrun-name>` show
**"AnalysisRun log streaming is not configured"** on this setup. That is
expected: Kargo does not read pod logs directly. It fetches them over HTTP from
a central log store that you configure in the Kargo Helm values
(`api.rollouts.logs.enabled`, `urlTemplate`, optional `tokenSecret`). The
quickstart cluster has no log store, so use `kubectl logs` (above). The
verification itself still runs and its pass/fail status is shown in the UI.

To enable it later: forward pod logs to a store reachable by HTTP GET (for
example Loki, or your platform's logging), then set, for example:

```yaml
api:
  rollouts:
    integrationEnabled: true
    logs:
      enabled: true
      urlTemplate: https://logs.example.com/${{project}}/${{analysisRun}}/${{jobName}}/${{container}}
```

### When verification fails

The deploy stays in place (Kargo does not roll back on its own), and the Freight
is not verified, so it cannot move to the next Stage.

| Option | Command |
|---|---|
| Read the curl output | `kubectl logs -n kargo-simple job/<job-name>` (see [Viewing verification results and logs](#viewing-verification-results-and-logs)) |
| Re-run (flaky check, or after fixing the cluster) | `kargo verify stage dev --project kargo-simple` |
| Roll back: promote the last good Freight. On `dev` this places an auto-promotion hold, so the bad Freight is not promoted again | `kargo promote --project kargo-simple --freight <good-freight> --stage dev` |
| Resume auto-promotion on `dev` after a fix | `kargo promote --project kargo-simple --warehouse guestbook --stage dev` |
| Fix forward: new image tag or config commit → new Freight → dev auto-promotes | push a new tag or merge to `main` |
| Skip verification for one Freight (use sparingly) | `kargo approve --project kargo-simple --freight <freight> --stage staging` |

### 6. Simulate a release

```shell
docker buildx imagetools create \
  ghcr.io/akuity/guestbook:latest \
  -t ghcr.io/<yourgithubusername>/guestbook:v0.0.2
kargo refresh warehouse guestbook --project kargo-simple
```

A config change merged to `argocd/`, `base/`, `components/` or `stages/` on
`main` also creates new Freight. Either way, dev is promoted automatically;
staging is promoted automatically after dev verification and waits for its PR to be merged; prod is manual.

### Later: instant Freight detection with webhooks

Not set up yet. Today the Warehouse **polls** ghcr.io and `main` on a
system-wide interval (a few minutes); `kargo refresh warehouse guestbook` only
skips the wait. `spec.interval` on the Warehouse can make polling slower, not
faster than the system minimum.

With a GitHub webhook receiver, GitHub notifies Kargo and the Warehouse
refreshes within seconds:

| GitHub event | Effect |
|---|---|
| `push` to `main` touching `argocd/`, `base/`, `components/`, `stages/` | New Freight right away (path filters apply) |
| `package` (new ghcr.io version) | New Freight right away |
| `pull_request` closed (merged) | A staging/prod Promotion waiting in `git-wait-for-pr` continues right away |

Steps to try it:

1. Create the signing secret (not in Git):

   ```shell
   WH_SECRET=$(openssl rand -hex 32); echo "$WH_SECRET"   # keep it for step 4
   kargo create generic-credentials gh-wh-secret --project kargo-simple --set secret="$WH_SECRET"
   ```

2. Add the receiver to `kargo/projectconfig.yaml`, commit, push, `kargo apply -f kargo/`:

   ```yaml
   spec:
     webhookReceivers:
     - name: github
       github:
         secretRef:
           name: gh-wh-secret
   ```

3. Expose Kargo's webhook server to GitHub. On kind it is only at
   `localhost:31082`, so use a tunnel, for example
   `cloudflared tunnel --url http://localhost:31082` or `ngrok http 31082`.
   This makes the endpoint public (requests are signature-checked); stop the
   tunnel when done. On EKS, use the internal ALB instead.

4. Get the receiver path and add the webhook in GitHub:

   ```shell
   kubectl get projectconfigs kargo-simple -n kargo-simple -o jsonpath='{.status.webhookReceivers}'
   ```

   Repo → Settings → Webhooks → Add webhook: payload URL = tunnel URL + the
   receiver path, content type `application/json`, secret = `$WH_SECRET`,
   events: **Pushes**, **Packages**, **Pull requests**. Check that the ping
   under Recent Deliveries returns 200.

Reference: https://docs.kargo.io/user-guide/reference-docs/webhook-receivers/github

### Later: handling queued promotions (design notes, not implemented)

Status: **not implemented yet**. Verified against the Kargo **v1.12.4** source
code. Today, handle a backlog by hand (see "What to do today" below).

#### What Kargo v1.12.4 does

If a staging PR is still open and newer Freight passes dev, Kargo does **not**
open a second PR. It queues another Promotion behind the one waiting on the PR.

| Behaviour | Where in v1.12.4 |
|---|---|
| Auto-promotion picks one candidate per origin: the newest Freight by discovery time | `pkg/api/auto_promotion.go` (`SelectAutoPromotionCandidates`) |
| Each new candidate gets its own Promotion; older queued Promotions are **not** cancelled, so the queue grows (B, C, D, ...) | `pkg/controller/stages/regular_stages.go` (`autoPromoteFreight`) |
| One Promotion runs per Stage at a time, oldest first. Names are `<stage>.<ULID>.<hash>`, and the ULID sorts by time | `pkg/api/promotion.go` (`GeneratePromotionName`), `pkg/controller/promotions/promotions.go` |
| Freight whose last finished Promotion was not `Succeeded` (failed, aborted) is not auto-promoted again | `autoPromoteFreight` |
| Manually promoting older Freight pauses auto-promotion for that Stage (a "hold") until the newest is promoted | `computeEffectiveAutoPromotionHolds` |
| Known issue [#7032](https://github.com/akuity/kargo/issues/7032): the next Promotion only waits for verification while the Stage is `Healthy` (or health unknown), so a back-to-back Promotion can skip verifying the previous Freight | `regular_stages.go`, verification gate before the next Promotion |
| No built-in "supersede" option ([#3108](https://github.com/akuity/kargo/issues/3108), open) | — |
| No plugin mechanism for custom promotion steps; only built-in steps | open-source source tree |
| Built-in steps that help: `http` (success/failure/error expressions), `fail`, `argocd-wait` | `pkg/promotion/runner/builtin/` |
| Expression context that helps: `ctx.promotion`, `ctx.stage`, `ctx.project`, `ctx.meta.promotion.rollback`; `secret()` reads only Secrets labelled `kargo.akuity.io/cred-type: generic` | `pkg/promotion/evaluator.go`, `pkg/expressions/function/functions.go` |

Kargo v1.12 keeps all of this (Freight, Promotions, Stages, holds) as
Kubernetes resources in the cluster, with no database or files. The queue is
just Promotions in phase `Pending`:

```shell
kubectl get promotions -n kargo-simple --sort-by=.metadata.creationTimestamp
```

Kargo 2.0 plans to change how state is stored (the chart on `main` already has a
`database` section, unused by v1.12).

#### What to do today (manual)

```shell
kargo get promotions --project kargo-simple --stage staging      # Running = waiting on the open PR, Pending = queued
kargo promote --project kargo-simple --name <promotion> --abort  # abort each stale one
```

Close the stale PR on GitHub too (aborting does not close it). Merging an old PR
deploys that old Freight first, and the next queued one follows.

#### Planned design: three small layers, no Kargo changes

**Layer 0: `argocd-wait` after `argocd-update`** in `kargo/promotiontask.yaml`.
The Promotion ends only once the Argo CD app is Healthy, which avoids #7032.

**Layer 1: a "superseded" guard as the first step of the promote task.** When a
queued Promotion starts, it lists Promotions for its Stage. If a newer one is
queued, it fails right away (before any PR), and Kargo won't retry that Freight.
When the open PR is merged or closed, the older queued Promotions fail in
seconds and only the newest opens a PR.

```yaml
- uses: http
  as: supersedeGuard
  if: ${{ !ctx.meta.promotion.rollback }}        # never block deliberate rollbacks
  config:
    method: GET
    url: https://kubernetes.default.svc/apis/kargo.akuity.io/v1alpha1/namespaces/${{ ctx.project }}/promotions
    headers:
    - name: Authorization
      value: Bearer ${{ secret('promotion-guard').token }}
    insecureSkipTLSVerify: true                    # cluster-internal CA; revisit on EKS
    successExpression: >-
      response.status == 200 && len(filter(response.body.items,
        {.spec.stage == '${{ ctx.stage }}' && .metadata.name > '${{ ctx.promotion }}'
         && (.status?.phase ?? '') in ['', 'Pending']})) == 0
    failureExpression: >-
      response.status != 200 || len(filter(response.body.items,
        {.spec.stage == '${{ ctx.stage }}' && .metadata.name > '${{ ctx.promotion }}'
         && (.status?.phase ?? '') in ['', 'Pending']})) > 0
    errorExpression: "'superseded by a newer queued Promotion (or guard could not list Promotions)'"
```

Supporting file (planned `kargo/promotion-guard.yaml`, applied with `kubectl`):
a ServiceAccount `promotion-guard`, a Role allowing `get`/`list` on
`promotions` in `kargo-simple`, a RoleBinding, and a token Secret
(`type: kubernetes.io/service-account-token`) named `promotion-guard` and
labelled `kargo.akuity.io/cred-type: generic` so `secret()` can read it. The
token is generated in the cluster; nothing sensitive is in Git.

**Layer 2: retire the PR that is already open.** The Promotion waiting on an
open PR blocks the queue, so nothing inside Kargo can replace that PR. Either:

* close it by hand (zero code); Layer 1 then drains the queue to the newest, or
* run a small script (planned `scripts/retire-stale-prs.sh`, `kubectl` + `gh`):
  for each Stage, if a Promotion is Running and a newer one is Pending, close
  the PR whose head branch is `kargo/promotion/<running-promotion-name>`
  (`git-push` with `generateTargetBranch` names it that way), with a comment
  pointing at the newer Freight. Run by hand, in a loop, or later as a CronJob.

**Not recommended**

* Comparing PR commit SHAs to Freight: the Promotion order (ULID names) already
  identifies the newest exactly.
* Deleting Freight (`kargo delete freight`): Freight is the history and audit
  record, and queued Promotions reference it. Fail or abort Promotions instead;
  Kargo's garbage collector handles retention.
* A custom step plugin: not supported in v1.12.4.

**Caveats**

* `insecureSkipTLSVerify` is needed because the controller doesn't trust the
  cluster CA for this call. Acceptable on kind; revisit on EKS.
* The `http` step reads at most 2 MiB of response; fine while the garbage
  collector keeps the Promotion list small.
* Untested. Check the Promotion name format first
  (`kubectl get promotions -n kargo-simple -o name`, expect `staging.<ULID>.<hash>`).

**Test plan once implemented**

1. Promote to staging and leave its PR open.
2. Push three image tags (v0.0.3, v0.0.4, v0.0.5) and let them pass dev.
3. `kargo get promotions --project kargo-simple --stage staging`: one Running, three Pending.
4. Close the open PR (or run the retire script).
5. Expect v0.0.3 and v0.0.4 to fail with "superseded", and only v0.0.5 to open a PR.

### Troubleshooting

#### Warehouse: `error listing tags ... ghcr.io/token ... UNAUTHORIZED: authentication required`

Kargo could not read the image tags. ghcr.io returns this same error when the
package is **private** and Kargo has no (valid) credentials, and when the
package **does not exist** (for example, the first push failed).

1. Check whether the package is readable anonymously:

   ```shell
   curl -s "https://ghcr.io/token?scope=repository:<yourgithubusername>/guestbook:pull&service=ghcr.io"
   # {"token":"..."}                 -> public: the problem is elsewhere (check repoURL)
   # {"errors":[{"code":"UNAUTHORIZED" -> private or missing: continue
   ```

2. Check that it exists, with your token (see step 0.2 for the full command).
   If the tag list is empty or `NAME_UNKNOWN`, push the image (step 0.2) and
   continue.

3. Give Kargo access, either way:

   * **Make the package public** (simplest for this demo): GitHub → your
     profile → Packages → `guestbook` → Package settings → Change visibility →
     Public. No image credentials needed.
   * **Or keep it private** and create image credentials with a classic PAT
     that has `read:packages`. The `--repo-url` must match the Warehouse
     exactly (`ghcr.io/<yourgithubusername>/guestbook`, no `https://`, no tag):

     ```shell
     kargo get repo-credentials --project kargo-simple
     kargo delete repo-credentials ghcr-creds --project kargo-simple   # if it exists but is wrong
     kargo create repo-credentials ghcr-creds --project kargo-simple --image \
       --username <yourgithubusername> --password "$GH_PAT" \
       --repo-url ghcr.io/<yourgithubusername>/guestbook
     ```

4. Re-check:

   ```shell
   kargo refresh warehouse guestbook --project kargo-simple
   kargo get freight --project kargo-simple
   ```

#### Debugging credentials (without the UI)

Kargo stores each `repo-credentials` entry as a Secret in the Project
namespace. These commands show the metadata and test the same credentials the
way Kargo uses them, without printing the token.

```shell
# 1. What Kargo has (type, repoURL; the password is not shown)
kargo get repo-credentials --project kargo-simple
kubectl get secrets -n kargo-simple -L kargo.akuity.io/cred-type

# 2. The exact repoURL and username stored (must match the Warehouse/task exactly)
for c in github-creds ghcr-creds; do
  echo "$c: $(kubectl get secret $c -n kargo-simple -o jsonpath='{.data.repoURL}' | base64 -d)" \
       "user=$(kubectl get secret $c -n kargo-simple -o jsonpath='{.data.username}' | base64 -d)"
done

# 3. Replay the stored ghcr.io credentials (what the Warehouse does)
U=$(kubectl get secret ghcr-creds -n kargo-simple -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl get secret ghcr-creds -n kargo-simple -o jsonpath='{.data.password}' | base64 -d)
curl -s -o /dev/null -w '%{http_code}\n' -u "$U:$P" \
  "https://ghcr.io/token?scope=repository:<yourgithubusername>/guestbook:pull&service=ghcr.io"
# 200 = credentials work; 401/403 = wrong token, fine-grained token, or missing read:packages

# 4. Replay the stored GitHub credentials (what git-clone/git-push do)
U=$(kubectl get secret github-creds -n kargo-simple -o jsonpath='{.data.username}' | base64 -d)
P=$(kubectl get secret github-creds -n kargo-simple -o jsonpath='{.data.password}' | base64 -d)
git ls-remote "https://$U:$P@github.com/<yourgithubusername>/kargo-simple.git" main >/dev/null \
  && echo "git: OK" || echo "git: FAILED (token lacks repo scope, or wrong repo URL)"
unset U P

# 5. What the Warehouse itself reports
kubectl get warehouse guestbook -n kargo-simple \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}: {.message}{"\n"}{end}'

# 6. Kargo controller logs (find the deployment names first)
kubectl get deploy -n kargo
kubectl logs -n kargo deploy/kargo-controller --since=15m | grep -iE 'guestbook|error'
```

To fix a credential: `kargo delete repo-credentials <name> --project kargo-simple`,
create it again (step 4b), then `kargo refresh warehouse guestbook --project kargo-simple`.

#### A Promotion to dev failed

Auto-promotion starts a Promotion as soon as Freight exists. If credentials,
the Argo CD Application or the smoke test were broken, that Promotion fails
and stays failed; fixing the cause does not re-run it.

Where to look:

```shell
kargo get promotions --project kargo-simple --stage dev      # phase: Succeeded / Failed / Errored
kargo get promotion <promotion-name> --project kargo-simple -o yaml   # status.message names the failed step
kargo get stages dev --project kargo-simple -o yaml            # status.conditions, current Freight, health
kubectl get analysisruns -n kargo-simple                       # if the Promotion succeeded but verification failed
kubectl logs -n kargo-simple job/<job-name>                    # curl output (kubectl get jobs -n kargo-simple)
```

| Failed step / message | Usual cause | Fix |
|---|---|---|
| `git-clone`, `git-push`: authentication / 403 | `github-creds` missing, wrong `repoURL`, token without `repo` | Fix credentials (above) |
| `git-clone`: commit or path not found, or `kustomize-set-image`: `could not find any Kustomization files in "./src/stages/dev"` | The Freight's commit of `main` on GitHub doesn't have the `stages/` layout (local changes not pushed) | Push `main` (step 2). The push creates new Freight and dev auto-promotes it; the old Freight keeps failing, ignore it |
| `kustomize-build` | Broken overlay at that commit | Fix on `main`; that commit makes new Freight |
| `argocd-update`: not authorized / not found | Application missing, or wrong `kargo.akuity.io/authorized-stage` annotation | `kubectl apply -R -f argocd/` (step 3) |
| Promotion Succeeded, Stage unhealthy | Argo CD can't sync `stage/dev` (private repo, bad manifest) | Check the app in the Argo CD UI |
| Verification Failed | Smoke test `curl` failed | See "When verification fails" |

Ways to recover, after fixing the cause:

```shell
# Re-run: promote the newest Freight to dev, as auto-promotion would (also clears an auto-promotion hold)
kargo promote --project kargo-simple --warehouse guestbook --stage dev

# Or promote one specific Freight
kargo get freight --project kargo-simple
kargo promote --project kargo-simple --freight <freight-name> --stage dev

# Abort a Promotion that is stuck Running (e.g. waiting on something that will never happen)
kargo promote --project kargo-simple --name <promotion-name> --abort

# Only verification failed: re-run it without promoting again
kargo verify stage dev --project kargo-simple
```

#### Pod: `ErrImagePull ... failed to fetch anonymous token ... 401 Unauthorized`

The image is private and the namespace has no pull secret. Either make the
package public, or create `ghcr-pull` (step 3b). Then restart the pods instead
of waiting for the pull back-off:

```shell
kubectl rollout restart deployment/guestbook-simple -n guestbook-simple-dev
kubectl get pods -n guestbook-simple-dev -w
```

If `ghcr-pull` exists but the pull still fails, check that the token in it has
`read:packages`:
`kubectl get secret ghcr-pull -n guestbook-simple-dev -o jsonpath='{.data.\.dockerconfigjson}' | base64 -d | head -c 80`
(shows the registry and username; don't share the output).

#### Staging PR doesn't open after dev verification passes

Staging needs auto-promotion in `kargo/projectconfig.yaml`. Check and apply:

```shell
kargo get projectconfig --project kargo-simple -o yaml | grep -A3 stageSelector
kargo apply -f kargo/projectconfig.yaml
kargo get promotions --project kargo-simple --stage staging    # should show a Running Promotion
```

To start it by hand instead: `kargo promote --project kargo-simple --freight <freight> --stage staging`
(or `--downstream-from dev`). A staging Promotion stays **Running** while its
PR is open; that is normal.

If the Promotion fails at `git-open-pr`, the `github-creds` token can't open
PRs (needs `repo` scope).

#### Verification: `container has runAsNonRoot and image has non-numeric user (curl_user)`

The smoke-test pod runs with `runAsNonRoot: true`, and the `curlimages/curl`
image names its user instead of giving a UID, so Kubernetes refuses to start
it. `kargo/analysistemplate.yaml` sets `runAsUser: 100` / `runAsGroup: 101`
(curl_user). After changing the template, re-apply and re-run:

```shell
kubectl apply -f kargo/analysistemplate.yaml
kargo verify stage dev --project kargo-simple
```

### Tear down

```shell
kind delete cluster --name kargo-quickstart
```

This deletes Argo CD, Kargo, all Freight/Promotion history and the Kargo
credentials. What stays: your fork, the `stage/*` branches, `versions/*.yaml`
on `main`, and the ghcr.io images.

Optional full reset of Git state (next promotions recreate them):

```shell
git push origin --delete stage/dev stage/staging stage/prod
```

### Bring it back

Run steps 1–5 again (skip step 0). Re-export `GH_PAT` first in a new terminal.
