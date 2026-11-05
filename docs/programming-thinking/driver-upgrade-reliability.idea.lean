-- Finite process specification only: no MSI engine, DLL, registry, device, or reboot effects execute here.
import Std

set_option autoImplicit false

namespace DriverUpgradeReliability

-- Inputs describe one component's selected ownership and externally established inverse capabilities, not facts proved about Windows.
inductive RemovalSchedule
  | early
  | afterInstallExecute
  deriving DecidableEq, Repr

inductive FailureBoundary
  | none
  | earlyCancellation
  | afterNewScript
  | afterOldRemoval
  | nativeDriverError
  deriving DecidableEq, Repr

inductive UpgradeStage
  | admitted
  | newScriptExecuted
  | oldRemovalExecuted
  | committed
  | rolledBack
  | rejected
  | rollbackUnavailable
  | hiddenFailureCommitted
  deriving DecidableEq, Repr

structure UpgradeInput where
  schedule : RemovalSchedule
  compatibleComponents : Bool
  successorRequestsComponent : Bool
  baselineLegacyMetadata : Bool
  rollbackEnabled : Bool
  rollbackGuard : Bool
  newEffectsHaveInverse : Bool
  legacyRemovalHasInverse : Bool
  checksNativeErrors : Bool
  failure : FailureBoundary
  deriving DecidableEq, Repr

-- Product/component ownership is MSI-managed; legacy persistence and new native effects are separate observable state.
structure ProcessState where
  stage : UpgradeStage
  oldProductPresent : Bool
  newProductPresent : Bool
  oldComponentOwner : Bool
  newComponentOwner : Bool
  legacyMetadata : Bool
  newExternalEffects : Bool
  nativeError : Bool
  failureReported : Bool
  deriving DecidableEq, Repr

-- Baseline can already lack legacy metadata. Successful rollback must preserve that baseline, not invent a repair.
def initialState (input : UpgradeInput) : ProcessState :=
  { stage := .admitted
    oldProductPresent := true
    newProductPresent := false
    oldComponentOwner := true
    newComponentOwner := false
    legacyMetadata := input.baselineLegacyMetadata
    newExternalEffects := false
    nativeError := false
    failureReported := false }

-- Compatible identity alone is insufficient: successor must request ownership before predecessor release.
def retainedCompatibleComponent (input : UpgradeInput) : Bool :=
  input.compatibleComponents && input.successorRequestsComponent

def sharedOwnershipHandoff (input : UpgradeInput) : Bool :=
  input.schedule == .afterInstallExecute && retainedCompatibleComponent input

-- InstallExecute applies new work without commit; an existing error prevents subsequent new work in this model.
def installNewProduct (input : UpgradeInput) (state : ProcessState) : ProcessState :=
  if state.nativeError then state else
  { state with
    stage := .newScriptExecuted
    newProductPresent := true
    newComponentOwner := retainedCompatibleComponent input
    newExternalEffects := true }

-- Shared ownership avoids legacy cleanup; real last-owner removal consumes persistence and can fail when it was already absent.
def removeOldProduct (state : ProcessState) : ProcessState :=
  if state.newComponentOwner then
    { state with stage := .oldRemovalExecuted
                 oldProductPresent := false
                 oldComponentOwner := false }
  else if state.legacyMetadata then
    { state with stage := .oldRemovalExecuted
                 oldProductPresent := false
                 oldComponentOwner := false
                 legacyMetadata := false }
  else
    { state with stage := .oldRemovalExecuted, nativeError := true }

-- Early scheduling releases old ownership first; late scheduling exposes a new-script/before-old-removal failure boundary.
def afterNewScript (input : UpgradeInput) : ProcessState :=
  match input.schedule with
  | .afterInstallExecute => installNewProduct input (initialState input)
  | .early => installNewProduct input (removeOldProduct (initialState input))

