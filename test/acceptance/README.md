# Driver installer acceptance tests

Black-box tests of what the driver MSI promises a user. Each test drives a disposable Windows VM the way a
user or admin would (install, cancel, change features, uninstall, reboot) and judges only what Windows
shows afterwards. They do not look at the installer's code, tables or private registry data.

## What is checked

| Test | Promise |
|---|---|
| `test_upgrade_from_an_older_release_leaves_every_device_working` | Upgrading an older release succeeds; after reboot every virtio device has a working driver and every driver service runs |
| `test_upgrade_repairs_a_machine_whose_earlier_upgrade_was_interrupted` | On a machine where an earlier upgrade was cancelled half-way (some devices left without a driver), upgrading succeeds and repairs it |
| `test_a_later_release_upgrades_this_one` | The next release upgrades this one |
| `test_a_failed_upgrade_changes_nothing` | When Windows refuses a driver (admin device-install policy), the install fails and, after reboot, the machine looks exactly as before |
| `test_cancelling_at_the_last_step_changes_nothing_and_a_retry_works` | Cancelling at the very end leaves the machine as before; installing again then works |
| `test_removing_and_adding_back_a_driver_feature_keeps_its_device_working` | Removing a driver feature in maintenance mode, then adding it back, never leaves its device without a driver |
| `test_uninstall_leaves_no_device_without_a_driver` | After uninstall no virtio device is left without a driver |
| [Additional owned-package removal rollback](uninstall-rollback/README.md) (separate invocation) | Cancelling after actual owned BALLOON removal restores its binding, public delivery state and customized service configuration; all five path gates and cleanup must pass |

The additional case is not counted as one of the seven pytest scenarios. It requires both complete
suite receipts first and does not treat scheduling ActionStart events as proof that removal occurred.

"What Windows shows" (`guest/observe.ps1`): installed virtio products, Red Hat driver packages in the driver
store, every present virtio PCI device with its status, driver version and service, and for those services
whether they run and whether their driver file exists. It also records delivered driver/tool file hashes and
user-mode services with their startup mode, running state and executable presence. Upgrade checks reject
lost tools or services even when device drivers still work; rollback comparisons include these observations.
The old `VirtIO-FS Service` identity may be retained, or replaced by `VirtioFsSvc`; the retained or
replacement service must point to an existing executable.

A reboot is complete only when Windows reports a different boot time; an SSH response from the old
session does not count. Boot-time and readiness queries have at most 20 seconds each, capped by the
remaining monotonic wait budget, including a small reserved drain/reap portion. A timed-out read-only
wrapper/SSH process group is signalled only within its known ownership; output drain and reaping are
bounded, and captured pipe ends are closed rather than waiting for an escaped holder. Authentication
evidence already received before or during timeout cleanup still stops the suite. The reboot request
is not retried, and installer, cancellation, uninstall and other mutating commands do not receive a
short execution timeout. Query diagnostics omit command arguments and scripts.

## Running

Needs a Linux host with libvirt, a Windows guest reachable over SSH with key authentication (OpenSSH
server, an administrator account, PowerShell), and `pytest`.

1. Prepare VM snapshots, shut off:
   - **healthy**: Windows with an older official virtio-win driver installer installed (we used 0.1.248).
   - **interrupted**: start from *healthy*, run a newer official installer (we used 0.1.271) and cancel it at
     `InstallFinalize` (`Machine.install_and_cancel_at`); reboot; snapshot. Some devices are now driverless.
2. Set the environment and run:

   ```bash
   export PR85_VM=win-test PR85_SSH=tester@192.168.122.10
   export PR85_SNAPSHOT_HEALTHY=official-248 PR85_SNAPSHOT_DAMAGED=interrupted-271
   export PR85_MSI=/path/to/virtio-win-gt-x64.msi      # the build under test
   export PR85_MSI_NEXT=/path/to/next-version.msi      # optional: same source, higher version
   cd test/acceptance && pytest -v
   ```

`PR85_SSH_WRAPPER` (optional) is put in front of every `ssh`/`scp` call, e.g. a script that supplies a
password or a pinned known_hosts file. The snapshots must not have a device-install restriction policy
configured; the failure test refuses to run otherwise.

Tests whose settings are missing are skipped. Each test reverts a snapshot, so the run takes minutes per test.
MSI verbose logs stay in the guest under `C:\virtio-win-acceptance`.

The first clear SSH/SCP authentication failure stops the entire suite, including readiness checks and
reboot waits. No further connection, policy restoration, uninstall or VM lifecycle call is made. The
current guest state is left for operator recovery rather than retrying credentials or changing access.
Non-authentication connection resets during an expected reboot remain retryable.

The VM is only ever shut down gracefully; if it hangs, the run stops and asks for a human instead of
forcing it off.

Additional [native/helper reference checks](../native/README.md) exercise real SCM/SetupAPI behavior
and portable journal contracts. They are separate from these black-box MSI delivery scenarios and do
not certify the complete owned-package uninstall rollback path or a clean seven-test invocation.
