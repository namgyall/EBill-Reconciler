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
README. The script resolves its project root from its own location, so it
works from any current Terminal directory. Its only output directory is that
root's `BUILD/`; it does not create an `EBill-Reconciler/` or
`EBILL-Reconciler/` project folder. It refuses to overwrite an existing app
bundle. The generated `.app` is a macOS application bundle: Finder presents
it like a single package, but internally it is a directory containing the
app's executable, resources, and metadata.

To clone into a project folder you already created, first make sure that
folder is empty, then run this from inside it:

```sh
git clone <repository-url> .
```

The final `.` means “clone into this folder”; omitting it makes Git create a
new child folder instead.

The ad-hoc signature is intended for local use and does not provide Apple
Developer ID notarization. macOS may display a first-launch security prompt.

## Source package

- `BPCApp.swift` and `BPCServices.swift` — application and processing logic
- `BPCAppInfo.plist` — bundle metadata
- `Resources/AppIcon.icns` — app icon
- `build-macos.command` — builds, signs, verifies, and installs the app

Generated build output is excluded by `.gitignore`. Do not add customer
invoices, receipts, exported data, logs, or other personal documents to the
source package.
