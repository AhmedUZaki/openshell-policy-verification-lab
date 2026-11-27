# Setup

Installs everything this project needs, in order. Run the files in `setup/`
numbered `1` through `4`. Each one checks whether its own job is already done
before doing anything, so re-running any of them is safe.

| # | File | What it does |
|---|---|---|
| 1 | `1-check-environment.sh` + `.cmd` | Read-only. Reports what is missing and what to run next. Changes nothing. |
| 2 | `2-install-wsl.cmd` | Installs WSL 2 + Ubuntu-24.04, if missing. **Windows only** — WSL is a Windows concept, there is nothing to install on macOS/Linux. |
| 3 | `3-install-docker-desktop.cmd` | Installs Docker Desktop, if missing; makes sure it is running and reachable from Ubuntu-24.04. **Windows only** — on macOS, install Docker Desktop yourself (`brew install --cask docker`). |
| 4 | `4-install-nemoclaw.sh` + `.cmd` | Installs NemoClaw (which installs OpenShell and its gateway as part of its own install). Runs on macOS, Linux, and Windows (via WSL). |
| 4b | `4b-install-openshell-versions.sh` + `.cmd` | Optional. Downloads specific OpenShell releases (default: `0.0.116` and `0.1.9`; or any you list, e.g. `install 0.1.5`) into `~/.local/share/openshell-lab/`, verified against the published SHA-256 lists. Downloading does not change the active version; `use VERSION` does, and `run-enforcement-audit` switches versions itself. Linux/WSL only. |
| 5 | `5-uninstall-everything.sh` + `.cmd` | **Deletes things.** Menu by number (`0` = items 1-5): sandboxes/containers, gateway service, commands, `~/.nemoclaw`, nvm; and, Windows only, Docker Desktop (6) and the Ubuntu distro (7). Items 6 and 7 are never part of `0` and each needs its own typed confirmation. Add `dry` (`.cmd`) or `DRY_RUN=1` (`.sh`) to preview. |


The paired setup `.cmd` files for steps 1, 4, and 5 forward into WSL and run
the matching `.sh` logic. Steps 2 and 3 are native Windows scripts with no
`.sh` counterpart because installing WSL, or installing Docker Desktop via
`winget`, has no Linux/macOS equivalent.

## Why step 4 sets `NEMOCLAW_AGENT=hermes`

Step 4 installs without onboarding (no sandbox, no model provider, no API key).
NemoClaw's installer only allows that for agents that declare
`deferred_onboarding: true` (`hermes`, `langchain-deepagents-code`), not for
the default `openclaw`. No agent is actually onboarded, so the installed tools
(`nemoclaw`, `openshell`, the gateway) are identical either way, and you can
choose any agent later with `nemoclaw onboard --agent <name>`. The installer's
closing "NemoHermes CLI is installed" message is a side effect of this.

## Notes for a fresh Windows machine

- Steps 2 and 3 install Windows features and Docker Desktop: expect a UAC
  prompt (or run them from an administrator terminal) and possibly a restart.
- Every `.cmd` file targets `Ubuntu-24.04` explicitly (`wsl -d`), so another
  default distro does not confuse the checks. Step 3 does make `Ubuntu-24.04`
  the default distro, because Docker Desktop's WSL integration follows it.
- Step 4 refuses to run NemoClaw's installer unless the pinned tag still
  points at the commit recorded in `4-install-nemoclaw.sh`.
- On Linux without apt-get, git and curl are installed with dnf, pacman or
  zypper; any other package manager needs them installed by hand. macOS needs
  Homebrew and a running Docker Desktop.

## Start here

```
setup\1-check-environment.cmd
```

It tells you exactly which numbered file to run next for anything that is
missing. Keep running it after each step until everything passes, then run
`setup\4-install-nemoclaw.cmd`.

After setup passes, return to the project root and run:

```text
run-enforcement-audit.cmd
```

The menu lets the user choose network tests, filesystem tests, or both. For unattended execution, pass exactly one of `--all`, `--network-only`, or `--filesystem-only` after `nopause`.

## Known issue: Docker Desktop installed, but step 3 or 4 still can't reach it

This happened on a real test of this project's own setup, and is worth
knowing about before it wastes your time.

**Symptom:** `3-install-docker-desktop.cmd` sits at `[3/4] Making sure Docker
Desktop is running` for several minutes and then fails with
`Docker did not become ready`, even though Docker Desktop's own window shows
"Engine running".

**Cause:** Docker Desktop has a separate on/off switch for whether it
connects to WSL distros at all. On a fresh install, it can be **off by
default** — so Docker's engine can be perfectly healthy on the Windows side
while being completely unreachable from inside Ubuntu-24.04.

**Fix:** open Docker Desktop itself (not this script) →
**Settings → Resources → WSL integration**:

