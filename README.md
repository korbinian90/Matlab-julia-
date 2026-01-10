# MATLAB-Julia Satellite Engine (MJSE)
## Universal Hybrid Architecture: TCP + Shared Memory

High-performance bidirectional communication between MATLAB and Julia using **TCP localhost** (control) + **shared memory** (data).
Compatible with **R2019b through R2026+**.

## 🚀 Key Features

- **✅ Zero Setup**: Automatically downloads a portable Julia runtime (1.12.x) if none is found.
- **✅ No Java Bridge**: Uses pure `tcpclient`, eliminating JVM version conflicts.
- **✅ Automatic Data Handling**:
  - Automatically handles **Dimensions** (up to 8D).
  - Automatically handles **Data Types** (Double, Single, Int/UInt).
  - ✅ **Complex Numbers**: Full support for complex arrays.
- **✅ Dynamic Memory**: Shared memory buffer **automatically grows** (to fit large data) and **shrinks** (to save resources).
- **✅ Linux/Windows/macOS**: Cross-platform support with automated environment handling (e.g., `patchelf` isolation on Linux).

## 📦 Quick Start

**Step 1: Clone & Run**
No manual setup required. Just clone and run the example.

```matlab
% In MATLAB
addpath('m_src');
SimpleExample  % Demo script
```

**Step 2: Basic Usage**
Use the `MJSE` class directly. The first time you run `start()`, it will automatically download Julia if needed (approx. 5-10 mins on first run).

```matlab
% Create engine
engine = MJSE();
engine.start(); % Auto-downloads Julia if missing!

% 1. Send Data (Automatic Type & Shape Preservation)
data = rand(100, 100);
result = engine.call('process', data); 
% result is 100x100 double

% 2. Complex Numbers
c_data = complex(rand(5), rand(5));
res_c = engine.call('fft', c_data); 
% res_c is 5x5 complex double

% Clean up
engine.shutdown();
```

## 🧠 Architecture Requirements

- **MATLAB**: R2019b or newer (requires `tcpclient`).
- **OS**: Windows 10/11, macOS, or Linux (Ubuntu/Debian tested).
- **Network**: Localhost (127.0.0.1) access required.

## 📁 Repository Structure

```
Matlab-julia-/
├── m_src/              # MATLAB Source
│   └── MJSE.m          # Single-file engine manager (Setup + Execution)
├── jl_src/             # Julia Backend
│   └── MJSEWorker.jl   # Worker daemon
├── tests/              # Test Suite
│   ├── test_roundtrip.m # Verify data integrity
│   └── test_resize.m    # Verify dynamic buffer resizing
├── external/           # Downloaded Julia runtime (created automatically)
└── SimpleExample.m     # Usage demo
```

## 🔧 Advanced Details

### Protocol
The communication uses a custom header (128 bytes) in shared memory:
- **Metadata**: Encodes `DataType`, `NDims`, `Dims`, and `DataSize`.
- **Dynamic Resizing**: If data exceeds the default 256MB buffer, the engine performs a synchronized `RESIZE` handshake to expand the file mapping on the fly.

### Linux Isolation
On Linux, MJSE ensures stability by preventing MATLAB's outdated system libraries (`libstdc++`, etc.) from interfering with Julia. It uses an `env -u LD_LIBRARY_PATH` strategy (and optional `patchelf` patching if needed) to ensure Julia loads its own correct dependencies.

## 🤝 Contributing

Run the test suite to ensure no regressions:
```matlab
addpath('tests', 'm_src');
test_roundtrip;
test_resize;
```
