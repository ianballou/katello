# Container distribution overlap validation — proof-of-concept design

## Status and scope

This document records the design agreed while reviewing Katello PR 11949 and the subsequent proof of concept. **The proof of concept is not ready to replace the PR.** The requirements and design below are the intended behavior; the implementation and test results are described separately so that an aspiration is not mistaken for a verified guarantee.

The implementation was developed and tested on November 12, 2026, on branch `distribution-overlap-take2`, based on `bcf3796b9b16c089327cf312349073057a802762`. At the time of testing, the proof-of-concept changes were uncommitted; the branch was subsequently committed as `30365f0e357955aca8cd877615f6b8566c3896b8`. The objective is to replace duplicated path-conflict logic with the smallest correct shared implementation and early checks at existing operation boundaries. Live tests used the proof of concept, not PR 11949's branch.

## User-facing requirements

- Do not automatically change existing distributions during an upgrade. Existing overlaps may remain until a user attempts an operation which would create or update an affected distribution.
- Detect predictable conflicts involving Katello-managed distributions before an operation creates or updates Pulp distributions. This includes a refresh of an unchanged legacy-overlapping path, not just newly renamed paths. Avoid pausing tasks for known managed conflicts.
- Do not reject an operation solely because two unrelated existing distributions overlap. Permit a proposed path that actually repairs an overlap, provided it has no conflict with other distributions during the transition.
- Explain the conflicting paths and repositories only when the caller is authorized to see them. Do not disclose another organization's repositories or paths. For hidden or unknown objects, use generic guidance and suggest contacting an administrator. Apply the same redaction to API errors, background task output, and lower-level errors.
- Direct administrators to choose a new lifecycle environment registry name pattern. Documentation should explain that `docker_upstream_name` can contain slashes, so distinct upstream names can still yield parent/child paths. Changing registry paths can require client image-reference changes.
- Validate pattern changes before saving them. A proposed pattern must not create exact duplicates or parent/child overlaps, including conflicts with existing paths during transition. Do not automatically reorder distribution moves; reject unsafe transitions with actionable, authorized details.
- A pause with an actionable, privacy-safe error is acceptable for a genuinely unmanaged Pulp distribution or an actual race. Do not use that exception to leave known managed overlaps undetected.

## Shared validation approach

Use one side-effect-free path-conflict checker, extending or supporting the existing `EnvironmentDockerRepositoriesValidator` rather than adding separate comparisons in each model and action. Retain existing syntax and exact-name validations.

Each operation supplies its actual projected distributions, not merely source repositories. Each candidate should identify the effective Pulp base path, destination/proxy or domain, and the specific distribution being updated when known. Compare:

1. All candidates with one another.
2. Each candidate with relevant current distributions, including those in other lifecycle environments and the current paths of other repositories in the same operation.
3. Exclude only the exact existing distribution the candidate will update; other clones of the same root or content view remain distinct.

Use slash-segment-aware comparisons: exact equality and `a` versus `a/child` conflict; `a` versus `ab` does not. Normalize consistently with Pulp. Pulp's relevant namespace is domain-wide and can contain other content types, other organizations, and unmanaged objects; detection and authorization-filtered presentation are distinct concerns. Check current and proposed paths for a pattern operation without treating an object's own current path as a separate conflict when it is truly being updated in place. Do not report a conflict between two unrelated pre-existing objects.

## Operation boundaries

Use the fewest existing entry points that provide accurate candidates and reject before important changes; do not introduce a separate Dynflow action merely to host comparison logic.

- **LCE pattern:** extend the existing environment validator to examine the proposed naming pattern and destination set before `environment.update!` persists it, including a change back to the default/blank pattern.
- **Repository creation/update and distribution refresh:** identify prospective paths before create or the relevant update is saved/planned, including unchanged paths that will actually be refreshed. Do not block an unrelated operation solely due to other old overlaps.
- **Content view publish/promotion:** derive the target view, version, and lifecycle environment for the actual destination clone, including composites and an existing clone being reused. Validate the entire operation's candidate set and the actual existing distributions. Avoid applying unrelated source-view or source-version paths.
- **Scheduled/background tasks and Capsules:** trace which operations plan distribution writes separately and where an early shared check must be called. Primary and Capsule refresh use separate actions, and some updates bypass `RefreshDistribution`; a single low-level planning hook is not universal.

