# GitLab ⇄ Gerrit pipeline

GitLab (`gitlab.com/Linedwell/UmamiAnalytics`) is the working repository.
Gerrit (`mediawiki/extensions/UmamiAnalytics` on `gerrit.wikimedia.org`) is
the canonical repository. This pipeline keeps them in step.

## How it works

GitLab and Gerrit keep **two separate histories with the same content**. They
differ only in identities and commit IDs (SHA):

| | On GitLab | On Gerrit |
|---|---|---|
| Your commits | your GitLab e-mail (`GITLAB_EMAIL`, e.g. noreply) | your Gerrit e-mail (`GERRIT_EMAIL`) |
| Commits by others (bots, admins, contributors) | original author | original author |
| `Change-Id` trailer | optional | always (added if missing) |

Commits are copied between the two sides, and identities are swapped on the way:

- **GitLab → Gerrit (`gerrit:push`):** runs on every push to `main` or `REL1_*`. It uploads the new commits with `git review`, one Gerrit change per commit. If `GERRIT_AUTO_SUBMIT=true`, it then votes Code-Review +2 and Verified +2 and submits them. This repository is not tested by Zuul, so Verified has to be voted by hand; if jenkins-bot ever votes Verified, set `GERRIT_VERIFIED_VOTE` to an empty value.
- **Gerrit → GitLab (`gerrit:sync`):** runs from a pipeline schedule, or manually. It copies commits made directly in Gerrit (LibUp, translation bots, admins, release branches) on top of the GitLab branches.

**GitLab branches only ever move forward:** the pipeline never force-pushes. Clones never break, and a plain `git pull` is always enough. Your Gerrit e-mail never appears on GitLab: not in commits, and not in job logs.

### The sync point

To decide what is new, the pipeline does not compare commit IDs, which always differ between the two sides. It looks for the **last content state both sides share**: the newest Gerrit commit whose files are identical to some GitLab commit. Everything after that point on one side is new for the other side.

Changes already present on the other side are dropped automatically: a re-run pipeline, a commit already merged, the same fix made on both sides.

### Consequences

- The same change has a different SHA on GitLab and on Gerrit. To refer to a change across both, use its `Change-Id` or its subject.
- Commits may appear in a slightly different order on each side. For example, a bot commit merged in Gerrit while your change was under review appears after your change on GitLab. The content is always the same once everything is merged; `gerrit:sync` prints `content identical`.

## Files

| File | Role |
|---|---|
| `.gitlab-ci.yml` | Job definitions and settings. |
| `.gitlab/ci/gerrit-common.sh` | Shared helpers: SSH, remotes, sync point, `sync_branch`. |
| `.gitlab/ci/gerrit-push.sh` | `gerrit:push`. |
| `.gitlab/ci/gerrit-sync.sh` | `gerrit:sync`. |
| `.gitlab/ci/gerrit-align.sh` | `gerrit:align`, the manual escape hatch. |
| `.gitlab/ci/map-commit.sh` | Identity swap and `Change-Id`, applied to each copied commit. |

## One-time setup

### 1. Create a dedicated SSH key

```bash
ssh-keygen -t ed25519 -N "" -C "gitlab-ci-UmamiAnalytics" -f ./gerrit_ci_ed25519
```

The key comment must not contain spaces: Gerrit rejects the key otherwise.

- Add `gerrit_ci_ed25519.pub` to Gerrit: <https://gerrit.wikimedia.org/r/settings/#SSHKeys>.
- Keep the private key for step 4, then delete it from your disk.

> The key acts as your `linedwell` account on Gerrit, for every repository you can access, not just this one. Anyone with Maintainer access to the GitLab project can use it through a pipeline. Revoke it in Gerrit if the GitLab project is ever compromised.

Test it:

```bash
ssh -i ./gerrit_ci_ed25519 -p 29418 linedwell@gerrit.wikimedia.org gerrit version
```

### 2. Get Gerrit's host key

```bash
ssh-keyscan -p 29418 gerrit.wikimedia.org 2>/dev/null > gerrit_known_hosts
ssh-keygen -lf gerrit_known_hosts
```

Compare the fingerprints with the ones published on Wikitech (search *"SSH Fingerprints gerrit.wikimedia.org"*), or with your own `~/.ssh/known_hosts`.

### 3. Check your Gerrit e-mail

`GERRIT_EMAIL` must appear in <https://gerrit.wikimedia.org/r/settings/#EmailAddresses>.

### 4. GitLab settings

**a. Project access token.** Go to *Settings → Access tokens → Add new token*:
- name `gerrit-sync`
- role **Maintainer**
- scope **`write_repository`**
- the longest expiry allowed

The pipeline uses it to push Gerrit commits to GitLab. Add a calendar reminder to renew it before it expires.

**b. Protected branches.** Go to *Settings → Repository → Protected branches*:
- `main`: *Allowed to push and merge* = Maintainers. **Force push stays disabled.**
- Add a wildcard rule `REL1_*` with the same settings.

Protected variables are only available on protected branches.

**c. CI/CD variables.** Go to *Settings → CI/CD → Variables*. Tick **Protected** on all of them.