def afterOldRemoval (input : UpgradeInput) : ProcessState :=
  match input.schedule with
  | .afterInstallExecute => removeOldProduct (afterNewScript input)
  | .early => afterNewScript input

-- MSI rollback restores managed ownership; external restoration is conditional on enabled rollback and actual inverses.
def rollback (input : UpgradeInput) (state : ProcessState) : ProcessState :=
  if input.rollbackEnabled then
    { state with
      stage := .rolledBack
      oldProductPresent := true
      newProductPresent := false
      oldComponentOwner := true
      newComponentOwner := false
      legacyMetadata := if input.legacyRemovalHasInverse then
                          input.baselineLegacyMetadata else state.legacyMetadata
      newExternalEffects := state.newExternalEffects && !input.newEffectsHaveInverse
      failureReported := true }
  else
    { state with stage := .rollbackUnavailable, failureReported := true }

-- Checked native errors fail the transaction; ignoring them can hide failure rather than repairing it.
def reportNativeFailure (input : UpgradeInput) (state : ProcessState) : ProcessState :=
  if input.checksNativeErrors then rollback input state
  else { state with stage := .hiddenFailureCommitted }

def finalize (input : UpgradeInput) (state : ProcessState) : ProcessState :=
  if state.nativeError then reportNativeFailure input state
  else { state with stage := .committed }

-- Intended rollback-disabled admission guard precedes mutation. Cancellation and native faults exercise distinct boundaries.
def runUpgrade (input : UpgradeInput) : ProcessState :=
  if input.rollbackGuard && !input.rollbackEnabled then
    { (initialState input) with stage := .rejected, failureReported := true }
  else
    match input.failure with
    | .earlyCancellation => rollback input (initialState input)
    | .afterNewScript => rollback input (afterNewScript input)
    | .afterOldRemoval => rollback input (afterOldRemoval input)
    | .nativeDriverError => reportNativeFailure input
        { (afterNewScript input) with nativeError := true }
    | .none => finalize input (afterOldRemoval input)

-- Restored registration is not sufficient: external baseline equality and absence of new residual effects are required.
def RestoredBaseline (input : UpgradeInput) (state : ProcessState) : Prop :=
  state.oldProductPresent = true ∧ state.newProductPresent = false ∧
  state.oldComponentOwner = true ∧ state.newComponentOwner = false ∧
  state.legacyMetadata = input.baselineLegacyMetadata ∧
  state.newExternalEffects = false ∧ state.failureReported = true

def AllowedOutcome (input : UpgradeInput) (state : ProcessState) : Prop :=
  (state.stage = .committed ∧ state.oldProductPresent = false ∧
    state.newProductPresent = true ∧ state.nativeError = false) ∨
  ((state.stage = .rolledBack ∨ state.stage = .rejected) ∧ RestoredBaseline input state)

-- These are ideal inverse assumptions to be discharged by real artifacts and rollback/reboot experiments, not declarations about existing DLLs.
def InverseRequirements (input : UpgradeInput) : Prop :=
  input.newEffectsHaveInverse = true ∧
  (sharedOwnershipHandoff input = true ∨ input.legacyRemovalHasInverse = true)

-- Ownership handoff preserves even damaged preexisting metadata because the old removal is a no-op for this component.
theorem shared_handoff_avoids_legacy_cleanup (input : UpgradeInput)
    (hShared : sharedOwnershipHandoff input = true) :
    (afterOldRemoval input).legacyMetadata = input.baselineLegacyMetadata ∧
    (afterOldRemoval input).nativeError = false ∧
    (afterOldRemoval input).newComponentOwner = true := by
  cases hSchedule : input.schedule <;>
    simp_all [sharedOwnershipHandoff, afterOldRemoval, afterNewScript,
      installNewProduct, removeOldProduct, initialState]

