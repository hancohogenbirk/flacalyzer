# TODO - Future Features & Improvements

This document tracks potential features, improvements, and ideas for the FLAC Analyzer project.

## 🔥 High Priority Features

### 1. JSON/CSV Export + Analysis Database Cache 💾📊

**Why it's exciting:** Makes the tool production-ready and automation-friendly

**Features:**
- [ ] Export results in machine-readable formats (JSON, CSV) for integration with scripts/tools
- [ ] SQLite database to cache analysis results (avoid re-analyzing unchanged files)
- [ ] Incremental analysis mode - only check new/modified files
- [ ] Query interface to search previous results
- [ ] File hash tracking (SHA256) to detect changes

**CLI Flags:**
- `--format json|csv|txt` - Output format selection
- `--cache` - Enable database mode
- `--incremental` - Only analyze changed files
- `--db-path <path>` - Custom database location

**Impact:** Makes tool practical for CI/CD pipelines, repeated use, and music library management

**Technical Approach:**
- Add `output_json.zig` and `output_csv.zig` modules
- Add `cache.zig` module for SQLite integration
- Use SHA256 hashing for file change detection
- Store analysis results with timestamps

**Estimated Effort:** Medium (3-5 days)

---

### 2. Visual Spectrum Analysis & Spectrograms 📈🎨

**Why it's exciting:** Makes analysis results visually verifiable and easier to understand

**Features:**
- [ ] Generate PNG spectrograms for suspicious files
- [ ] Frequency response plots showing the cutoff points
- [ ] Side-by-side comparisons of good vs transcoded files
- [ ] HTML report with embedded visualizations
- [ ] Waterfall spectrograms showing frequency content over time

**CLI Flags:**
- `--visualize` - Generate visualizations for suspicious files
- `--viz-dir <path>` - Output directory for visualizations
- `--html-report` - Generate HTML report with embedded images

**Impact:** Helps users understand *why* a file is flagged, educational value

**Technical Approach:**
- SVG or PNG generation using simple plotting libraries
- Optional feature (not required for basic use)
- Can use `stb_image_write` for PNG output (single header library)
- Generate waterfall spectrograms showing frequency content over time
- Add `visualization.zig` module

**Estimated Effort:** Medium-High (4-7 days)

---

## 🔧 Code Quality & Quick Wins

These are smaller improvements that can be done quickly to polish the existing codebase.

### 3. Code Quality Improvements

**Code Readability:**
- [ ] Create `SpectrumResult` struct - Replace 5-tuple return from `analyzeSpectrum()` with named struct for better readability
- [ ] Simplify FFT bit-reversal - Current implementation works but could use more standard approach

**Estimated Effort:** Low (1 day)

---

### 4. Audio Processing Enhancements

**Features:**
- [ ] Average L+R channels - Currently only analyzes left channel; averaging both channels would be more accurate for mid-side stereo recordings
- [ ] Add DC removal filter - Apply high-pass filter before FFT to remove DC offset (Hann window currently mitigates this)
- [ ] Make analysis duration configurable - Expose `samples_to_collect` as CLI option instead of hardcoding
- [ ] Add 32-bit bit depth detection - Support for 32-bit integer FLAC files (rare but complete)

**Estimated Effort:** Low-Medium (2-3 days)

---

### 5. CLI & UX Polish

**Features:**
- [ ] Input validation for CLI arguments:
  - Threshold values in valid range (0.0-1.0)
  - Thread count > 0 and ≤ CPU count
  - Path existence before processing
- [ ] Better error messages - Ensure unknown flags trigger clear errors
- [ ] Configurable detection thresholds - Allow users to tune sensitivity via CLI

**Estimated Effort:** Low (1-2 days)

---

## 🎯 Medium Priority Features

### 6. Source Format Detection 🔍

**Description:** Try to identify the original lossy format based on frequency fingerprints

**Features:**
- [ ] MP3 detection (typically 16kHz cutoff for lower bitrates, 18-20kHz for higher)
- [ ] AAC detection (variable cutoff, smoother rolloff)
- [ ] Ogg Vorbis detection (unique spectral characteristics)
- [ ] WMA detection
- [ ] Report likely source format in output

**Technical Approach:**
- Analyze cutoff frequency patterns
- Measure rolloff characteristics
- Check for codec-specific artifacts
- Statistical classification based on known patterns

**Estimated Effort:** Medium (2-4 days)

---

### 7. Auto-Organize Mode 📂

**Description:** Automatically move/sort files into good/suspicious/bad directories

**Features:**
- [ ] `--organize` flag to enable auto-organization
- [ ] Configurable directory structure
- [ ] Dry-run mode (`--dry-run`) to preview changes
- [ ] Option to copy instead of move
- [ ] Preserve directory structure option

**Example Structure:**
```
output/
├── lossless/        # Genuine FLAC files
├── suspicious/      # Likely transcoded
├── transcoded/      # Definitely transcoded
└── invalid/         # Corrupted/invalid files
```

**CLI Flags:**
- `--organize` - Enable file organization
- `--org-dir <path>` - Base directory for organized files
- `--copy` - Copy instead of move
- `--preserve-structure` - Maintain source directory structure
- `--dry-run` - Show what would be done without doing it

