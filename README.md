# MATLAB-Julia Satellite Engine (MJSE)
## Universal Hybrid Architecture: TCP + Shared Memory

High-performance bidirectional communication between MATLAB and Julia using **TCP localhost** (control) + **shared memory** (data) for **R2019b-R2026+** compatibility.

## 🚀 Quick Start

**Step 1: One-time setup** (downloads Julia and dependencies)

```matlab
% Clone the repository and navigate to it
% git clone https://github.com/korbinian90/Matlab-julia-.git
% cd Matlab-julia-

mjse_setup  % Downloads Julia 1.12.x, installs packages (5-10 minutes)
```

**Step 2: Use MJSE in your code**

```matlab
% Add to path
addpath('m_src');

% Create and use the engine
engine = MJSE();
engine.start();

% Process data with Julia (zero-copy transfer via shared memory)
data = rand(215, 215, 215);  % ~80MB
result = engine.call('process', data);

% Clean up
engine.shutdown();
```

**That's it!** Pure MATLAB and Julia - no Java Bridge, no version conflicts.

## Features

- **✅ R2019b-R2026+ Compatible**: No Java Bridge, no version conflicts
- **✅ Zero-Copy Transfer**: Shared memory via `memmapfile` ↔ `Mmap.mmap`
- **✅ TCP Control Plane**: Native MATLAB `tcpclient` + Julia `Sockets`
- **✅ Dynamic Ports**: Auto-selects available port using `java.net.ServerSocket(0)`
- **✅ PID Monitoring**: Julia worker exits if MATLAB terminates
- **✅ Cross-platform**: Ubuntu, macOS, Windows
- **✅ Simple Setup**: One-time `mjse_setup` downloads everything

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

## Testing

Run the verification test after setup:

```matlab
addpath('m_src', 'tests');
test_roundtrip();  % Tests 100MB roundtrip with zero-error verification
```

## Linux Library Isolation

On Linux, MJSE uses `LD_LIBRARY_PATH` to prioritize Julia's own libraries when launching the Julia worker, preventing conflicts with MATLAB's bundled libraries. This approach:
- Does not modify Julia's library files (no renaming needed)
- Allows Julia to use its own `libstdc++.so.6`, `libgcc_s.so.1`, and `libgfortran.so.5`
- Prevents MATLAB library hijacking without breaking Julia's internal dependencies

## Development Status

### ✅ Implemented

- TCP + Shared Memory hybrid architecture
- Native MATLAB `tcpclient` (no Java Bridge)
- `memmapfile`-based shared memory with StateFlag protocol
- Julia worker with TCP server and heartbeat
- Dynamic port allocation
- 100MB roundtrip test with zero-error verification
- CI/CD with GitHub Actions (Ubuntu/macOS/Windows)
- Linux library isolation via `LD_LIBRARY_PATH`

### 🔄 In Progress (TODOs in code)

- Full function dispatch in Julia worker (currently echo stub)
- Rich payload metadata (dimensions, element type, endianness, checksum)
- Timeout handling and error recovery
- Configurable buffer sizing
- Performance optimization

## Contributing

This is an active development project. See TODO comments in the code for areas that need implementation or improvement.

## Repository Structure

```
Matlab-julia-/
├── m_src/              # MATLAB source files
│   ├── jlcall.m        # High-level interface (legacy compatibility)
│   └── MJSE.m          # Engine manager (TCP + shared memory)
├── jl_src/             # Julia source files
│   ├── MJSEWorker.jl   # Worker daemon (TCP server + StateFlag protocol)
│   └── Project.toml    # Julia dependencies
├── tests/              # Test files
│   └── test_roundtrip.m
├── external/           # Downloaded Julia runtime (gitignored)
├── mjse_setup.m        # One-time setup script
└── .github/workflows/  # CI configuration
```

## License

See repository license file.

