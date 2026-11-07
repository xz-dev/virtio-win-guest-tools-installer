# Native transaction regressions (reference only)

These are additional checks, not a replacement for the [seven black-box MSI delivery scenarios](../acceptance/README.md). Run only against a disposable, authorized guest and preserve failures. Keep all test code and test DLLs outside the installer logic PR.

| Layer | Observable contract | What it does not establish |
|---|---|---|
| Black-box MSI suite | Upgrade, repair, failure/cancel, maintenance and uninstall preserve the promised devices, files and user services | Every possible interruption or original running share survives |
| Windows native helpers here | Real SCM configuration A → B → production inverse → A; real SetupAPI discovers services through Needs | Actual device-compatible-list capture or a complete owned-package MSI uninstall rollback |
| Portable header contracts | Dependency snapshot encoding, unknown retained hashes, write-ahead staging intent, torn-tail replay and safe journal retention | Windows SCM, driver-store I/O, exclusive package ownership or crash atomicity |

## Portable contracts

From the source checkout, with a C++14 compiler and assertions enabled:

```sh
g++ -std=c++14 -Wall -Wextra -Werror -UNDEBUG \
  -Isrc/DrvInst/DrvInstCA test/native/transaction_contract_test.cpp \
  -o /path/to/task/transaction_contract_test
/path/to/task/transaction_contract_test
```

This includes the actual `DriverTransaction.h`; it does not duplicate its implementation. The failure callbacks model the write/copy/compensation outcomes around the production staging helper. They do not perform a real disk-full or driver-store failure injection.

## Real Windows helper checks

Use the existing native project's build dependencies: Visual Studio Build Tools v143 (14.44.35207), Windows SDK 10.0.26100.0 and a WiX3 SDK folder containing `sdk`. The scripts use that project in a **fresh temporary source copy**, not a new build framework. The source and task directories must be different.

```powershell
& .\test\native\build-native-regressions.ps1 `
  -SourceRoot C:\path\to\candidate-checkout `
  -TaskRoot C:\path\to\fresh-task-build `
  -WixRoot C:\path\to\wix

& .\test\native\run-native-regressions.ps1 `
  -DllPath C:\path\to\fresh-task-build\out\Pr85NativeRegressions-x64.dll `
  -OutputRoot C:\path\to\task-results -Architecture x64
```

For x86, copy the runner and `Pr85NativeRegressions-x86.dll` to the x86 guest and use its normal elevated 32-bit PowerShell. On a 64-bit guest, an x86 DLL requires 32-bit PowerShell. No credential management is included.

The builder refuses source bytes other than CPP `a3c1f9fd7c8135f32dfe8d304a8a59e918d2280209c24aae28998ba470c9fc51` and header `0cb4fe3e8e13b5e8496aac56b806b2e7d2be28df5d7a808a995bee1d1b212696`. These pin the tested candidate; review the test seam before changing the pins for another revision.

The wrapper includes the unchanged production `DriverTransaction.cpp` and calls its private query, comparison, inverse and service-name collector. **Only `WcaLog` diagnostic calls are suppressed** because no MSI session exists in this helper test. SCM and SetupAPI are real, not mocked. Never copy these test DLLs into `Libraries`, embed them in an MSI or distribute them as the production custom action: they contain an additional test-only export.

The Windows test:

1. Creates unique `Pr85ReviewNative*` services that this invocation owns. It never starts them, installs a driver, edits ownership metadata or changes an existing system service.
2. Changes only those scratch services from captured configuration A to B; the real production inverse must restore A, including empty/nonempty and `+Base` dependency lists.
3. Parses unsigned test INF **parsing fixtures**, including Needs reaching the already-existing scratch service. It does not stage/install those INFs or alter trust/signing policy.
4. Parses the real system `mf.inf` Include/Needs path read-only. Finding `mf` does not claim that service already existed or was restored.
5. Refuses cycles, missing references and destructive directives, checks scratch configuration stayed unchanged, and deletes only services/files created by this invocation.

Each run writes a new GUID-named result directory. Count it as passed only if the exit value is zero, `native-results.tsv` contains no FAIL, and `remainingTestServices` is empty. Preserve the TSV, run/build receipts and logs on failure; inspect leftovers rather than blindly deleting prefixed services.

## Evidence boundaries

The parent lab recorded 30 real Windows helper checks passing on each architecture with no remaining scratch services. That validates those helper paths, not the complete MSI inverse. The first final MSI-suite invocation had an x64 reboot-wait timeout after two passes and an x86 reboot-wait timeout after six passes **before uninstall**. The two failed cases then passed with unchanged reboot logic and diagnostic tracing; those reruns did not establish the original cause. A later traced full run was interrupted after read-only SSH boot-time queries were observed hanging without a per-call timeout. Neither invocation is a clean suite pass. The reference helper now caps only read-only boot/readiness queries and uses monotonic remaining wait budgets; installer operations remain unbounded. A later full invocation must have its own immutable receipt.

The separately authored owned-package uninstall/late-cancel controller has not yet been accepted by this reference packaging step. No pass is claimed for it. Manual-demand service running-state/live-share preservation and simultaneous journal-write/compensation failure remain bounded by the documented recovery contract: intent is not proof of exclusive creation, and unresolved cleanup must retain its own recovery record rather than guess-delete a package.
