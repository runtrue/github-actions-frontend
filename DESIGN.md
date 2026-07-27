---
name: Runtrue Trust Console
description: A restrained operational interface for GitHub Actions control-plane work.
colors:
  action-cobalt: "#1f5bd8"
  graphite-navigation: "#16202e"
  raised-graphite: "#202c3c"
  mineral-canvas: "#f2f4f7"
  data-surface: "#ffffff"
  ink: "#111827"
  secondary-ink: "#5f6b7d"
  structural-line: "#d7dde5"
  success: "#168a4b"
  warning: "#b66a00"
  danger: "#c0343d"
typography:
  headline:
    fontFamily: "Aptos, Segoe UI Variable Text, Segoe UI, system-ui, sans-serif"
    fontSize: "40px"
    fontWeight: 720
    lineHeight: 1.2
    letterSpacing: "-0.025em"
  title:
    fontFamily: "Aptos, Segoe UI Variable Text, Segoe UI, system-ui, sans-serif"
    fontSize: "20px"
    fontWeight: 680
    lineHeight: 1.2
  body:
    fontFamily: "Aptos, Segoe UI Variable Text, Segoe UI, system-ui, sans-serif"
    fontSize: "16px"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "Aptos, Segoe UI Variable Text, Segoe UI, system-ui, sans-serif"
    fontSize: "14px"
    fontWeight: 650
    lineHeight: 1.5
  data:
    fontFamily: "SFMono-Regular, Cascadia Code, Roboto Mono, ui-monospace, monospace"
    fontSize: "12px"
    fontWeight: 600
    lineHeight: 1.5
rounded:
  control: "6px"
  surface: "10px"
  dialog: "14px"
  pill: "9999px"
spacing:
  xs: "4px"
  sm: "8px"
  md: "12px"
  base: "16px"
  lg: "20px"
  xl: "24px"
  section: "32px"
  page: "48px"
components:
  button-primary:
    backgroundColor: "{colors.action-cobalt}"
    textColor: "{colors.data-surface}"
    rounded: "{rounded.control}"
    padding: "10px 16px"
    height: "44px"
  button-secondary:
    backgroundColor: "{colors.data-surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "10px 16px"
    height: "44px"
  data-panel:
    backgroundColor: "{colors.data-surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.surface}"
    padding: "20px"
  text-field:
    backgroundColor: "{colors.data-surface}"
    textColor: "{colors.ink}"
    rounded: "{rounded.control}"
    padding: "0 12px"
    height: "44px"
  navigation-active:
    backgroundColor: "{colors.action-cobalt}"
    textColor: "{colors.data-surface}"
    rounded: "{rounded.control}"
    padding: "8px"
    height: "40px"
---

# Design System: Runtrue Trust Console

## Overview

**Creative North Star: "The Verifiable Run"**

Runtrue feels like a trust console built around one verifiable journey: authenticated GitHub event, bounded workflow plan, exact policy decision, fenced runner execution, and durable evidence. The default view is exception-led so daily operators see blocked work first while evaluators can understand the product’s distinctive control model from real interface material.

The system rejects decorative dashboard chrome and instead uses continuous data planes, structural rules, restrained typography, and one action color. Familiar controls disappear into the task; status colors appear only when the underlying state earns them.

**Key Characteristics:**

- Dark graphite navigation anchors the product without turning the workspace into dark mode.
- Mineral-gray canvas separates the application shell from white operational data planes.
- Cobalt marks current location, primary action, and selected state only.
- Tabular metadata and compact status language make live control-plane state easy to compare.
- Motion is crisp, state-led, and reduced or removed for frequent interactions.

## Colors

The palette is cool, restrained, and state-rich: graphite and mineral neutrals carry the shell, while action and semantic colors remain scarce.

### Primary

- **Action Cobalt** (`action-cobalt`): Primary actions, current navigation, selected controls, links, and running state.

### Neutral

- **Graphite Navigation** (`graphite-navigation`): Persistent navigation and high-confidence transient surfaces.
- **Raised Graphite** (`raised-graphite`): Hover and count layers inside graphite navigation.
- **Mineral Canvas** (`mineral-canvas`): The workspace background and recessed neutral controls.
- **Data Surface** (`data-surface`): Tables, panels, dialogs, and fields where users read or act.
- **Ink** (`ink`): Primary text and high-value labels.
- **Secondary Ink** (`secondary-ink`): Descriptions, metadata, and inactive navigation.
- **Structural Line** (`structural-line`): Dividers and single-source surface boundaries.

### Tertiary

- **Success** (`success`): Ready, active, online, approved, and succeeded states.
- **Warning** (`warning`): Pending, degraded, missing, and draining states.
- **Danger** (`danger`): Failed, rejected, canceled, destructive, and error states.

### Named Rules

**The Earned Color Rule.** Cobalt means action or selection; green, amber, and red mean real backend state. None are decoration.

**The One Boundary Rule.** A surface uses either a structural border or an elevation shadow at rest, never both.

## Typography

**Display Font:** Aptos / Segoe UI Variable Text with the system sans stack
**Body Font:** Aptos / Segoe UI Variable Text with the system sans stack
**Label/Mono Font:** SFMono-Regular / Cascadia Code / Roboto Mono with `ui-monospace`

