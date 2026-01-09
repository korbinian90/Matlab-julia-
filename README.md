# MATLAB-Julia Satellite Engine (MJSE)

High-performance bidirectional communication engine between MATLAB and Julia using shared memory and UNIX domain sockets.

## Features

- **Double-buffered shared memory**: 64-byte header + two 128MB pages for efficient data transfer
- **UNIX domain sockets**: Low-latency IPC via Java bridge (POSIX) with Windows Named Pipe support planned
- **Portable Julia runtime**: Automated download and setup of Julia 1.12.x
- **Cross-platform**: Ubuntu, macOS, and Windows support
- **CI/CD**: Automated testing via GitHub Actions

## Quick Start

### Prerequisites

- MATLAB R2024b or later
- Java JDK 11+ (for compiling the bridge)
- Julia 1.12+ (optional - can be downloaded via setup script)

### Installation

```matlab
% Run the setup script to download Julia, build the bridge, and prewarm caches
setup
```

### Usage

```matlab
% Initialize the engine
engine = MJSE();
engine.start();

% Test roundtrip communication
test_data = rand(1000, 1000);  % 8MB matrix
latency = engine.test_roundtrip(test_data);
fprintf('Latency: %.4f seconds\n', latency);

% Shutdown
engine.shutdown();
```

### Running Tests

```matlab
addpath('m_src');
addpath('tests');
test_roundtrip();
```

## Architecture

### Components

- **`m_src/MJSE.m`**: MATLAB manager class handling initialization, communication, and cleanup
- **`m_src/mjse/Bridge.java`**: Java bridge for UNIX socket communication
- **`jl_src/MJSEWorker.jl`**: Julia worker daemon for payload processing
- **`setup.m`**: Setup script for environment preparation

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
[Page 1: 128 MB data buffer]
```

### Communication Protocol

1. MATLAB creates shared memory file and launches Julia worker
2. Julia worker opens shared memory and starts UNIX socket server
3. Binary handshake exchange ("MJSE_HANDSHAKE" / "MJSE_ACK")
4. Heartbeat task monitors MATLAB process
5. Payload exchange via socket (currently echo stub)

## Development Status

### Implemented

- ✅ Double-buffered shared memory setup
- ✅ Java bridge with UNIX socket support (via reflection for Java 11+ compatibility)
- ✅ Julia worker with socket listener and heartbeat
- ✅ Binary handshake protocol
- ✅ Roundtrip test framework
- ✅ CI/CD with GitHub Actions

### Planned (TODOs in code)

- ⏳ Windows Named Pipe support in Java bridge
- ⏳ Rich payload metadata (dimensions, element type, endianness, checksum)
- ⏳ Timeout handling and error recovery
- ⏳ Configurable buffer sizing
- ⏳ Platform-specific PID monitoring

## Contributing

This is an active development project. See TODO comments in the code for areas that need implementation or improvement.

## License

See repository license file.

