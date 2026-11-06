# QGA variant lifecycle — reference acceptance checks

These are destructive black-box checks for a **disposable Windows VM**. They belong
on the test reference branch, not in the installer logic PR. They inspect delivered
MSI registrations, service state, installed files and real guest-agent RPC results.
They do not assert the bootstrapper's internal branches or package IDs.

## Before running

- Use only a VM that you own and have explicitly authorized for installer testing.
  Restore a clean snapshot yourself: no QGA product, service or VSS provider.
- Keep the VM running with working VirtIO serial drivers and a configured
  `org.qemu.guest_agent.0` channel. A missing channel is a fixture error, not a VSS result.
- Supply **QGA-only lab bundles** built from the corresponding installer source;
  do not run a full companion-driver bundle with these tests. Other-driver upgrades
  and their reboot requirements are outside this suite.
- The old/new bundles must share their bundle upgrade family. Each must contain an
  unchanged official full MSI and a genuine, separately built no-VSS MSI. The full
  and no-VSS variants must have distinct stable MSI UpgradeCodes across releases.
  Use matching versions within each release and distinct ProductCodes. Do not rename
  a full MSI to pretend it is no-VSS, or modify Windows Installer's cached packages.
- Use the platform's normal verification/signing rules. A self-signed lab package is
  not a production artifact: do not import its signer into trusted roots/publishers,
  disable verification, export its private key or enable test-signing to run this suite.
- Set up SSH authentication outside this repository, preferably with SSH config/key
  authentication. No test reads a credential file or changes guest authentication.
  Any private wrapper must keep credentials in memory, preserve meaningful whitespace
  and never put secrets into command arguments, files or logs.
- Save an operator-controlled pre-test snapshot and configuration receipt. This suite
  does not create, revert, destroy, mount, restart or power off VMs. Restore the original
  VM/configuration yourself after testing; retain test evidence and failure snapshots.

Requirements: Python 3, `pytest`, OpenSSH `ssh`/`scp`, `virsh` and PowerShell in the guest.
Run the suite separately on x64 and x86 Windows guests. Example (paths are placeholders):

```sh
export QGA_TEST_ALLOW_INSTALL=1
export QGA_TEST_DOMAIN=your-disposable-vm
export QGA_TEST_SSH=your-ssh-config-host
export QGA_TEST_OLD_BUNDLE=/path/to/qga-only-old.exe
export QGA_TEST_NEW_BUNDLE=/path/to/qga-only-new.exe
export QGA_TEST_OLD_VERSION=109.1.0
export QGA_TEST_NEW_VERSION=110.0.2
export QGA_TEST_OUTPUT=/path/to/preserved-evidence
# Optional: QGA_TEST_URI (default qemu:///system), QGA_TEST_SSH_WRAPPER
sha256sum "$QGA_TEST_OLD_BUNDLE" "$QGA_TEST_NEW_BUNDLE"
python3 -m pytest -v test/qga
```