-- Only stated inverse capabilities plus enabled rollback justify full restoration in this finite state abstraction.
theorem inverse_restores_external_and_managed_state (input : UpgradeInput)
    (state : ProcessState) (hEnabled : input.rollbackEnabled = true)
    (hNew : input.newEffectsHaveInverse = true)
    (hLegacy : input.legacyRemovalHasInverse = true) :
    RestoredBaseline input (rollback input state) := by
  simp [RestoredBaseline, rollback, hEnabled, hNew, hLegacy]

-- The intended guard rejects before mutation whenever required rollback cannot run.
theorem rollback_disabled_is_rejected_before_mutation (input : UpgradeInput)
    (hGuard : input.rollbackGuard = true) (hDisabled : input.rollbackEnabled = false) :
    (runUpgrade input).stage = .rejected ∧
    RestoredBaseline input (runUpgrade input) := by
  simp [runUpgrade, hGuard, hDisabled, RestoredBaseline, initialState]

-- Counterexamples separate product rollback from external recovery, including unselected legacy components and missing modern inverses.
def legacyPartialRollback : UpgradeInput :=
  { schedule := .early
    compatibleComponents := true
    successorRequestsComponent := true
    baselineLegacyMetadata := true
    rollbackEnabled := true
    rollbackGuard := true
    newEffectsHaveInverse := true
    legacyRemovalHasInverse := false
    checksNativeErrors := true
    failure := .afterOldRemoval }

theorem legacy_partial_rollback_counterexample :
    (runUpgrade legacyPartialRollback).stage = .rolledBack ∧
    (runUpgrade legacyPartialRollback).oldProductPresent = true ∧
    (runUpgrade legacyPartialRollback).legacyMetadata = false ∧
    ¬ RestoredBaseline legacyPartialRollback (runUpgrade legacyPartialRollback) := by
  simp only [RestoredBaseline]
  decide

theorem unselected_legacy_component_still_needs_inverse :
    let input := { legacyPartialRollback with
      schedule := .afterInstallExecute, successorRequestsComponent := false }
    (runUpgrade input).stage = .rolledBack ∧
    ¬ RestoredBaseline input (runUpgrade input) := by
  simp only [RestoredBaseline]
  decide

theorem missing_new_inverse_is_not_safe :
    let input := { legacyPartialRollback with
      schedule := .afterInstallExecute, newEffectsHaveInverse := false }
    (runUpgrade input).oldProductPresent = true ∧
    (runUpgrade input).newExternalEffects = true ∧
    ¬ RestoredBaseline input (runUpgrade input) := by
  simp only [RestoredBaseline]
  decide

theorem rollback_disabled_without_guard_is_not_atomic :
    let input := { legacyPartialRollback with
      rollbackEnabled := false, rollbackGuard := false }
    (runUpgrade input).stage = .rollbackUnavailable ∧
    ¬ RestoredBaseline input (runUpgrade input) := by
  simp only [RestoredBaseline]
  decide

theorem ignoring_native_errors_can_hide_failure :
    let input := { legacyPartialRollback with
      failure := .nativeDriverError, checksNativeErrors := false }
    (runUpgrade input).stage = .hiddenFailureCommitted ∧
    (runUpgrade input).failureReported = false := by
  decide

-- All modeled outcomes satisfy the contract only under guard, checked-return, and conditional inverse assumptions. Real timing, bindings, Driver Store and reboot correctness remain empirical obligations.
theorem process_is_correct (input : UpgradeInput)
    (hGuard : input.rollbackGuard = true)
    (hCheck : input.checksNativeErrors = true)
    (hInverses : InverseRequirements input) :
    AllowedOutcome input (runUpgrade input) := by
  rcases hInverses with ⟨hNew, hOld⟩
  cases hEnabled : input.rollbackEnabled
  · simp [AllowedOutcome, (rollback_disabled_is_rejected_before_mutation
      input hGuard hEnabled).1, (rollback_disabled_is_rejected_before_mutation
      input hGuard hEnabled).2]
  · rcases hOld with hShared | hLegacy
    · cases hSchedule : input.schedule <;>
        cases hFailure : input.failure <;>
        simp_all [sharedOwnershipHandoff, AllowedOutcome, RestoredBaseline,
          runUpgrade, afterOldRemoval, afterNewScript, installNewProduct,
          removeOldProduct, initialState, rollback, reportNativeFailure, finalize]
    · cases hSchedule : input.schedule <;>
        cases hFailure : input.failure <;>
        cases hMetadata : input.baselineLegacyMetadata <;>
        cases hRetained : retainedCompatibleComponent input <;>
        simp [AllowedOutcome, RestoredBaseline, runUpgrade, afterOldRemoval,
          afterNewScript, installNewProduct, removeOldProduct, initialState,
          rollback, reportNativeFailure, finalize, hGuard, hCheck, hEnabled,
          hNew, hLegacy, hSchedule, hFailure, hMetadata, hRetained]

