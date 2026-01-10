classdef MJSE < handle
    %MJSE MATLAB-Julia Satellite Engine (Universal Hybrid Architecture)
    %
    % Uses TCP localhost + shared memory for R2019b-R2026+ compatibility.
    % No Java Bridge required - pure MATLAB tcpclient + Julia Sockets.
    %
    % Usage:
    %   engine = MJSE();
    %   engine.start();
    %   data = rand(100, 100, 100);  % 100MB matrix
    %   result = engine.call('process', data);
    %   engine.shutdown();
    
    properties (Access = private)
        shm_path        % Path to shared memory file
        shm_mmap        % memmapfile object
        tcp_port        % Dynamic TCP port
        tcp_client      % MATLAB tcpclient object
        julia_process   % Julia process handle
        is_initialized  % Initialization flag
        current_buffer_size % Current buffer size
    end
    
    properties (Constant)
        STATE_IDLE = uint64(0)
        STATE_READY = uint64(1)
        STATE_PROCESSING = uint64(2)
        STATE_DONE = uint64(3)
        
        % Protocol constants
        HEADER_SIZE = 128  % Total Header Size
        DEFAULT_BUFFER_SIZE = 256 * 1024 * 1024  % 256 MB default
        
        % Data Types
        TYPE_DOUBLE = uint64(1)
        TYPE_SINGLE = uint64(2)
        TYPE_INT8   = uint64(3)
        TYPE_UINT8  = uint64(4)
        TYPE_INT16  = uint64(5)
        TYPE_UINT16 = uint64(6)
        TYPE_INT32  = uint64(7)
        TYPE_UINT32 = uint64(8)
        TYPE_INT64  = uint64(9)
        TYPE_UINT64 = uint64(10)
        
        % Complex Types
        TYPE_COMPLEX_DOUBLE = uint64(11)
        TYPE_COMPLEX_SINGLE = uint64(12)
        TYPE_COMPLEX_INT8   = uint64(13)
        TYPE_COMPLEX_UINT8  = uint64(14)
        TYPE_COMPLEX_INT16  = uint64(15)
        TYPE_COMPLEX_UINT16 = uint64(16)
        TYPE_COMPLEX_INT32  = uint64(17)
        TYPE_COMPLEX_UINT32 = uint64(18)
        TYPE_COMPLEX_INT64  = uint64(19)
        TYPE_COMPLEX_UINT64 = uint64(20)
    end
    
    methods
        function obj = MJSE()
            obj.is_initialized = false;
            obj.shm_mmap = [];
            obj.tcp_client = [];
            obj.julia_process = [];
            obj.current_buffer_size = obj.DEFAULT_BUFFER_SIZE;
        end
        

        
        function start(obj)
            if obj.is_initialized
                warning('MJSE:AlreadyInitialized', 'Already initialized');
                return;
            end
            
            try
                % Step 1: Auto-setup if Julia is missing
                MJSE.setup();

                % Step 2: Find available port
                obj.find_available_port();
                fprintf('Using TCP port: %d\n', obj.tcp_port);
                
                % Step 2: Set up shared memory
                obj.setup_shared_memory();
                
                % Step 3: Launch Julia worker
                obj.launch_julia_worker();
                
                % Step 4: Connect TCP client
                obj.connect_tcp();
                
                % Step 5: Perform handshake
                obj.perform_handshake();
                
                obj.is_initialized = true;
                fprintf('MJSE initialized successfully\n');
                
            catch ME
                obj.cleanup();
                rethrow(ME);
            end
        end
        
        function shutdown(obj)
            if ~obj.is_initialized
                return;
            end
            
            try
                % Send shutdown command
                if ~isempty(obj.tcp_client)
                    write(obj.tcp_client, uint8('SHUTDOWN'));
                    pause(0.1);
                end
            catch
                % Ignore errors during shutdown
            end
            
            obj.cleanup();
            obj.is_initialized = false;
            fprintf('MJSE shutdown complete\n');
        end
        
        function result = call(obj, ~, data)
            % CALL Execute Julia function with data transfer via shared memory
            
            if ~obj.is_initialized
                error('MJSE:NotInitialized', 'Not initialized. Call start() first.');
            end
            
            % Write data to shared memory
            obj.write_shared_memory(data);
            
            % Send trigger via TCP
            write(obj.tcp_client, uint8('PROCESS'));
            
            % Wait for completion
            result = obj.wait_and_read();
        end
        
        function latency = test_roundtrip(obj, data)
            % TEST_ROUNDTRIP Measure roundtrip latency
            
            tic;
            result = obj.call('echo', data);
            latency = toc;
            
            % Verify data integrity
            if isnumeric(data) && isnumeric(result)
                error_norm = norm(double(data(:)) - double(result(:)));
                if error_norm > 1e-10
                    warning('MJSE:DataMismatch', 'Roundtrip error: %.2e', error_norm);
                end
            end
        end
    end
    
    methods (Access = private)
        function find_available_port(obj)
            % Use Java to find an available port
            try
                server_socket = java.net.ServerSocket(0);
                obj.tcp_port = server_socket.getLocalPort();
                server_socket.close();
            catch
                % Fallback to random high port
                obj.tcp_port = randi([49152, 65535]);
            end
        end
        
        function setup_shared_memory(obj)
            % Create shared memory file
            obj.shm_path = fullfile(tempdir, sprintf('mjse_shm_%s.dat', ...
                char(matlab.lang.internal.uuid())));
            
            % Initialize shared memory file
            total_size = obj.current_buffer_size;
            fid = fopen(obj.shm_path, 'wb');
            fwrite(fid, zeros(1, total_size, 'uint8'));
            fclose(fid);
            
            % Create memory map object
            obj.create_memmap();
            
            % Initialize
            obj.shm_mmap.Data.StateFlag = obj.STATE_IDLE;
            
            fprintf('Shared memory created: %s (%.2f MB)\n', obj.shm_path, ...
                total_size / 1024 / 1024);
        end
        
        function launch_julia_worker(obj)
            % Launch Julia worker with port and shm path as arguments
            
            % Find Julia executable
            repo_root = fileparts(fileparts(mfilename('fullpath')));
            julia_dir = fullfile(repo_root, 'external', 'julia');
            
            if ispc
                julia_exe = fullfile(julia_dir, 'bin', 'julia.exe');
            else
                julia_exe = fullfile(julia_dir, 'bin', 'julia');
            end
            
            if ~isfile(julia_exe)
                error('MJSE:JuliaNotFound', 'Julia not found. Run mjse_setup first.');
            end
            
            % Worker script path
            worker_script = fullfile(repo_root, 'jl_src', 'MJSEWorker.jl');
            
            % Log file for debugging
            log_file = fullfile(tempdir, sprintf('mjse_worker_%d.log', obj.tcp_port));
            
            % Debug: Show paths being used
            fprintf('DEBUG: Julia exe: %s\n', julia_exe);
            fprintf('DEBUG: Worker script: %s\n', worker_script);
            fprintf('DEBUG: jl_src dir: %s\n', fullfile(repo_root, 'jl_src'));
            fprintf('DEBUG: Port: %d, SHM: %s, PID: %d\n', obj.tcp_port, obj.shm_path, feature('getpid'));
            
            % Build command with environment scrubbing on Linux (prevents MATLAB interference)
            if isunix && ~ismac
                % Use 'env -u' to clear LD_LIBRARY_PATH and LD_PRELOAD
                % Julia will use its own shadowed libraries via RPATH
                % Redirect output to log file for debugging
                cmd = sprintf('env -u LD_LIBRARY_PATH -u LD_PRELOAD "%s" --project="%s" "%s" --port %d --shm "%s" --pid %d > "%s" 2>&1 &', ...
                    julia_exe, fullfile(repo_root, 'jl_src'), ...
                    worker_script, obj.tcp_port, obj.shm_path, feature('getpid'), log_file);
            elseif ispc
                % Windows: Use 'start' command to run in background without window
                % Note: /B runs without new window, first "" is window title (required)
                % Use cmd /c to handle redirection properly
                cmd = sprintf('start /B "Julia Worker" cmd /c ""%s" --project="%s" "%s" --port %d --shm "%s" --pid %d > "%s" 2>&1"', ...
                    julia_exe, fullfile(repo_root, 'jl_src'), ...
                    worker_script, obj.tcp_port, obj.shm_path, feature('getpid'), log_file);
            else
                % macOS: Write command to temp script for proper redirection
                script_file = fullfile(tempdir, sprintf('mjse_launch_%d.sh', obj.tcp_port));
                fid = fopen(script_file, 'w');
                fprintf(fid, '#!/bin/bash\n');
                fprintf(fid, 'exec "%s" --project="%s" "%s" --port %d --shm "%s" --pid %d > "%s" 2>&1 &\n', ...
                    julia_exe, fullfile(repo_root, 'jl_src'), ...
                    worker_script, obj.tcp_port, obj.shm_path, feature('getpid'), log_file);
                fclose(fid);
                system(sprintf('chmod +x "%s"', script_file));
                cmd = sprintf('"%s"', script_file);
            end
            
            fprintf('Launching Julia worker...\n');
            fprintf('DEBUG: Command: %s\n', cmd);
            fprintf('Julia worker log: %s\n', log_file);
            if ispc || ismac
                % On Windows and macOS, background launch returns immediately
                % (Windows: start command, macOS: nohup with &)
                [status, output] = system(cmd);
                fprintf('DEBUG: system() returned status=%d\n', status);
                if ~isempty(output)
                    fprintf('DEBUG: system() output: %s\n', output);
                end
                % Give Julia more time to start (macOS/Windows have slower startup)
                pause(5);
            else
                % Linux: env -u with & also returns immediately, but faster startup
                [status, output] = system(cmd);
                fprintf('DEBUG: system() returned status=%d\n', status);
                if ~isempty(output)
                    fprintf('DEBUG: system() output: %s\n', output);
                end
                pause(2);
            end
            
            % Display log file contents if it exists (for CI debugging)
            if isfile(log_file)
                fprintf('--- Julia Worker Log ---\n');
                log_content = fileread(log_file);
                if isempty(strtrim(log_content))
                    fprintf('(Log file is empty)\n');
                else
                    fprintf('%s\n', log_content);
                end
                fprintf('--- End Julia Worker Log ---\n');
            else
                fprintf('DEBUG: Log file does not exist yet: %s\n', log_file);
            end
            
            % Try to read log again after a short delay
            pause(1);
            if isfile(log_file)
                fprintf('--- Julia Worker Log (after delay) ---\n');
                log_content = fileread(log_file);
                if isempty(strtrim(log_content))
                    fprintf('(Log file is still empty)\n');
                else
                    fprintf('%s\n', log_content);
                end
                fprintf('--- End Julia Worker Log ---\n');
            end
        end
        
        function connect_tcp(obj)
            % Connect to Julia TCP server
            max_attempts = 10;
            for attempt = 1:max_attempts
                try
                    obj.tcp_client = tcpclient('127.0.0.1', obj.tcp_port, 'Timeout', 60);
                    fprintf('TCP connected to 127.0.0.1:%d\n', obj.tcp_port);
                    return;
                catch
                    if attempt == max_attempts
                        error('MJSE:ConnectionFailed', 'Failed to connect to Julia after %d attempts', max_attempts);
                    end
                    pause(0.5);
                end
            end
        end
        
        function perform_handshake(obj)
            % Perform handshake with Julia
            fprintf('DEBUG: Sending HANDSHAKE...\n');
            write(obj.tcp_client, uint8('HANDSHAKE'));
            fprintf('DEBUG: HANDSHAKE sent, waiting for response...\n');
            
            % Wait for response
            pause(0.2);
            fprintf('DEBUG: BytesAvailable = %d\n', obj.tcp_client.BytesAvailable);
            if obj.tcp_client.BytesAvailable > 0
                response = read(obj.tcp_client, obj.tcp_client.BytesAvailable, 'char');
                fprintf('DEBUG: Received response: "%s"\n', response);
                if ~strcmp(strtrim(response), 'ACK')
                    error('MJSE:HandshakeFailed', 'Invalid handshake response: %s', response);
                end
            else
                error('MJSE:HandshakeFailed', 'No handshake response');
            end
            
            fprintf('Handshake complete\n');
        end
        
        function write_shared_memory(obj, data)
            % Write data to shared memory and set flag
            
            % Encode metadata
            [type_code, byte_data] = obj.encode_data(data);
             
            required_size = length(byte_data) + obj.HEADER_SIZE;
            
            % Check resizing logic
            if length(byte_data) > (obj.current_buffer_size - obj.HEADER_SIZE)
                % Grow buffer
                new_size = max(required_size * 1.5, obj.current_buffer_size * 2);
                % Align to 1MB
                new_size = ceil(new_size / (1024*1024)) * 1024*1024;
                fprintf('MJSE: Growing shared memory to %.2f MB\n', new_size/1024/1024);
                obj.resize_shared_memory(new_size);
                
            elseif required_size < (obj.DEFAULT_BUFFER_SIZE - obj.HEADER_SIZE) && ...
                   obj.current_buffer_size > obj.DEFAULT_BUFFER_SIZE
               % Shrink buffer if it's large but we only need small space
               % Only shrink if we are significantly over default
               fprintf('MJSE: Shrinking shared memory to default (%.2f MB)\n', obj.DEFAULT_BUFFER_SIZE/1024/1024);
               obj.resize_shared_memory(obj.DEFAULT_BUFFER_SIZE);
            end
            
            % Write metadata
            obj.shm_mmap.Data.DataType = type_code;
            obj.shm_mmap.Data.DataSize = uint64(length(byte_data));
            
            dims = size(data);
            obj.shm_mmap.Data.NDims = uint64(length(dims));
            
            % Write dims (up to 8 supported)
            dims_padded = ones(1, 8, 'uint64');
            dims_padded(1:length(dims)) = uint64(dims);
            obj.shm_mmap.Data.Dims = dims_padded;
            
            % Write data bytes
            obj.shm_mmap.Data.Data(1:length(byte_data)) = byte_data;
            
            % Set state to READY
            obj.shm_mmap.Data.StateFlag = obj.STATE_READY;
        end
        
        function result = wait_and_read(obj)
            % Wait for Julia to complete and read result
            
            max_wait = 30;  % 30 second timeout
            start_time = tic;
            
            while toc(start_time) < max_wait
                current_state = obj.shm_mmap.Data.StateFlag;
                
                if current_state == obj.STATE_DONE
                    % Read result 
                    data_size = double(obj.shm_mmap.Data.DataSize);
                    type_code = obj.shm_mmap.Data.DataType;
                    n_dims = double(obj.shm_mmap.Data.NDims);
                    dims = double(obj.shm_mmap.Data.Dims);
                    
                    % Sanity check size
                    if data_size > (obj.current_buffer_size - obj.HEADER_SIZE)
                         % This implies Julia wrote more than we expected? 
                         % Or we processed in place.
                         % If Julia needs to resize output, we haven't implemented that direction yet.
                         % But for now, let's assume result <= buffer.
                         % If result > buffer, Julia side check would fail or we need "RESIZE" from Julia.
                         % For this iteration:
                         warning('MJSE:DataTruncated', 'Data size exceeds buffer');
                         data_size = obj.current_buffer_size - obj.HEADER_SIZE;
                    end
                    
                    if data_size > 0
                        raw_bytes = obj.shm_mmap.Data.Data(1:data_size);
                        result = obj.decode_data(raw_bytes, type_code, dims(1:n_dims));
                    else
                        result = [];
                    end
                    
                    % Reset to IDLE
                    obj.shm_mmap.Data.StateFlag = obj.STATE_IDLE;
                    return;
                end
                
                pause(0.01);
            end
            
            error('MJSE:Timeout', 'Timeout waiting for Julia');
        end
        
        function cleanup(obj)
            % Clean up resources
            
            try
                if ~isempty(obj.tcp_client)
                    clear obj.tcp_client;
                    obj.tcp_client = [];
                end
            catch
            end
            
            try
                if ~isempty(obj.shm_mmap)
                    clear obj.shm_mmap;
                    obj.shm_mmap = [];
                end
            catch
            end
            
            try
                if ~isempty(obj.shm_path) && isfile(obj.shm_path)
                    delete(obj.shm_path);
                end
            catch
            end
        end
        
        function [type_code, byte_data] = encode_data(obj, data)
            % Helper: Encode data to bytes and get type code
            if ~isnumeric(data)
                error('MJSE:UnsupportedType', 'Only numeric data supported');
            end
            
            % Handle Complex Numbers
            if ~isreal(data)
                % Interleave real and imaginary parts: [r1, i1, r2, i2, ...]
                % MATLAB stores separate arrays, Julia stores interleaved structs
                real_part = real(data(:))';
                imag_part = imag(data(:))';
                % Create interleaved array [r1; i1; r2; i2...] -> then flatten
                interleaved = [real_part; imag_part]; 
                
                byte_data = typecast(interleaved(:), 'uint8');
                
                switch class(data)
                    case 'double', type_code = obj.TYPE_COMPLEX_DOUBLE;
                    case 'single', type_code = obj.TYPE_COMPLEX_SINGLE;
                    case 'int8',   type_code = obj.TYPE_COMPLEX_INT8;
                    case 'uint8',  type_code = obj.TYPE_COMPLEX_UINT8;
                    case 'int16',  type_code = obj.TYPE_COMPLEX_INT16;
                    case 'uint16', type_code = obj.TYPE_COMPLEX_UINT16;
                    case 'int32',  type_code = obj.TYPE_COMPLEX_INT32;
                    case 'uint32', type_code = obj.TYPE_COMPLEX_UINT32;
                    case 'int64',  type_code = obj.TYPE_COMPLEX_INT64;
                    case 'uint64', type_code = obj.TYPE_COMPLEX_UINT64;
                    otherwise
                        error('MJSE:UnsupportedType', 'Unsupported complex class: %s', class(data));
                end
            else
                % Handle Real Numbers
                byte_data = typecast(data(:), 'uint8');
                
                switch class(data)
                    case 'double', type_code = obj.TYPE_DOUBLE;
                    case 'single', type_code = obj.TYPE_SINGLE;
                    case 'int8',   type_code = obj.TYPE_INT8;
                    case 'uint8',  type_code = obj.TYPE_UINT8;
                    case 'int16',  type_code = obj.TYPE_INT16;
                    case 'uint16', type_code = obj.TYPE_UINT16;
                    case 'int32',  type_code = obj.TYPE_INT32;
                    case 'uint32', type_code = obj.TYPE_UINT32;
                    case 'int64',  type_code = obj.TYPE_INT64;
                    case 'uint64', type_code = obj.TYPE_UINT64;
                    otherwise
                        error('MJSE:UnsupportedType', 'Unsupported class: %s', class(data));
                end
            end
        end
        
        function result = decode_data(obj, raw_bytes, type_code, dims)
            % Helper: Decode bytes to typed array
            is_complex = false;
            
            switch type_code
                case obj.TYPE_DOUBLE, type_str = 'double';
                case obj.TYPE_SINGLE, type_str = 'single';
                case obj.TYPE_INT8,   type_str = 'int8';
                case obj.TYPE_UINT8,  type_str = 'uint8';
                case obj.TYPE_INT16,  type_str = 'int16';
                case obj.TYPE_UINT16, type_str = 'uint16';
                case obj.TYPE_INT32,  type_str = 'int32';
                case obj.TYPE_UINT32, type_str = 'uint32';
                case obj.TYPE_INT64,  type_str = 'int64';
                case obj.TYPE_UINT64, type_str = 'uint64';
                
                % Complex types
                case obj.TYPE_COMPLEX_DOUBLE, type_str = 'double'; is_complex = true;
                case obj.TYPE_COMPLEX_SINGLE, type_str = 'single'; is_complex = true;
                case obj.TYPE_COMPLEX_INT8,   type_str = 'int8';   is_complex = true;
                case obj.TYPE_COMPLEX_UINT8,  type_str = 'uint8';  is_complex = true;
                case obj.TYPE_COMPLEX_INT16,  type_str = 'int16';  is_complex = true;
                case obj.TYPE_COMPLEX_UINT16, type_str = 'uint16'; is_complex = true;
                case obj.TYPE_COMPLEX_INT32,  type_str = 'int32';  is_complex = true;
                case obj.TYPE_COMPLEX_UINT32, type_str = 'uint32'; is_complex = true;
                case obj.TYPE_COMPLEX_INT64,  type_str = 'int64';  is_complex = true;
                case obj.TYPE_COMPLEX_UINT64, type_str = 'uint64'; is_complex = true;
                
                otherwise
                    warning('MJSE:UnknownType', 'Unknown type code %d, returning bytes', type_code);
                    result = raw_bytes;
                    return;
            end
            
            typed_data = typecast(raw_bytes, type_str);
            
            if is_complex
                % De-interleave complex data [r1, i1, r2, i2...]
                % 1:2:end are reals, 2:2:end are imags
                real_part = typed_data(1:2:end);
                imag_part = typed_data(2:2:end);
                result_flat = complex(real_part, imag_part);
                result = reshape(result_flat, dims);
            else
                result = reshape(typed_data, dims);
            end
        end
        
        function create_memmap(obj)
             % Create memory map object with current buffer size
             obj.shm_mmap = memmapfile(obj.shm_path, ...
                'Format', {
                    'uint64', [1 1], 'StateFlag'; ...
                    'uint64', [1 1], 'DataType'; ...
                    'uint64', [1 1], 'NDims'; ...
                    'uint64', [1 1], 'DataSize'; ...
                    'uint64', [1 8], 'Dims'; ...
                    'uint8',  [1 (128 - 32 - 64)], 'Reserved'; ...
                    'uint8',  [1 (obj.current_buffer_size - 128)], 'Data'
                }, ...
                'Writable', true);
        end
        
        function resize_shared_memory(obj, new_size)
            % RESIZE_SHARED_MEMORY Protocol to resize buffer
            % 1. Send RESIZE command
            % 2. Close local mapping
            % 3. Wait for ACK
            % 4. Re-create mapping
            
            % Send resize command
            cmd = sprintf('RESIZE %d', new_size);
            write(obj.tcp_client, uint8(cmd));
            
            % Close local map immediately to release file lock
            obj.shm_mmap = [];
            
            % Wait for ACK (or timeout)
            % We can use read(obj.tcp_client, 3) for "ACK"
            ack = char(read(obj.tcp_client, 3, 'uint8'));
            
            if ~strcmp(ack, 'ACK')
                 error('MJSE:ResizeFailed', 'Failed to receive resize ACK. Received: %s', ack);
            end
            
            % Update size and remap
            obj.current_buffer_size = new_size;
            obj.create_memmap();
        end
    end
    
    methods (Static)
        function setup()
            % SETUP Ensure Julia environment is ready
            % Downloads Julia and prewarms cache if needed
            
            % Get project root directory
            script_dir = fileparts(mfilename('fullpath'));
            repo_root = fileparts(script_dir); % m_src -> root
            external_dir = fullfile(repo_root, 'external');
            julia_dir = fullfile(external_dir, 'julia');
            
            % Create external directory if needed
            if ~exist(external_dir, 'dir')
                mkdir(external_dir);
            end
            
            % Check if Julia is present
            if ~exist(julia_dir, 'dir')
                fprintf('MJSE: Downloading portable Julia 1.12.x...\n');
                MJSE.download_julia(julia_dir);
            end
            
            % Check if cache needs prewarming
             marker_file = fullfile(julia_dir, '.mjse_ready');
             if ~exist(marker_file, 'file')
                 fprintf('MJSE: Prewarming Julia cache...\n');
                 MJSE.prewarm_julia_cache(julia_dir);
                 fclose(fopen(marker_file, 'w'));
             end
        end
    end
    
    methods (Static, Access = private)
        function download_julia(julia_dir)
            % Download portable Julia based on architecture
            arch = computer('arch');
            
            if ispc
                if strcmp(arch, 'win64')
                    julia_url = 'https://julialang-s3.julialang.org/bin/winnt/x64/1.12/julia-1.12.4-win64.zip';
                    archive_ext = 'zip';
                else
                    error('MJSE:UnsupportedPlatform', 'Unsupported Windows architecture');
                end
            elseif ismac
                if strcmp(arch, 'maci64') || strcmp(arch, 'maca64')
                    julia_url = 'https://julialang-s3.julialang.org/bin/mac/x64/1.12/julia-1.12.4-mac64.tar.gz';
                    archive_ext = 'tar.gz';
                else
                    error('MJSE:UnsupportedPlatform', 'Unsupported macOS architecture');
                end
            elseif isunix
                if strcmp(arch, 'glnxa64')
                    julia_url = 'https://julialang-s3.julialang.org/bin/linux/x64/1.12/julia-1.12.4-linux-x86_64.tar.gz';
                    archive_ext = 'tar.gz';
                else
                    error('MJSE:UnsupportedPlatform', 'Unsupported Linux architecture');
                end
            else
                error('MJSE:UnsupportedPlatform', 'Unsupported platform');
            end
            
            archive_path = fullfile(fileparts(julia_dir), ['julia.' archive_ext]);
            
            try
                opts = weboptions('Timeout', 600);
                websave(archive_path, julia_url, opts);
                
                % Extract
                if strcmp(archive_ext, 'zip')
                    unzip(archive_path, fileparts(julia_dir));
                else
                    system(sprintf('tar -xzf "%s" -C "%s"', archive_path, fileparts(julia_dir)));
                end
                
                % Move folder
                parent_dir = fileparts(julia_dir);
                extracted = dir(fullfile(parent_dir, 'julia-*'));
                if ~isempty(extracted) && extracted(1).isdir
                    movefile(fullfile(parent_dir, extracted(1).name), julia_dir);
                end
                
                delete(archive_path);
            catch ME
                if exist(archive_path, 'file'), delete(archive_path); end
                rethrow(ME);
            end
        end
        
        function prewarm_julia_cache(julia_dir)
             if ispc
                julia_bin = fullfile(julia_dir, 'bin', 'julia.exe');
            else
                julia_bin = fullfile(julia_dir, 'bin', 'julia');
            end
            
            if ~exist(julia_bin, 'file'), return; end
            
            % Get project directory (jl_src is sibling to m_src)
            script_dir = fileparts(mfilename('fullpath'));
            repo_root = fileparts(script_dir);
            jl_project = fullfile(repo_root, 'jl_src');
            
            % Run precompilation with environment scrubbing on Linux
            if isunix && ~ismac
                cmd = sprintf('env -u LD_LIBRARY_PATH -u LD_PRELOAD "%s" --project="%s" -e "using Pkg; Pkg.add(\\"ArgParse\\"); Pkg.precompile()"', ...
                    julia_bin, jl_project);
            else
                cmd = sprintf('"%s" --project="%s" -e "using Pkg; Pkg.add(\\"ArgParse\\"); Pkg.precompile()"', ...
                    julia_bin, jl_project);
            end
            
            [status, output] = system(cmd);
            if status ~= 0
                warning('MJSE:PrecompileFailed', 'Julia precompilation warning:\n%s', output);
            end
        end
    end
    
    methods
        function delete(obj)
            % Destructor - automatically called when object is destroyed
            obj.shutdown();
        end
    end
end
