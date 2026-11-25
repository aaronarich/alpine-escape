# AGENTS.md — Alpine Express (`TrainGame`)

Project instructions and engineering conventions for AI coding agents working on **Alpine Express** (macOS 14+ & tvOS 17+ procedural low-poly train simulation).

## Architecture & Design Principles

- **Zero External Assets**: Every 3D mesh, texture, sky gradient, particle image, and stereo sound is generated procedurally in Swift. Do not add bundled images, 3D model files, or audio assets unless explicitly requested.
- **Native Apple Stack**: SwiftUI + SceneKit + AVAudioEngine + GameController + CoreLocation + Open-Meteo. No third-party packages or dependencies.
- **Xcode Synchronized Group Warning**: `TrainGame/` is a `PBXFileSystemSynchronizedRootGroup` in `TrainGame.xcodeproj/project.pbxproj`. Any non-source file placed inside `TrainGame/` (such as images or `Info.plist`) will be copied into the app bundle or cause duplicate-output errors. Keep `Info.plist`, `README.md`, `AGENTS.md`, and `docs/` screenshots at the repository root.

## Source Map (`TrainGame/`)

| File | Responsibility |
| :--- | :--- |
| `TrainGameApp.swift` | SwiftUI `@main` app, macOS (`NSViewRepresentable`) & tvOS (`UIViewControllerRepresentable` with `UIPress` focus handling), HUD, Express Menu, Confetti overlay, and macOS `-snapshot` harness. |
| `Game.swift` | `SCNSceneRendererDelegate` render loop, world/train hot-swapping, 16-chunk track, viaduct, hollow tunnel, Train Wash, animated road crossings, 3-stage station stop signals, depot auto-stop assist, 3s/30s horn cooldown, and cameras. |
| `Track.swift` | `WorldTheme` (`alps`, `tokyo`, `blueRidge`), `TrainKind` (`steam`, `bullet`, `freight`), 3D closed spline loop, grade/curvature queries, landmark spans, and AABB-pruned `nearest(x:z:)`. |
| `Terrain.swift` | Concurrent heightmap generation, viaduct gorge & tunnel portal cutouts (`blocksTunnelPortal`), 6×6 spatially chunked ground & scenery for Swiss Alps, Tokyo, and Blue Ridge Mountains. |
| `Train.swift` | Batched wheel-axle trains (`Steam`, `Shinkansen Bullet`, `Cargo Freight` with loadable cargo), animated coupling rods, headlight spot & volumetric cone, and `CabDashboard` (3D gauges, moving lever, switches, auto wipers). |
| `Station.swift` | Flattened chalet stations, canopies, water towers, platform lanterns, animated mechanical semaphore departure signals, and pooled low-poly passengers. |
| `Weather.swift` | Dynamic day/night solar arc, sun/moon/380-star sky rig, fluffy faceted `cloudPuff` rings, optimized rain/snow emitters, and Open-Meteo live weather. |
| `Audio.swift` | Real-time lock-free (`OSAllocatedUnfairLock.withLockIfAvailable`) stereo synthesizer using 2-pole SVF filters: Steam chuffs, Shinkansen VVVF inverter hum, Freight diesel thrum, train-specific horns with stereo echo, bogie clack, crossing bell, Train Wash, Swiss bell / Tokyo Hassha melody, songbirds, crickets, raindrops, and thunder. |
| `Input.swift` | Unified input polling: Apple TV Siri Remote (`GCDirectionalGamepad` cardinal/center + `UIPress`), Xbox One S / Extended gamepads (`RT`/`LT` throttle, `L3` horn, D-pad views/weather, `Menu` Express Menu), and macOS keyboard. |
| `Mesh.swift` | Compact 36-byte interleaved `MeshVertex`, implicit indexless `SCNGeometryElement(data: nil, ...)`, outward-wound `ribbon`, `cloudPuff`, `chalet`, `redBarn`, `cow`, `toriiGate`, `hardwoodTree`, `wildflowerCluster`, and `Noise`. |

## Critical Invariants & Gotchas

1. **Performance (60 fps on Apple TV 4K)**:
   - Keep static world meshes spatially chunked (6×6 for terrain/scenery, 16 chunks for track) with `isDoubleSided = false` and shared `SCNMaterial` instances so SceneKit frustum- and shadow-culls effectively.
   - Keep tvOS at `.multisampling2X` and 2 shadow cascades (`1536×1536`); macOS uses `.multisampling4X` and 3 cascades (`2048×2048`).
   - Never allocate `SCNGeometry` or `SCNMaterial` per frame or per passenger spawn—reuse shared prototypes.
2. **Thread Safety**:
   - Simulation state lives on the SceneKit render thread (`renderer(_:updateAtTime:)`).
   - Cross-thread state (`InputController`, `TrainAudio`, `Game.sharedState`) must use `OSAllocatedUnfairLock`; the CoreAudio render callback must only use `withLockIfAvailable` so it never blocks.
3. **Tunnel Portals**:
   - Because terrain is a heightmap, `Terrain.blocksTunnelPortal` must omit triangles crossing the bore elevation at both tunnel entrances, bridged externally by wide rock sleeves in `Game.buildTunnel`.
4. **Cab Dashboard & Camera**:
   - `CabDashboard` attaches to `cameraNode` (`zNear = 0.3`). Keep all instruments proud of the vertical panel backing (`z = -0.91`) so nothing clips into the console, and keep `.cab` camera at `head + 0.6` so locomotive geometry never obstructs the windshield.
5. **Apple TV Remote & Controller Input**:
   - Never fall back to `GCMicroGamepad.buttonA` on 2nd/3rd-gen Siri Remotes when `GCInputDirectionalCardinalDpad` is present (`buttonA` fires on outer-ring clicks too). Always leave `.menu` unhandled in `UIPress` so Back/Menu exits to the tvOS Home Screen.
   - Keep `Info.plist` declaring `GCSupportsMultipleMicroGamepads = YES` and `DirectionalGamepad` / `ExtendedGamepad` / `MicroGamepad`.
6. **Horn Policy**:
   - Preserve the 3-second maximum horn duration and 30-second cooldown (`Game.maxHornDuration`, `Game.hornCooldownDuration`).

## Build, Verify & Deploy Commands

```bash
# macOS Release build (Universal Apple Silicon + Intel)
xcodebuild -project TrainGame.xcodeproj -scheme TrainGame -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath /tmp/TrainGameMacReleaseDD \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO build

# Launch macOS app directly into a specific world (alps | tokyo | blueridge)
open -n /tmp/TrainGameMacDD/Build/Products/Release/TrainGame.app --args -world blueridge

# Capture automated visual snapshots on macOS
open -W -n /tmp/TrainGameMacDD/Build/Products/Debug/TrainGame.app --args -snapshot /tmp/snapshots

# Build, install, and launch on paired physical Apple TV (find UDID via `xcrun devicectl list devices`)
xcodebuild -project TrainGame.xcodeproj -scheme TrainGame -configuration Release \
  -destination 'platform=tvOS,id=<APPLE_TV_UDID>' -derivedDataPath /tmp/TrainGameAppleTVDD \
  -allowProvisioningUpdates build
xcrun devicectl device install app --device <APPLE_TV_UDID> /tmp/TrainGameAppleTVDD/Build/Products/Release-appletvos/TrainGame.app
xcrun devicectl device process launch --device <APPLE_TV_UDID> com.aaronarich.TrainGame
```
