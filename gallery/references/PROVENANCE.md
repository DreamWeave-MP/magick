# Reference images

References the gallery paints from. They are read by `tools/demos.jsl` only and are not part of the
package (`jess.toml` does not include `gallery/`).

## mona-lisa-500.png

- **Work:** *Mona Lisa*, Leonardo da Vinci, oil on poplar panel, between 1503 and 1506, Musée du
  Louvre. Leonardo died in 1519; the painting has been in the public domain for centuries.
- **Photograph:** Wikimedia Commons,
  [File:Mona_Lisa,_by_Leonardo_da_Vinci,_from_C2RMF_retouched.jpg](https://commons.wikimedia.org/wiki/File:Mona_Lisa,_by_Leonardo_da_Vinci,_from_C2RMF_retouched.jpg),
  "Cropped and relevelled from File:Mona Lisa, by Leonardo da Vinci, from C2RMF.jpg", originally the
  C2RMF high-definition imaging showcase. Commons marks it **Public domain** (license and usage
  terms "Public domain", `Copyrighted: False`): a faithful photographic reproduction of a
  two-dimensional public-domain work carries no new copyright under Commons' policy and in the
  United States (*Bridgeman Art Library v. Corel Corp.*, 1999).
- **Original file:** 7479 × 11146, SHA-1 `4ba2f28c16b265bcde00336a8e0b1251e4a258da` (as the Commons
  API reports it).
- **What was fetched (2026-11-26):** Wikimedia's own 500-pixel thumbnail,
  `https://upload.wikimedia.org/wikipedia/commons/thumb/e/ec/Mona_Lisa%2C_by_Leonardo_da_Vinci%2C_from_C2RMF_retouched.jpg/500px-Mona_Lisa%2C_by_Leonardo_da_Vinci%2C_from_C2RMF_retouched.jpg`,
  a 500 × 745 baseline JPEG of 117,341 bytes, SHA-256
  `12f3a161df70534079eb582149d17862f83b86987232d9c944e81123499e4389`.
- **How it became this file:** decoded once, with no resampling, color change or crop, because
  Magick reads PNG and not JPEG:

  ```sh
  magick thumb.jpg -strip -define png:compression-level=9 PNG24:mona-lisa-500.png
  magick compare -metric AE thumb.jpg mona-lisa-500.png null:   # 0: every pixel the same
  ```

  ImageMagick 7.1.2-35. This is format conversion of the input, not rendering; every pixel the
  painting is made of is drawn by Magick.
- **This file:** 500 × 745, 736,017 bytes, SHA-256
  `f8054a8d3a9a7a8c26fe959d49fe373584a7ca553d7ac4b862e95528ea7ea402`. `tools/demos.jsl` refuses
  to paint from a file with any other checksum.
