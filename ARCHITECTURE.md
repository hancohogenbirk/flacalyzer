# Architecture

This document describes the modular architecture of the FLAC Analyzer.

## Project Structure

```
flacalyzer/
├── src/
│   ├── main.zig              (136 lines) - Entry point and orchestration
│   ├── types.zig             (175 lines) - Shared data structures
│   ├── analysis.zig          (436 lines) - FFT and spectral analysis algorithms
│   ├── flac_decoder.zig      (178 lines) - FLAC file decoding
│   ├── parallel.zig          (226 lines) - Thread pool and work queue
│   ├── output.zig            (140 lines) - Result formatting
│   └── utils.zig              (73 lines) - File system utilities
├── build.zig                           - Build configuration
├── README.md                           - User documentation
├── PARALLEL_IMPLEMENTATION.md          - Parallel processing details
└── CHANGELOG.md                        - Version history
```

**Total:** 1,364 lines (down from 1,442 lines in monolithic version)

## Module Overview

### 1. `main.zig` - Entry Point
**Purpose:** Minimal orchestration layer  
**Responsibilities:**
- Command-line argument parsing
- Thread count configuration
- Progress monitoring
- Coordination of all modules
- Output writing to result.txt

**Key Functions:**
- `main()` - Program entry point

### 2. `types.zig` - Data Structures
**Purpose:** Shared type definitions and C bindings  
**Exports:**
- `Complex` - Complex numbers for FFT
- `BandAnalysisResult` - Frequency band analysis results
- `TranscodingConfidence` - Enum for detection confidence
- `FlacAnalysis` - Complete analysis results
- `SuspiciousFile` - Reporting structure
- `DecoderContext` - FLAC decoder state
- `c` - C bindings to libFLAC

### 3. `analysis.zig` - Core Analysis Algorithms
**Purpose:** All audio analysis algorithms  
**Key Functions:**
- `fft()` - Fast Fourier Transform (Cooley-Tukey)
- `analyzeSpectrum()` - Complete spectral analysis
- `analyzeHistogram()` - Sample distribution analysis
- `analyzeBitDepth()` - Bit depth validation
- `analyzeFrequencyBands()` - Band energy analysis
- `calculateSpectralFlatness()` - Spectral flatness measurement

**Analysis Pipeline:**
```
Raw Samples → FFT → Spectrum → {
    - Frequency cutoff detection
    - Energy dropoff measurement
    - Band analysis
    - Histogram analysis
    - Spectral flatness
} → Confidence Score
```

### 4. `flac_decoder.zig` - FLAC Decoding
**Purpose:** Interface with libFLAC for file decoding  
**Key Functions:**
- `analyzeFlac()` - Main analysis entry point
- `metadataCallback()` - Extract file metadata
- `writeCallback()` - Collect audio samples
- `errorCallback()` - Handle decoding errors

**Process:**
1. Create FLAC decoder
2. Register callbacks
3. Extract metadata (sample rate, bit depth, channels)
4. Collect audio samples (100,000 samples)
5. Pass to analysis pipeline
6. Combine results with supporting evidence

### 5. `parallel.zig` - Threading Infrastructure
**Purpose:** Parallel processing implementation  
**Key Types:**
- `SharedAnalysisState` - Thread-safe shared state
- `WorkQueue` - File distribution queue
- `WorkerContext` - Worker thread parameters

**Key Functions:**
- `workerThread()` - Worker thread entry point

**Thread Safety:**
- Mutex for shared state updates
- Atomic counter for lock-free progress tracking
- Work-stealing queue for load balancing

### 6. `output.zig` - Result Formatting
**Purpose:** Format and display analysis results  
**Key Functions:**
- `printSummary()` - Print overall statistics
- `printSuspiciousFiles()` - Detailed file reports
- `printMethodNotes()` - Analysis method descriptions
- `printBoth()` - Dual output (console + file)

### 7. `utils.zig` - File System Utilities
**Purpose:** File system operations  
**Key Functions:**
- `isFlacFile()` - Check file extension
- `countFlacFiles()` - Recursive file counting
- `collectFlacFiles()` - Collect paths into work queue

## Data Flow

