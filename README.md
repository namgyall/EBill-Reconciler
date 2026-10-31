# BPC E-bill Reconciler

BPC E-bill Reconciler is a native macOS SwiftUI application for processing BPC
electricity-bill and receipt PDFs. It is implemented in Swift; there is no
Python implementation or Python runtime requirement.

## Requirements

- macOS 14 or later
- Xcode Command Line Tools, including `swiftc`, `codesign`, and `lipo`

## Build and install

Double-click `build-macos.command` in Finder, or run it from Terminal:

```sh
./build-macos.command
```

The script builds a universal Apple silicon and Intel app, ad-hoc signs and
verifies it, then places it in `BUILD/` at the repository root beside this
README. The top-level cloned repository is the project root; do not create or
clone another `EBill-Reconciler/` directory inside it. The script resolves its
paths from its own location, so it works from any current Terminal directory.
It refuses to overwrite an existing app bundle.

Set `OUTPUT_DIR` for another destination. Relative paths resolve from the
repository root; absolute paths are used as supplied:

```sh
OUTPUT_DIR="$HOME/Desktop/BPC build test" ./build-macos.command
```

## Verify

```sh
./verify.command
```

By default, this verifies the app in the root `BUILD/` directory. Set
`APP_PATH` to verify a specific `.app` bundle.

The ad-hoc signature is intended for local use and does not provide Apple
Developer ID notarization. macOS may display a first-launch security prompt.

## Source package

- `BPCApp.swift` and `BPCServices.swift` — application and processing logic
- `BPCAppInfo.plist` — bundle metadata
- `Resources/AppIcon.icns` — app icon
- `build-macos.command` — builds, signs, verifies, and installs the app
- `verify.command` — verifies an existing app bundle

Generated build output is excluded by `.gitignore`. Do not add customer
invoices, receipts, exported data, logs, or other personal documents to the
source package.
