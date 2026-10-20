# Creator kit 0.1.0

A local authoring kit for independent native plugins. Generated projects use the SDK in `Vendor/NookPluginSDK` and keep their own code, tests, fixture data and build products. They do not compile or link the NeroNook app. Creator tooling does not become a runtime dependency.

## Commands

Run `python3 Creator/nook.py` from the SDK directory, or `python3 Tools/nook.py` inside a generated project.

| Command | Result |
| --- | --- |
| `create /path/to/MyModule --id com.example.my-module --name "My Module"` | New Swift project with local SDK, tests and instructions; existing destinations are never overwritten |
| `validate /path/to/MyModule` | Builds the project checker and validates the manifest with the actual vendored SDK |
| `dev /path/to/MyModule` | Builds/packages and opens the standalone native preview; rerun after edits, quit the preview to stop it |
| `dev /path/to/MyModule --replay /path/to/replay.json` | Replays bounded starter-owned ready/offline/recovered states every two seconds |
| `test /path/to/MyModule` | Runs project tests and the packaged process against old/current fake hosts, without invoking actions |
| `test /path/to/MyModule --replay /path/to/replay.json` | Also verifies the starter's ordered status/availability replay |
| `pack /path/to/MyModule --identity YOUR_SIGNING_IDENTITY` | Release build, manifest validation, stable certificate signing, compatibility verification, a new app and zip |

`pack` and `dev` create content-addressed app names in the project's `build` directory. They never overwrite the installed plugin or a running app. Older builds remain there for manual reinstall with the host's usual review. Edited existing output is rejected. Nothing automatically grants cross-plugin access or starts device/account connections.

Installable builds use an explicit `--identity`, `NERONOOK_SIGNING_IDENTITY`, or the installed plugin's certificate. They never fall back to ad hoc signing. An update must keep its bundle identifier and satisfy the installed app's designated requirement. A first installation needs an explicit certificate. Signing that does not finish within 25 seconds stops with one actionable error; it does not retry or change Keychain settings. The independently copied `signing.py` contains no private keys or credential values. See [signing and Keychain](../../docs/SIGNING-AND-KEYCHAIN.md).

The `test` command alone uses ad hoc signing under a distinct `.protocol-test` bundle identifier. This exercises the protocol without impersonating the installed app's privacy/credential identity; it is not an installable update.

The test host checks identity, fresh session, sequence ordering, real SDK validation, three periodic snapshots and clean EOF shutdown. Protocol payloads and plugin stderr are not printed in diagnostics. Compiler/test output is ordinary local developer output, not a general secret-redaction service. Test only source projects you trust: native code and its build scripts are executable code.

## Starter behavior

The module supplies a local counter, inline Add and reviewed Reset, a Settings gear with an offline toggle, a read-only shared `read_status` action and an expiring status channel. Modern hosts receive control cards; older hosts receive ordinary fields and actions, with Reset review kept in a plugin-owned native alert. The counter is memory-only and does not claim restart persistence. State is shared by both displays through one plugin process. The native preview has a 720×405 content area plus a status line; the host owns actual card styling, selector and display sizing.

The generated README explains where to replace demo logic. The tool supports these Swift-package stdio starter projects; existing specialized Xcode/Catalyst/plugin build systems stay independent. The full SDK's application-launch transport is documented separately. Automatic rebuild/watch, arbitrary third-party project adapters, interactive error-console UI and integrated automatic rollback are not part of this version.

## Export

From the host source checkout, `python3 SDK/Creator/export-kit.py` creates `build/NeroNook-Creator-Kit-0.1.4.zip`. It includes SDK source, creator templates/tools, reference docs and source hashes. The kit can create another independent project after extraction. It excludes build caches, the host implementation, installed-plugin packages and account/device data.

No public SDK/examples license has been selected. Export is a local development artifact; publication, notarization, external creator trials and distribution policy remain separate milestones.

## Recover an installed native plugin

NeroNook 0.18.0 records up to five distinct previous packages during updates. In host Settings → Modules, expand **Previous versions** for your plugin and review **Restore**. The host checks the exact saved package again and keeps current enabled/display/compact settings. Older unindexed folders are not automatically discovered. Restoring code does not rewind module-owned settings or data; test schema compatibility before recommending a downgrade. No actions are replayed. See [host recovery](../../docs/PLUGIN-RECOVERY.md).

Creator kit 0.1.3 introduced a bundled custom-view example and independent native-window helper. Read [custom views](../CUSTOM-VIEWS.md). View assets under Resources/Views are packaged with the plugin; no host checkout is required.

Creator kit 0.1.4 adds an editable manifest icon to every new module and a reusable SwiftUI icon view. Read [module icons](../ICONS.md).
