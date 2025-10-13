# oavif

`oavif` is a tool for target quality AVIF encoding using [fssimu2](https://github.com/gianni-rosato/fssimu2), a fast perceptual image quality metric.

## Usage

```sh
oavif | [version]

usage:  oavif [options] <in> <out.avif>

options:
 -h, --help
    show this help
 -v, --version
    show version information
 -s, --speed u8
    encoder speed (0..10) [9]
 -t, --score-tgt f64
    target SSIMULACRA2 score (0..100) [80]
 --quality-alpha u8
    quality factor for alpha (0..100=lossless) [100]
 --max-threads u8
    maximum number of threads to use (1..255) [1]
 --tile-rows-log2 u8
    tile rows log2 (0..6) [0]
 --tile-cols-log2 u8
    tile columns log2 (0..6) [0]
 --auto-tiling 0/1
    enable automatic tiling [1]
 --tune str
    libaom tuning mode (ssim, iq, ssimulacra2) [iq]
 --tenbit 0/1
    force 10-bit AVIF output [1]
 --tolerance f64
    target quality error tolerance (1..100) [2]
 --max-pass u8
    maximum search passes (1..12) [6]
 -q, --quality u8
    quantizer (0..100), bypasses search

Input image formats: PNG, PAM, JPEG, WebP, or AVIF
```

A script is included in the `scripts/` directory to test oavif's performance on a directory of images.
```
./scripts/measure.py --help
usage: measure.py [-h] [--tolerance TOLERANCE]
                  images_dir oavif_path output_csv

Measure oavif performance on a directory of images

positional arguments:
  images_dir            Directory containing input images
  oavif_path            Path to oavif binary
  output_csv            Output CSV file path

options:
  -h, --help            show this help message and exit
  --tolerance TOLERANCE
                        Tolerance value for oavif encoding
```

## Compilation

Compilation requires:
- Zig 0.15.1
- libavif
- libwebp
- libjpeg-turbo

```sh
git clone https://github.com/gianni-rosato/oavif
cd oavif
zig build --release=fast
```

The `oavif` binary will be emitted to `zig-out/bin`. To install system-wide on macOS or Linux, run the following command as root:

```sh
zig build --release=fast --prefix /usr/local
```

## License

`oavif` is governed by the [Apache 2.0 License](./LICENSE).
