# Scan4D — App Store Connect Listing

> Copy-paste ready content for promoting from TestFlight to the App Store.

---

## App Name

```
Scan4D
```

## Subtitle (30 chars max)

```
Time-Series Reality Capture
```

---

## Promotional Text (170 chars max)

> This text appears above your description and can be updated without a new build.

```
Capture, re-scan, and export high-fidelity 3D scans with LiDAR depth, RGB, and camera poses — all from your iPhone or iPad.
```

---

## Description (4000 chars max)

```
Scan4D is a reality capture app for LiDAR-equipped iPhone and iPad. It turns the depth sensor and camera into a 3D scanner, capturing detailed meshes, depth maps, photos, and camera poses for reconstruction, photogrammetry, and spatial computing.

• AR mode: real-time mesh with a wireframe overlay and occlusion-aware coverage visualization
• VR mode: live accumulated depth point cloud with bloom and confidence decay
• 16-bit depth maps with confidence maps at adaptive frame rates
• Scan capacity metrics: polygon count, drift tracking, session duration
• Scan coaching: real-time tips on tracking, scanning pattern, and progress
• Automatic hi-res photos: sharp native-resolution stills taken whenever the device is steady and the view has changed, with a coverage overlay showing where photos are still needed
• Focus scans: draw a box around one area (a work table, a shelf) on a previous scan and photograph it in detail, from a quick check to dense coverage for 3D reconstruction, with a live dial of the angles covered; rescan the same box later to see how it changed
• Space staging analyzer: an optional 360° sweep before scanning checks lighting, doors, screens, and people, with tips
• Interactive 3D preview with camera-sampled vertex colors
• Privacy filtering: people removed from meshes and faces blurred in exported images; switched off, it turns itself back on after 24 hours
• Tracking guard: the scan halts and offers to save if tracking is lost

PROXY MODE (Meta Ray-Ban Smart Glasses)
• Stream frames from Meta Ray-Ban glasses over Bluetooth, with a picture-in-picture preview, adjustable frame rate, and the privacy filter applied

TIME-SERIES SCANNING
• Group scans by location and rescan the same space over time
• On-device Process step finishes each scan: room layout, registration, ghost proxy, and vertex coloring
• Automatic plane registration aligns every rescan into the location's shared coordinate frame; unreliable fits are refused, never guessed
• Rescan Space and Link Adjacent Space show a ghost of previous captures, aligned live against detected planes, with relocalization checks and manual alignment
• Multi-level spaces: steps, landings, and ramps are recovered from the scan's own mesh
• Bad-scan warning right after save, so a failed capture can be redone on the spot
• Linked-scan graph with a combined-mesh viewer

BULK OPERATIONS
• Multi-select locations and scans for bulk Process, Share, Sync, and Delete with per-tile progress
• Background post-scan processing with per-card progress

FLEXIBLE EXPORT FORMATS
• Scan4D: everything a scan captured in one bundle: images, depth, confidence, camera poses, the colored mesh, room layout, ARKit feature points, 360° stills, and metadata. A Scan4D server turns it into Nerfstudio training data or flame3d object-search input
• OBJ / PLY / USDZ: mesh formats in the scan's real colors for MeshLab, Blender, and iOS Quick Look

SCAN4D SERVER SYNC
• Sync to your own Scan4D server: each space's map, then every processed scan as one bundle
• Choose which spaces sync, and keep test scans on the device
• Gaussian splats the server makes of your focus scans download to the phone, open in a 3D viewer, and replace the mesh inside their box in the room's preview
• Bundles upload in the background over Wi-Fi, even with the screen locked, with a sync badge on each space
• Share to Files or AirDrop for offline workflows

DEVELOPER MODE
• Simulator testing with synthetic IMU, camera, and depth, mock glasses, and performance diagnostics

Designed for researchers, 3D scanning professionals, and spatial computing developers who need raw, high-fidelity sensor data with full control over the reconstruction pipeline.

Requires a LiDAR-equipped iPhone or iPad Pro. Meta Ray-Ban Smart Glasses supported for proxy frame capture.
```

---

## What's New (version 0.5.0 — upcoming release)

```
• Process step: finish scans on-device — room layout, plane-based registration into a shared per-location frame, rescan ghost, and vertex coloring — with sharing and sync gated until complete
• Automatic rescan alignment: walls and floors register each rescan into the location's canonical coordinate frame; unreliable fits are refused, never guessed
• Multi-level rooms: steps, landings, and ramps are recovered from the scan mesh, and curved walls keep their real geometry instead of being flattened
• Focus scans: Rescan Space can now photograph one region in detail — draw a box on the previous scan, pick Check, Detail or Splat, and walk around it; saved as a partial scan you can share or sync
• Automatic hi-res photos: room scans take native-resolution stills on their own, sharp at walking pace; no more tapping (a tap remains the 360° camera's shutter)
• Photo coverage tracking: occlusion-correct world-space coverage grid with overlap and parallax coaching, exported for dataset triage
• Stop safety: the stop button always asks — Save & End, Save & Scan Adjacent, Discard, or Cancel
• Naming after save: the name prompt now waits for the save pipeline, eliminating the frozen-keyboard stall on stop
• Bad-scan warning right after save so a failed capture can be redone on the spot
• Scan4D server sync: each space's map, then each processed scan as one bundle, in the background over Wi-Fi; a cloud on each space shows whether the server has its map or everything (replaces Upload and the upload URL)
• Focus splats: when the server makes a Gaussian splat of a focus scan, its card offers it; tap Download, then tap the card to orbit the splat in its box, or see it in place in the room's 3D preview
• Space analyzer: sweep progress in real degrees with honest partial results on timeout
• Faster, safer exports: memory-bounded blur pipeline and double-tap guards on process, share, and delete
• Tracking recovery: automatic session re-bootstrap after a mid-scan tracking collapse
• Many stability fixes across save, rescan, and VR capture
```

