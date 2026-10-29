# Read this before using apt in this VM

This is about apt on the Ubuntu VM this repo is developed in, not
about apt in general. The problem is a mirror, not the packages.

## The problem

`apt-get update` (and sometimes `apt-get install`) hangs or crawls
on the second mirror in this VM's sources. The VM's
`/etc/apt/sources.list.d/ubuntu.sources` lists two URIs, in order:

- `http://azure.archive.ubuntu.com/ubuntu` — usually fast
- `http://mirror.cogentco.com/pub/linux/ubuntu` — the problem mirror

Symptoms seen, more than once:

- Oct 27, 2026: `apt-get update` hung for 12+ minutes on the
  cogentco fallback, with apt's http method processes stuck and no
  output. The process had to be killed.
- Oct 28, 2026: an update fetched 4003 kB in 2 min 43 s
  (24.6 kB/s), with `W: Failed to fetch
  http://mirror.cogentco.com/.../noble-updates/InRelease
  Connection failed [IP: 198.19.0.1 3128]` — that is the egress
  proxy address, so the failure is in reaching cogentco through it,
  not in the package itself.
- Oct 28, 2026, again: an update still fetching
  `noble-security/universe` from cogentco was killed by a 280 s
  timeout. The install that followed then reported `E: Unable to
  locate package libxkbcommon-x11-0` and `E: Unable to locate
  package xdotool`. That did NOT mean those packages do not exist
  in noble/universe; it meant the package lists were incomplete
  because the update never finished.

A normal update on a healthy mirror takes well under a minute
here, so several minutes with no output, or repeated `Ign:` lines
for cogentco, is the hang, not normal slowness.

## The solution

1. Never run a bare `apt-get update` or `apt-get install` and wait
   on it. Always wrap it in a timeout, with retries, exactly as
   the repo's Ubuntu install scripts already do
   (`install_ubuntu.sh`, `install_dependencies_ubuntu.sh`):
   update in `timeout 300`, install in `timeout 600`, up to
   5 attempts with a 20 s sleep between them. A retry loop alone
   does not help: a hung update never exits, so it never reaches
   the retry — the timeout is what makes it fail fast.
2. Run apt work in the background and do other work while it
   runs. If it hits its timeout, that is the expected outcome,
   not a reason to run the same command again unchanged.
3. If you must stop a hung update, kill that process
   (`ps` for the apt-get process, then `kill` it) and check that
   no apt/dpkg process is still running before starting another
   one. Never run two apt commands at once: the second will just
   block on `/var/lib/dpkg/lock`.
4. After a killed or timed-out update, do not conclude a package
   is unavailable. Re-run the update (with a timeout) to a
   completion first, then check `apt-cache policy <package>`.
5. Do NOT rewrite `/etc/apt/sources.list.d/ubuntu.sources` to drop
   cogentco, force azure, or otherwise pick a mirror, and do not
   add mirror selection to this repo. The sources belong to the
   machine image, rewriting them is destructive, and cloud-init
   can undo it. This was already decided on Oct 27-28, 2026, when
   mirror selection was deliberately left out and only the
   timeout/retry tweak was added to the install scripts. If you
   think the sources genuinely must change, ask the user first.
6. Prefer not using apt at all when there is another route:
   check whether the tool is already installed, use the repo's
   install scripts (which already implement the timeouts), or
   use a tool from the user's home directory or cargo instead.
   Note that anything installed by apt outside the home directory
   is ephemeral on this VM: a VM replacement loses it, so a tool
   missing after a replacement is expected, not a repo bug.
7. If a task is blocked only by an apt install — for example, a
   GUI smoke test that needs `libxkbcommon-x11-0` or
   `mesa-vulkan-drivers` under Xvfb — do not let it block the
   whole task. Verify what can be verified without it (build,
   unit tests), say plainly that the GUI check is blocked on apt,
   and move on. That is what happened on Oct 28, 2026, for the
   rust-egui URL import: the import was verified by unit tests
   instead of a clicked-through Xvfb run.
