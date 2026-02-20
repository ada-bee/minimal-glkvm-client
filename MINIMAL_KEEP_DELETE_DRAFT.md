# minimal-glikvm keep/delete draft

Target: single-device, wired-LAN, lowest-latency macOS client for GL.iNet Comet/GLKVM.

## Keep (core path)

- `Overlook/OverlookApp.swift` (but remove menu-bar wiring)
- `Overlook/ContentView.swift` (trim to video + connect/disconnect + manual host)
- `Overlook/VideoSurfaceView.swift`
- `Overlook/InputManager.swift`
- `Overlook/WebRTCManager.swift`
- `Overlook/GLKVMClient.swift`
- `Overlook/KVMDeviceManager.swift` (manual device only; remove scans)
- `Overlook/JSONValue.swift`
- `Overlook/ConnectSheets.swift` (manual connect/password)

## Delete (high-confidence, non-core)

- `Overlook/OCRManager.swift`
- `Overlook/OCRViews.swift`
- `Overlook/MenuBarAgent.swift`
- `Overlook/StatusBarView.swift`
- `Overlook/PluginManager.swift`
- `Overlook/TailscaleManager.swift`
- `Overlook/HardwareControlManager.swift`
- `Overlook/ContentControlBar.swift` (currently unused)

## Keep for now, then minimize

- `Overlook/WebUISettingsPanel.swift`
  - either remove entirely, or keep a tiny subset:
    - video processing mode
    - bitrate/FPS preset
    - reconnect

## Optional delete (if no audio/mic needed)

Delete these only if you want video-only + keyboard/mouse:

- `Overlook/CoreAudioDevices.swift`
- `Overlook/WebRTCAudioDevice.swift`
- `Overlook/WebRTCFactoryBuilder.h`
- `Overlook/WebRTCFactoryBuilder.m`
- `Overlook/RTCAudioDeviceShim.h`
- Remove audio sections in:
  - `Overlook/WebRTCManager.swift`
  - `Overlook/WebUISettingsPanel.swift`
  - `Overlook/ContentView.swift` (audio stats rows)

## Mandatory project cleanup after deletes

- Remove deleted files from `Overlook.xcodeproj/project.pbxproj`:
  - `PBXFileReference`
  - `PBXBuildFile`
  - `PBXSourcesBuildPhase`
  - group children entries
- If audio stack is removed, also clean bridging header imports:
  - `Overlook/Overlook-Bridging-Header.h`

## Latency-first changes to apply after pruning

- In `Overlook/WebRTCManager.swift`:
  - remove Google STUN for LAN mode (host candidates only)
  - keep `playoutDelayHint = 0` behavior
  - keep video-only watch by default (`audio: false`, `mic: false`)
- In `Overlook/KVMDeviceManager.swift`:
  - disable mDNS/subnet scan by default
  - prefer explicit manual host list / single saved device
- In `Overlook/ContentView.swift`:
  - auto-connect to last saved/manual host on launch (optional)

## Phase order (recommended)

1. Delete non-core files and clean project references.
2. Remove scan/discovery logic (manual host only).
3. Set LAN ICE policy (no public STUN).
4. Remove audio path (optional), then simplify settings UI.