**Estimated Effort:** Low-Medium (2-3 days)

---

### 8. Watch Mode 👀

**Description:** Monitor a directory and analyze new files as they appear

**Features:**
- [ ] `--watch` flag to enable watch mode
- [ ] Real-time analysis of new FLAC files
- [ ] Configurable polling interval
- [ ] Integration with auto-organize mode
- [ ] Desktop notifications for findings (optional)

**CLI Flags:**
- `--watch` - Enable watch mode
- `--interval <seconds>` - Polling interval (default: 5)
- `--notify` - Enable desktop notifications

**Technical Approach:**
- Use inotify (Linux) / FSEvents (macOS) / ReadDirectoryChangesW (Windows)
- Or simple polling for cross-platform compatibility
- Integration with existing analysis pipeline

**Estimated Effort:** Medium (3-4 days)

---

### 9. Batch Report Generation 📄

**Description:** Generate comprehensive reports for entire music collections

**Features:**
- [ ] Statistics dashboard (% transcoded, most common issues)
- [ ] Graphical charts and visualizations
- [ ] Export to PDF
- [ ] HTML report with sortable tables
- [ ] Email report option

**Estimated Effort:** Medium (3-4 days)

---

## 🚀 Performance Optimizations

### 10. Dynamic Work Splitting

**Description:** Split large files across multiple threads for better load balancing

**Current Issue:** Large files can create load imbalance at end of queue

**Improvements:**
- [ ] Split files > certain size across multiple threads
- [ ] Dynamic work stealing when workers become idle
- [ ] Better load balancing for mixed file sizes

**Impact:** More efficient CPU utilization, especially with mixed file sizes

**Estimated Effort:** Low-Medium (2-3 days)

---

### 11. I/O Optimization

**Features:**
- [ ] Prefetch files while analyzing (async I/O)
- [ ] Memory-mapped file reading for large files
- [ ] Compressed result storage

**Impact:** Reduced I/O wait time, especially on slow storage

**Estimated Effort:** Medium (3-4 days)

---

### 12. Memory Pooling

**Features:**
- [ ] Reuse FFT buffers across analyses
- [ ] Reduce allocation overhead
- [ ] Arena allocator for per-file analysis

**Impact:** Reduced memory allocations, better cache performance

**Estimated Effort:** Low (1-2 days)

---

### 13. NUMA Awareness

**Features:**
- [ ] Pin threads to NUMA nodes
- [ ] Improve cache locality on multi-socket systems
- [ ] Automatic NUMA topology detection

**Impact:** Better performance on high-end workstations/servers

**Estimated Effort:** Medium (2-3 days)

---

## 🧪 Quality & Testing

### 14. Comprehensive Test Suite

**Features:**
- [ ] Unit tests for each module
- [ ] Integration tests for full pipeline
- [ ] Test with known good/bad FLAC files
- [ ] Benchmark suite for performance tracking
- [ ] CI/CD integration (GitHub Actions)

**Test Coverage Goals:**
- [ ] `analysis.zig` - FFT correctness, algorithm validation
- [ ] `flac_decoder.zig` - Various FLAC file formats
- [ ] `parallel.zig` - Thread safety, race condition tests
- [ ] `output.zig` - Format validation
- [ ] End-to-end accuracy tests

**Estimated Effort:** High (5-7 days)

---

### 15. Fuzzing

**Features:**
- [ ] Fuzz testing for FLAC decoder
- [ ] Malformed file handling
- [ ] Edge case discovery

**Estimated Effort:** Medium (2-3 days)

---

## 📚 Documentation & Usability

### 16. Interactive Mode

**Features:**
- [ ] TUI (Text User Interface) with real-time updates
- [ ] Interactive file browser
- [ ] Keyboard navigation
- [ ] File preview/details view

**Libraries:** Consider using `zgt` or similar for TUI

**Estimated Effort:** High (5-7 days)

---

### 17. Configuration File

**Features:**
- [ ] Support for `.flacalyzerrc` configuration file
- [ ] TOML or JSON format
- [ ] Default settings for flags
- [ ] Profile support (different configs for different use cases)

**Estimated Effort:** Low (1-2 days)

---

### 18. Man Page / Documentation

**Features:**
- [ ] Complete man page
- [ ] Online documentation website
- [ ] Tutorial videos
- [ ] FAQ section

**Estimated Effort:** Medium (2-3 days)

---

## 🔧 Additional Features

### 19. Multi-Format Support

**Description:** Extend analysis to other lossless formats

