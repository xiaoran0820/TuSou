# TuSou — Offline Image Search for iPhone

TuSou lets you find photos in your iPhone's photo library, and images imported into the app, by typing what is in them, in Chinese or English. It combines Apple Vision (scene classification, text recognition, face and barcode detection) with Apple's MobileCLIP-S2 image–text model, so it can also match free-form visual descriptions such as "red car" or "city at night".
Everything runs on the device: the app contains no networking code and works in Airplane Mode.

- Minimum OS: iOS 17.0 (built with Xcode 16.4 and the iOS 18.5 SDK)
- Frameworks: SwiftUI, PhotoKit, Vision, Core ML, NaturalLanguage, Accelerate, SQLite3; no third-party code libraries
- Data: a Chinese-English glossary of about 80,000 words derived from CC-CEDICT (1.9 MB, CC BY-SA 4.0), used to turn Chinese words into English descriptions for MobileCLIP
- Model: MobileCLIP-S2 in Core ML format (about 190 MB). Its license allows non-commercial research use only, so the model files are not included in this repository (see "On-device image–text model")
- iPhone only; also runs on Apple silicon Macs as an iPhone app ("Designed for iPhone")
- Interface language: Simplified Chinese (the examples in this README are translated)

## What you can search for

| Kind | Example queries (English glosses) | How it works |
| --- | --- | --- |
| Scene and object content | seaside, cat, dog, birthday cake, food, sunset, snowy mountain, car | Apple Vision image classification (1,303 classes) plus a bundled Chinese/English dictionary |
| Free-form visual descriptions and landmarks | red car, city at night, rainy street, dog on the beach, menu boards, Samoyed, Mount Fuji, Tokyo Tower | MobileCLIP-S2 image–text similarity; Chinese words are turned into an English description through a bundled lexicon, the dictionary, and a CC-CEDICT glossary |
| Synonyms and slang | internet slang for cats and dogs, puppy, Shiba Inu, Ragdoll | Dictionary synonyms plus on-device word embeddings (NLEmbedding) |
| Text inside images | invoice, receipt, parking lot, restaurant, amounts, order numbers | Vision text recognition (Simplified Chinese, Traditional Chinese, English; Traditional is normalized to Simplified) |
| Cross-language matches | the Chinese word for "invoice" also finds an English "RECEIPT", and "invoice" finds Chinese invoices | Synonyms of the same label are matched against recognized text |
| Photo attributes | screenshots, favorites, selfies, panoramas, Live Photos, Portrait mode | PhotoKit metadata |
| Other detections | QR codes, barcodes, faces, group photos (three or more faces), images that contain text | Vision detectors |
| Dates | "2024", "October 2025", "March", "today", "yesterday", "last week", "last year" | Capture date; a date written inside an image (a receipt, a screenshot) also matches, ranked below capture-date matches |
| Combined queries | "seaside sunset", "seaside last year" | Images matching every term are shown; images matching only some of the terms are collapsed under a separate button |

Results are ranked by relevance, and each thumbnail shows why it matched (for example "beach · confidence 86%", "visual match · similarity 0.28", or "text contains ..."). The confidence is Vision's classification confidence for that label and the similarity is MobileCLIP's cosine similarity; neither is a calibrated probability that the image is relevant to the query, and the weights that combine labels, recognized text, visual similarity, and metadata are hand-set. Tapping a result opens a full-screen viewer with swipe paging, pinch and double-tap zoom, and an info sheet listing every recognized label and the recognized text.

Each image records which recognition steps (classification, text, faces, QR codes and barcodes, MobileCLIP embedding) are missing, so "nothing found" is never confused with "not checked": search results state how many images a query could not check, and rescanning retries those images.

## On-device image–text model (MobileCLIP)

