# Why this repo is the way it is

This repo repackages the upstream Prometheus node_exporter release binary as a Debian package. It has one consumer, its owner, but it is public. It contains no application code: its whole value is in a small number of packaging decisions. This file records the reasons for them. How things work is the code's job; if the code cannot explain itself, fix the code rather than documenting it here.

## Principles

**Repackage, never rebuild.** The binary is upstream's own release artifact. Compiling it here would add a toolchain to maintain and would make the package differ from what upstream tested.

**Pin and verify everything that is downloaded.** The upstream version and its checksums are committed, and the build fails on a mismatch. The checksums come from a commit a human reviewed, not from the place the tarball is downloaded from, so a tampered upstream release cannot slip through. The same reasoning is why nFPM and the CI actions are pinned by digest or commit rather than by a moving tag. The Debian base image is the one deliberate exception: it follows its release tag so the build tools get security updates and the smoke test runs against Debian as hosts currently have it.

**All versions live in one place.** A version bump should be a one-file change that is easy to review.

**Containers are the only build environment.** A developer machine is assumed to have Docker or Podman and nothing else: no particular shell, no Debian tooling, no nFPM. Local runs and CI execute the same container commands, so there is one code path and "works on my machine" cannot diverge from CI. This is also why there are no host-side wrapper scripts, and why only container features that both engines support on every host OS are used, even where an engine-specific shortcut exists.

**Follow Debian conventions instead of inventing.** Standard paths, declarative user and directory creation, and the same service-handling snippets Debian's own tooling generates. A host admin should find nothing surprising. When in doubt, do what a package from the Debian archive would do.

**Keep the package's name and identity distinct from Debian's own node exporter package.** They would fight over the same port, so the two are declared as conflicting rather than made interchangeable. Mirroring Debian's name would let an ordinary `apt upgrade` silently replace this package.

## Decisions that look odd without context

**Two textfile directories.** One persists across reboots and one does not. Rare jobs (a nightly backup) want their last result to survive a reboot; other metrics must not be reported stale after one. Both are provisioned and read by default so a host needs no extra setup. Writing is restricted to a dedicated group so that publishing metrics does not require running as the exporter or as root.

**The service has almost no sandboxing.** The exporter's job is to observe the whole host. The usual systemd hardening options hide exactly the things it measures.

**The service cannot be reloaded.** The exporter has no reload handler; a reload signal would terminate it in a way systemd regards as a clean stop and does not restart.

**The service user is never deleted.** Files it or the writers group own may outlive the package, and reusing system account IDs is discouraged in Debian.

**A failed service start does not fail the package installation.** This is the Debian norm: a half-configured package is harder to recover from than a stopped service. The smoke test exists to catch this case before a release.

## Testing

There is one smoke test, and that is deliberate. It answers a single question: does this package give a working exporter on a fresh host? It installs the package into a booted systemd container the way a real host would.

Do not grow it into a lifecycle suite. Upgrade, removal, purge and config-preservation behaviour belong to dpkg and systemd tooling; testing them here would mostly test those tools, and the test code would outweigh the thing under test. Add a check only for behaviour this repo itself implements and that has actually broken.

## Releasing

A final release is cut by a human pushing a tag, and CI refuses to publish if the tag disagrees with the pinned versions: the tag is a statement of intent, the pinned file is the truth, and they must not drift.

There is no pre-release flow. It was designed and then dropped: it added version-ordering rules, a second publishing path and clean-up duties, which is more than trying a build on a host is worth. The package built for any pull request is available as a CI artifact, and that covers the need.

## Working in this repo

- Line endings are forced to LF only for files that are executed or parsed on Linux (scripts, pinned values, everything that goes into the package or the test container), because those break on a Windows checkout otherwise. Other files are left to each contributor's git settings.
- Nothing may depend on file modes or executable bits from the checkout, for the same reason.
- Comments say why, not what.
- If a change needs a new tool on the host, it is the wrong change; put the tool in a container stage.