---

## What's New (version 0.3.0)

```
• Meta Ray-Ban Smart Glasses: stream, capture, and privacy-filter wearable frames via Bluetooth
• VR capture mode: live accumulated point cloud with bloom effects and confidence decay
• AR coverage overlay: 3D occlusion-based visualization shows scanned vs. unscanned areas
• Procedural wireframe: replaced depth rainbow with a color-controlled wireframe shader
• Tracking safety: VIO starvation guard halts the scan and prompts save on tracking loss
• Scan coaching: real-time 4-tier guidance system (tracking + capacity warnings, pattern tips, progress encouragement) with swipe-to-dismiss and Settings toggle
• Relocalization rejection and manual ghost mesh alignment for rescan/stitch workflows
• Linked-scan graph and combined-mesh viewer for adjacent-space stitching
• Bulk operations: multi-select locations and scans for Save, Upload, and Delete
• Depth confidence map export alongside depth frames
• Tracking instruction banners guide initial scanning and relocalization
• Use case picker when naming a scan (Rescan Space or Link Adjacent Space)
• Settings access button added directly to the capture view
• Live percentage indicator for photo-based vertex coloring progress
• Mesh preview loading indicator while geometry loads
• Extensive performance optimizations: faster stop, lower memory, throttled UI updates
• Numerous bug fixes for AR session lifecycle, privacy filtering, and stitching stability
```

---

## Keywords (100 chars max, comma-separated)

```
3D scanner,LiDAR,reality capture,photogrammetry,depth map,mesh,point cloud,ARKit,spatial,wearable
```

---

## Categories

| Field | Value |
|-------|-------|
| **Primary Category** | Utilities |
| **Secondary Category** | Productivity |

---

## Age Rating

| Question | Answer |
|----------|--------|
| Contains unrestricted web access? | No |
| Contains gambling or contests? | No |
| Contains mature/suggestive themes? | No |
| Contains profanity or crude humor? | No |
| Contains medical information? | No |
| Contains horror/fear themes? | No |
| Contains violence? | No |
| Contains alcohol, tobacco, drugs? | No |

**Recommended Rating:** 4+

---

## Support URL


```
https://github.com/WiseLabCMU/scan4d-ios
```

---

## Privacy Policy URL

```
https://github.com/WiseLabCMU/scan4d-ios/blob/main/docs/PRIVACY.md
```

---

## Screenshots

> [!NOTE]
> You need **at least 3 screenshots** for each device size class (6.7" iPhone, 6.1" iPhone, and iPad if supported). Recommended: 5-8 screenshots.

### Suggested Screenshot Sequence

| # | Screen | Caption |
|---|--------|---------|
| 1 | **AR Capture View** (recording active, wireframe visible) | "Real-time LiDAR mesh capture with procedural wireframe overlay" |
| 2 | **VR Capture View** (point cloud on black background) | "Accumulated depth point cloud with bloom and confidence decay" |
| 3 | **Capture View** (privacy filter on, red-eye markers) | "Built-in privacy filtering with person detection and face blurring" |
| 4 | **3D Mesh Preview** (colored mesh in SceneKit viewer) | "Interactive 3D preview with camera-sampled vertex coloring" |
| 5 | **Scans List** (location grid with multi-select active) | "Organize scans by location with bulk Share, Sync, and Delete" |
| 6 | **Link Adjacent Space** (ghost overlay + tracking banner) | "Re-scan over time or link adjacent areas with guided alignment" |
| 7 | **Meta Ray-Ban PiP** (glasses stream + capture view) | "Stream frames from Meta Ray-Ban Smart Glasses via Bluetooth" |
| 8 | **Share Format Menu** (Share on a scan card, its format list open) | "Share as Scan4D, OBJ, PLY, or USDZ" |
| 9 | **Dashboard** (server status + glasses connection) | "Connect to your server and pair Meta Ray-Ban Smart Glasses" |
| 10 | **Settings** (capture mode + glasses) | "Full control over capture quality, mode, and device pairing" |
| 11 | **Server tab** (sync status + pending bundles) | "Sync your spaces to your own Scan4D server" |

---

## App Store Icon

> Already set via `AppIcon` in `Assets.xcassets`. Ensure it meets the 1024×1024 requirement with no transparency.

---
