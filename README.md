# FLAC Analyzer (Zig Edition)

A comprehensive FLAC audio file analyzer that detects transcoded (lossy-to-lossless) files using multiple advanced analysis techniques.

## Features

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

## Requirements

- Zig 0.15.2 or later
- libFLAC development libraries

### Install Dependencies (Arch Linux)

```bash
sudo pacman -S flac
```

### Install Dependencies (Debian/Ubuntu)

```bash
sudo apt install libflac-dev
```

## Building

```bash
zig build
```

## Usage

```bash
./zig-out/bin/flacalyzer [path/to/flac/directory]
```

If no path is provided, it analyzes the current directory.

### Example

```bash
./zig-out/bin/flacalyzer /path/to/music/collection
```

## Output

The analyzer produces:

1. **Console output** with progress bar and summary
2. **result.txt** file with detailed analysis of all files

### Sample Output

```
🎵 FLAC Lossless Analyzer with FFT Spectral Analysis (Zig Edition)
Scanning directory: /path/to/music
Found 153 FLAC files to analyze

🔍 [153/153] 100.0% | Complete

═══════════════════════════════════════
📊 Summary:
   Total FLAC files found: 153
   Valid lossless FLAC: 148
   Definitely transcoded: 0
   Likely transcoded: 5
   Invalid/Corrupted: 0
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

Divides spectrum into three bands and measures energy distribution:

- **Low band** (0-5 kHz): Bass frequencies
- **Mid band** (5-15 kHz): Midrange
- **High band** (15 kHz-Nyquist): Treble

Calculates rolloff between bands to detect excessive high-frequency attenuation.

### Spectral Flatness

Measures how "noise-like" vs "tone-like" the spectrum is:

- Calculates geometric mean / arithmetic mean of magnitude spectrum
- Natural lossless audio: typically > 0.05
- Lossy-transcoded audio: typically < 0.03 (more structured/peaky)

## Conservative Approach

All advanced analysis methods (histogram, band analysis, spectral flatness) work as **supporting evidence only**:

- They only add confidence when spectral analysis already found issues
- This prevents false positives from natural audio characteristics
- Requires multiple methods to agree before upgrading confidence level

## Technical Details

- **FFT Size**: 8192 samples
- **Hop Size**: 4096 samples (50% overlap)
- **Threshold**: -30dB (3% of maximum magnitude)
- **Confidence Levels**: not_transcoded, likely_transcoded, definitely_transcoded

## License

This project is open source. Feel free to use, modify, and distribute.

## Acknowledgments

- Uses libFLAC for FLAC decoding
- Inspired by various audio analysis tools and research on lossy codec characteristics