-- Previous authoring-only candidate changes scheduling and admission; it does not credit a legacy inverse.
def sourceCandidateInput (input : UpgradeInput) : UpgradeInput :=
  { input with
    schedule := .afterInstallExecute
    rollbackGuard := true
    checksNativeErrors := true
    legacyRemovalHasInverse := false }

-- Selected compatible retention is safe in this model only with a real modern inverse; actual legacy removal remains a counterexample, not silently unsupported behavior.
theorem candidate_retained_component_contract (input : UpgradeInput)
    (hCompatible : input.compatibleComponents = true)
    (hSelected : input.successorRequestsComponent = true)
    (hNewInverse : input.newEffectsHaveInverse = true) :
    AllowedOutcome (sourceCandidateInput input) (runUpgrade (sourceCandidateInput input)) := by
  apply process_is_correct
  · rfl
  · rfl
  · exact ⟨hNewInverse, Or.inl (by
      simp [sharedOwnershipHandoff, retainedCompatibleComponent, sourceCandidateInput,
        hCompatible, hSelected])⟩

theorem candidate_actual_legacy_removal_is_still_not_atomic :
    let input := sourceCandidateInput
      { legacyPartialRollback with successorRequestsComponent := false }
    (runUpgrade input).stage = .rolledBack ∧
    ¬ RestoredBaseline input (runUpgrade input) := by
  simp only [RestoredBaseline]
  decide

-- Read-only MSI ownership admission covers DIFx and historical native predecessors; private persistence is absent from its inputs.
structure LegacyOwnership where
  installed : Bool
  permanent : Bool
  retainedMachineOwner : Bool
  successorRequestsSameIdentity : Bool
  deriving DecidableEq, Repr

def legacyTransitionAdmitted (ownership : LegacyOwnership) : Bool :=
  !ownership.installed || ownership.permanent || ownership.retainedMachineOwner ||
    ownership.successorRequestsSameIdentity

def runWithLegacyAdmission (ownership : LegacyOwnership) (input : UpgradeInput) : ProcessState :=
  if legacyTransitionAdmitted ownership then runUpgrade (sourceCandidateInput input)
  else { (initialState input) with stage := .rejected, failureReported := true }

-- Refusal preserves baseline, while actual selected ownership admits even a damaged legacy baseline.
theorem unsafe_last_owner_is_rejected_before_mutation (input : UpgradeInput) :
    let ownership : LegacyOwnership := ⟨true, false, false, false⟩
    (runWithLegacyAdmission ownership input).stage = .rejected ∧
    RestoredBaseline input (runWithLegacyAdmission ownership input) := by
  simp [runWithLegacyAdmission, legacyTransitionAdmitted, initialState, RestoredBaseline]

theorem selected_shared_handoff_is_admitted_even_with_missing_metadata
    (input : UpgradeInput) (hMissing : input.baselineLegacyMetadata = false) :
    let ownership : LegacyOwnership := ⟨true, false, false, true⟩
    runWithLegacyAdmission ownership input = runUpgrade (sourceCandidateInput input) ∧
    input.baselineLegacyMetadata = false := by
  simp [runWithLegacyAdmission, legacyTransitionAdmitted, hMissing]

