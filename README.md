# TuSou — Offline Image Search for iPhone

TuSou lets you find photos in your iPhone's photo library, and images imported into the app, by typing what is in them, in Chinese or English.
Everything runs on the device: the app contains no networking code and works in Airplane Mode.

- Minimum OS: iOS 17.0 (built with Xcode 16.4 and the iOS 18.5 SDK)
- System frameworks only, no third-party dependencies: SwiftUI, PhotoKit, Vision, NaturalLanguage, SQLite3
- iPhone only; also runs on Apple silicon Macs as an iPhone app ("Designed for iPhone")

## What you can search for

| Kind | Example queries (English glosses) | How it works |
| --- | --- | --- |
| Scene and object content | seaside, cat, dog, birthday cake, food, sunset, snowy mountain, car | Apple Vision image classification (1,303 classes) plus a bundled Chinese/English dictionary |
| Synonyms and slang | internet slang for cats and dogs, puppy, Samoyed, Shiba Inu, Ragdoll | Dictionary synonyms plus on-device word embeddings (NLEmbedding) |
| Text inside images | invoice, receipt, parking lot, restaurant, amounts, order numbers | Vision text recognition (Simplified Chinese, Traditional Chinese, English; Traditional is normalized to Simplified) |
| Cross-language matches | the Chinese word for "invoice" also finds an English "RECEIPT", and "invoice" finds Chinese invoices | Synonyms of the same label are matched against recognized text |
| Photo attributes | screenshots, favorites, selfies, panoramas, Live Photos, Portrait mode | PhotoKit metadata |
| Other detections | QR codes, barcodes, faces, group photos (three or more faces), images that contain text | Vision detectors |
| Dates | "2024", "October 2025", "March", "today", "yesterday", "last week", "last year" | Capture date; a date written inside an image (a receipt, a screenshot) also matches, ranked below capture-date matches |
| Combined queries | "seaside sunset", "seaside last year" | Images matching every term rank first |

Results are ranked by relevance, and each thumbnail shows why it matched (for example "beach 86%" or "text contains ..."). Tapping a result opens a full-screen viewer with swipe paging, pinch and double-tap zoom, and an info sheet listing every recognized label and the recognized text.

Each image records which recognition steps (classification, text, faces, QR codes and barcodes) failed to run, so "nothing found" is never confused with "not checked": search results state how many images a query could not check, and rescanning retries those images.

## Privacy and offline operation

- No network requests anywhere: no URLSession and no Network framework. The compiled binary contains no networking symbols and links neither Network nor CFNetwork.
- Photos whose originals exist only in iCloud ("Optimize iPhone Storage") are never downloaded; the preview that is already on the device is used for analysis and display.
- Imported images are copied into the app's own sandbox. Deleting the app removes them together with the index. The system photo library is never modified.
- Photo access uses read/write authorization, and the usage description explains that all photos are read to build a local index:
  - Full Access: the whole library is indexed and kept in sync incrementally (additions, deletions, edits).
  - Limited Access: only the selected photos are searchable. The app explains this and offers a shortcut to switch to Full Access in Settings, or to add more photos. `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` is set so the system does not keep prompting.
  - Denied: imported images remain searchable, and the app offers a shortcut to Settings.
  - When access is reduced or revoked, index data for photos the app can no longer read is deleted.

## Compatibility

The app runs on iOS 17 and every later version without code changes. Apple supports running and debugging from Xcode on a device only with an Xcode version that supports that device's iOS version:

| Device iOS | Xcode | Mac |
| --- | --- | --- |
| 17 – 18 | 16 or later | macOS 15 |
| 26 | 26 or later | macOS Sequoia 15.6 or later |
| 27 | 27 or later | macOS Tahoe 26.6 or later, Apple silicon only |

An older Xcode can still build and sign the app for a newer device. It cannot launch or debug the app on a device whose chip is missing from its developer disk image: Xcode 16.4 fails on iPhone 17 models with "Failed to find image for variant/identity". Such a build can still be installed through the device's standard installation service, which does not use the developer disk image; `Tools/mdinstall.c` does this through MobileDevice.framework.

Builds signed with a free Apple ID expire after seven days. Distribution through TestFlight requires a paid Apple Developer Program membership and a build made with Xcode 26 or later.

## Known limitations