```
┌─────────────────────────────────────────────────────────────┐
│                          main.zig                            │
│  - Parse CLI arguments                                       │
│  - Initialize work queue & shared state                      │
│  - Spawn worker threads                                      │
│  - Monitor progress                                          │
└──────────────────┬──────────────────────────────────────────┘
                   │
        ┌──────────┴──────────┐
        │                     │
        ▼                     ▼
┌──────────────┐      ┌──────────────┐
│  utils.zig   │      │ parallel.zig │
│              │      │              │
│ countFlac... │      │ WorkQueue    │
│ collectFlac..│      │ SharedState  │
└──────────────┘      │ workerThread │
                      └──────┬───────┘
                             │
                             ▼
                      ┌─────────────┐
                      │flac_decoder │
                      │             │
                      │ analyzeFlac │
                      └──────┬──────┘
                             │
                             ▼
                      ┌─────────────┐
                      │ analysis.zig│
                      │             │
                      │ fft()       │
                      │ analyzeSp...│
                      │ analyzeBit..│
                      │ analyzeHist.│
                      └──────┬──────┘
                             │
                             ▼
                      ┌─────────────┐
                      │ output.zig  │
                      │             │
                      │ printSummary│
                      │ printSusp...│
                      └─────────────┘
```

## Module Dependencies

```
main.zig
  ├─→ types.zig
  ├─→ parallel.zig ──→ types.zig
  │                 └─→ flac_decoder.zig ──→ types.zig
  │                                       └─→ analysis.zig ──→ types.zig
  ├─→ output.zig ────→ types.zig
  │                └─→ parallel.zig
  └─→ utils.zig ─────→ parallel.zig
```

**Dependency Rules:**
- `types.zig` has no dependencies (base layer)
- Analysis algorithms depend only on types
- FLAC decoder depends on types + analysis
- Parallel infrastructure depends on types + decoder
- Output depends on types + parallel
- Utils depends on parallel
- Main depends on all modules

## Design Principles

### 1. **Separation of Concerns**
Each module has a single, well-defined responsibility:
- Types: Data structures only
- Analysis: Pure algorithms
- Decoder: libFLAC interface
- Parallel: Threading logic
- Output: Formatting
- Utils: File operations
- Main: Orchestration

### 2. **Modularity**
- Modules are independently testable
- Clear interfaces between modules
- Minimal coupling between modules

### 3. **Idiomatic Zig**
- Follows Zig project structure conventions
- Proper use of `pub` for exported items
- Explicit error handling
- Zero-cost abstractions

### 4. **Performance**
- Lock-free progress tracking
- Efficient work distribution
- Minimal memory allocations
- Streaming analysis (no full file buffering)

### 5. **Maintainability**
- Clear module boundaries
- Self-documenting code structure
- Easy to extend (add new analysis methods)
- Easy to modify (change output format, threading model, etc.)

## Benefits of Modular Structure

### Before (Monolithic)
- ❌ Single 1,442-line file
- ❌ All functionality mixed together
- ❌ Hard to navigate and understand
- ❌ Difficult to test individual components
- ❌ High coupling between concerns

### After (Modular)
- ✅ 6 focused modules (73-436 lines each)
- ✅ Clear separation of concerns
- ✅ Easy to navigate and understand
- ✅ Individual modules can be tested
- ✅ Loose coupling with clear interfaces
- ✅ Easy to add new features (e.g., new output formats, analysis methods)

## Testing Strategy

Each module can be tested independently:

1. **types.zig** - Unit tests for data structures
2. **analysis.zig** - Test FFT and analysis algorithms with known inputs
3. **flac_decoder.zig** - Test with sample FLAC files
4. **parallel.zig** - Test thread safety and work distribution
5. **output.zig** - Test formatting with mock data
6. **utils.zig** - Test file system operations

## Future Extensions

The modular structure makes it easy to add:

1. **New Output Formats**
   - Add `output_json.zig` or `output_csv.zig`
   - Import in `main.zig`, add CLI flag

2. **New Analysis Methods**
   - Add functions to `analysis.zig`
   - Update `FlacAnalysis` type
   - Integrate in `flac_decoder.zig`

3. **Database Caching**
   - Add `cache.zig` module
   - Import in `main.zig` for incremental analysis

4. **Visualization**
   - Add `visualization.zig` for spectrograms
   - Generate PNGs from spectrum data

5. **Additional Audio Formats**
   - Add `mp3_decoder.zig`, `aac_decoder.zig`
   - Share analysis pipeline

## Building

```bash
zig build                          # Debug build
zig build -Doptimize=ReleaseFast  # Optimized build
```

The build system automatically links all modules together.

## Conclusion

The modular architecture provides:
- **Better organization** - Logical separation of concerns
- **Easier maintenance** - Changes isolated to specific modules
- **Improved testability** - Independent testing of components
- **Enhanced extensibility** - Simple to add new features
- **Cleaner code** - Smaller, focused files

This structure follows Zig best practices and makes the codebase significantly more maintainable and professional.