- Model: Apple's MobileCLIP-S2 Core ML export (image encoder about 68 MB, text encoder about 121 MB). It maps a 256 × 256 image, or a text of up to 77 tokens, to a 512-dimensional embedding. On a device, Core ML decides whether to run it on the CPU, GPU, or Neural Engine; in the iOS Simulator the app limits it to the CPU. On an Apple M4 Pro Mac, encoding one image took about 4.5 ms on average.
- Indexing: each image's embedding is stored as half-precision floats (1 KB per image). When the model becomes available for an existing index, only the embeddings are computed; classification and text recognition are not rerun.
- Queries: an English query is used as written, prefixed with "a photo of" (for example "a photo of red car"). A Chinese query is turned into an English description word by word: a lexicon of common descriptive words (colors, time and weather, actions, people, places, objects, and cat and dog breeds) is tried first, then the English name of the dictionary label, then a glossary of about 80,000 words derived from CC-CEDICT (place names, landmarks, foods, objects), and phrases such as "at night" or "in the rain" are moved after the nouns ("a photo of city at night"). Before the glossary, words outside the lexicon and the dictionary were dropped: the Chinese query for Mount Fuji was split into "Fuji" (untranslated) and "mountain" and searched as "a photo of mountain"; it is now kept whole and searched as "a photo of Mt. Fuji". Glossary words that can be split entirely into words the app already knows are still split, so those words keep matching Vision labels. The glossary keeps one gloss per word and leaves out surnames, words whose senses are all verbs (except "-ing" forms such as "skiing"), and counting words, which had turned a kitchen island into "Nakajima", parking into "pull up", and "two (elephants)" into "both ends"; counting words such as "two" or "a group of" are not search terms either. Words that the lexicon or the glossary translates are left to MobileCLIP instead of being guessed through character substrings or word-embedding neighbors, which had matched "menu" to food, "rain" to cloudy skies, and Mount Fuji to every mountain. The glossary loads in about 25 ms on the Mac, in the background at launch. Dates and photo attributes are left out of the description, and Chinese words that cannot be translated keep matching only through labels and recognized text. The description is shown above the results.
- Fusion: a term covered by the description also counts as matched when the image is similar enough to the description, and the higher of the two scores is used; dates and photo attributes must still match on their own. An image counts as similar when its cosine similarity (1) is at least 0.18, (2) in a search over 30 or more images, is at least z standard deviations above the mean of that search, where z grows with the library so that about five images would pass by chance (2.5 up to a few hundred images, about 3.1 for 5,000, at most 3.5), and (3) is at most 0.10 below the best match of that search. In a query with several terms, a term that has its own detector (a Vision label or face detection) must also be visible on its own: its detector fires, or the image is similar to that word alone (at least 0.15 and 1.5 standard deviations above the mean), unless the whole description matches strongly (0.25 or more); without this, a photo with only people matched "chair dining table" on the strength of the combined description. Results with the same score are ordered by similarity, and a single Chinese character found in recognized text scores below any visual match. The 0.18 floor comes from a five-image check (matching pairs at 0.203 or higher, non-matching pairs at 0.134 or lower). The deviation requirement was 1.5 until 2026-11-10, which admitted roughly the top 7% of any library; the other values were chosen on 2026-11-10 by comparing variants on the two evaluation sets below.
- Tokenizer: CLIP's byte-pair encoding, implemented in Swift with the 48,894 merge rules that CLIP uses. Apple's iOS sample loads all 262,144 rules from the same file, which can merge rare words into tokens that are not in the vocabulary.
- Without the model files the project still builds and its tests pass; the app then falls back to labels and recognized text.
- License: the model weights are licensed under the Apple Machine Learning Research Model License, which permits non-commercial research use only. They are not included in this repository and come from Apple's `apple/coreml-mobileclip` repository on Hugging Face. See `ThirdPartyNotices.md`.

## Evaluation

Retrieval quality was measured with the app's own analysis, storage, and search code, running natively on an Apple M4 Pro Mac, on a small labeled development set and on the COCO 2017 validation set.

### In-app evaluation mode

For manual comparisons on a small set of images, Settings has an evaluation mode, off by default. When it is on, the search screen offers two switches, and the results header names the current choice:

- Retrieval method: the normal fusion; Vision only (labels, recognized text, and dictionary expansion, configuration C below); or MobileCLIP only (every image in scope that has an embedding, ranked by similarity with no threshold, configuration E below).
- Scope: every image, or only the images imported into the app.

