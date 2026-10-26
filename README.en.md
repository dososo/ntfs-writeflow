<div align="center">

<img src="assets/logo.png" width="116" alt="NTFS WriteFlow" />

# NTFS 畅写 · NTFS WriteFlow

[简体中文](README.md) · **English**

Read and write NTFS on your Mac, with a clear view of your disks.

[![License](https://img.shields.io/badge/License-GPL--2.0-168B86.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-26%2B-23334B.svg)](#install)
[![Architecture](https://img.shields.io/badge/Architecture-Apple%20Silicon-168B86.svg)](#install)
[![Status](https://img.shields.io/badge/Status-Development%20candidate-B66C24.svg)](#validation-and-limits)
[![Version](https://img.shields.io/badge/Version-0.1.1--Preview-23334B.svg)](https://github.com/dososo/ntfs-writeflow/releases/tag/v0.1.1)
[![Built with](https://img.shields.io/badge/SwiftUI%20%2B%20FSKit%20%2B%20NTFS--3G-23334B.svg)](#architecture)

<p>
  <a href="https://github.com/dososo/ntfs-writeflow/releases/download/v0.1.1/NTFS-WriteFlow-0.1.1-arm64.dmg"><strong>⬇ Download for Mac (DMG)</strong></a>
  &nbsp;·&nbsp;
  <a href="https://github.com/dososo/ntfs-writeflow/releases/download/v0.1.1/NTFS-WriteFlow-0.1.1-arm64.zip">Download ZIP</a>
  &nbsp;·&nbsp;
  <a href="https://github.com/dososo/ntfs-writeflow/releases/tag/v0.1.1">All release assets</a>
</p>
<p><sub>0.1.1 Preview · Apple Silicon · macOS 26 or later</sub></p>

</div>

> A free, open-source NTFS utility for macOS: inspect actual disk state, choose read-only or read-write mounting, work with files in Finder, and unmount normally or safely eject the whole disk when finished.

<div align="center">
  <a href="https://dososo.github.io/ntfs-writeflow/"><img src="assets/video/intro-poster.jpg" width="82%" alt="NTFS WriteFlow 36-second intro (click to watch)" /></a>
  <br><sub><b>▶ NTFS WriteFlow · 36-second intro</b> · real screen recordings &nbsp;·&nbsp; <a href="https://dososo.github.io/ntfs-writeflow/"><b>Watch online</b></a> (works on phones) &nbsp;·&nbsp; <a href="https://github.com/dososo/ntfs-writeflow/releases/download/v0.1.1/NTFS-WriteFlow-0.1.1-intro-36s-1080p.mp4">Download MP4</a></sub>
</div>

## What is NTFS WriteFlow?

NTFS WriteFlow is a **native macOS desktop app for NTFS**. SwiftUI provides the interface, Apple's FSKit hosts the user-space filesystem, and NTFS-3G supplies the NTFS engine. The app interface is currently in Simplified Chinese; this README provides English usage and build guidance. Volumes mounted by this app use the `blntfs` filesystem type and are accessible through Finder and ordinary file operations.

Core read/write, normal unmounting, and safe removal of an external fixed disk have been tested on actual media. Product functionality and compatibility validation are still in progress. **This is a development candidate, not a stable-release claim covering every NTFS disk.**

## Why WriteFlow?

When you connect an NTFS disk, you should be able to see which driver mounted it, whether it is writable, and what must finish before you disconnect it. WriteFlow brings these states and actions into a native interface, with its implementation, tests, and limitations available for review.

Free distribution and clear data-operation boundaries are both part of the product.

## Features

- **Actual volume state:** filesystem, capacity, mount location, and access state; focus on NTFS by default or show other filesystems.
- **Read-only and read-write mounting:** file access through FSKit and NTFS-3G, with physical disks mounted through a system-authorized privileged service.
- **Finder operations:** create files and directories, rename, and copy; tests cover Chinese text, long names, extended attributes, large files, and sparse files.
- **Normal unmounting and whole-disk ejection:** synchronize volumes, unmount related partitions normally, request whole-disk ejection, and verify the result. Busy volumes and errors do not trigger forced unmounting. Fixed USB disks that remain physically connected are distinguished from media that disappears from the system.
- **Menu bar and settings:** inspect volumes, control automatic refresh, manage the helper, and export local diagnostics.
- **Other-driver awareness:** show when another driver owns a mounted volume, without automatically taking it over or counting its writes as WriteFlow's work.

**A fixed USB hard disk may remain in the system's device tree after safe removal because it is still physically connected.** WriteFlow displays a safe-to-disconnect result only after a successful ejection request, unchanged original media identities and capacities, no mounted partitions, and closed open-reference states for all media in that disk's tree. Disk images and removable media must instead disappear. Unmounting alone is not enough. If a later refresh finds that another program remounted the disk, the app revokes that session's ejected state. See the [release notes](发布/版本说明.md).

## A look around

<div align="center">
  <img src="assets/screenshots/main.jpg" width="90%" alt="NTFS WriteFlow with a read-write test volume" />
  <br><sub><b>Readable disk state</b> — a real test volume mounted as blntfs, with Finder, unmount, and whole-disk ejection actions together.</sub>
</div>

<br>

<div align="center">
  <img src="assets/screenshots/ejected.jpg" width="90%" alt="NTFS WriteFlow after ejecting the test disk image" />
  <br><sub><b>Wait for the result before disconnecting</b> — the ejected test image disappears from the list. Fixed USB disks receive a distinct safely removed but still connected message.</sub>
</div>

<br>

<div align="center">
  <img src="assets/screenshots/settings.jpg" width="64%" alt="NTFS WriteFlow settings and privileged helper authorization" />
  <br><sub><b>Permissions and preferences together</b> — menu-bar visibility, automatic refresh, and helper authorization status.</sub>
</div>

These are actual app screenshots using the dedicated `WriteFlow Demo` image. Temporary device numbers and mount paths in the screenshots are not commands to reuse on another Mac.

## Install

> **Target:** macOS 26 or later · Apple Silicon. The tested host runs macOS 26.6.2; Intel, older macOS versions, and every macOS 26 point release have not been validated.

Download the [0.1.1 preview release](https://github.com/dososo/ntfs-writeflow/releases/tag/v0.1.1): [DMG installer](https://github.com/dososo/ntfs-writeflow/releases/download/v0.1.1/NTFS-WriteFlow-0.1.1-arm64.dmg) or [app ZIP](https://github.com/dososo/ntfs-writeflow/releases/download/v0.1.1/NTFS-WriteFlow-0.1.1-arm64.zip). The same release includes complete corresponding source, `SHA256SUMS.txt`, and distribution verification records. This remains a development preview.

Installation:

1. Check its `SHA256SUMS.txt`, extract the app ZIP, and place `NTFSWriteFlow.app` in **`Applications` inside your home folder**, or `~/Applications`. This is the installation location used in current validation.
2. Open the app from that fixed location. Enable its filesystem extension in **System Settings → General → Login Items & Extensions → File System Extensions**. Some macOS versions expose this through the category view.
3. For physical disks, open the app's **Settings → Physical disk mounting → Configure privileged mount service** (`设置 → 物理磁盘挂载 → 配置管理员挂载服务`) and authenticate in the macOS system prompt.
4. Choose read-only or read-write mounting for a test volume, verify that its actual mount type is `blntfs`, and open it in Finder. If another driver already mounted it, save your files and unmount normally with that tool first.
5. Finish with normal unmounting or the validated whole-disk ejection workflow, and wait for the system result. If a disk is busy, resolve the open files and retry.

The filesystem extension and helper require separate system authorizations. The whole-disk ejection workflow may also trigger a foreground macOS device-access authentication prompt. Complete it yourself in the system dialog using Touch ID or your Mac password; do not put your password in chat, an issue report, or a custom app form. Helper approval does not guarantee permission for the current device operation. If authorization is canceled or denied, volumes may already be unmounted while the disk remains unejected; wait for a confirmed result rather than treating unmount success as permission to unplug. WriteFlow does not require disabling SIP or Gatekeeper, reducing startup security, or granting the background service Full Disk Access. Check notarization against **the actual artifact for the version you received**, not a previous release's result.

See [installation and removal](发布/安装与卸载.md) for the full procedure and the required order for removing the helper and app. Supporting technical documents are currently in Chinese.

## Validation and limits

Tests already performed include:

| Scope | Verified behavior |
| --- | --- |
| System-mounted images | Eight functional cases: identity rejection, concurrent small files, rename/open-handle behavior, sparse files, long names and attributes, read-only protection, disk-full recovery, and over-4-GiB writes with full rereading after remount. |
| Physical external NTFS media | Read/write, synchronization, Chinese directory operations, and normal unmounting within a designated new test directory, followed by full test-file and attribute verification with another driver. |
| Permissions and errors | Helper policies, actual file ACLs, XPC descriptor transfer, incorrect-signature rejection, synchronization failures, and lifecycle tests. |
| Version 0.1.1 whole-disk ejection | An actual external fixed USB disk completed safe removal through the app, with independent original-media, unmounted-state, and closed-reference checks. A test image was mounted read-write and ejected through the GUI; its mapping and original device disappeared, and an offline tool verified the full SHA-256 of a 65,573-byte file. 314 non-device regression checks and five system ejection integration cases passed. The real-disk ejection test added no new test writes. |

The app has passed Developer ID signing, Apple notarization, ticket stapling, and local Gatekeeper checks. The DMG and ZIP contain the same validated app. Product source and build resources were frozen before the offline rebuild; public download documentation is updated for this release. Consult `分发验证摘要.json`, `构建对应记录.json`, and `SHA256SUMS.txt` attached to the release for artifact identity and verification scope. Notarization does not establish complete filesystem compatibility.

**Not yet complete:** Windows reading and write-back, Windows filesystem checks, physical power loss or unexpected unplugging, sleep/wake, long-running stress tests, actual multi-user isolation, and clean-Mac installation and full removal. Formatting, complete filesystem checking/repair, login launch, per-volume preferences, and notifications are not all delivered. Testing a dedicated directory does not validate every pre-existing file on a disk.

See [known issues and release gates](发布/已知问题与发布门禁.md) for scope, retained error observations, and outstanding work.

## Privacy and permissions

File operations run locally. The current app has no account system, telemetry, or automatic upload feature. The diagnostic summary exported from within the app omits volume names, mount paths, volume identifiers, accounts, and user-file contents. Screenshots and system logs you attach separately need their own review; remove private details before sharing them.

The privileged service accepts requests only from the app after signature verification and uses constrained operations with media-identity checks. Its implementation and permission boundaries are documented in the [helper guide](发布/管理员挂载服务.md).

## Build from source

Requires **an Apple Silicon Mac, macOS 26, Xcode 26 with a macOS 26 SDK, XcodeGen, Autoconf, Automake, and GNU Libtool**. The tested build baseline is Xcode 26.6, macOS SDK 26.5, and XcodeGen 2.44.1.

Clone the public repository with its pinned submodule, then build:

```sh
git clone --recurse-submodules https://github.com/dososo/ntfs-writeflow.git
cd ntfs-writeflow
git submodule update --init --recursive
NTFS_BUILD_CONFIGURATION=Release bash script/build_and_run.sh --build-only
```

For the complete source archive distributed with a release, use the offline path:

```sh
bash 发布/准备离线源码.sh
NTFS_BUILD_CONFIGURATION=Release bash script/build_and_run.sh --build-only
```

The complete source package includes the pinned NTFS-3G tree, its upstream Git bundle, and file hashes. The preparation script restores dependency Git metadata without overwriting source files or installing drivers, and requires no network access. The GitHub repository keeps a real Git submodule reference, while the source archive includes the full dependency tree; these are separate delivery formats.

The output is `build/xcode/Build/Products/Release/NTFSWorkbench.app`. The default script uses ad-hoc signing; **compiling and launching the main window does not grant FSKit loading authorization**. To distribute your own build, use your own Developer ID, FSKit profile, and matching identifiers, and verify the helper's signature policy. See the [source and signing guide](发布/开源说明.md).

```sh
bash script/test_engine.sh
bash ThirdParty/FSKitAdapter/Tests/run.sh
python3 -m unittest discover -s Tests -p 'test_signing_gate.py'
```

The engine and adapter tests above create independent file images. Review [core test documentation](Tests/Core/README.md) and [system tests](Tests/System/README.md) for system-mount prerequisites, real-media authorization boundaries, and cleanup.

## Architecture

| Component | Responsibility |
| --- | --- |
| [SwiftUI app](Sources/App) | Disk listing, operation state, Finder integration, menu bar, settings, and diagnostics. |
| [Core models and guards](Sources/Core) | Media identity, eligibility checks, and result verification. |
| [Privileged helper](Sources/PrivilegedHelper) | Constrained mounting, normal unmounting, and whole-disk-ejection preparation after system authorization, client-signature and target-identity checks. |
| [Foreground disk ejection](Sources/HelperShared/DiskEject.swift) | The app obtains system-authorized read-only device access, uses the same descriptor to eject, and verifies either media disappearance or a fixed-disk safe-removal receipt. |
| [FSKit adapter](ThirdParty/FSKitAdapter) | macOS filesystem calls and volume lifecycle. |
| [C bridge](ThirdParty/NTFSBridge) and NTFS-3G | NTFS file and directory operations, with pinned upstream versions and recorded changes. |

## License and provenance

New project code uses the [GNU General Public License, version 2](LICENSE). Third-party components retain their own licenses, copyright notices, and pinned revisions; see [third-party notices](第三方组件说明.md). Binary distribution must include matching complete corresponding source and build materials.

The project uses open-source NTFS-3G and modified open-source bridge/adapter code. It contains no Paragon proprietary driver, license files, resources, or decompiled implementation. Studying an existing product's behavior is not the same as recovering its original source code.

## Author

**爆裂队长 NEXT · BLCaptain** · [GitHub: dososo](https://github.com/dososo)

<div align="center"><sub>NTFS 畅写 · NTFS WriteFlow — free and open source, with clear state and verifiable operations.</sub></div>
