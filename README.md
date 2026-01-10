# MATLAB-Julia Satellite Engine (MJSE)
## Universal Hybrid Architecture: TCP + Shared Memory

High-performance bidirectional communication between MATLAB and Julia using **TCP localhost** (control) + **shared memory** (data) for **R2019b-R2026+** compatibility.

## 🚀 Quick Start (Clone and Run!)

**Just clone and run - everything auto-installs on first use:**

```matlab
% Clone the repository
% git clone https://github.com/korbinian90/Matlab-julia-.git
% cd Matlab-julia-

% Add to path
addpath('m_src');

% Create and use the engine
engine = MJSE();
engine.start();  % Auto-downloads Julia on first run

% Test with 100MB data
data = rand(215, 215, 215);  % ~80MB
result = engine.call('process', data);

% Clean up
engine.shutdown();
```

**That's it!** On first run, setup will automatically:
- Download portable Julia 1.12.x
- Install required packages (ArgParse, Sockets, Mmap)
- Configure library isolation (Linux)

No Java Bridge, no manual setup - pure MATLAB and Julia!

## Features

- **✅ R2019b-R2026+ Compatible**: No Java version conflicts
- **✅ Auto-Setup**: Downloads Julia automatically on first run
- **✅ Zero-Copy Transfer**: Shared memory via `memmapfile` ↔ `Mmap.mmap`
- **✅ TCP Control Plane**: Native MATLAB `tcpclient` + Julia `Sockets`
- **✅ Dynamic Ports**: Auto-selects available port using `java.net.ServerSocket(0)`
- **✅ PID Monitoring**: Julia exits if MATLAB dies (heartbeat)
- **✅ Cross-platform**: Ubuntu, macOS, Windows

## Architecture

### Universal Hybrid Design

**Control Plane** (TCP on `127.0.0.1`):
- Commands: HANDSHAKE, PROCESS, SHUTDOWN
- Dynamic port allocation
- Native MATLAB `tcpclient` + Julia `Sockets.listen`

**Data Plane** (Shared Memory):
- 8-byte StateFlag header: `[0=Idle | 1=Ready | 2=Processing | 3=Done]`
- 256 MB data buffer
- MATLAB: `memmapfile` for direct writes
- Julia: `Mmap.mmap` for direct reads

### Core Components

- **`MJSE.m`**: Manager - handles TCP connection, shared memory, Julia launch
- **`MJSEWorker.jl`**: Worker - TCP server, shared memory processor, heartbeat
- **`mjse_setup.m`**: Setup script (auto-called on first run)
- **`test_roundtrip.m`**: 100MB verification test with `norm(original - returned) == 0`

### Shared Memory Layout

```
[Header: 8 bytes]
  StateFlag (uint64): 0=Idle, 1=Ready, 2=Processing, 3=Done

[Data: 256 MB buffer]
  Raw data bytes for transfer
```

## Manual Setup (Optional)

```matlab
mjse_setup  % Downloads Julia, installs packages
```

## Testing

```matlab
addpath('m_src', 'tests');
test_roundtrip();  % Tests 100MB roundtrip with zero-error verification
```

## Linux Library Isolation

Julia is launched with `LD_LIBRARY_PATH` pointing to its own libraries, preventing MATLAB library conflicts without file modification.

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