- In the iOS Simulator on Apple silicon Macs, Vision's neural models (scene classification, faces, barcodes) cannot run and fail with "Failed to create espresso context"; only text recognition works. The app flags the affected images and shows a notice. Scene search works on physical devices and when the app runs on a Mac as "Designed for iPhone".
- Content recognition is limited to Vision's 1,303-class taxonomy. Concepts outside it (for example, dog breeds Vision does not know) fall back to their parent category, such as "dog".
- Query understanding relies on the bundled dictionary and on-device word embeddings. Words that are unknown to both only match recognized text.
- The shared scheme disables Metal API Validation. When the app runs under the Xcode debugger on a Mac as "Designed for iPhone", Vision's GPU inference trips a Metal validation assertion ("... NOT MTLResourceStorageModeShared") and the app is aborted. The app does not use Metal directly, and builds that are not launched from Xcode never enable this validation.
- Indexing time grows with the size of the library (roughly 0.1 s per image on Apple silicon). Recent photos are indexed first, and search works while indexing is in progress.

## Project layout

```
ImageSearch/
├── ImageSearch.xcodeproj
├── Config/Info.plist                    # URL scheme: tusou://search?q=<keyword>
├── Tools/mdinstall.c                    # Installs a signed build on a USB-connected device without a developer disk image
├── ImageSearchTests/                    # Unit tests (Swift Testing): query parsing, ranking, failed-recognition flags, dictionary
└── ImageSearch/
    ├── App/                             # App entry point, global state, search state, image loading and caching
    ├── Models/ImageRecord.swift         # Index record: labels, recognized text, face count, QR/barcode flags
    ├── Indexing/
    │   ├── ImageAnalyzer.swift          # Vision: classification, Chinese/English OCR, faces, QR codes
    │   ├── PhotoLibraryService.swift    # PhotoKit: authorization, fetching, change observation
    │   ├── ImportedImageStore.swift     # Images imported from Files or the photo picker
    │   ├── IndexingEngine.swift         # Incremental indexing: additions, edits, deletions; newest first; batched writes
    │   └── IndexStore.swift             # SQLite persistence
    ├── Search/
    │   ├── LabelDictionary.swift        # Loads the dictionary; maps Chinese/English terms to Vision labels
    │   ├── QueryParser.swift            # Chinese word segmentation, dates, photo-attribute keywords
    │   ├── SemanticExpander.swift       # On-device word-embedding neighbors
    │   └── SearchEngine.swift           # Scoring, ranking, and match explanations
    ├── Views/                           # Search, Import, Settings, full-screen viewer
    └── Resources/LabelDictionary.txt    # Chinese names and synonyms for all 1,303 Vision labels
```

## Customizing the dictionary

`ImageSearch/Resources/LabelDictionary.txt` maps every Vision label to Chinese names and synonyms, one label per line:

```
label: <display name>|<synonym>|~<related term>|<english synonym>
```

The first entry is the name shown in the app. A `~` prefix marks a related term that matches with a lower weight. Entries made only of ASCII characters are treated as English synonyms.

## Verification status (2026-11-09, Xcode 16.4)

- Builds without code warnings for the iOS Simulator and for arm64 devices / "My Mac (Designed for iPhone)" (signed with a free Personal Team).
- Unit tests: 34 tests covering date parsing, word segmentation, ranking, failed-recognition flags, and the dictionary pass on the iOS Simulator. Reverting the year-boundary or face-detection-flag fix makes the corresponding tests fail.
- iOS Simulator (iPhone 16, iOS 18.6): photo permission prompt, indexing with progress, Chinese and English keyword search, the full-screen viewer, importing from Files, and incremental indexing of photos added while the app is running.
- Scene and object search (seaside, cat, dog, birthday cake, food, sunset, Samoyed, "cat", "beach", QR code) was verified by running the same Swift analysis and search code natively on macOS, because the simulator cannot run the classifier.
- Runs on an Apple silicon Mac as "My Mac (Designed for iPhone)" from Xcode: the local photo library (about 160 photos) was indexed with classification and text recognition, without crashes, after Metal API Validation was disabled. Keyword searches on these real photos returned correct results.
- Physical iPhone: a Release build signed with a free Personal Team was installed on an iPhone 17 Pro running iOS 27.2 through `Tools/mdinstall.c`, and the app works there. Xcode 16.4 recognizes this device but cannot launch the app on it (see Compatibility).
- Limited Access (iOS Simulator): selecting three photos in the permission prompt shows the limited-access notice and indexes only those photos; adding a photo from the notice indexes it incrementally; switching to Full Access in Settings indexes the whole library and removes the notice; reducing access again deletes the index entries of photos that are no longer readable.
- Failed-recognition notices (iOS Simulator, where classification, face detection, and barcode detection cannot run): the home screen lists the steps that did not run, and a search for QR codes reports that 4 images could not be checked.
- The current build, including the failed-recognition flags, was installed on that iPhone the same day as an update that keeps the existing index, and it works there.
