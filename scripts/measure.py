#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.14"
# dependencies = [
#     "rich",
# ]
# ///

import argparse
import csv
import os
import re
import subprocess
import sys
import time
from pathlib import Path
import statistics
from typing import Optional, Tuple, List
from rich import print


def parse_oavif_output(stderr_output: str) -> Optional[int]:
    """
    Parse oavif stderr output to extract passes information.
    """
    passes_match = re.search(r"(\d+)\s+passes?", stderr_output)
    passes: int | None = int(passes_match.group(1)) if passes_match else None

    return passes


def process_image(
    oavif_path: str,
    image_path: Path,
    output_dir: Path,
    tolerance: Optional[float] = None,
) -> Tuple[Optional[float], Optional[int], Optional[str]]:
    """
    Process a single image with oavif and return encoding time and passes.
    """
    image_name: str = Path(image_path).stem
    avif_output: Path = Path(output_dir) / f"{image_name}.avif"

    cmd: list[str] = [oavif_path]
    if tolerance is not None:
        cmd.extend(["--tolerance", str(tolerance)])
    cmd.extend([str(image_path), str(avif_output)])
    try:
        start_time: float = time.time()
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        end_time: float = time.time()

        encoding_time_ms: float = (end_time - start_time) * 1000

        stderr_output: str = result.stderr
        passes: int | None = parse_oavif_output(stderr_output)
        return encoding_time_ms, passes, None
    except subprocess.CalledProcessError as e:
        return None, None, f"Error processing {image_path}: {e}"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Measure oavif performance on a directory of images"
    )
    parser.add_argument("images_dir", help="Directory containing input images")
    parser.add_argument("oavif_path", help="Path to oavif binary")
    parser.add_argument("output_csv", help="Output CSV file path")
    parser.add_argument(
        "--tolerance", type=float, help="Tolerance value for oavif encoding"
    )
    args = parser.parse_args()

    if not Path(args.oavif_path).exists():
        print(f"Error: oavif binary not found at {args.oavif_path}")
        sys.exit(1)

    temp_output_dir: Path = Path("temp_avif_output")
    temp_output_dir.mkdir(exist_ok=True)

    images_dir = Path(args.images_dir)
    image_extensions: set[str] = {".png", ".jpg", ".jpeg"}
    image_files: list[Path] = [
        f
        for f in images_dir.iterdir()
        if f.is_file() and f.suffix.lower() in image_extensions
    ]

    if not image_files:
        print(f"No images found in {images_dir}")
        sys.exit(1)

    results: List[Tuple[str, str, int]] = []
    encoding_times: List[float] = []
    passes_list: List[int] = []

    for image_file in image_files:
        print(f"Processing {image_file.name}...")
        encoding_time, passes, error = process_image(
            args.oavif_path, image_file, temp_output_dir, args.tolerance
        )

        if error:
            print(error)
            continue

        if encoding_time is not None and passes is not None:
            results.append((image_file.name, f"{encoding_time:.2f}", passes))
            encoding_times.append(encoding_time)
            passes_list.append(passes)
        else:
            print(f"Failed to parse output for {image_file.name}")

    with open(args.output_csv, "w", newline="") as csvfile:
        writer = csv.writer(csvfile)
        writer.writerow(["Image", "Encoding Time (ms)", "Passes"])
        writer.writerows(results)

    if encoding_times and passes_list:
        avg_encoding_time: float = sum(encoding_times) / len(encoding_times)
        encoding_time_stddev: float = (
            statistics.stdev(encoding_times) if len(encoding_times) > 1 else 0
        )
        avg_passes: float = sum(passes_list) / len(passes_list)
        max_passes: int = max(passes_list)
        min_passes: int = min(passes_list)
        passes_stddev: int = (
            statistics.stdev(passes_list) if len(passes_list) > 1 else 0
        )

        print(f"\nStatistics:")
        print(
            f"Average encoding time: {avg_encoding_time:.2f} ms ± {encoding_time_stddev:.2f}"
        )
        print(
            f"Average passes: {avg_passes:.2f} ± {passes_stddev:.2f} (max: {max_passes} min: {min_passes})"
        )
        print(f"Results written to {args.output_csv}")
    else:
        print("No valid results to calculate statistics")


if __name__ == "__main__":
    main()