-- Native effects are distinct obligations: package deletion cannot invert a changed binding or claim ownership of hardware.
inductive NativeEffect
  | preexistingPackage
  | transactionCreatedPackage
  | changedBinding
  | preexistingHardwareInstance
  deriving DecidableEq, Repr

def packageCleanupRequiresCreatedDelta (effect : NativeEffect) : Bool :=
  effect == .transactionCreatedPackage

-- Historical partial patch lacked a created-resource delta; preserve that counterexample independently of current typed records.
def partialSourceHasCreatedPackageDelta : Bool := false

theorem package_cleanup_is_not_a_general_inverse :
    packageCleanupRequiresCreatedDelta .preexistingPackage = false ∧
    packageCleanupRequiresCreatedDelta .changedBinding = false ∧
    packageCleanupRequiresCreatedDelta .preexistingHardwareInstance = false ∧
    partialSourceHasCreatedPackageDelta = false := by decide

-- INF/catalog hashes are immutable package identity; OEM aliases and Store paths are hints, including in typed metadata and recorded bindings. Old metadata without hashes supplies no creator authority.
-- Forward flags0 delegates ranking to Windows: unchanged better bindings are valid, while intents cover all potentially affected present hardware/compatible-ID matches before the package-wide call. Exact prior selection is inverse-only; identities and typed metadata are captured values, not registry reconstruction.
-- Observed N27/C1 (Win11 26100.1742): an already-imported, already-bound package returns FALSE with ERROR_NO_MORE_ITEMS ("No devices were updated"). That status is staged-only success; post-call store identity and binding checks still decide.
inductive PackageWideStatus
  | installed
  | noDeviceUpdated
  | otherError
  deriving DecidableEq, Repr

def packageWideAccepted : PackageWideStatus → Bool
  | .installed => true
  | .noDeviceUpdated => true
  | .otherError => false

theorem no_device_updated_is_not_a_failure_but_other_errors_are :
    packageWideAccepted .noDeviceUpdated = true ∧ packageWideAccepted .otherError = false := by decide

-- Observed N27/E2: binding a parent revives a non-present child devnode that then uses the created package.
-- Scope adds only non-present children of present in-scope parents (unrelated phantoms are never read), captured
-- parent-first; a parent cycle refuses before mutation. The inverse replays in reverse, so the child is restored
-- while its parent still exposes it, and only then can the created package be removed. Ancestry across
-- non-matching present intermediates is not ordered (bounded limit).
-- Observed N30/E6: on a NULL-driver prior, the package-wide install's AddService rewrote existing services'
-- ImagePath into the created package; the binding inverse cannot undo that. Existing services named by the
-- INF's AddService lines are captured via SCM and restored with ChangeServiceConfig (verified re-query)
-- after bindings and before created-package removal. Newly created services are not deleted (limit).
-- N32: also LoadOrderGroup; captured services are re-verified unchanged just before the package-wide call
-- (refuse otherwise), and the inverse writes them only if that call was attempted (bind intents journaled).
-- Services reached only through Include/Needs (e.g. inbox mf for qemupciserial) are not captured (limit).
-- N34 (observed x86 damaged history): a non-present child naming a deleted package (oem8.---) has no package
-- to select or restore; it is captured, checked and inverted as NULL-driver. Present nodes and other errors
-- still fail closed. Effect on rollback after revival: the child ends NULL-driver, not the dangling name.
-- N35 (N34 review): only a not-found from the published-name -> store-location lookup qualifies; any error
-- while reading a resolved store INF or its catalog fails closed.
def inverseOrder (captured : List Nat) : List Nat := captured.reverse

theorem child_restored_before_parent :
    inverseOrder [0, 1] = [1, 0] := by decide
inductive DriverOperation
  | install
  | uninstall
  deriving DecidableEq, Repr