A proposed early hook must be verified for transaction behavior, separate async task creation, partial external work, and accurate user-facing result. Planning is useful where the destination is known, but the checker itself must not depend on Dynflow.

## Distribution reconciliation and late failures

Preflight does not replace Pulp's authoritative check. Preserve useful privacy-safe conflict information for unmanaged distributions and real races; a paused task is acceptable for these cases. Do not automatically skip distribution failures or present incomplete publication as success.

Review the existing reference-first move behavior separately from comparison logic: updating a registry pattern must actually repair affected Pulp paths. Prior testing showed path-first lookup could create a second distribution and leave the old one; PR 11949's reference-first update fixes successful moves but its reference bookkeeping has stale-reference and asynchronous-failure problems. Include only the smallest reconciliation fix needed for reliable repair, update stored reference data after Pulp success, and do not change unrelated repository types without tests. Do not delete or adopt unknown distributions solely by path.

## Implemented in the proof of concept

This section describes the proof-of-concept implementation inspected on `distribution-overlap-take2`, not all of the requirements above.

### Shared checker and call sites

- `app/lib/katello/validators/distribution_path_validator.rb` compares projected candidates with one another and with unscoped Katello `DistributionReference` records. It checks equality and slash-delimited parent/child relationships, strips leading and trailing slashes, and excludes the selected reference ID for a candidate. It does not itself inspect Pulp. References have no usable proxy/domain identity in this implementation; unknown namespaces are treated as potentially overlapping.
- `repository_distribution_path_validator.rb` constructs a projected Library candidate for normal Docker repository creation and checks the existing Library repository path for Pulp-affecting root updates. Sync, metadata generation, primary refresh planning, and Capsule refresh planning call it as a backstop. Docker candidates are compared with all managed references; non-Docker refresh candidates are compared with managed Docker references. This does not yet cover every entry point or every actual future path.
- `content_view_distribution_path_validator.rb` renders projected destination repositories with the target view, version, and environment. Publish checks source groups and prospective Library, requested environment, and optionally archive destinations before creating the version/history. Promotion checks the promoted version's archived repositories and target environments. An existing destination clone's selected reference is excluded. Source-based duplicate checks were removed from the content-view readiness methods; projected container-name format is also checked in the new preflight.
- `EnvironmentDockerRepositoriesValidator` validates a changed pattern before persistence, including resetting to the default pattern. It checks generated names, proposed candidates, and managed current references. The controller schedules republishing when a registry setting is explicitly submitted, including an unchanged pattern, blank/nil pattern, or `false` unauthenticated-pull setting. The pattern validator itself only runs its new checks when the pattern changes; this distinction matters for retry and pull-setting updates.
- The shared check separates broad conflict detection from presentation. Detailed messages require both repositories to be persisted, in the operation's organization, and readable by the supplied non-anonymous user; otherwise it returns generic guidance. This is deliberately conservative but makes new-repository errors generic, even for an authorized administrator.

### Why the proof of concept changes distribution handling

The overlap comparison and distribution reconciliation are related but distinct concerns. The shared checker detects whether proposed paths overlap; it does not move a Pulp distribution. The service changes aim to make a registry-pattern repair actually move the intended distribution and leave the stored reference consistent with Pulp.

**Path-first metadata refresh:** In the baseline generic `app/services/katello/pulp3/repository.rb`, `refresh_distributions` first searches for a distribution at the *desired new path*. If the repository is still referencing a live distribution at `org/old` but no distribution exists at `org/new`, this path can create another distribution instead of moving the referenced one; the old distribution can remain. If the paths themselves overlap, that creation can also fail. If the target path exists, baseline recovery may adopt it without establishing ownership. The exact reference state and resulting cleanup depend on the path taken; these are distribution-reconciliation issues, not the overlap comparison rule.

**Docker reference-first refresh:** The proof of concept adds `refresh_distributions` in `app/services/katello/pulp3/repository/docker.rb`. For a live saved href it calls the inherited `update_distribution` to move that specific distribution. For a missing or stale reference it attempts creation instead of assuming an object found at the target path is owned by the repository. This deliberately changes Docker recovery behavior and needs missing/stale-reference and existing-target tests.

