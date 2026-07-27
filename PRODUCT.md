# Product

<!-- impeccable:product-schema 1 -->

## Platform

web

## Users

The primary user is a platform, infrastructure, or security engineer operating GitHub Actions workloads through Runtrue. Repository evidence indicates they connect repositories, review workflow compatibility and execution state, decide policy approvals, and administer secrets, runners, identities, teams, and API access.

## Product Purpose

Runtrue provides a strict GitHub Actions product surface over the Runtrue control plane. It connects GitHub repositories, translates supported workflow definitions into bounded native Runtrue material, exposes workflow runs and approval state, and keeps browser authentication and configuration on the same origin.

Success means an operator can understand repository and execution state quickly, take an authorized action confidently, and see failure or policy attention before it becomes hidden operational drift.

## Positioning

Runtrue is fail-closed infrastructure, not a permissive workflow viewer. It binds workflow translation, repository identity, policy approvals, runner posture, provenance, and execution state to reviewed control-plane contracts.

## Operating Context

Operators work across GitHub App installations, repositories, workflow runs, approval requests, secrets and variables, runner fleets, tenant users and teams, API tokens, and audit events. The browser UI is a GitHub Actions-specific surface backed by same-origin browser APIs; it is not the generic Runtrue product UI.

## Capabilities and Constraints

- Preserve all existing browser routes, API contracts, capability gating, authentication, CSRF behavior, and factual product copy.
- Work within the existing dependency-free HTML, CSS, and JavaScript UI. Do not migrate the frontend framework.
- The UI must remain responsive, keyboard accessible, and usable when capabilities are absent.
- Secret values are write-only and never returned in browser inventory.
- The current repository worktree, including uncommitted quick-start and embedded-UI work, is the deployable product boundary.
- The adapter analyzes and translates workflows; it is not the execution engine.

## Brand Commitments

The product name is Runtrue. Existing voice is concise, technical, calm, and direct. The cube-like Runtrue mark and the phrase “Run local. Run remote. Run true.” are established assets and language. The redesign must feel operational and trustworthy without imitating GitHub’s visual identity.

## Evidence on Hand

- Product and deployment truth: `README.md`, `product/server/README.md`, and `ui/README.md`.
- Current browser surface: `ui/public/index.html`, `ui/public/styles.css`, and `ui/public/app.js`.
- Existing brand mark: `ui/public/favicon.svg` and inline header SVGs.
- Backend behavior and browser contracts: `product/server/src/app` and `product/server/tests/http`.
- No customer claims, pricing, benchmarks, testimonials, or marketing proof are available and none may be fabricated.

## Product Principles

1. Make state and policy attention legible before adding decoration.
2. Preserve fail-closed behavior and explain unavailable actions plainly.
3. Keep frequent operator actions crisp, familiar, and interruptible.
4. Use real backend state as the visual material; never simulate product capability.
5. Keep privileged or destructive actions clearly distinguishable from routine work.

## Primary Product Story

The repository catalog is an activation and administration tool, not the product’s opening argument. The authenticated entry surface should make Runtrue’s execution contract evident through real operator state rather than a standalone explainer:

1. GitHub supplies an authenticated event and exact source identity.
2. The frontend translates only supported workflow material into a bounded plan.
3. Policy binds approvals to the exact plan and requested capabilities.
4. An enrolled runner executes under certificate, lease, fence, and posture checks.
5. Results, artifacts, and decisions leave durable tenant-scoped evidence.

The first screen therefore prioritizes blocked decisions, active execution, GitHub ingress, runner availability, repository readiness, and audit evidence. Evaluators can understand why Runtrue exists while experienced operators can immediately act on exceptions.

## Accessibility & Inclusion

The web surface must preserve semantic structure, keyboard navigation, visible focus, reduced-motion behavior, readable contrast, responsive layouts, and explicit loading, empty, error, disabled, and permission-gated states.