Results are listed in score order, with partial matches after the full matches instead of collapsed, and each thumbnail shows its rank and, for imported images, the file name without its extension. Images imported from Files keep their names. Images imported from the photo picker keep their original file name when it is already such a number (IMG_07); the others are named IMG_01, IMG_02, … in the order they were selected, taking the lowest free numbers, and the import message lists the numbers assigned and warns when a number appears twice. To copy a prepared, numbered set from a Mac, the app's Documents folder is shared: it appears in Finder's file sharing and in the Files app, and the app itself stores nothing there. Turning the mode off returns to the normal search.

### Development set (118 images)

The set (`Evaluation/`) was first used only for testing. On 2026-11-10 it was also used to diagnose problems and choose the rule changes described above, so the figures below, measured after those changes, are optimistic.

- Images: 118. 114 come from Wikimedia Commons, found by category search: cats, dogs, beach sunsets, birthday cakes, snowy mountains, red and blue cars, cities at night, cyclists, rainy streets, noodles, flowers, menus, waterfalls, hot air balloons, children playing, basketball, bridges, dogs on beaches, interiors, and forests. Four (a Chinese invoice, a Chinese receipt, an English receipt, and a QR-code poster) were generated for this project.
- Queries: 22 (17 Chinese, 5 English). Each query lists the images that clearly show the concept. The labels were assigned once, by the AI coding assistant that built this feature after viewing every image, and were fixed before any results were computed. Borderline images were left out, for example a toy red car, a statue of a cyclist, and beach photos in which no dog is visible.
- Metrics: Precision@5, Recall@5, and mean reciprocal rank (MRR), averaged over the queries; and the results the app shows by default (the full matches, or every result when nothing matches all terms), summed over the queries, with how many of them are irrelevant.

| Configuration | Precision@5 | Recall@5 | MRR | Shown (irrelevant) |
| --- | --- | --- | --- | --- |
| A. Vision labels | 0.555 | 0.578 | 0.725 | 104 (37) |
| B. A + recognized text | 0.573 | 0.608 | 0.816 | 107 (38) |
| C. B + dictionary synonyms and word-embedding expansion (before MobileCLIP) | 0.609 | 0.657 | 0.809 | 120 (47) |
| D. C + MobileCLIP (current app) | 0.745 | 0.864 | 0.932 | 106 (17) |
| E. MobileCLIP alone, ranking every image (reference) | 0.773 | 0.893 | 0.932 | – |

Before the 2026-11-10 changes, D scored 0.736 / 0.854 / 0.909 and showed 231 results across the 22 queries, 140 of them irrelevant (61%). It now shows 106, 17 of them irrelevant (16%), and 89 relevant images (91 before).

Findings:

- Most irrelevant results came from images that matched only part of a multi-word query. Before the changes, "person riding a bicycle" showed 32 images, 27 of them irrelevant, because every photo with a face matched "person"; "rainy street" showed 35, 33 of them irrelevant. With partial matches collapsed and the stricter similarity requirement, they show 6 images (1 irrelevant) and 3 (1 irrelevant).
- MobileCLIP brings the largest gains on concepts that are neither a Vision label nor found in the recognized text: "menu" (Precision@5 from 0.0 to 0.8), "rainy street" (both relevant images found, none before), "city at night" (0.2 to 0.8), and "dog on the beach" (not found before, now ranked first). Compared with C, D is better on 9 queries, unchanged on 11, and worse on 2.
- Both regressions come from borderline images that MobileCLIP ranks first and that the labels count as not relevant: a toy red car for the Chinese "red car", and a dish whose noodles are hidden for "a bowl of noodles".
- Word order matters for descriptions assembled from Chinese: turned into "a photo of at night city", the Chinese query for "city at night" reached a Precision@5 of 0.6; with prepositional phrases moved after the nouns ("a photo of city at night") it reaches 1.0.
- On this set, MobileCLIP alone (E) scores slightly higher than the fusion (D). The fusion returns only images that match a label or the recognized text or pass the similarity thresholds, so several queries return fewer than five images, while E always ranks every image; top-5 metrics favor the latter, and the set cannot show the cost of always returning something because every query has relevant images. Within the results shown, an irrelevant image still ranks above a relevant one 6 times (20 times before the changes); in all 6, MobileCLIP itself gives the irrelevant image the higher similarity, which ranking rules cannot correct.
- MobileCLIP does not replace the other signals: it cannot reliably read order numbers or amounts, has no access to capture dates or photo attributes such as favorites, and understands only English.

