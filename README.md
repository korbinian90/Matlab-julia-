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

On Linux, MJSE uses **patchelf library shadowing** to prevent MATLAB library conflicts. This provides production-grade stability:

### How It Works

1. **Library Renaming**: During setup, Julia's problematic libraries are renamed:
   - `libstdc++.so.6` → `libstdc++_mjse.so.6`
   - `libgcc_s.so.1` → `libgcc_s_mjse.so.1`
   - `libgfortran.so.5` → `libgfortran_mjse.so.5`

2. **Dependency Updates**: The `libjulia.so.1.12` binary is patched using `patchelf --replace-needed` to reference the renamed libraries.

3. **RPATH Configuration**: Both `libjulia.so.1.12` and the `julia` binary have their RPATH set to `$ORIGIN/../lib:$ORIGIN/../lib/julia`, ensuring Julia always uses its own libraries.

4. **Environment Scrubbing**: Julia is launched with `env -u LD_LIBRARY_PATH -u LD_PRELOAD` to prevent MATLAB's environment from interfering.

### Benefits

- **Immunity to MATLAB Conflicts**: Julia will never load MATLAB's incompatible versions of `libstdc++`, `libgcc_s`, or `libgfortran`
- **No Runtime Overhead**: Library paths resolved at load time via RPATH
- **Stable Across Systems**: Works regardless of system library versions
- **No Julia Modification**: Julia's internal dependencies remain unchanged

### Requirements

- **patchelf** must be installed: `sudo apt-get install patchelf`
- Automatically applied during `mjse_setup` on Linux
- No action needed on macOS or Windows

## Atomic Memory Synchronization

The StateFlag protocol ensures data integrity even with concurrent access:

### Protocol Sequence

1. **MATLAB** writes data to shared memory buffer
2. **MATLAB** sets StateFlag = 1 (READY)  
3. **MATLAB** sends TCP "PROCESS" command
4. **Julia** receives TCP command
5. **Julia** spin-waits until StateFlag == 1 (prevents torn reads)
6. **Julia** processes data from shared memory
7. **Julia** sets StateFlag = 3 (DONE)
8. **MATLAB** spin-waits until StateFlag == 3
9. **MATLAB** reads result from shared memory

This prevents race conditions where TCP arrives before memory writes are visible to Julia.

## Robust Cleanup

### Julia-Side
- **Heartbeat Monitor**: Background task checks MATLAB PID every 5 seconds
- **Auto-Exit**: If MATLAB terminates, Julia worker exits gracefully
- **Prevents Orphans**: No orphaned Julia processes after MATLAB crashes

### MATLAB-Side
- **onCleanup Handler**: Automatically sends SHUTDOWN command
- **Resource Cleanup**: Deletes shared memory file on exit
- **Graceful Termination**: Waits for Julia acknowledgment before closing

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

