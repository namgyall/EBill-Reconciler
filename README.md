# BPC E-bill Reconciler

Native macOS SwiftUI app for reading BPC electricity bill and receipt PDFs,
checking outstanding balances, reconciling payments, managing station
mappings, and generating reports and settlement documents. PDF extraction and
scanned-page OCR use Apple's PDFKit and Vision frameworks locally.

## Requirements

- macOS 14 or later
- Apple's Swift compiler and signing tools (`swiftc`, `codesign`, `ditto`),
  available with Xcode Command Line Tools

This is the macOS Swift app; there are no Python source files. A separate
Windows port would require a distinct implementation.

## Build from Terminal

Clone or download this repository, then run:

```sh
mkdir -p ~/Desktop/"EBill-Reconciler" && \
cd ~/Desktop/"EBill-Reconciler" && \
git clone https://github.com/namgyall/EBill-Reconciler.git && \
cd "EBill-Reconciler" && \
chmod +x build-macos.command && \
./build-macos.command
```

By default, the script builds into the Desktop `EBill-Reconciler` directory and
copies the app to `~/Desktop/EBill-Reconciler`. It will not replace an existing Desktop app;
instead, it selects the next available numbered app name, such as
`BPC E-bill Reconciler SwiftUI (2).app`.

The App will be available at `~/Desktop/EBill-Reconciler/build` Folder

To install the built app in another folder:

```sh
OUTPUT_DIR="$HOME/Applications" ./build-macos.command
```

The app is ad-hoc signed, not notarized. macOS may show a Gatekeeper warning
the first time it is opened.

## Project files

- `BPCApp.swift` — SwiftUI interface and app workflows
- `BPCServices.swift` — PDF/OCR parsing, reconciliation, station persistence,
  and document/report exports
- `BPCAppInfo.plist` — app bundle metadata
- `Resources/AppIcon.icns` — app icon
- `build-macos.command` — terminal build, signing, verification, and install

No sample invoices or receipts are required to build. Keep user documents out
of source control. Before publishing a public GitHub repository, choose and
add an appropriate license; this folder does not include one.