structure DriverBaseline where
  packagePresent : Bool
  bindingIdentityAndSection : Nat
  typedModuleMetadata : Nat
  hardwareInstances : List Nat
  deriving DecidableEq, Repr

structure DriverUndo where
  operation : DriverOperation
  before : DriverBaseline
  snapshotComplete : Bool
  stageResultRecorded : Bool
  packageCreatedByThisCall : Bool
  bindingAttempted : Bool
  metadataAttempted : Bool
  removalAttempted : Bool
  knownComponentCreator : Bool
  soleMachineOwner : Bool
  retainedTypedPackageClient : Bool
  deriving DecidableEq, Repr

structure DriverObservation where
  packagePresent : Bool
  bindingIdentityAndSection : Nat
  typedModuleMetadata : Nat
  hardwareInstances : List Nat
  journalPresent : Bool
  failureReported : Bool
  deriving DecidableEq, Repr

-- These are empirical API/effect prerequisites, not Windows facts proved here. Ordinary MSI failures exclude crash/power loss because WiX flush is best effort.
structure DriverApiEvidence where
  ordinaryExecutionWithoutPowerLoss : Bool
  exactPriorBindingRestored : Bool
  typedMetadataRestored : Bool
  newlyCreatedPackageRemoved : Bool
  signedSourceRestoredBeforeInverse : Bool
  ownedPackageRestagedAndVerified : Bool
  deriving DecidableEq, Repr

-- Cleanup needs this call's recorded staging delta; owned removal additionally needs creator evidence, sole ownership and a non-nested transaction.
def newPackageCleanupPermitted (undo : DriverUndo) : Bool :=
  undo.operation == .install && undo.stageResultRecorded && undo.packageCreatedByThisCall

def forwardOwnedRemovalPermitted (undo : DriverUndo) (nested : Bool) : Bool :=
  undo.operation == .uninstall && undo.knownComponentCreator && undo.soleMachineOwner &&
    !undo.retainedTypedPackageClient && !nested

-- An owned uninstall inverse additionally requires MSI-restored complete signed INF-referenced payload (including required support files) and verified restaging; failed evidence cannot certify restoration.
def inverseRequirementsObserved (undo : DriverUndo) (evidence : DriverApiEvidence) : Bool :=
  undo.snapshotComplete && evidence.ordinaryExecutionWithoutPowerLoss &&
  (!undo.bindingAttempted || evidence.exactPriorBindingRestored) &&
  (!undo.metadataAttempted || evidence.typedMetadataRestored) &&
  (!newPackageCleanupPermitted undo || evidence.newlyCreatedPackageRemoved) &&
  (!undo.removalAttempted || (evidence.signedSourceRestoredBeforeInverse &&
    evidence.ownedPackageRestagedAndVerified && evidence.exactPriorBindingRestored &&
    evidence.typedMetadataRestored))

-- Inverse changes only attempted fields/resources and never rewrites hardware instances; failed inverse retains its own journal and reports failure.
def replayDriverInverse (undo : DriverUndo) (evidence : DriverApiEvidence)
    (observed : DriverObservation) : DriverObservation :=
  if inverseRequirementsObserved undo evidence then
    { packagePresent := if newPackageCleanupPermitted undo then false else
          if undo.removalAttempted then true else observed.packagePresent
      bindingIdentityAndSection := if undo.bindingAttempted || undo.removalAttempted then
          undo.before.bindingIdentityAndSection else observed.bindingIdentityAndSection
      typedModuleMetadata := if undo.metadataAttempted || undo.removalAttempted then
          undo.before.typedModuleMetadata else observed.typedModuleMetadata
      hardwareInstances := observed.hardwareInstances
      journalPresent := false
      failureReported := true }
  else { observed with failureReported := true, journalPresent := true }