**Reference bookkeeping:** A `DistributionReference` stores both an href and a path. Baseline `update_distribution` PATCHes the referenced Pulp distribution but does not refresh the reference's stored path; baseline `save_distribution_references` retains an existing live reference without updating its path. A move can therefore leave Katello recording `org/old` while Pulp serves `org/new`. That is significant here because the proof-of-concept checker uses stored reference paths: stale data can cause a false rejection or a missed conflict. The Docker-specific `save_distribution_references` override rereads href, path, PRN, and guard from Pulp after successful work. The generic `repository.rb` change defers its pre-PATCH guard-field update for Docker so Docker bookkeeping can be reconciled after success; it leaves the existing non-Docker guard behavior unchanged.

**Related action changes:** Normal primary `RefreshDistribution` sequences `SaveDistributionReferences` after its Pulp refresh. The proof of concept additionally sequences that saver after the primary Docker `RefreshIfNeeded` action. In the direct-refresh path, `existing_only` ignores created resources from other Pulp tasks and reconciles only the captured, still-matching distribution href. Failed asynchronous operations must not be recorded as successful moves; tests cover the intended ordering, but real Pulp failure and response-shape coverage remains necessary.

**Important distinction:** An LCE pattern change first reaches `InstanceUpdate` -> `RefreshIfNeeded`, which already attempts to update a referenced distribution by href. A separate `MetadataGenerate` task later reaches the path-first `refresh_distributions` flow. The successful proof-of-concept LCE repair demonstrates the outcome for that test, but did not isolate which refresh performed the move or prove that the Docker override was necessary for every normal pattern repair. Repeating the repair and subsequent metadata refresh without these reconciliation changes is still needed before claiming they are indispensable to overlap validation.

**Scope decision:** Keep the new movement and reference-reconciliation behavior Docker-only for now to avoid inadvertently changing Yum and other content types' established distribution recovery behavior. This is a risk-limiting choice, **not** a claim that the underlying generic behavior is Docker-specific. Non-Docker paths can change too, and the shared checker compares Docker candidates with references belonging to other content types. Investigate a separately tested, content-type-independent reconciliation fix later, including Yum path-adoption behavior, other plugin-specific metadata, stale references, asynchronous failures, and Capsule mirrors. The POC's Docker-only handling does not make non-Docker reference paths authoritative.

The normal simulated legacy repair succeeded in the POC, but this is not a general guarantee that all repair paths are safe. Direct `RefreshIfNeeded` behavior with missing or stale references and supported asynchronous response shapes still needs integration coverage. Capsule mirrors have separate distribution lookup/update behavior.

## Results observed on the proof of concept

After the code changes, the development server was started from the Foreman directory using `bundle exec foreman start`. The following are recorded test results, not results of an actual product upgrade. Live tests used isolated, empty, unsynced test repositories unless noted.

| Test | Observed result |
| --- | --- |
| Library default-view parent and Dev child, regular and composite views | Both rejected with HTTP 409 before promotion; errors named the visible conflicting paths and repositories. |
| Library clone belonging to the same view and Dev child, regular and composite | Both rejected with HTTP 409 before promotion. |
| Dev parent and QA child, regular and composite | Both rejected with HTTP 409 before QA promotion. |
| Non-conflicting regular and composite promotions, republish and re-promotion | Tested controls completed stopped/success. |
| Existing overlap on an affected repository update | After an isolated simulation aligned Pulp paths, Katello names, and reference paths, the update returned HTTP 409 and its task stopped/error; an unrelated update succeeded. |
| LCE pattern repair | The simulated legacy overlap was repaired by a pattern change; its task stopped/success, and the checked repository names, reference paths, and Pulp paths matched afterward. Pulp distribution hrefs and IDs remained unchanged in that test. |
| Pattern transition versus another repository's current path | A proposed non-overlapping final set was rejected with HTTP 422 because one proposed path overlapped a different repository's current path. The saved pattern, Pulp distributions, and references stayed unchanged. |
| New repository conflict | Rejected with HTTP 409, but the message was generic even for an authorized administrator. This is an outstanding usability gap. |
| Cross-organization conflict | In one test using an administrator who could read both test organizations, the conflict returned a generic redacted message and left the pattern unchanged. This does not establish behavior for every restricted-user or background-task case. |
| Other controls | Empty and file/RPM-only views, normal Docker publish/promote and repeat promotion, a composite view, and an unrelated view succeeded. Duplicate candidates were rejected. |

The final focused automated run completed **202 tests, 725 assertions, 0 failures, 0 errors, and 5 skips** across 13 files. The five skipped content-view tests reported `TODO: Fix content views`. These were focused tests, including mocked Pulp/action tests, not a full-suite or remote Capsule test.