Keep the checksums with the test output. Each fixture writes logs, observed state
(including the installed executable's SHA-256) and RPC results to a new output
subdirectory. Omitting the opt-in skips all destructive tests. Missing required
configuration after opt-in is a failure, not an unexplained skip.

## Executable cases

| Check | Observable result |
| --- | --- |
| Old full → new, no variant argument | Actual Agent version changes; exactly one full product, VSS files/provider and `thawed` remain |
| Old no-VSS → new, no variant argument | Actual Agent version changes; exactly one no-VSS product, no VSS files/provider and explicit VSS-unavailable response remain, including with SENS disabled |
| Opposite request on ordinary upgrade or Repair | Refused before the delivered log's Apply phase; original registration, files, service and RPC remain |
| Ordinary Repair | Actual installed variant is retained |
| Explicit `/modify` in both directions | Exactly one target product, running service, target files and actual RPC/VSS capability match |
| Disabled SENS or COMSysApp policy | Full install/repair/removal and relevant switches refuse before Apply; no-VSS install/repair/removal remain usable |

The dependency test changes the selected service's startup configuration and restores
it in `finally`. It does **not** stop a running COM+ service. Other prerequisite
failures are not synthesized. A refusal must leave product/file/service state
unchanged and must not rewrite the disabled startup policy.

Cleanup uninstalls only the bundle successfully installed by the current test; it
never guesses product ownership or force-removes an MSI. If an operation remains
pending, SSH/SCP authentication fails, or OpenSSH exits with transport status 255,
no additional installer/SSH cleanup is attempted. Status 255 is not treated as proof
of credential rejection. The guest is deliberately left for inspection and an
operator snapshot restore.
Reboot-requiring cases may fail the immediate RPC assertion; the suite does not
silently reboot and call that a no-reboot pass.

## Original maintenance GUI: manual check, not a CLI substitute

Use the **same checksummed candidate** and an already authorized logged-in desktop.
Use a normal login if needed; do not change credentials, automatic login or licensing.
A failure to authenticate is a stop condition, not permission to try alternate access.

1. On a fresh machine, launch with no arguments. Confirm the VSS choice and native
   Install control exist. Before accepting the license, Install must be disabled;
   accepting it enables Install when otherwise eligible. Close without installing.
   Record keyboard testing separately: clicking a native control is not keyboard proof.
2. Install a no-VSS fixture. Verify `guest-info` reports the expected version before
   any UI action; do not discover a missing guest-agent channel after claiming success.
3. Relaunch the same bundle **with no arguments**. On the original maintenance page,
   confirm VSS is unchecked and enabled, and Apply changes/Uninstall are available.
   Select VSS and click the native Apply changes button. Close the completion page.
4. Confirm exactly one full product, running Agent, VSS files/provider, expected
   `guest-info` version and `guest-fsfreeze-status` = `thawed`. Product count or exit 0
   alone does not prove a functional VSS switch. Do not actually freeze a live filesystem.
5. Relaunch with no arguments; clear VSS and Apply changes. Confirm one no-VSS product,
   no VSS files/provider, expected Agent version and the specific VSS-unavailable
   response. An RPC transport error is not that response.
6. Exercise explicit `/repair` separately: it must not authorize a variant switch.
   Record GUI Repair, keyboard accessibility and error-state checks as unverified
   until they are actually performed.

When automating this manual check, select the visible `WixStdBA` window owned by
this launch's observed process/descendant chain. A matching title alone can identify
an older window, hidden owner or cancellation dialog. Close the owned success window
and confirm its destruction before launching the reverse operation. Store each phase
in a separate, immutable receipt; do not overwrite the earlier successful result.

## Failure, cancellation and continuation boundaries

A representative failure may be tested on a fresh no-VSS fixture by creating a
**test-owned nonempty directory** at the otherwise-absent `qga-vss.dll` file target.
Attempt full Modify, verify failure preserves the original no-VSS product and RPC,
then remove only the marker/directory owned by this fixture. Never edit a cached MSI.
An ACL-only write denial is not guaranteed to make Windows Installer fail; do not
call it a rollback test if installation succeeds. This fault case is manual here,
not an extra generalized injection framework.

A preserved lab observation is **not fixed** by these tests: disabling COMSysApp
while a full Agent is running, then restoring its startup type, left the Agent in
Stop Pending and a subsequent stock full removal returned service-stop error 1921.
Keep that observation separate from the isolated failure result. Do not claim that
the installer repairs a service process damaged by an administrator policy change.

No general crash/reboot/cancellation/rollback guarantee follows from this suite.
ARP or stale saved intent must not authorize a Repair switch. Inconsistent ordinary
Install continuation must fail closed; a GUI Modify reconstructed as Repair may be
conservatively refused. Exercise any promised continuation behavior with its exact
interruption/resume entry path before calling it supported.

## Evidence scope

Authoring or collecting this suite is **not** an installer run. Keep source review,
compilation, CLI execution, GUI execution, keyboard checks and full companion-driver
Apply as separate entries. Preserve failed attempts as well as passes. The parent
lab's historical receipts do not make this newly authored portable suite passed;
it must be run against the operator's supplied artifacts and guests.