def DriverBaselineRestored (before : DriverBaseline) (after : DriverObservation) : Prop :=
  after.packagePresent = before.packagePresent ∧
  after.bindingIdentityAndSection = before.bindingIdentityAndSection ∧
  after.typedModuleMetadata = before.typedModuleMetadata ∧
  after.hardwareInstances = before.hardwareInstances

-- Created/removed deltas must match baseline, including verification/restaging of a preexisting target after forward internal preinstallation. This observation is after that prerequisite; untouched fields and hardware preservation remain explicit frame hypotheses.
def DriverInverseFrame (undo : DriverUndo) (observed : DriverObservation) : Prop :=
  (newPackageCleanupPermitted undo = true → undo.before.packagePresent = false) ∧
  (undo.removalAttempted = true → undo.before.packagePresent = true) ∧
  (newPackageCleanupPermitted undo = false → undo.removalAttempted = false →
    observed.packagePresent = undo.before.packagePresent) ∧
  (undo.bindingAttempted = false → undo.removalAttempted = false →
    observed.bindingIdentityAndSection = undo.before.bindingIdentityAndSection) ∧
  (undo.metadataAttempted = false → undo.removalAttempted = false →
    observed.typedModuleMetadata = undo.before.typedModuleMetadata)

-- This combined restoration contract is conditional on actual API success and frame/hardware hypotheses; it does not establish Windows behavior from source tokens.
theorem typed_driver_inverse_contract (undo : DriverUndo) (evidence : DriverApiEvidence)
    (observed : DriverObservation)
    (hNative : inverseRequirementsObserved undo evidence = true)
    (hFrame : DriverInverseFrame undo observed)
    (hHardware : observed.hardwareInstances = undo.before.hardwareInstances) :
    DriverBaselineRestored undo.before (replayDriverInverse undo evidence observed) ∧
    (replayDriverInverse undo evidence observed).failureReported = true := by
  rcases hFrame with ⟨hCreated, hRemoved, hPackage, hBinding, hMetadata⟩
  cases hCleanup : newPackageCleanupPermitted undo <;>
    cases hRemove : undo.removalAttempted <;>
    cases hBind : undo.bindingAttempted <;>
    cases hMeta : undo.metadataAttempted <;>
    simp_all [replayDriverInverse, DriverBaselineRestored]

-- Error reporting and retention are independent of successful restoration; preexisting packages never qualify for created-resource cleanup.
theorem inverse_error_retains_own_record (undo : DriverUndo) (evidence : DriverApiEvidence)
    (observed : DriverObservation) (hFailed : inverseRequirementsObserved undo evidence = false) :
    (replayDriverInverse undo evidence observed).journalPresent = true ∧
    (replayDriverInverse undo evidence observed).failureReported = true := by
  simp [replayDriverInverse, hFailed]

theorem preexisting_package_has_no_cleanup (undo : DriverUndo)
    (hExisting : undo.packageCreatedByThisCall = false) :
    newPackageCleanupPermitted undo = false := by
  simp [newPackageCleanupPermitted, hExisting]

theorem nested_owned_removal_is_rejected (undo : DriverUndo) :
    forwardOwnedRemovalPermitted undo true = false := by
  simp [forwardOwnedRemovalPermitted]

-- Other installed typed references prevent removal even with a sole MSI client. Retained-candidate access/I/O/type/data read failures cannot authorize removal; only intentionally missing hashes remain UNKNOWN, with no inferred creator rights.
theorem shared_typed_package_client_prevents_removal (undo : DriverUndo) (nested : Bool)
    (hShared : undo.retainedTypedPackageClient = true) :
    forwardOwnedRemovalPermitted undo nested = false := by
  simp [forwardOwnedRemovalPermitted, hShared]

-- ProductCode is available to deferred/rollback and ordinary immediate actions, not commit actions. Nested native work is refused, and only top-level finalize or completed inverse permits own-script cleanup.
inductive DriverCleanupBoundary
  | activeTransaction
  | nestedProductFinalize
  | topLevelFinalize
  | successfulInverse
  | failedInverse
  deriving DecidableEq, Repr

