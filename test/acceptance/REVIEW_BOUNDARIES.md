# PR85 conflicting-registration boundaries

Source: `d3ae29e36472e41157f886734f8416349547fbb0`, following `bf4c24a`. These reference checks are separate from the logic PR. The existing seven delivery scenarios and native/service-inverse reference files are preserved unchanged from `be9c4da`.

## Behavior being checked

- Two Windows client component searches succeed: a new install/upgrade, Repair, Modify or partial feature removal is refused. An already-installed product can use an **explicit CLI full uninstall** (`msiexec /x {its-ProductCode}` / early `REMOVE=ALL`). There is no promise that an early maintenance dialog can reach GUI Remove.
- Both `VirtIO-FS Service` and `VirtioFsSvc` are detected: **every operation, including full uninstall, is refused before changes**. Resolve the conflict through its confirmed owner, not by guessing which service to delete. This service guard takes precedence over the client full-uninstall exception.
- The old component GUIDs, paths and service control/Wait behavior remain unchanged for normal single-name paths.

This is not persistent service-ownership tracking or automatic migration. If an administrator removes/replaces a service and only the other name remains, this change does not establish its ownership. Existing ImagePath searches do not interpret every damaged SCM state, and they do not lock out concurrent administrator changes. Cached older MSIs, including `.350`, retain their original behavior.

## Portable source contracts

```sh
PR85_SOURCE_ROOT=/path/to/candidate \
  PYTEST_DISABLE_PLUGIN_AUTOLOAD=1 \
  uv run --no-project --with pytest python -m pytest -q -p no:cacheprovider \
  test/acceptance/test_review_authoring_contract.py
```

The 55 assertions bind precise XML to finite policy tables. They do **not** implement an MSI expression parser or prove real installation recovery.

## Real Windows Installer engine and compiled tables

On a disposable Windows machine, use the candidate and same-architecture `.350` baseline:

```powershell
powershell -NoProfile -File test\acceptance\guest\check-msi-guards.ps1 `
  -MsiPath C:\lab\virtio-win-gt-x64-0.1.352.msi `
  -BaselineMsiPath C:\lab\virtio-win-gt-x64-0.1.350.msi `
  -OutputPath C:\lab\guard-x64-352.json
```

Use a fresh output path. Repeat for `.353` and x86. The script reads MSI databases without modifying them and evaluates the **compiled conditions with Windows Installer APIs** in an ignore-machine-state session. It never executes installation actions or creates ownership records.

It compares component/directory/file-name/service/sequence tables with the baseline, then checks presence/absence of both searches, installed/uninstalled state, full/partial removal, case-insensitive `all`, Repair and Modify. It also verifies that AppSearch and LaunchConditions are not skipped during maintenance and precede mutation. x86 has no Win11 client guard; that absence is reported, not counted as client-conflict coverage.

Observed for **each** `.352` and `.353` package:

| Package | Client rows | Actual MSI-engine cases | Total table/engine checks |
|---|---:|---:|---:|
| x64 | 13 | 1,344 | 1,490 |
| x86 | 0 | 96 | 216 |

All four packages passed. Separately, a read-only extraction of `Binary.DrvInstallDll` from every package matched the existing source-built production DLL. No test export or helper DLL was packaged.

## Focused real installation checks

The `.352` packages also underwent actual MSI operations. Files, devices/bindings/packages and user-mode services were observed with the existing acceptance observer; explicit refusal had to leave that public state unchanged and logs had to stop before InstallInitialize/StopServices/DeleteServices/driver mutation.

### Genuine legacy-name path, x64

1. Restore the actual `.215` installation with its original `VirtIO-FS Service`. Do not manufacture this MSI ownership or substitute a manually added service for the canonical installation.
2. Only if `VirtioFsSvc` is absent, create it as a separate, explicitly test-owned, stopped SCM fixture. Record successful creation and its exact name/display name/path/start/state. It is not claimed as MSI-owned or a functioning foreign product.
3. Attempt `.352` upgrade. Expect 1603 at LaunchConditions, with original delivery and the separate service configuration unchanged.
4. Remove **only** that known test-created fixture after checking its identity. Upgrade and Repair the genuine single-name installation; verify the legacy name and normal delivery remain.
5. Add the separately owned fixture again. Both Repair and `/x` must refuse before mutation. Verify both services' configuration and delivered state remain unchanged, then clean up only the fixture this test created.
6. In a normal single-service state, supply both client **search property values only in the MSI session**. Repair must refuse unchanged. Explicit `/x` of the actual installed ProductCode must complete successfully. This tests the real command entry/timing, **not genuine dual-GUID registrations**; no MSI registry ownership was fabricated.

The final x64 invocation passed all seven checks. Upgrade and full removal returned 0; normal Repair returned 1641 with an actually observed new Windows boot time; refusals returned 1603.

### Current-name path, x86

Using the normal healthy older installation, `.352` upgrade retained `VirtioFsSvc`. Normal Repair completed. A separately test-created, stopped legacy-name fixture then caused both Repair and `/x` to refuse before mutation, without changing public delivery or either service configuration. After identity-checked cleanup of only that fixture, normal full removal returned 0 and no delivered user services remained.

The final x86 invocation passed five checks. It does not claim Win11 client-guard coverage.

## Restart, failure and evidence limits

- Normal Repair on **both architectures** returned 1641: the preexisting `CA_ScheduleReboot` changed `REBOOT=ReallySuppress` to `Force`. The observer confirmed an actual changed boot time. This authoring change did not fix or introduce that scheduling policy; do not rely on ReallySuppress to prevent a lab restart.
- The first x64 controller rejected 1641 and its graceful-shutdown request raced the automatic reboot. Logs and a shutoff evidence snapshot were retained. The final invocation explicitly observed automatic restart before continuing. It is distinct from the initial failed invocation, not a relabeled pass.
- An earlier fixture-selection precondition failure and initial missing task-local SDK/preparation failure are retained as harness/setup failures, not installer failures or passes.
- `.353` received compiled-table/engine and embedded-DLL checks; it did **not** receive another full installation lifecycle run. Earlier `.350/.351` seven-per-architecture results remain results for those exact packages, not new `.352/.353` passes.
- No real dual-client-registration fixture, GUI ambiguous-state recovery, running foreign service, persistent service identity, crash/power-loss atomicity or universal cleanup is certified.
- Both guests were restored to their original snapshot and shutoff state; inactive domain XML matched the saved originals. No forced power-off, cached-MSI edit, guessed ownership, root/publisher import or signing-policy weakening was used.

The test packages/custom-action DLLs are unsigned laboratory artifacts. Signed Git commits/tags do not imply Authenticode signing. Native code and the production DLL inputs are unchanged in this follow-up; x64 packaging retains the existing short-name warnings.