| Key | Type | Value | Masked |
|---|---|---|---|
| `GERRIT_SSH_PRIVATE_KEY` | **File** | Contents of `gerrit_ci_ed25519`, **ending with a newline** | no (multi-line) |
| `GERRIT_KNOWN_HOSTS` | **File** | Contents of `gerrit_known_hosts` | no |
| `GITLAB_PUSH_TOKEN` | Variable | The project access token | **yes** |
| `GERRIT_NAME` | Variable | Your display name, e.g. `Linedwell` | no |
| `GERRIT_EMAIL` | Variable | Your Gerrit-registered e-mail, **with the exact same case** as in Gerrit settings | **yes**, if GitLab accepts it |
| `GITLAB_EMAIL` | Variable | Your GitLab commit e-mail, e.g. `12345678-Linedwell@users.noreply.gitlab.com` (*Preferences → Profile → Commit email*) | no |

Optional: `GITLAB_NAME` is the display name used on GitLab. It defaults to `GERRIT_NAME`.

Values that are not secret (`GERRIT_USER`, `GERRIT_PROJECT`, `GERRIT_AUTO_SUBMIT`, …) are in `.gitlab-ci.yml`. A CI/CD variable with the same name overrides them.

The scripts never print e-mail addresses. Masking `GERRIT_EMAIL` also hides it if it ever appears in an error message returned by Gerrit, because job logs of a public project are public.

**d. Pipeline schedule.** Go to *Build → Pipeline schedules → New schedule*:
- target branch `main`
- e.g. every day at 03:17 (`17 3 * * *`)

This runs `gerrit:sync`.

### 5. First run

1. Do steps 1 to 4, then add the CI/CD variable `GERRIT_AUTO_SUBMIT` = `false` for this first run only.
2. Add the pipeline files to `main`, in the Web IDE or from a clone. Commit directly to `main`.
3. `gerrit:push` runs. It finds the last state shared with Gerrit and uploads **only** the new commit (the pipeline files). Check in Gerrit that this single change is there and that only *Owner* is shown (no separate Author/Committer). Then vote Code-Review +2 and Verified +2, and Submit it.
4. Delete the `GERRIT_AUTO_SUBMIT` variable, so the default `true` from `.gitlab-ci.yml` applies again.
5. Open the pipeline and click the manual job `gerrit:sync`. It:
   - copies the Gerrit-only commits to GitLab `main` (e.g. the admin's `Add .gitreview`);
   - checks `REL1_43`;
   - creates `REL1_47` on GitLab.

   Each branch should end with `content identical`.
6. In your clone, run `git pull`.

## Day-to-day use

- **Normal work:** commit (from a local clone or the Web IDE), push to `main`, done. The change shows up in Gerrit already merged, with your Gerrit identity and a comment linking to the pipeline.
- **Local clone:** no special setup. Keep your GitLab identity. `git review -s` is optional: it installs Gerrit's hook, which adds `Change-Id`s locally; otherwise the pipeline adds them.
- **Review in Gerrit instead:** set the CI/CD variable `GERRIT_AUTO_SUBMIT=false`, or set it only for one run in the *Run pipeline* form. Changes are uploaded but not approved. After you submit them in Gerrit, run `gerrit:sync` or wait for the schedule.
- **Backports:** push to GitLab `REL1_xx`, which goes to Gerrit `REL1_xx`. You can also cherry-pick in Gerrit; `gerrit:sync` then brings the result to GitLab.
- **Several commits in one push:** each commit becomes its own Gerrit change, in a chain. They are approved and submitted oldest first.
- **Merge commits:** they are flattened, since Gerrit expects linear history.
- **Tests:** add test or lint jobs in the `test` stage. `gerrit:push` only runs if they pass.

## When a branch is stuck: `gerrit:align`

A conflict happens when someone changes in Gerrit the same lines as a GitLab commit that is not merged yet. Symptoms:
- `gerrit:push` fails with *do not apply cleanly*;
- `gerrit:sync` ends with a warning (exit 3).

To fix it:

1. Click the manual job **`gerrit:align`** in a `main` pipeline. Set the variable `ALIGN_BRANCH` in the *Run pipeline* form for a branch other than `main`. The job adds **one commit** on GitLab that makes the branch content identical to Gerrit. History is kept, nothing is force-pushed, and the commit message lists the GitLab changes it undid.
2. Run `git pull`, re-apply your change on top (re-edit it, or `git cherry-pick <your commit>` and resolve the conflict), then push. The pipeline starts again from the aligned state.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Permission denied (publickey)` | Public key not in Gerrit settings, or the File variable is missing its final newline. |
| `Host key verification failed` | `GERRIT_KNOWN_HOSTS` is wrong or outdated: redo step 2. |
| `invalid committer` / `does not match your user account` | `GERRIT_EMAIL` is not registered in Gerrit (step 3). |
| Gerrit shows separate *Author*/*Committer* lines | `GERRIT_EMAIL` differs from the address of your Gerrit account, even only by case. Copy it exactly from Gerrit settings. |
| `invalid author` | A commit author other than you is not accepted by Gerrit (*Forge Author* permission, normally granted to all registered users). Ask a Gerrit admin. |
| `do not apply cleanly` / sync warning (exit 3) | Conflict: see `gerrit:align` above. |
| `no content in common` | The GitLab branch shares no file state with Gerrit. Create the GitLab branch from scratch with `gerrit:sync` (delete it first), or run `gerrit:align`. |
| `Could not submit … after N attempts` | The change is not submittable (missing label, conflict). Submit it in Gerrit by hand, then run `gerrit:sync`. |
| `remote: HTTP Basic: Access denied` in the sync step | `GITLAB_PUSH_TOKEN` has expired or lacks `write_repository`. |
| Push to GitLab rejected (non-fast-forward) | `gerrit:sync` added commits: run `git pull` (or `git pull --rebase`). |
