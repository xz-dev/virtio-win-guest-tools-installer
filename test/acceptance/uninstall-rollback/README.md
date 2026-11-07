# Owned-package feature-removal rollback check

This is one **additional delivery case**, separate from the seven pytest scenarios and the native-helper tests. It uses the existing `Machine` transport and a supported Windows Installer external-UI callback. The Python and C# files are the exact tested controller/helper; only this guide uses portable operator paths.

## What must be proved

1. From the recorded healthy official248 snapshot, install the exact frozen **0.1.350** candidate and reboot. Correlate the healthy BALLOON device's public DriverInfPath with one live `createdByThisCall=1` stage result in that installation's log. Pre-existing or ambiguous ownership means **NOT COVERED**; no ownership record is fabricated or edited.
2. Read SCM configuration. Refuse a non-kernel service or boot/system start0/1. Set only BALLOON start to Automatic2 through SCM, without manually starting it; retain both the original configuration and the customized delivery baseline.
3. Invoke that same installed MSI with `REMOVE=FE_balloon_driver REBOOT=ReallySuppress`. Do not edit any INF, catalog, driver binary or cached MSI.
4. Arm only on the exact owned component's formatted INFO message: `Driver uninstall: component=<owned component> knownCreatedPackage=1.` That message alone starts the operation; it does not prove completion.
5. Cancel with `IDCANCEL` only on the following matching PROGRESS increment whose integer fields are **1=2 and 2=200000**. Reset, explicit-mode and extend records are not completion. An ERROR, rollback start or different increment disarms this seam. Keep the ACTION/INFO/PROGRESS/ARM/DISARM/CANCEL trace.
6. Require MSI result1602 and all five path gates: owned removal attempt, completed-record progress, actual binding reinstall, custom-service inverse, and rollback action. Missing a gate is **NOT COVERED**, not a pass.
7. Reboot and compare public products/packages/bindings/file hashes/service observations plus independently read SCM configuration with the customized baseline. Restore the original start mode, uninstall/reboot the candidate, verify cleanup and shut down gracefully.

The source ordering gives the progress marker its meaning: `ForwardUninstall` returns before the deferred loop's completed-record `WcaProgressMessage(200000, FALSE)`. The retained WiX3 API encodes that increment as fields `(2,200000,0)` and accepts `IDCANCEL`. Runtime trace and inverse/delivery gates remain mandatory; source ordering alone is not a Windows pass.

## Run only after both complete suites finish

Supply the existing `PR85_VM`, `PR85_SSH`, `PR85_SSH_WRAPPER` and optional `PR85_LIBVIRT_URI`; keep credentials outside these files. Only the authorized domain/architecture pairs `win-test`/x64 and `win-test-x86`/x86 are accepted. Install pytest for the reused `Machine` module. No new transport or VM manager is included.

```sh
python3 test/acceptance/uninstall-rollback/run.py \
  --arch x64 \
  --acceptance-dir test/acceptance \
  --msi /path/to/artifacts/virtio-win-gt-x64-0.1.350.msi \
  --build-receipt /path/to/receipts/build-receipt.json \
  --prior-suite-receipt /path/to/receipts/completed-suites.json \
  --healthy-snapshot healthy-248-x64 \
  --output /path/to/fresh-results/x64-owned-rollback \
  --allow-guest-mutation
```

For x86, supply the x86 MSI/domain, `--arch x86`, its recorded healthy snapshot and a new output directory. The code intentionally targets the frozen350 candidate, not arbitrary installers.

The build receipt is a list of MSI entries containing `kind`, `arch`, `version`, `file` and `sha256`; the supplied MSI must exactly match its architecture/version/hash entry. The prior-suite receipt must contain `x64` and `x86`, each with successful `exit=0` and `end`; this architecture's `newMsi` path and `healthy` snapshot must match the arguments. Record these from actual completed runs. Do not fabricate successful receipts or overlap another VM owner. Missing opt-in or invalid prerequisites refuse execution before guest access.

Output directories must not exist. Exit0 means all path, delivery/configuration and cleanup gates passed; exit1 means an operation/comparison/cleanup failure; exit2 means refused prerequisites or **NOT COVERED**; exit3 means authentication stopped the run. Preserve `result.json`, raw install/cancellation logs and `actions.tsv`, including unsuccessful attempts. Authentication failure or unknown installer completion suppresses further guest operations; never start a second installer or force off a guest to guess recovery.

## Recorded evidence and limits

The parent recorded one final complete seven-case JUnit invocation on each architecture: **7 tests, 0 failures, 0 errors, 0 skipped**, using the corrected bounded read-only helper and the unchanged350/351 payloads. These results do not erase the earlier x64 two-pass/reboot-timeout and x86 six-pass/reboot-timeout failures (the latter occurred before uninstall), the diagnostic reruns, or the later interrupted traced invocation with a hung read-only SSH query.

Earlier owned-removal attempts cancelled on ActionStart while deferred actions were being scheduled. Their `{arch}-final` receipts remain **NOT COVERED**: observing `UninstallDriverPackages`/`InstallFinalize` was not enough to show actual package removal. They were not relabeled after changing the cancellation seam.

For the exact post-removal-progress controller here, the parent recorded **both architectures passing**: result1602; all five path gates true; customized start2 restored to2; cleanup0; no pending operation. This packaging step does not itself rerun Windows. The test proves the observed owned BALLOON feature-removal inverse, not every service, driver, user-mode demand service's prior running state, live share, power-loss failure or general cancellation/restart recovery.