**Formats:**
- [ ] ALAC (Apple Lossless)
- [ ] APE (Monkey's Audio)
- [ ] WavPack
- [ ] Direct WAV analysis

**Estimated Effort:** High (4-6 days per format)

---

### 20. Plugin System

**Features:**
- [ ] Allow custom analysis plugins
- [ ] Dynamic loading of analysis modules
- [ ] User-defined detection algorithms
- [ ] Community plugin repository

**Estimated Effort:** High (7-10 days)

---

### 21. Network/Remote Analysis

**Features:**
- [ ] Client-server architecture
- [ ] Analyze files on remote servers
- [ ] Distributed analysis across multiple machines
- [ ] Web interface

**Estimated Effort:** Very High (10-15 days)

---

### 22. Machine Learning Enhancement

**Features:**
- [ ] Train ML model on known good/bad files
- [ ] Improve detection accuracy
- [ ] Reduce false positives
- [ ] Automatic threshold tuning

**Technical Approach:**
- Collect labeled dataset
- Feature extraction from spectral analysis
- Train classifier (Random Forest, SVM, or neural network)
- Integrate model into analysis pipeline

**Estimated Effort:** Very High (15-20 days)

---

### 23. Metadata Analysis

**Features:**
- [ ] Check for suspicious metadata patterns
- [ ] Detect upscaled sample rates
- [ ] Validate metadata consistency
- [ ] Report metadata anomalies

**Estimated Effort:** Low-Medium (2-3 days)

---

## 🎨 UI/UX Improvements

### 24. Progress Bar Enhancements

**Features:**
- [ ] Show current file being analyzed
- [ ] ETA calculation
- [ ] Speed graph (files/sec over time)
- [ ] Per-thread activity display

**Estimated Effort:** Low (1 day)

---

### 25. Color Themes

**Features:**
- [ ] Support for different terminal color schemes
- [ ] Dark/light mode
- [ ] Customizable colors
- [ ] NO_COLOR environment variable support

**Estimated Effort:** Low (1 day)

---

### 26. Verbose/Debug Modes

**Features:**
- [ ] `-v/--verbose` for detailed output
- [ ] `-vv` for very verbose
- [ ] `--debug` for debugging information
- [ ] `--quiet` for minimal output

**Estimated Effort:** Low (1 day)

---

## 📦 Distribution

### 27. Package Manager Distribution

**Platforms:**
- [ ] Arch Linux AUR package
- [ ] Debian/Ubuntu package (.deb)
- [ ] Homebrew formula (macOS)
- [ ] Chocolatey package (Windows)
- [ ] Flatpak
- [ ] Snap
- [ ] Docker image

**Estimated Effort:** Medium (3-5 days for all platforms)

---

### 28. Binary Releases

**Features:**
- [ ] Automated GitHub releases
- [ ] Pre-built binaries for all platforms
- [ ] Checksums and signatures
- [ ] Release notes automation

**Estimated Effort:** Low (1-2 days)

---

## 🤝 Community

### 29. Contributing Guidelines

**Features:**
- [ ] CONTRIBUTING.md
- [ ] Code style guide
- [ ] PR template
- [ ] Issue templates
- [ ] Community guidelines

**Estimated Effort:** Low (1 day)

---

### 30. Benchmark Database

**Features:**
- [ ] Public database of analysis results
- [ ] Accuracy validation
- [ ] Community contributions
- [ ] Reference dataset for testing

**Estimated Effort:** Medium (2-3 days)

---

## 📊 Priority Matrix

| Priority | Feature | Complexity | Impact | Effort |
|----------|---------|------------|--------|--------|
| 🔥 High | JSON/CSV Export | Medium | High | 3-5d |
| 🔥 High | Visualizations | Medium-High | High | 4-7d |
| 🎯 Medium | Source Detection | Medium | Medium | 2-4d |
| 🎯 Medium | Auto-Organize | Low-Medium | High | 2-3d |
| 🎯 Medium | Watch Mode | Medium | Medium | 3-4d |
| 🚀 Perf | Work Splitting | Low-Medium | Medium | 2-3d |
| 🚀 Perf | Memory Pooling | Low | Medium | 1-2d |
| 🧪 Quality | Test Suite | High | High | 5-7d |
| 📚 Docs | Config File | Low | Medium | 1-2d |
| 🔧 Feature | Metadata Analysis | Low-Medium | Low | 2-3d |

---

## 🗓️ Suggested Roadmap

### Version 2.2.0 (Next Release)
- [ ] JSON/CSV Export
- [ ] Database caching
- [ ] Incremental mode
- [ ] Configuration file support

### Version 2.3.0
- [ ] Visualizations (PNG spectrograms)
- [ ] HTML reports
- [ ] Auto-organize mode

### Version 2.4.0
- [ ] Source format detection
- [ ] Watch mode
- [ ] Comprehensive test suite

### Version 3.0.0
- [ ] Multi-format support (ALAC, APE)
- [ ] Interactive TUI mode
- [ ] Plugin system foundation

---

## 💡 Ideas Welcome!

Have an idea for a feature? 
1. Check if it's already listed here
2. Open an issue on GitHub with the `enhancement` label
3. Describe the use case and expected behavior
4. Discuss implementation approach

**Contributing:**
Feel free to pick any item from this list and implement it! See `CONTRIBUTING.md` for guidelines.

---

**Last Updated:** 2025-11-10  
**Maintainers:** Add your ideas and update priorities as needed!

**Note:** Code quality items (#3-5) are based on reviews by ChatGPT and Grok (November 2024). Current code is production-quality - these are optional enhancements only.

