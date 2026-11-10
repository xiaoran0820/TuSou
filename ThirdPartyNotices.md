# Third-Party Notices

## MobileCLIP-S2 model weights (Apple)

`ImageSearch/MLModels/mobileclip_s2_image.mlpackage` and `ImageSearch/MLModels/mobileclip_s2_text.mlpackage` are the Core ML exports that Apple publishes in the `apple/coreml-mobileclip` repository on Hugging Face. They are used unmodified and are not included in this repository.

Apple Machine Learning Research Model is licensed under the Apple Machine Learning Research Model License Agreement.

The agreement permits use for non-commercial research purposes only and excludes commercial use and product development. The full text is in `Licenses/MobileCLIP-model-license.txt`.

## CLIP tokenizer

`ImageSearch/Search/CLIPTokenizer.swift` implements the byte-pair encoding of OpenAI CLIP's `simple_tokenizer`. Its Swift structure is based on Hugging Face swift-coreml-transformers (Apache License 2.0) as modified in Apple's ml-mobileclip iOS sample (MIT License), and was rewritten for this project; the file header lists the changes. License texts: `Licenses/ml-mobileclip-LICENSE.txt`, and `Licenses/ml-mobileclip-ACKNOWLEDGEMENTS.txt`, which contains the Apache License 2.0.

`ImageSearch/Resources/clip-vocab.json` and `ImageSearch/Resources/clip-merges.txt` come from Apple's ml-mobileclip iOS sample and contain OpenAI CLIP's vocabulary (MIT License, Copyright (c) 2021 OpenAI). `clip-merges.txt` is truncated to the first 48,894 merge rules, the number CLIP uses.

## CC-CEDICT Chinese-English glossary

`ImageSearch/Resources/cedict-glossary.tsv` is derived from CC-CEDICT, the community-maintained Chinese-English dictionary published by MDBG (https://www.mdbg.net/chinese/dictionary?page=cc-cedict), which builds on CEDICT, Copyright (C) 1997, 1998 Paul Andrew Denisowski. CC-CEDICT is licensed under the Creative Commons Attribution-ShareAlike 4.0 International License (https://creativecommons.org/licenses/by-sa/4.0/).

`Tools/make_glossary.py` keeps simplified headwords of two or more characters, each with one cleaned English gloss. The glossary is distributed under the same license. The first line of the file records the CC-CEDICT release it was made from; `Licenses/CC-CEDICT-NOTICE.txt` contains the original notice and the list of changes.

## COCO 2017 annotations

`Evaluation/COCO/phrases_zh.tsv` and the COCO result files contain image IDs, category names, and 300 English captions from the COCO 2017 validation annotations (https://cocodataset.org), which the COCO Consortium licenses under the Creative Commons Attribution 4.0 License (https://creativecommons.org/licenses/by/4.0/). The Chinese phrases in that file were written for this project. The COCO images are not included in this repository; they are downloaded separately, are used here only for research evaluation, and remain subject to the Flickr terms of use.

## Evaluation images

The images used in `Evaluation/` are downloaded from Wikimedia Commons by `Evaluation/fetch_images.py` and are not included in this repository. Each image keeps its own author and license, listed in `Evaluation/image_credits.tsv`. Four receipt and QR-code images were generated for this project.
