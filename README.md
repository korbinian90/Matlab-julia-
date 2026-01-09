# MATLAB-Julia Satellite Engine (MJSE)

High-performance bidirectional communication engine between MATLAB and Julia using shared memory and UNIX domain sockets.

## 🚀 Quick Start (Clone and Run!)

**Just clone and run - everything auto-installs on first use:**

```matlab
% Clone the repository
% git clone https://github.com/korbinian90/Matlab-julia-.git
% cd Matlab-julia-

% Add to path
addpath('m_src');

% Start the Julia daemon (auto-downloads Julia and builds bridge on first run)
jlcall('start');

% Use Julia functions
result = jlcall('sum', [1 2 3 4 5]);

% Stop when done
jlcall('stop');
```

**That's it!** On first run, `jlcall` will automatically:
- Download portable Julia 1.12.x (if not found)
- Build the Java bridge for socket communication
- Configure everything for immediate use

No manual setup required - just clone and call `jlcall('start')`!

## Features

- **Auto-Setup**: Downloads Julia and builds dependencies automatically on first run
- **Zero-Copy Transfer**: Uses `memmapfile` (MATLAB) and `Mmap.mmap` (Julia) for shared memory
- **Unix Domain Sockets**: Low-latency IPC via Java bridge (POSIX) with Windows Named Pipe support planned
- **MATDaemon-style Interface**: Simple `jlcall()` function for all Julia interactions
- **Cross-platform**: Ubuntu, macOS, and Windows support
- **CI/CD**: Automated testing via GitHub Actions

## Architecture

### Core Components

- **`jlcall.m`**: Main interface - handles auto-setup, daemon lifecycle, and function calls
- **`MJSE.m`**: Engine managing shared memory (via memmapfile), Java bridge, and Julia daemon
- **`Bridge.java`**: Java bridge for UNIX socket communication (Java 11+/16+ compatible)
- **`MJSEWorker.jl`**: Julia worker daemon with shared memory mapping and heartbeat monitoring
- **`mjse_setup.m`**: Setup script (called automatically by jlcall on first run)

### Data Flow

1. **Control Path** (Unix Domain Socket):
   - Function name and metadata
   - Handshake and status messages
   - Small control signals

2. **Data Path** (Shared Memory):
   - MATLAB: `memmapfile` for zero-copy writes
   - Julia: `Mmap.mmap` for zero-copy reads
   - Large arrays (100MB+) transfer with minimal overhead

### Shared Memory Layout

```
[Header: 64 bytes]
  - Bytes 0-3:   Magic number (0x4D4A5345 = "MJSE")
  - Bytes 4-7:   Version (1)
  - Bytes 8-15:  Page size (default: 128MB)
  - Bytes 16-23: Current write page (0 or 1)
  - Bytes 24-31: MATLAB PID
  - Bytes 32-63: Reserved

[Page 0: 128 MB data buffer]
[Page 1: 128 MB data buffer]  (double-buffered for pipelining)
```

## Manual Setup (Optional)

If you want to run setup manually (not needed for normal use):

```matlab
mjse_setup  % Downloads Julia, builds bridge, sets up environment
```

## Advanced Usage

### Direct Engine Access

```matlab
% For advanced users who want direct engine control
engine = MJSE();
engine.start();
latency = engine.test_roundtrip(rand(1000, 1000));
engine.shutdown();
```

### Linux Library Isolation

On Linux, MJSE uses `LD_LIBRARY_PATH` to prioritize Julia's own libraries when launching the Julia worker, preventing conflicts with MATLAB's bundled libraries. This approach:
- Does not modify Julia's library files (no renaming needed)
- Allows Julia to use its own `libstdc++.so.6`, `libgcc_s.so.1`, and `libgfortran.so.5`
- Prevents MATLAB library hijacking without breaking Julia's internal dependencies

The `MJSE_SHADOW_LIBS=1` environment variable in CI indicates library isolation is active (via `LD_LIBRARY_PATH`).

## Development Status

### ✅ Implemented

- Auto-setup on first run
- `jlcall()` interface for MATLAB-Julia communication  
- `memmapfile`-based shared memory (MATLAB side)
- Java bridge with UNIX socket support (via reflection for Java 11+/16+)
- Julia worker with socket listener and heartbeat
- Binary handshake protocol
- Roundtrip test framework
- CI/CD with GitHub Actions (Ubuntu/macOS/Windows)

### 🔄 In Progress (TODOs in code)

- Windows Named Pipe support in Java bridge
- Full shared memory data protocol (currently echo stub)
- Rich payload metadata (dimensions, element type, endianness, checksum)
- Timeout handling and error recovery
- Function dispatch in Julia worker
- Configurable buffer sizing

## Testing

```matlab
addpath('m_src', 'tests');
test_roundtrip();
```

## Contributing

This is an active development project. See TODO comments in the code for areas that need implementation or improvement.

## Repository Structure

```
Matlab-julia-/
├── m_src/              # MATLAB source files
│   ├── jlcall.m        # Main interface (auto-setup)
│   ├── MJSE.m          # Engine manager
│   └── mjse/           # Java bridge
│       ├── Bridge.java
│       └── bridge_build.m
├── jl_src/             # Julia source files
│   ├── MJSEWorker.jl   # Worker daemon
│   └── Project.toml
├── tests/              # Test files
│   └── test_roundtrip.m
├── external/           # Auto-downloaded Julia runtime (gitignored)
├── mjse_setup.m        # Setup script (auto-called by jlcall)
├── setup.m             # Legacy setup script
└── .github/workflows/  # CI configuration
```

## License

See repository license file.

