classdef MJSE < handle
    %MJSE MATLAB-Julia Satellite Engine manager
    %
    % Manages double-buffered shared memory, Java bridge, and Julia worker daemon.
    %
    % Usage:
    %   engine = MJSE();
    %   engine.start();
    %   % Use engine for computations
    %   engine.shutdown();
    %
    % TODO: Add rich payload metadata (dims/eltype/endian/checksum)
    % TODO: Add timeout handling and error recovery
    
    properties (Access = private)
        shm_path        % Path to shared memory file
        shm_mmap        % memmapfile object for zero-copy access
        socket_path     % Path to UNIX domain socket
        bridge          % Java bridge object
        julia_process   % Julia process handle
        header_size     % Size of shared memory header (64 bytes)
        page_size       % Size of each buffer page (128 MB)
        is_initialized  % Initialization flag
    end
    
    properties (Constant)
        MAGIC_NUMBER = uint32(hex2dec('4D4A5345'))  % "MJSE"
        VERSION = uint32(1)
        HEADER_SIZE = 64
        PAGE_SIZE = 128 * 1024 * 1024  % 128 MB - TODO: Make configurable
    end
    
    methods
        function obj = MJSE()
            %MJSE Constructor
            obj.header_size = MJSE.HEADER_SIZE;
            obj.page_size = MJSE.PAGE_SIZE;
            obj.is_initialized = false;
            obj.shm_mmap = [];
            obj.bridge = [];
            obj.julia_process = [];
        end
        
        function start(obj)
            %START Initialize the MJSE engine
            
            if obj.is_initialized
                warning('MJSE:AlreadyInitialized', 'MJSE already initialized');
                return;
            end
            
            try
                % Step 1: Set up shared memory
                obj.setup_shared_memory();
                
                % Step 2: Load Java bridge
                obj.load_java_bridge();
                
                % Step 3: Launch Julia daemon
                obj.launch_julia_daemon();
                
                % Step 4: Perform handshake
                obj.perform_handshake();
                
                obj.is_initialized = true;
                fprintf('MJSE initialized successfully\n');
                
            catch ME
                obj.cleanup();
                rethrow(ME);
            end
        end
        
        function shutdown(obj)
            %SHUTDOWN Clean up and terminate the MJSE engine
            
            if ~obj.is_initialized
                return;
            end
            
            obj.cleanup();
            obj.is_initialized = false;
            fprintf('MJSE shutdown complete\n');
        end
        
        function latency = test_roundtrip(obj, data)
            %TEST_ROUNDTRIP Test roundtrip communication with timing
            %
            % Inputs:
            %   data - Data to send (will be converted to bytes)
            %
            % Outputs:
            %   latency - Roundtrip time in seconds
            
            if ~obj.is_initialized
                error('MJSE:NotInitialized', 'MJSE not initialized. Call start() first.');
            end
            
            % Convert data to bytes
            if isnumeric(data)
                bytes = typecast(data(:), 'uint8');
            else
                error('MJSE:InvalidData', 'Data must be numeric');
            end
            
            payload_size = int64(length(bytes));
            
            % Start timer
            tic;
            
            % Send size (8 bytes)
            size_bytes = typecast(payload_size, 'uint8');
            sent = obj.bridge.send(size_bytes);
            if sent ~= 8
                error('MJSE:SendFailed', 'Failed to send payload size');
            end
            
            % Send data
            sent = obj.bridge.send(bytes);
            if sent ~= length(bytes)
                error('MJSE:SendFailed', 'Failed to send complete payload');
            end
            
            % Receive size back
            recv_size_bytes = obj.bridge.receive(8);
            if isempty(recv_size_bytes) || length(recv_size_bytes) ~= 8
                error('MJSE:ReceiveFailed', 'Failed to receive payload size');
            end
            
            recv_size = typecast(uint8(recv_size_bytes), 'int64');
            
            % Receive data back
            recv_bytes = obj.bridge.receive(double(recv_size));
            if isempty(recv_bytes) || length(recv_bytes) ~= recv_size
                error('MJSE:ReceiveFailed', 'Failed to receive complete payload');
            end
            
            % End timer
            latency = toc;
            
            % Verify data matches
            if ~isequal(bytes, uint8(recv_bytes)')
                warning('MJSE:DataMismatch', 'Received data does not match sent data');
            end
        end
        
        function delete(obj)
            %DELETE Destructor
            obj.shutdown();
        end
    end
    
    methods (Access = private)
        function setup_shared_memory(obj)
            %SETUP_SHARED_MEMORY Create and initialize double-buffered shared memory
            %
            % Uses memmapfile for zero-copy access from MATLAB side
            % Julia will use Mmap.mmap to access the same file
            
            % Create temporary shared memory file
            if ispc
                obj.shm_path = fullfile(tempdir, ['mjse_shm_' char(java.util.UUID.randomUUID()) '.dat']);
            else
                obj.shm_path = fullfile('/tmp', ['mjse_shm_' char(java.util.UUID.randomUUID()) '.dat']);
            end
            
            % Create socket path
            if ispc
                % TODO: Named pipe path for Windows
                obj.socket_path = ['\\.\pipe\mjse_' char(java.util.UUID.randomUUID())];
            else
                obj.socket_path = fullfile('/tmp', ['mjse_sock_' char(java.util.UUID.randomUUID()) '.sock']);
            end
            
            % Calculate total size: header + 2 pages
            total_size = obj.header_size + 2 * obj.page_size;
            
            % Create and initialize shared memory file
            fid = fopen(obj.shm_path, 'w');
            if fid == -1
                error('MJSE:ShmCreate', 'Failed to create shared memory file: %s', obj.shm_path);
            end
            
            % Write header
            header = zeros(1, obj.header_size, 'uint8');
            
            % Magic number (bytes 0-3)
            header(1:4) = typecast(MJSE.MAGIC_NUMBER, 'uint8');
            
            % Version (bytes 4-7)
            header(5:8) = typecast(MJSE.VERSION, 'uint8');
            
            % Page size (bytes 8-15)
            header(9:16) = typecast(int64(obj.page_size), 'uint8');
            
            % Current write page (bytes 16-23) - start with page 0
            header(17:24) = typecast(int64(0), 'uint8');
            
            % MATLAB PID (bytes 24-31)
            matlab_pid = int64(feature('getpid'));
            header(25:32) = typecast(matlab_pid, 'uint8');
            
            % Write header to file
            fwrite(fid, header, 'uint8');
            
            % Allocate space for two pages (write zeros)
            page_buffer = zeros(1, obj.page_size, 'uint8');
            fwrite(fid, page_buffer, 'uint8');  % Page 0
            fwrite(fid, page_buffer, 'uint8');  % Page 1
            
            % Flush and close
            fclose(fid);
            
            % Create memmapfile for zero-copy access
            % Format: header (64 bytes) + page0 (128MB) + page1 (128MB)
            obj.shm_mmap = memmapfile(obj.shm_path, ...
                'Format', { ...
                    'uint8', [1 obj.header_size], 'header'; ...
                    'uint8', [1 obj.page_size], 'page0'; ...
                    'uint8', [1 obj.page_size], 'page1' ...
                }, ...
                'Writable', true);
            
            fprintf('Shared memory created: %s (%.2f MB)\n', obj.shm_path, total_size / 1024 / 1024);
            fprintf('Memory-mapped for zero-copy access\n');
        end
        
        function load_java_bridge(obj)
            %LOAD_JAVA_BRIDGE Load the Java bridge JAR
            
            % Get path to MJSEBridge.jar
            script_dir = fileparts(mfilename('fullpath'));
            jar_path = fullfile(script_dir, 'MJSEBridge.jar');
            
            if ~exist(jar_path, 'file')
                error('MJSE:JarNotFound', ...
                    'MJSEBridge.jar not found at: %s\nRun mjse_setup to build the bridge.', jar_path);
            end
            
            fprintf('Loading Java bridge from: %s\n', jar_path);
            fprintf('==== Java Bridge Loading Diagnostics ====\n');
            
            % 1. Check current classpath state
            fprintf('\n[Step 1] Checking current Java classpath...\n');
            java_classpath_before = javaclasspath('-dynamic');
            fprintf('  Dynamic classpath entries: %d\n', length(java_classpath_before));
            has_jar = any(contains(java_classpath_before, 'MJSEBridge.jar'));
            fprintf('  MJSEBridge.jar already loaded: %s\n', mat2str(has_jar));
            
            % 2. Add JAR to classpath ONLY if missing
            if ~has_jar
                fprintf('\n[Step 2] Adding JAR to classpath...\n');
                javaaddpath(jar_path);
                fprintf('  javaaddpath() completed\n');
            else
                fprintf('\n[Step 2] JAR already in classpath, skipping javaaddpath\n');
            end
            
            % 3. Verify JAR is now in classpath
            fprintf('\n[Step 3] Verifying JAR in classpath...\n');
            java_classpath_after = javaclasspath('-dynamic');
            fprintf('  Dynamic classpath entries: %d\n', length(java_classpath_after));
            for i = 1:length(java_classpath_after)
                if contains(java_classpath_after{i}, 'MJSEBridge.jar')
                    fprintf('  ✓ Found: %s\n', java_classpath_after{i});
                end
            end
            
            % 4. Check Java version compatibility
            fprintf('\n[Step 4] Checking Java version...\n');
            java_version = version('-java');
            fprintf('  MATLAB Java Runtime: %s\n', java_version);
            
            % 5. Inspect JAR contents
            fprintf('\n[Step 5] Inspecting JAR contents...\n');
            [status, jar_contents] = system(sprintf('jar tf "%s"', jar_path));
            if status == 0
                fprintf('  JAR contents:\n');
                jar_lines = strsplit(jar_contents, '\n');
                for i = 1:min(10, length(jar_lines))  % Show first 10 entries
                    if ~isempty(strtrim(jar_lines{i}))
                        fprintf('    %s\n', jar_lines{i});
                    end
                end
                if contains(jar_contents, 'mjse/Bridge.class')
                    fprintf('  ✓ mjse/Bridge.class found in JAR\n');
                else
                    fprintf('  ✗ mjse/Bridge.class NOT found in JAR!\n');
                end
            else
                fprintf('  Warning: Could not inspect JAR contents\n');
            end
            
            % 6. Check class file version
            fprintf('\n[Step 6] Checking Bridge.class bytecode version...\n');
            [status, class_info] = system(sprintf('javap -verbose -cp "%s" mjse.Bridge 2>&1 | grep "major version"', jar_path));
            if status == 0 && ~isempty(class_info)
                fprintf('  %s\n', strtrim(class_info));
            else
                fprintf('  Could not determine bytecode version\n');
            end
            
            % 7. Attempt to load bridge using javaObject (most robust method)
            fprintf('\n[Step 7] Attempting to load bridge...\n');
            fprintf('  Using javaObject(''mjse.Bridge'') - bypasses MATLAB name cache\n');
            
            try
                obj.bridge = javaObject('mjse.Bridge');
                fprintf('  ✓✓✓ SUCCESS: Bridge loaded successfully! ✓✓✓\n');
            catch ME
                fprintf('  ✗✗✗ FAILED: %s ✗✗✗\n', ME.message);
                fprintf('\n[Step 8] Additional diagnostics on failure...\n');
                
                % Try to get more specific error info
                fprintf('  Error identifier: %s\n', ME.identifier);
                fprintf('  Error message: %s\n', ME.message);
                
                % Check if it's a bytecode version mismatch
                if contains(ME.message, 'Unsupported') || contains(ME.message, 'version')
                    fprintf('\n  ⚠ DIAGNOSIS: Bytecode version mismatch likely!\n');
                    fprintf('  The Bridge.class file was compiled for a different Java version.\n');
                    fprintf('  Bridge should be compiled for Java 8 compatibility (bytecode version 52.0)\n');
                    fprintf('  Ensure javac is invoked with: --release 8\n');
                elseif contains(ME.message, 'not found') || contains(ME.message, 'cannot be located')
                    fprintf('\n  ⚠ DIAGNOSIS: Class not found in JAR or classpath issue!\n');
                    fprintf('  Check that mjse/Bridge.class exists in the JAR.\n');
                else
                    fprintf('\n  ⚠ DIAGNOSIS: Unknown issue. Full error:\n');
                    fprintf('  %s\n', getReport(ME));
                end
                
                fprintf('\n========================================\n');
                error('MJSE:JavaBridgeLoadFailed', 'Failed to load Java bridge. See diagnostics above.');
            end
            
            fprintf('========================================\n');
        end
        
        function launch_julia_daemon(obj)
            %LAUNCH_JULIA_DAEMON Start the Julia worker process
            
            % Find Julia executable
            julia_bin = obj.find_julia_binary();
            
            % Get worker script path
            script_dir = fileparts(mfilename('fullpath'));
            project_root = fileparts(script_dir);
            worker_script = fullfile(project_root, 'jl_src', 'MJSEWorker.jl');
            
            if ~exist(worker_script, 'file')
                error('MJSE:WorkerNotFound', 'Julia worker not found at: %s', worker_script);
            end
            
            % Build Julia command
            julia_cmd = sprintf('"%s" --project="%s" -e "include(raw\\"%s\\"); MJSEWorker.run_worker(raw\\"%s\\", raw\\"%s\\")"', ...
                julia_bin, ...
                fullfile(project_root, 'jl_src'), ...
                worker_script, ...
                obj.shm_path, ...
                obj.socket_path);
            
            % Launch Julia process
            if ispc
                obj.julia_process = System.Diagnostics.Process.Start('cmd.exe', ...
                    sprintf('/c %s', julia_cmd));
            else
                % Set LD_LIBRARY_PATH to prioritize Julia's libraries over MATLAB's
                % This prevents library conflicts without needing to rename files
                julia_lib_path = fullfile(fileparts(fileparts(julia_bin)), 'lib', 'julia');
                if exist(julia_lib_path, 'dir')
                    env_prefix = sprintf('LD_LIBRARY_PATH="%s:$LD_LIBRARY_PATH" ', julia_lib_path);
                else
                    env_prefix = '';
                end
                
                % Use system with & to run in background
                cmd = sprintf('%s%s > /tmp/mjse_worker.log 2>&1 &', env_prefix, julia_cmd);
                system(cmd);
            end
            
            % Wait a moment for Julia to start
            pause(2.0);
            
            fprintf('Julia worker launched\n');
        end
        
        function perform_handshake(obj)
            %PERFORM_HANDSHAKE Establish connection and perform binary handshake
            
            % Wait for socket to be created by Julia
            max_wait = 30;  % seconds
            wait_time = 0;
            while ~exist(obj.socket_path, 'file') && wait_time < max_wait
                pause(0.5);
                wait_time = wait_time + 0.5;
            end
            
            if ~exist(obj.socket_path, 'file')
                error('MJSE:SocketTimeout', 'Julia worker did not create socket within %d seconds', max_wait);
            end
            
            % Connect to UNIX socket
            connected = obj.bridge.connectUnix(obj.socket_path);
            if ~connected
                error('MJSE:ConnectionFailed', 'Failed to connect to Julia worker socket');
            end
            
            fprintf('Connected to Julia worker\n');
            
            % Send handshake message
            handshake_msg = uint8('MJSE_HANDSHAKE');
            handshake_msg(end+1:16) = 0;  % Pad to 16 bytes
            
            sent = obj.bridge.send(handshake_msg);
            if sent ~= 16
                error('MJSE:HandshakeFailed', 'Failed to send handshake message');
            end
            
            % Receive acknowledgment
            ack = obj.bridge.receive(16);
            if isempty(ack) || length(ack) ~= 16
                error('MJSE:HandshakeFailed', 'Failed to receive handshake acknowledgment');
            end
            
            expected_ack = uint8('MJSE_ACK');
            expected_ack(end+1:16) = 0;
            
            if ~isequal(uint8(ack'), expected_ack)
                error('MJSE:HandshakeFailed', 'Invalid handshake acknowledgment');
            end
            
            fprintf('Handshake completed\n');
        end
        
        function julia_bin = find_julia_binary(obj)
            %FIND_JULIA_BINARY Locate Julia executable
            
            % Check for portable Julia in external/
            script_dir = fileparts(mfilename('fullpath'));
            project_root = fileparts(script_dir);
            
            if ispc
                portable_julia = fullfile(project_root, 'external', 'julia', 'bin', 'julia.exe');
            else
                portable_julia = fullfile(project_root, 'external', 'julia', 'bin', 'julia');
            end
            
            if exist(portable_julia, 'file')
                julia_bin = portable_julia;
                return;
            end
            
            % Try system Julia
            [status, result] = system('julia --version');
            if status == 0
                if ispc
                    julia_bin = 'julia.exe';
                else
                    julia_bin = 'julia';
                end
                return;
            end
            
            error('MJSE:JuliaNotFound', ...
                'Julia not found. Run mjse_setup to download portable Julia or install Julia 1.12+');
        end
        
        function cleanup(obj)
            %CLEANUP Release all resources
            
            % Close bridge connection
            if ~isempty(obj.bridge)
                try
                    obj.bridge.close();
                catch
                end
                obj.bridge = [];
            end
            
            % Terminate Julia process (if handle exists)
            if ~isempty(obj.julia_process)
                try
                    if ispc
                        obj.julia_process.Kill();
                    end
                catch
                end
                obj.julia_process = [];
            end
            
            % Close memory map first
            if ~isempty(obj.shm_mmap)
                try
                    delete(obj.shm_mmap);
                catch
                end
                obj.shm_mmap = [];
            end
            
            % Remove shared memory file
            if ~isempty(obj.shm_path) && exist(obj.shm_path, 'file')
                try
                    delete(obj.shm_path);
                catch
                end
            end
            
            % Remove socket file
            if ~isempty(obj.socket_path) && exist(obj.socket_path, 'file')
                try
                    delete(obj.socket_path);
                catch
                end
            end
        end
    end
end