**Character:** One workhorse sans family keeps dense product UI coherent. Monospace appears only for identifiers, values, counts, code, and measurement.

### Hierarchy

- **Headline:** Heavy, compact page identity; fixed sizing rather than fluid display type.
- **Title:** Panel and section titles with a restrained ratio to body text.
- **Body:** Standard interface copy with descriptive prose kept near 65–75 characters.
- **Label:** Buttons, navigation, field labels, and table actions; sentence case by default.
- **Data:** Tabular counts, IDs, scopes, versions, and timestamps.

### Named Rules

**The Operator Scale Rule.** Type establishes scan order without becoming a spectacle; page headings are the largest text in the product.

## Layout

Desktop uses a fixed 248px navigation rail and a fluid workspace capped at 1360px with 24px gutters. The 64px sticky context bar locates the active product area while the page heading owns the current task. Overview is the default entry point; repository inventory remains a dedicated operating destination. Operational summaries are continuous divided bands, not detached metric cards.

Panels use grid for reliable data alignment, with more space between task groups than inside them. At 1023px the rail contracts to 224px. At 780px it becomes an off-canvas drawer. At 639px, headings and actions stack, summaries become a vertical ledger, and wide tables retain horizontal scrolling or hide secondary columns without changing type scale.

## Elevation & Depth

The system is flat by default. Canvas, surface color, and fine rules establish depth; broad shadows are reserved for dialogs, toasts, and the active navigation control where physical separation communicates state.

### Shadow Vocabulary

- **Raised Overlay:** A soft offset shadow for dialogs, menus, and toasts.
- **Primary Action:** A compact cobalt-tinted shadow that helps the single primary action read without inflating its shape.
- **Surface Rest:** A nearly imperceptible one-pixel ambient shadow used only on the main catalog plane.

### Named Rules

**The Flat-at-Rest Rule.** Tables and administration panels sit on the canvas with one structural boundary. Elevation appears only when an element actually moves above the workspace.

## Shapes

Controls use tight 6px corners; content surfaces use 10px corners; dialogs use 14px corners. Pill geometry is reserved for avatars, state dots, compact counts, and short status chips. Inner elements are always tighter than the surface containing them.

## Components

### Buttons

- **Shape:** Compact rectangular control with gently curved corners.
- **Primary:** Cobalt with white text, reserved for the one dominant action in a task region.
- **Hover / Focus:** Color darkens on hover, visible cobalt focus ring, and a quick 0.98 press scale.
- **Secondary / Quiet:** White or transparent neutral controls with a structural border only when the boundary aids recognition.

### Chips

- **Style:** Small state or filter controls with tight internal padding; rounded rectangles for filters and pills only for brief state metadata.
- **State:** Selected filters move to the data surface and cobalt text. Semantic chips use a tinted background derived from real state.

### Cards / Containers

- **Corner Style:** Data surfaces use 10px outer corners and square internal rows.
- **Background:** White data surface over mineral canvas.
- **Shadow Strategy:** Flat at rest; see Elevation & Depth.
- **Border:** One cool-gray rule contains the surface and separates rows.
- **Internal Padding:** 16–24px depending on density.

### Inputs / Fields

- **Style:** White field, structural one-pixel stroke, 6px corners, and a 44px minimum height.
- **Focus:** Cobalt border shift plus a visible three-pixel translucent focus ring.
- **Error / Disabled:** Error uses danger color in copy and boundary; disabled controls remain legible but visibly reduced.

### Navigation

The graphite rail groups workspace and administration destinations. Inactive items use cool muted text; hover moves to raised graphite; the active item becomes a solid cobalt control with white text. Mobile uses the same rail as an off-canvas drawer and preserves the standard menu affordance.

### Operational Summary

The summary is a continuous divided band. Each cell pairs a small semantic mark with one tabular value and a plain-language label. It reports existing backend data only and disappears with its gated capability.

### Attention Overview

The default workspace view is exception-led and begins with operational state rather than a product explainer. Pending approvals occupy the widest operational plane and expose repository, workflow, trigger, exact subject identity, risk score, and a direct review action. A narrower posture ledger reports only state already returned by the authenticated dashboard. Recent runs retain their source context and lead directly to existing run details.

### Repository Manifest

The repository catalog is the primary data plane: heading, search, filter, table header, and rows form one surface. Repository identity leads each row; provider, approval attention, and connection state stay aligned for fast comparison.

## Do's and Don'ts

### Do:

- **Do** let real repository, run, approval, runner, and policy state drive emphasis.
- **Do** keep one clear primary action in each task region.
- **Do** use the system sans for product UI and monospace only for comparable technical data.
- **Do** preserve visible focus, 44px touch targets, reduced motion, and explicit empty/error/loading states.
- **Do** keep responsive changes structural: collapse navigation and columns before shrinking type.

### Don't:

- **Don't** introduce decorative charts, gradients, glass, glow, or metric-card grids.
- **Don't** use cobalt as ornament or semantic colors for non-state decoration.
- **Don't** round every element into a pill or nest bordered cards inside bordered cards.
- **Don't** add motion to frequent navigation, search, filtering, or keyboard-driven actions.
- **Don't** invent repository health, workflow capability, commercial claims, or operational evidence.