![Docker Desktop's WSL integration settings, with "Enable integration with my default WSL distro" switched off](images/docker-wsl-integration.png)

If **"Enable integration with my default WSL distro"** is switched off (as
in the screenshot above), turn it on — Ubuntu-24.04 is already the default
distro, which `3-install-docker-desktop.cmd` sets up for you. Alternatively,
open the **"Enable integration with additional distros"** dropdown and select
`Ubuntu-24.04` there explicitly. Either one is enough on its own.

Click **Apply & Restart**, wait for Docker Desktop to come back up, then run
`setup\3-install-docker-desktop.cmd` again. It should now finish within a few
seconds.

This is a one-time, per-install setting: once it is on, it stays on across
reboots and restarts, and this step will not come up again unless Docker
Desktop is reinstalled from scratch.

### Why quitting and reopening Docker Desktop did not fix it on its own

Before finding the toggle above, we tried the more common fix for WSL
integration problems: fully quitting Docker Desktop (not just closing its
window) and reopening it, so it re-reads which WSL distro is the default one.
On a normal Docker Desktop install, that is often enough by itself.

On this test, it was not: the underlying switch above was off, and quitting
and reopening Docker Desktop does not turn it on. If you hit this problem on
your own machine, try quitting and reopening Docker Desktop first since it
is quick and sometimes is the whole fix — but if `3-install-docker-desktop.cmd`
still fails afterward, check the toggle above directly rather than trying
more restarts.

### Also normal: the very first start takes longer than usual

Right after Docker Desktop is first installed, its very first startup sets
up its backend from scratch and can take several minutes — longer than any
start after that. `3-install-docker-desktop.cmd` allows up to 6 minutes for
this and prints a line every 10 seconds so a long wait does not look frozen;
seeing those lines for a few minutes on a brand-new install is expected, not
a sign of a problem.

## Testing OpenShell 0.1.x (for example 0.1.9) on Docker Desktop: known blocker

**Status (2026-11-26):** on the reference machine (Docker Desktop with WSL 2) OpenShell
0.1.x sandboxes now start: the lab's full 36-test comparison ran on 0.1.9 on 2026-11-22,
and OpenShell 0.1.1 to 0.1.10 were later run in a separate repository. What changed on the
machine since the blocker was first recorded was not captured, so the notes below are kept
as the troubleshooting record: if you see the symptom, they still apply.

This applies only if you run the lab against OpenShell 0.1.x, for example with
`run-enforcement-audit --compare` or `--openshell-version 0.1.9`. OpenShell
0.0.116 does not need anything here.

**Symptom:** every sandbox fails to start, and the output ends with lines such as

```text
ControlSupervisorStartFailed: Docker supervisor exited before becoming ready
Startup configuration fetch failed, retrying
openshell: log push connect failed: failed to connect to OpenShell server
```

**Cause (from the OpenShell 0.1.9 source and documentation):** by default the sandbox
supervisor runs in a container with host networking and connects back to the gateway
at `127.0.0.1`. The documentation states that host mode on Docker Desktop requires
host networking to be enabled (Docker Desktop: **Settings → Resources → Network →
Enable host networking**).

![Docker Desktop settings, Network section, with "Enable host networking" switched on](images/docker-host-networking.png)

**What was and was not verified on this project's reference machine (Docker Desktop with
WSL 2):** with that setting switched on, a `--net=host` container still could not reach a
service listening on the WSL loopback, while a normal container could reach it through
`host.docker.internal`; OpenShell 0.1.9 still failed with the symptom above. The setting
may need "Apply & Restart" to take effect, which was not confirmed. The alternative
described by upstream, `supervisor_network_mode = "bridge"` in the gateway's
`gateway.toml`, has not been tried and is not applied by this lab.

While the symptom persists, a 0.1.x run ends as `INCOMPLETE` (exit code 2) and the comparison
shows its tests as not measured. It is never reported as a pass.

### Network tests on OpenShell 0.1.x: what the lab does differently

On OpenShell 0.1.x a sandbox has no network of its own, and names in the policy are resolved by the
supervisor (a separate host-network container). That container cannot see the lab's Docker network
aliases (`host-a.test`), and it does not trust the local test server's certificate authority. Measured on the
reference machine: on 0.0.116 the sandbox joins the `openshell-docker` network and has proxy variables; on
0.1.9 it has neither, and `curl` reported `Could not resolve host: host-a.test`.

So for 0.1.x the network suite changes three things (all in `tests/shared/gateway-network-config.sh`;
OpenShell 0.0.116 is never affected):

1. The local test servers are named `host.openshell.internal` (ports 443 and 444), as the lab already does on macOS.
2. The lab writes two temporary files, `~/.config/openshell/gateway.env` and
   `~/.config/openshell/lab-gateway.toml`, that (a) point `host.openshell.internal` at the test server
   (`drivers.docker.host_gateway_ip`) and (b) make the supervisor trust the test CA
   (`supervisor.network.additional_ca_bundle`). They are read when the gateway starts, so the lab restarts the gateway.
3. Because 0.1.x refuses a disallowed destination or executable at the sandbox boundary (connection refused,
   permission denied, or the name does not resolve) instead of answering HTTP 403, the report accepts that as the
   denial signal on 0.1.x only. It is labeled `boundary-refusal`, and the usual conditions still apply (working
   baseline, healthy sandbox and origin, no request in the origin log).

The files are marked as lab-managed; a `gateway.env` that the lab did not create is never overwritten, and the
network cleanup deletes both files and restarts the gateway so the settings do not stay loaded.