The live legacy state was **simulated**, not produced by upgrading a deployment. Unmanaged Pulp distributions, real races, actual upgrade behavior, remote Capsule behavior, and late-error redaction have not been proven end to end. Test-owned organizations and matching Pulp distributions/references were cleaned up. At the time of the tests, the source changes were uncommitted; the proof-of-concept branch was subsequently committed as noted in the status above.

### Known pre-existing behavior observed during testing

With a pattern using `docker_upstream_name`, updating the upstream name returned HTTP 200 but left the stored container name, reference path, and Pulp base path at their old values. Code inspection indicates this is baseline behavior, not introduced by the proof of concept. A later repository save can re-render the name, so a check of the stored path during planning may differ from a later write. Whether and when that can lead to a missed managed conflict still needs a targeted test.

## Remaining implementation and verification gaps

- **Managed coverage and timing:** Direct `RefreshIfNeeded`, registry-push creation, imports, separately spawned tasks, and other entry points need an end-to-end coverage audit. Resubmitting an unchanged pattern or changing the pull setting can republish without running the changed-pattern validator. Verify rejection timing, task state, locks, and partial state rather than assuming a planning check guarantees an upfront API error.
- **Namespace and stale state:** Stored references are not a complete or necessarily current Pulp inventory and do not identify the actual proxy/domain. Unknown namespace is treated conservatively. This can miss conflicts, create false positives, or compare primary state for a Capsule operation. Capsule-only and unmanaged distributions and races need separate handling.
- **Authorization and error details:** New-repository conflicts are overly redacted; restricted-user behavior, task-viewer authorization, and sanitization of synchronous and asynchronous Pulp failures need further verification. No different-organization repository names or paths may be disclosed.
- **Reconciliation and retry:** Verify missing/stale references, multiple references, incorrect-but-live href ownership, no-op and failed asynchronous updates, and the direct refresh path against real Pulp. Confirm behavior when a pattern saves but some subsequent updates fail, including a safe retry. A successful test of the aligned legacy repair is not proof for those cases.
- **Scale and semantics:** The checker currently loads all managed references and compares candidates against them, with additional per-candidate lookups. Measure and improve this at realistic scale if needed. Its normalization has not been established as identical to Pulp's for every possible stored path.
- **Simplicity:** Reassess the number of integration hooks and the Docker-specific reconciliation code after coverage is established. The current worktree is a proof of concept, not yet evidence that the desired reduction in overall complexity has been achieved.

## Acceptance and regression tests

This is the target matrix. The observed results above establish only the explicitly named cases; unchecked scenarios remain to be tested.

- Exact duplicate, parent/child in both directions, slash boundary, unrelated pre-existing overlaps, and authorized versus redacted errors.
- New repository creation and an existing overlapping repository's unchanged distribution update: early, actionable rejection and no paused task. An unrelated repository continues to work.
- LCE pattern edit: validate before persistence, including blank/default pattern; proposed paths against current and proposed paths; successful repair of aligned simulated legacy paths; no incorrect rejection of the same distribution's old path.
- Regular and composite publish/promotion: Library default-view parent vs Dev child; Library same-view clone vs Dev child; Dev parent vs QA child; safe controls; repeat promotion and different content views.
- No false positives for empty or non-container content views; cross-content-type and authorization/other-organization coverage.
- Primary and Capsule refresh paths and any separately spawned metadata task; identify HTTP/task state, locks, and Katello/Pulp consistency, not merely error text.
- Pattern move / stale reference / failed async update: verify reference href and stored path against Pulp only after success; no orphaning of the replaced distribution.
- Unmanaged and concurrent conflict cases: describe limitations and ensure sanitized, actionable errors; do not claim an upfront guarantee where Pulp state races.

## Open implementation questions

- Can the existing call sites be reduced without missing a distribution-changing operation or rendering a source clone under the wrong view or version?
- How is the actual Pulp domain and Capsule scope determined without excluding managed distributions merely because the user cannot read them?
- Beyond the successful simulated repair, can the rename flow safely handle missing/stale references and every supported asynchronous response, and how should partial failures be retried?
- How should permissions be retained for background actions so task output cannot leak privileged conflict details?
- How can the existing distribution reference scan and lookups be made suitable for large installations without obscuring the overlap rules?

The agreed behavior for a proposed path that conflicts with another distribution's current path is to reject the transition rather than calculate move order. No automatic cleanup or bulk renaming of legacy distributions is part of this design.
