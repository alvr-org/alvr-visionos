Repository Guidelines

## Project Structure & Module Organization
- `ALVRClient/` contains the visionOS client sources (Swift, Metal shaders, assets).
- `ALVREyeBroadcast/` contains the ReplayKit extension sources.
- `ALVR/` holds upstream ALVR components and samples.
- Xcode project: `ALVRClient.xcodeproj`.
- Configs and build scripts live at the repo root (`*.xcconfig`, `build_and_repack.sh`).

## Build, Test, and Development Commands
- Build the client (no simulator launch):
  `xcodebuild -project ALVRClient.xcodeproj -scheme ALVRClient -configuration Debug build`
- Optional release build:
  `xcodebuild -project ALVRClient.xcodeproj -scheme ALVRClient -configuration Release build`
- There is no standard test target in this repo; rely on build + device testing.

## Coding Style & Naming Conventions
- Swift: 4‑space indentation, Swift API Design Guidelines, `camelCase` for variables/functions, `PascalCase` for types.
- Metal: keep shaders in `ALVRClient/Shaders.metal`, follow existing naming (e.g., `hudVertexShader`).
- Prefer small, self‑contained helpers and keep tunables near the top of files.

## Testing Guidelines
- No automated test suite is defined.
- Validate by building and, when applicable, device testing on visionOS hardware.

## Commit & Pull Request Guidelines
- Commit subjects in recent history use short prefixes like `fix:`, `perf:`, and `WIP`; follow that pattern when appropriate.
- Keep commits focused; include a short description of user‑visible changes in PRs.
- If UI changes are made, include screenshots or a brief description in the PR.

## Agent-Specific Instructions
- After code changes, run an Xcode build (no simulator) before finalizing:
  `xcodebuild -project ALVRClient.xcodeproj -scheme ALVRClient -configuration Debug -destination 'generic/platform=visionOS' build`
- If the build fails, fix it or report the failure with the error summary.