def keepOwnDriverJournal (boundary : DriverCleanupBoundary) : Bool :=
  match boundary with
  | .topLevelFinalize | .successfulInverse => false
  | _ => true

theorem nested_finalize_does_not_discard_inverse :
    keepOwnDriverJournal .nestedProductFinalize = true ∧
    keepOwnDriverJournal .failedInverse = true := by decide

-- Rollback replays complete framed records from the readable whole-WCHAR prefix even after a later corrupt/read tail; the group still fails and retains its journal. Forward loading stays strict; this per-record contract does not prove Windows I/O or crash durability.
-- An empty valid header means no effects started, while missing/malformed state cannot certify no work.
inductive DriverJournalStart
  | begunEmpty
  | completeSnapshot
  | missingUnexpected
  | malformed
  deriving DecidableEq, Repr

def journalCertifiesNoWork (start : DriverJournalStart) : Bool := start == .begunEmpty

theorem missing_journal_is_not_no_work :
    journalCertifiesNoWork .missingUnexpected = false ∧
    journalCertifiesNoWork .malformed = false := by decide

-- Actual-section strings are external API evidence, not a model of Windows section resolution. A missing candidate or mismatched resolved decoration cannot authorize exact prior selection.
def exactActualSectionCandidate (expected : String) (actual : Option String) : Bool :=
  match actual with
  | some actualName => !actualName.isEmpty && actualName == expected
  | none => false

-- The N16 observed raw Models name differs from the captured section; only the externally resolved actual name matches. This finite comparison claim does not establish installation or inverse success.
theorem actual_section_comparison_contract :
    exactActualSectionCandidate "BALLOON_Device.NT" (some "BALLOON_Device") = false ∧
    exactActualSectionCandidate "BALLOON_Device.NT" (some "BALLOON_Device.NT") = true ∧
    exactActualSectionCandidate "BALLOON_Device.NT" none = false ∧
    exactActualSectionCandidate "BALLOON_Device.NT" (some "BALLOON_Device.NTarm64") = false := by
  decide

-- Inspect kernel foundations of the conditional contract and representative counterexample; no task-specific axioms are admitted.
#print axioms actual_section_comparison_contract
#print axioms shared_typed_package_client_prevents_removal
#print axioms missing_journal_is_not_no_work
#print axioms typed_driver_inverse_contract
#print axioms inverse_error_retains_own_record
#print axioms preexisting_package_has_no_cleanup
#print axioms nested_owned_removal_is_rejected
#print axioms nested_finalize_does_not_discard_inverse
#print axioms unsafe_last_owner_is_rejected_before_mutation
#print axioms package_cleanup_is_not_a_general_inverse
#print axioms process_is_correct
#print axioms candidate_retained_component_contract
#print axioms candidate_actual_legacy_removal_is_still_not_atomic
#print axioms legacy_partial_rollback_counterexample
#print axioms shared_handoff_avoids_legacy_cleanup

end DriverUpgradeReliability

-- Deterministic examples contrast destructive early rollback with retained/shared handoff; neither executes Windows.
def main : IO Unit := do
  let damaged := DriverUpgradeReliability.runUpgrade
    DriverUpgradeReliability.legacyPartialRollback
  let retained := DriverUpgradeReliability.runUpgrade
    (DriverUpgradeReliability.sourceCandidateInput DriverUpgradeReliability.legacyPartialRollback)
  IO.println s!"finite model: legacy rollback={repr damaged.stage}, metadata={damaged.legacyMetadata}; shared handoff rollback metadata={retained.legacyMetadata}"
  IO.println "Typed driver records distinguish created/preexisting packages, exact prior bindings and module metadata. Inverse theorem remains conditional on real API success, restored signed source and preserved hardware; no Windows preservation proved."
  IO.println "Conditional contract checked: guard, checked errors, compatible selected ownership or legacy inverse, and new-effects inverse. No Windows execution proved."