Limitations of the evaluation: 118 images and 22 queries form a small set; collecting images by category makes most queries visually distinct; there is a single annotator, who also wrote the search code; the measurements were taken on a Mac rather than an iPhone; the set contains no personal photos; and it was used to choose the 2026-11-10 changes, so an independent set is needed to confirm them. Per-query results, including the top five images of every configuration, are in `Evaluation/results.json`.

### COCO 2017 validation (5,000 images)

COCO 2017 validation (https://cocodataset.org) has 5,000 everyday photos, 25,014 English captions written by people, and annotations for 80 object categories. Relevance below comes from those annotations, not from this project: an image is relevant to a category when the object covers at least 1% of it, and images where it appears smaller are counted neither way. The images are downloaded separately and are not in this repository; the scripts and results are in `Evaluation/COCO/`.

- Model check: each caption retrieving its image among the 5,000 reaches Recall@1 / @5 / @10 of 44.0 / 69.1 / 78.0%, and each image retrieving its own captions 64.5 / 85.0 / 91.0%. The MobileCLIP paper reports a Recall@1 of 45.4% and 63.4% on COCO, so the Core ML export, tokenizer, and image preprocessing in the app reproduce the published model.
- Chinese object queries: the 80 category names in Chinese and the 30 pairs of categories that most often appear together; 109 have at least five relevant images. "Shown" counts the results the app shows by default.

| Configuration | Precision@10 | Average precision | Shown (irrelevant) | Relevant images shown |
| --- | --- | --- | --- | --- |
| A. Vision labels | 0.834 | 0.470 | 9,103 (22%) | 58% |
| C. Labels, recognized text, and expansion | 0.845 | 0.475 | 9,492 (25%) | 59% |
| D. App before the 2026-11-10 rule changes | 0.835 | 0.598 | 14,882 (41%) | 73% |
| D. Current app | 0.857 | 0.585 | 11,158 (26%) | 67% |
| E. MobileCLIP alone, ranking every image | 0.752 | 0.559 | – | – |

- Chinese phrases: 300 images were sampled at random and one of their captions was rewritten as a short Chinese search phrase and as an English phrase with the same content, both written for this project before any results were computed (`Evaluation/COCO/phrases_zh.tsv`, `phrases_en_zh.tsv`). Ranking all 5,000 images by MobileCLIP similarity, the described image is found at:

| Query | Recall@1 | Recall@10 | Recall@50 |
| --- | --- | --- | --- |
| Original English caption | 43.7% | 76.3% | 94.0% |
| English phrase with the content of the Chinese one | 35.0% | 72.7% | 93.0% |
| Chinese phrase, translated by the app | 18.3% | 47.3% | 77.7% |

Findings:

- The app's word-by-word translation halves top-1 accuracy compared with the same content in English. Apart from wrong glossary senses (fixed for the cases found), it loses numbers, relations, and verbs: "people sitting on a bench" becomes "a photo of bench person".
- Before the rule changes, MobileCLIP raised the share of relevant images shown from 59% to 73% but also showed 41% irrelevant images, most of them weak visual matches. Comparing variants on these queries (`evaluate sweep`): the library-size-dependent deviation requirement and the 0.10 limit cut the irrelevant share for single categories from 35% to 24% while the relevant images shown fell from 76% to 72%; checking each term on its own cut it for category pairs from 44% to 36%; and the strong-match exemption kept long descriptions from losing their image (an English caption's image is in the default results 91% of the time with it, 75% without it). Overall, the image a Chinese phrase describes is in the default results 84% of the time (91% before the changes) and an English caption's 91% (99% before).
- Chinese-CLIP comparison: OFA-Sys Chinese-CLIP ViT-B/16 (MIT license) reads Chinese directly and scored higher on these Chinese phrases (Recall@1 27.7%, Recall@10 63.3%) and object queries (Precision@10 0.779, average precision 0.574, against 0.752 and 0.559 for MobileCLIP alone). Its pretraining data includes translated COCO captions with only COCO's test sets removed, so most of these validation images were probably seen in training, and this comparison favors it. On images neither model was trained on it was not better: 0.718 / 0.835 / 0.947 (Precision@5 / Recall@5 / MRR) on the development set against 0.773 / 0.893 / 0.932 for MobileCLIP alone, and in a Mount Fuji check over 169 images (the development set plus 51 Wikimedia Commons photos of Mount Fuji, similar volcanoes, and Japanese landscapes), each model placed 10 of the 11 clear Fuji photos in its top 11 (Chinese-CLIP without the template; 9 with it). It is about twice the size of MobileCLIP-S2, so the app keeps MobileCLIP (`Evaluation/COCO/eval_chinese_clip.py`).

Limitations: COCO shows everyday scenes and objects, few landscapes or landmarks, and no personal photos; object annotations do not cover colors, scenes, or actions; the thresholds were chosen on these queries, so the current-app figures are optimistic; and the measurements were taken on a Mac.

## Privacy and offline operation

- No network requests anywhere: no URLSession and no Network framework. The compiled binary contains no networking symbols and links neither Network nor CFNetwork.
- Photos whose originals exist only in iCloud ("Optimize iPhone Storage") are never downloaded; the preview that is already on the device is used for analysis and display.
- Imported images are copied into the app's own sandbox. Deleting the app removes them together with the index. The system photo library is never modified. The app's Documents folder is visible in the Files app and in Finder's file sharing so that images can be copied in for import; the app stores nothing there, and the imported copies and the index live in its private Application Support folder.
- Photo access uses read/write authorization, and the usage description explains that all photos are read to build a local index:
  - Full Access: the whole library is indexed and kept in sync incrementally (additions, deletions, edits).
  - Limited Access: only the selected photos are searchable. The app explains this and offers a shortcut to switch to Full Access in Settings, or to add more photos. `PHPhotoLibraryPreventAutomaticLimitedAccessAlert` is set so the system does not keep prompting.
  - Denied: imported images remain searchable, and the app offers a shortcut to Settings.
  - When access is reduced or revoked, index data for photos the app can no longer read is deleted.

## Reliability

- The SQLite index is written before the in-memory index is updated. If a batch cannot be saved, those images are not shown as indexed, the app says so, and they are analyzed again on the next scan. If the database cannot be opened at all, indexing still works for the current session and the app states that nothing will be saved.
- Index entries of removed photos are deleted from the database first. If that fails, the entries are excluded from search and counts, and the deletion is retried on the next scan.
- Rebuilding the index cancels the running scan, waits for it to stop, and starts a new generation, so results from the previous run are never written back.
- Every PhotoKit image request ends. A degraded preview is not treated as the final image, and cancelled or failed callbacks, task cancellation, and a 15-second timeout all finish the request and cancel it in PhotoKit.
- Imported images are tracked by a manifest. A failed manifest write rolls back the import (the copied files are removed) or the deletion (nothing is removed). On launch, files missing from a readable manifest are removed; if the manifest cannot be read, no file is deleted and the images are registered again.
- Cached thumbnails and full-size images are versioned and invalidated when a photo is edited or deleted.
- Search results report separately how many images are not indexed yet, how many could not be read, and how many could not be checked because a recognition step or the embedding is missing.

## Compatibility

The app runs on iOS 17 and every later version without code changes. Apple supports running and debugging from Xcode on a device only with an Xcode version that supports that device's iOS version:

| Device iOS | Xcode | Mac |
| --- | --- | --- |
| 17 – 18 | 16 or later | macOS 15 |
| 26 | 26 or later | macOS Sequoia 15.6 or later |
| 27 | 27 or later | macOS Tahoe 26.6 or later, Apple silicon only |

An older Xcode can still build and sign the app for a newer device. It cannot launch or debug the app on a device whose chip is missing from its developer disk image: Xcode 16.4 fails on iPhone 17 models with "Failed to find image for variant/identity". Such a build can still be installed through the device's standard installation service, which does not use the developer disk image; `Tools/mdinstall.c` does this through MobileDevice.framework.

Builds signed with a free Apple ID expire after seven days. Distribution through TestFlight requires a paid Apple Developer Program membership and a build made with Xcode 26 or later. The MobileCLIP model license permits non-commercial research use only, so a distributed build would have to leave the model out; the app then falls back to labels and recognized text.

## Known limitations

- In the iOS Simulator on Apple silicon Macs, Vision's neural models (scene classification, faces, barcodes) cannot run and fail with "Failed to create espresso context"; only text recognition works. The app flags the affected images and shows a notice. MobileCLIP does run in the simulator, on the CPU.
- MobileCLIP understands English only. Chinese words found in neither the lexicon, the dictionary, nor the glossary (for example some temples and castles) do not reach it; the glossary gives a single English gloss per word, which is not always the sense the user means; and the English description is assembled word by word (only phrases such as "at night" are moved after the nouns), which is less natural than a written sentence. A single Chinese word can also map to an awkward label name, such as "adult cat" for the everyday word for "cat". On COCO this translation halves top-1 accuracy compared with the same content in English (see "Evaluation"); a better on-device translation or a model that reads Chinese without training on the test images would be needed to close that gap.
- The fusion weights and similarity thresholds are hand-set; the 2026-11-10 values were chosen on the development set and on COCO, so confirming them needs an independent set with landscapes and personal photos. In a large library, MobileCLIP-S2 still ranks some irrelevant images above relevant ones: on COCO about a quarter of the results shown for an object are irrelevant, and the stricter rules also hide some relevant images (the share of relevant images shown fell from 73% to 67%).
- Vision's labels are limited to its 1,303-class taxonomy; concepts outside it, such as dog breeds, fall back to their parent category ("dog"). MobileCLIP covers many of these concepts, but only when the query reaches it in English.
- The app is about 196 MB, almost all of it the MobileCLIP model.
- The shared scheme disables Metal API Validation. When the app runs under the Xcode debugger on a Mac as "Designed for iPhone", Vision's GPU inference trips a Metal validation assertion ("... NOT MTLResourceStorageModeShared") and the app is aborted. The app does not use Metal directly, and builds that are not launched from Xcode never enable this validation.
- Indexing time grows with the size of the library (roughly 0.1 s per image on Apple silicon, almost all of it Vision). Recent photos are indexed first, and search works while indexing is in progress.

## Project layout

```
ImageSearch/
├── ImageSearch.xcodeproj
├── Config/Info.plist                    # URL scheme: tusou://search?q=<keyword>
├── Tools/mdinstall.c                    # Installs a signed build on a USB-connected device without a developer disk image
├── Tools/make_glossary.py               # Builds the Chinese-English glossary from a CC-CEDICT release
├── ImageSearchTests/                    # Unit and fault-injection tests (Swift Testing), plus opt-in performance benchmarks
├── eval/                                # Experiment log (LOG.md) and the round-0 queries, results, and failure analysis
├── Evaluation/                          # Retrieval evaluation: image list and credits, labeled queries, Mac evaluation program, results
│   └── COCO/                            # COCO 2017 evaluation: indexing, model check, app check, threshold sweep, Chinese queries and phrases, Chinese-CLIP comparison
├── Licenses/, ThirdPartyNotices.md      # MobileCLIP model license, CC-CEDICT notice, and other third-party notices
└── ImageSearch/
    ├── App/                             # App entry point, global state, search state (including the evaluation mode), image loading and caching
    ├── Models/ImageRecord.swift         # Index record: labels, recognized text, face count, flags, MobileCLIP embedding
    ├── Indexing/
    │   ├── ImageAnalyzer.swift          # Vision: classification, Chinese/English OCR, faces, QR codes
    │   ├── MobileCLIP.swift             # Core ML image and text encoders, cosine similarity
    │   ├── PhotoLibraryService.swift    # PhotoKit: authorization, fetching, change observation
    │   ├── ImportedImageStore.swift     # Images imported from Files or the photo picker
    │   ├── IndexingEngine.swift         # Incremental indexing: additions, edits, deletions, embedding backfill; newest first
    │   └── IndexStore.swift             # SQLite persistence
    ├── Search/
    │   ├── LabelDictionary.swift        # Loads the dictionary; maps Chinese/English terms to Vision labels
    │   ├── QueryParser.swift            # Chinese word segmentation, dates, photo-attribute keywords
    │   ├── SemanticExpander.swift       # On-device word-embedding neighbors
    │   ├── PromptLexicon.swift          # Chinese descriptive words to English, for MobileCLIP descriptions
    │   ├── Glossary.swift               # CC-CEDICT glossary for Chinese words outside the lexicon and the dictionary
    │   ├── CLIPTokenizer.swift          # CLIP byte-pair encoding
    │   └── SearchEngine.swift           # Scoring, fusion, ranking, and match explanations
    ├── Views/                           # Search, Import, Settings, full-screen viewer
    ├── MLModels/                        # MobileCLIP-S2 Core ML packages (not in this repository)
    └── Resources/                       # LabelDictionary.txt (all 1,303 Vision labels), CLIP vocabulary and merge rules, cedict-glossary.tsv
```

## Customizing the dictionary

`ImageSearch/Resources/LabelDictionary.txt` maps every Vision label to Chinese names and synonyms, one label per line:

```
label: <display name>|<synonym>|~<related term>|<english synonym>
```

The first entry is the name shown in the app. A `~` prefix marks a related term that matches with a lower weight. Entries made only of ASCII characters are treated as English synonyms. Chinese words that should reach MobileCLIP in a specific English form are listed in `ImageSearch/Search/PromptLexicon.swift`.

## Performance

Search runs off the main thread. The figures below were measured with a Release build in the iOS Simulator on an Apple M4 Pro Mac, using a synthetic library without MobileCLIP embeddings (10 labels per image, recognized text on about a third of the images), as the median of 6 runs:

| Images | Fastest query ("2024") | Slowest query ("seaside sunset") |
| --- | --- | --- |
| 1,000 | 0.9 ms | 8.3 ms |
| 10,000 | 8.2 ms | 80 ms |
| 50,000 | 51 ms | 410 ms |

Recomputing the index statistics after each saved batch takes about 11 ms for 50,000 images. Search time grows linearly with the library and is dominated by matching dictionary synonyms against recognized text. Libraries well beyond 10,000 photos would benefit from an inverted text index such as SQLite FTS5, which is not implemented. MobileCLIP adds one text encoding per query (cached) and one 512-dimensional dot product per image; on the 118-image evaluation set, a search with MobileCLIP took 4.8 ms (median) on the Mac. The benchmarks are in `ImageSearchTests/PerformanceBenchmarks.swift` and are disabled by default.

## Verification status (2026-11-10, Xcode 16.4)

- Builds without code warnings for the iOS Simulator and for arm64 devices / "My Mac (Designed for iPhone)" (signed with a free Personal Team).
- Unit tests: 87 tests pass on the iOS Simulator; 2 benchmarks are off by default. Besides date parsing, word segmentation, ranking, failed-recognition flags, and the dictionary, they inject faults (failed SQLite writes and deletions mid-transaction, a database that cannot be opened, PhotoKit callbacks that never deliver a final image, rebuilding during a scan, failed manifest writes, a corrupt manifest, cache invalidation after a photo is edited) and cover MobileCLIP: tokenizer output against a reference implementation of CLIP's tokenizer, half-precision storage, migration of an older database, fusion and thresholds, dates and photo attributes that visual similarity cannot satisfy, embedding backfill without re-analysis, the bundled model producing sensible embeddings in the simulator, and the 2026-11-10 search-quality changes (collapsed partial matches, the stricter similarity requirement, similarity tie-breaks, weak single-character text matches, no guessing for lexicon words, word order), the glossary (loading, gloss selection and skipped senses, Mount Fuji kept whole and translated, words made of known words still split, counting words dropped), the COCO-calibrated rules (the library-size-dependent deviation requirement, the 0.10 limit, per-term checks, and the strong-match exemption), and the evaluation mode (ranking by similarity alone, Vision only without visual similarity, and picker numbering, including numbered original names). Six key reliability fixes were each reverted temporarily, and each time the corresponding test failed; reverting the six search-quality changes together made exactly their six tests fail; reverting the glossary's translation fallback, its no-guessing rule, or its splitting rule each made a glossary test fail; reverting the COCO-calibrated rules and the counting-word filter together made their tests fail.
- A copy of the project without the model files, as in this repository, builds without warnings, and its tests pass with the bundled-model test skipped.
- Retrieval evaluation on a Mac: see "Evaluation" (development set and COCO 2017 validation).
- Landmark spot check on a Mac, with the app's full search over the 118 evaluation images plus 12 Wikimedia Commons images (three photos of Mount Fuji, two Fuji prints, a view of its crater, and six similar volcanoes): without the glossary, the Chinese query for Mount Fuji was searched as "a photo of mountain" and showed 16 images, only partial matches, with the Fuji photos at positions 9 and 10; with it, the query is searched as "a photo of Mt. Fuji" and shows 4 images, the three Fuji photos and Mayon Volcano, which looks almost identical.
- iOS Simulator, current build: after Full Access was granted, the 33 photos in the simulator's library were indexed and all 33 MobileCLIP embeddings were computed on the CPU. With Vision's classifier unavailable there, the Chinese queries for "cat" and "street at night" returned exactly the library's three cat photos and its two neon-lit night streets, through visual similarity alone. With the search-quality changes, "cat yesterday" shows the three cats and collapses the 19 photos that match only the date under a button that expands them.
- iOS Simulator, evaluation mode: three photos picked from the library in a chosen order were imported as IMG_01, IMG_02, and IMG_03 in that order. With the scope set to imported images, MobileCLIP only listed all three for the Chinese query for "bird", ranked by similarity (0.244, 0.196, and 0.122 for a parrot, an owl, and a basketball), while Vision only found none, because Vision's classifier cannot run in the simulator. The switches kept their settings after the app was relaunched. A library photo whose original file name was IMG_05 kept that number while the other photo in the same selection received IMG_01; the Files picker listed the app's shared folder, and two images imported from it kept their names.
- iOS Simulator (iPhone 16, iOS 18.6), checked before the reliability fixes and MobileCLIP: photo permission prompt, indexing with progress, Chinese and English keyword search, the full-screen viewer, importing from Files, incremental indexing of photos added while the app is running, and Limited Access (the notice, adding photos, switching to Full Access, and deleting index entries when access is reduced).
- Runs on an Apple silicon Mac as "My Mac (Designed for iPhone)" from Xcode, checked before the reliability fixes and MobileCLIP: the local photo library (about 160 photos) was indexed with classification and text recognition, without crashes, after Metal API Validation was disabled.
- Physical iPhone (iPhone 17 Pro, iOS 27.2): the build with the reliability fixes and MobileCLIP (Release, 194 MB) was installed through `Tools/mdinstall.c` on 2026-11-10, over the index of the previous build, and works there. On a personal library its semantic search showed many irrelevant images, which led to the search-quality changes above; searching the Chinese name of Mount Fuji also ranked other mountains first, which led to the glossary. Builds with those changes were installed the same day. Even then, the query for Mount Fuji showed about 100 results, mostly landscapes with sky, sea, and distant mountains, which led to the COCO evaluation and the calibrated rules; the build with them, the evaluation mode, and file sharing (Release, 197 MB) was installed the same evening. Read-only checks over USB confirmed that the device lists the installed app with file sharing enabled and that the documents service Finder uses for file sharing opens its Documents folder, which was empty at the time. Later that evening, the 40 test images were copied into that folder through Finder and imported from Files. Round 0 of the manual evaluation was then run on the device in the evaluation mode: 50 queries over these images, each searched once with Vision only and once with MobileCLIP only, and each method's top five results (or fewer, when fewer were found) were recorded in `eval/round0/results.csv`. Unlike in the simulator, Vision only found images by their visual content there, for example for the Chinese queries for "airplane", "flower", and "food".
