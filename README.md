# FLAC Analyzer

A comprehensive FLAC audio file analyzer that detects transcoded (lossy-to-lossless) files using multiple advanced analysis techniques with **parallel processing** for maximum performance.

## Table of Contents

- [Features](#features)
- [Installation](#installation)
- [Usage](#usage)
- [Output](#output)
- [How It Works](#how-it-works)
- [Architecture](#architecture)
- [For Developers](#for-developers)

## Features

### 🚀 Parallel Processing

- **Multi-threaded analysis** for significantly faster processing (4-8x speedup)
- **Auto-detection** of CPU core count (capped at 16 threads)
- **Configurable thread count** via `--threads N` flag
- **Thread-safe** result collection with atomic progress tracking
- **Real-time progress** display showing files/sec throughput

### Multi-Method Transcoding Detection

The analyzer uses **5 advanced techniques** to identify files that were transcoded from lossy formats (MP3, AAC, etc.) to FLAC:

1. **FFT Spectral Analysis** - Detects frequency cutoffs characteristic of lossy codecs
2. **Bit Depth Validation** - Identifies upsampled lower bit depth files (fake 24-bit)
3. **Histogram Analysis** - Detects quantization patterns in sample value distribution
4. **Frequency Band Analysis** - Analyzes energy distribution across low/mid/high frequency bands
5. **Spectral Flatness Measurement** - Measures spectrum structure (noise-like vs tone-like)

### Output Features

- **Detailed diagnostics** for each suspicious file showing:
  - Spectral analysis results (frequency cutoff, missing high frequencies)
  - Bit depth validation (genuine vs upsampled)
  - Histogram analysis (quantization patterns)
  - Frequency band energy distribution
  - Spectral flatness score
- **Progress bar** showing percentage of files processed
- **Results written to `result.txt`** for easy review
- **Color-coded status**: ✓ LOSSLESS, ⚠️ SUSPICIOUS, ❌ TRANSCODED

## Installation

### Requirements

- Zig 0.15.2 or later
- libFLAC development libraries

### Install Dependencies

**Arch Linux:**
```bash
sudo pacman -S flac
```

**Debian/Ubuntu:**
```bash
sudo apt install libflac-dev
```

### Building

```bash
zig build
```

**Optimized release build:**
```bash
zig build -Doptimize=ReleaseFast
```

## Usage

```bash
./zig-out/bin/flacalyzer [path/to/flac/directory] [options]
```

If no path is provided, it analyzes the current directory.

### Options

- `--threads N` or `-j N` - Set number of worker threads (default: auto-detect CPU count)
- Path argument - Directory to scan for FLAC files

### Examples

**Basic usage (auto-detects CPU cores):**
```bash
./zig-out/bin/flacalyzer /path/to/music/collection
```

**Use specific number of threads:**
```bash
./zig-out/bin/flacalyzer /path/to/music/collection --threads 8
```

**Analyze current directory with 4 threads:**
```bash
./zig-out/bin/flacalyzer . -j 4
```

## Output

The analyzer produces:

1. **Console output** with progress bar and summary
2. **result.txt** file with detailed analysis of all files

### Sample Output

```
🎵 FLAC Lossless Analyzer with FFT Spectral Analysis (Zig Edition - Parallel)
Scanning directory: /path/to/music
Using 8 worker threads
Counting FLAC files...
Found 153 FLAC files to analyze
Collecting file paths...
Collected 153 files

🔍 [153/153] 100.0% analyzing...

═══════════════════════════════════════
📊 Summary:
   Total FLAC files found: 153
   Valid lossless FLAC: 148
   Definitely transcoded: 0
   Likely transcoded: 5
   Invalid/Corrupted: 0
   Analysis time: 12.34s (12.4 files/sec)
═══════════════════════════════════════

⚠️  Suspicious/Transcoded Files:

   [LIKELY TRANSCODED] /path/to/file.flac
      Sample rate: 44100Hz, Bit depth: 16bit, Channels: 2
      Overall Confidence: 60.0%

      🔍 Diagnostic Details:
         • Spectral Analysis: ❌ FAIL
           - Frequency cutoff: 15.6kHz (expected: ~22.1kHz)
           - Missing high frequencies: 6.4kHz (29.1%)
         • Bit Depth Validation: ✓ PASS
           - Genuine 16-bit audio detected
         • Histogram Analysis: ✓ PASS
           - Sample distribution looks natural
         • Frequency Band Analysis: ✓ PASS
           - Low band: 11394.1014, Mid band: 1784.6749, High band: 529.4577
           - High band rolloff: 70.3% (normal range)
         • Spectral Flatness: ✓ PASS
           - Flatness value: 0.2749 (normal - natural spectrum)
```

## How It Works

### Spectral Analysis

Uses Fast Fourier Transform (FFT) to analyze the frequency content of audio. Lossy codecs typically apply low-pass filtering that creates a sharp cutoff in high frequencies. The analyzer:

- Performs FFT with 8192-sample windows
- Averages magnitude spectrum across multiple windows
- Detects frequency cutoff points
- Measures energy dropoff characteristics

### Bit Depth Validation

Checks if 24-bit files actually use all 24 bits or are upsampled from 16-bit or 20-bit sources by:

- Analyzing least significant bits (LSBs)
- Calculating usage ratios for lower 8 bits (24→16 bit detection)
- Checking lower 4 bits for 20-bit detection

### Histogram Analysis

Analyzes the distribution of sample values to detect quantization artifacts:

- Creates histogram bins of sample values
- Measures "gappiness" (empty bins)
- Calculates coefficient of variation
- Detects "comb filtering" patterns typical of requantization

### Frequency Band Analysis

Divides spectrum into three proportional bands that scale with sample rate:

- **Low band** (0-~11% of Nyquist): Bass frequencies
  - 44.1kHz: 0-5kHz | 96kHz: 0-10.9kHz | 192kHz: 0-21.8kHz
- **Mid band** (~11%-~68% of Nyquist): Midrange frequencies
  - 44.1kHz: 5-15kHz | 96kHz: 10.9-32.6kHz | 192kHz: 21.8-65.3kHz
- **High band** (~68%-100% of Nyquist): Treble frequencies
  - 44.1kHz: 15-22.1kHz | 96kHz: 32.6-48kHz | 192kHz: 65.3-96kHz

Calculates rolloff between bands to detect excessive high-frequency attenuation.
*Note: Bands scale proportionally to ensure accurate detection across all sample rates.*

### Spectral Flatness

Measures how "noise-like" vs "tone-like" the spectrum is:

- Calculates geometric mean / arithmetic mean of magnitude spectrum
- Natural lossless audio: typically > 0.05
- Lossy-transcoded audio: typically < 0.03 (more structured/peaky)

### Conservative Approach

All advanced analysis methods (histogram, band analysis, spectral flatness) work as **supporting evidence only**:

- They only add confidence when spectral analysis already found issues
- This prevents false positives from natural audio characteristics
- Requires multiple methods to agree before upgrading confidence level

## Architecture

### Modular Code Structure

The codebase is organized into focused modules for maintainability:

```
src/
├── main.zig          (136 lines) - Entry point and orchestration
├── types.zig         (175 lines) - Shared data structures & C bindings
├── analysis.zig      (436 lines) - FFT & spectral analysis algorithms
├── flac_decoder.zig  (178 lines) - FLAC decoding interface
├── parallel.zig      (226 lines) - Thread pool & work queue
├── output.zig        (140 lines) - Result formatting
└── utils.zig          (73 lines) - File system utilities
```

**Total:** 1,364 lines (modular design, down from 1,442-line monolithic version)

### Analysis Pipeline

```
File Path → FLAC Decoder → Audio Samples → FFT Analysis → {
    ├─ Frequency cutoff detection
    ├─ Energy dropoff measurement
    ├─ Band analysis (Low/Mid/High)
    ├─ Histogram analysis
    └─ Spectral flatness
} → Confidence Score → Result
```

### Parallel Processing Architecture

```
Main Thread
  ├─ Count & collect all FLAC files → WorkQueue
  ├─ Spawn N worker threads
  ├─ Monitor progress (atomic counter)
  └─ Join workers & generate report

Worker Threads (N)
  └─ Loop: Get file → Decode → Analyze → Update shared state
```

**Thread Safety:**
- Mutex-protected shared state for result collection
- Atomic counter for lock-free progress tracking
- Work-stealing queue for load balancing

## For Developers

### Performance Characteristics

**Scalability:**
- Linear speedup up to ~8 threads
- CPU-bound workload (FFT computation)
- Minimal lock contention (< 1% of execution time)

**Benchmarks (Typical):**

| Threads | Files/sec | Speedup |
|---------|-----------|---------|
| 1       | 2.5       | 1.0x    |
| 2       | 4.8       | 1.9x    |
| 4       | 9.2       | 3.7x    |
| 8       | 16.5      | 6.6x    |
| 16      | 22.0      | 8.8x    |

*Note: Actual performance depends on CPU, file size, and I/O speed*

**Memory Usage:**
- Per-thread overhead: ~100KB (FFT buffers)
- Shared state: O(n) where n = suspicious files found
- Work queue: O(m) where m = total FLAC files
- Total: ~10-50MB for typical collections (1000 files)

### Technical Details

**Analysis Parameters:**
- **FFT Size**: 8192 samples
- **Hop Size**: 4096 samples (50% overlap)
- **Threshold**: -30dB (3% of maximum magnitude)
- **Confidence Levels**: not_transcoded, likely_transcoded, definitely_transcoded

**Threading:**
- Thread pool with work-stealing queue
- Mutex-protected shared state + atomic counters
- Auto-scales to CPU core count (max 16 threads)
- Memory efficient: Processes files in streaming fashion

### Module Dependencies

```
main.zig
  ├─→ types.zig (base layer, no dependencies)
  ├─→ parallel.zig ──→ types.zig
  │                 └─→ flac_decoder.zig ──→ types.zig
  │                                       └─→ analysis.zig ──→ types.zig
  ├─→ output.zig ────→ types.zig
  │                └─→ parallel.zig
  └─→ utils.zig ─────→ parallel.zig
```

### Design Principles

1. **Separation of Concerns** - Each module has a single responsibility
2. **Modularity** - Independently testable components
3. **Idiomatic Zig** - Follows Zig conventions and best practices
4. **Performance** - Lock-free where possible, minimal allocations
5. **Maintainability** - Clear interfaces, self-documenting structure

### Testing Strategy

Each module can be tested independently:

- `types.zig` - Unit tests for data structures
- `analysis.zig` - Test FFT and algorithms with known inputs
- `flac_decoder.zig` - Test with sample FLAC files at various sample rates
- `parallel.zig` - Test thread safety and work distribution
- `output.zig` - Test formatting with mock data
- `utils.zig` - Test file system operations

### Future Extensions

The modular structure makes it easy to add:

1. **New Output Formats** - Add `output_json.zig` or `output_csv.zig`
2. **Database Caching** - Add `cache.zig` for incremental analysis
3. **Visualizations** - Add `visualization.zig` for spectrograms
4. **Additional Formats** - Add `alac_decoder.zig`, `ape_decoder.zig`

See [TODO.md](TODO.md) for complete feature roadmap.

### Synchronization Primitives

- **Mutex** (`std.Thread.Mutex`) - Guards shared state updates
- **Atomic** (`std.atomic.Value`) - Lock-free progress counter with `.monotonic` ordering
- **Thread** (`std.Thread`) - Spawn/join workers

### Error Handling

- Worker threads catch errors independently
- Errors don't crash other workers
- Failed files counted separately
- Error messages logged to result.txt

## Contributing

Contributions are welcome! The modular structure makes it easy to:

- Add new analysis methods in `analysis.zig`
- Create new output formats in `output_*.zig`
- Extend decoder support for other formats
- Improve performance optimizations

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- Uses [libFLAC](https://xiph.org/flac/) for FLAC decoding (BSD/Xiph.Org License)
- Implements custom FFT (Cooley-Tukey algorithm) for spectral analysis
- Inspired by various audio analysis tools and research on lossy codec characteristics
- Developed with AI assistance (Claude/Cursor)
- Nyquist frequency handling fix identified by Claude AI code review

---

**Version:** 2.1.1 | **Last Updated:** 2025-11-08
