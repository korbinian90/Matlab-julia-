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
    end
    
    properties (Constant)
        STATE_IDLE = uint64(0)
        STATE_READY = uint64(1)
        STATE_PROCESSING = uint64(2)
        STATE_DONE = uint64(3)
        HEADER_SIZE = 8  % 8-byte StateFlag
        BUFFER_SIZE = 256 * 1024 * 1024  % 256 MB data buffer
    end
    
    methods
        function obj = MJSE()
            obj.is_initialized = false;
            obj.shm_mmap = [];
            obj.tcp_client = [];
            obj.julia_process = [];
        end
        
        function start(obj)
            if obj.is_initialized
                warning('MJSE:AlreadyInitialized', 'Already initialized');
                return;
            end
            
            try
                % Step 1: Find available port
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
            
            total_size = obj.HEADER_SIZE + obj.BUFFER_SIZE;
            
            % Create file
            fid = fopen(obj.shm_path, 'w');
            fwrite(fid, zeros(1, total_size, 'uint8'));
            fclose(fid);
            
            % Memory map with 8-byte header + data buffer
            obj.shm_mmap = memmapfile(obj.shm_path, ...
                'Format', {'uint64', [1 1], 'StateFlag'; ...
                           'uint8', [1 obj.BUFFER_SIZE], 'Data'}, ...
                'Writable', true);
            
            % Initialize to IDLE state
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
            fprintf('Julia worker log: %s\n', log_file);
            if ispc || ismac
                % On Windows and macOS, background launch returns immediately
                % (Windows: start command, macOS: nohup with &)
                [~, ~] = system(cmd);
                % Give Julia more time to start (macOS/Windows have slower startup)
                pause(5);
            else
                % Linux: env -u with & also returns immediately, but faster startup
                [~, ~] = system(cmd);
                pause(2);
            end
            
            % Display log file contents if it exists (for CI debugging)
            if isfile(log_file)
                fprintf('--- Julia Worker Log ---\n');
                log_content = fileread(log_file);
                fprintf('%s\n', log_content);
                fprintf('--- End Julia Worker Log ---\n');
            end
        end
        
        function connect_tcp(obj)
            % Connect to Julia TCP server
            max_attempts = 10;
            for attempt = 1:max_attempts
                try
                    obj.tcp_client = tcpclient('127.0.0.1', obj.tcp_port, 'Timeout', 5);
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
            write(obj.tcp_client, uint8('HANDSHAKE'));
            
            % Wait for response
            pause(0.2);
            if obj.tcp_client.BytesAvailable > 0
                response = read(obj.tcp_client, obj.tcp_client.BytesAvailable, 'char');
                if ~strcmp(strtrim(response), 'ACK')
                    error('MJSE:HandshakeFailed', 'Invalid handshake response');
                end
            else
                error('MJSE:HandshakeFailed', 'No handshake response');
            end
            
            fprintf('Handshake complete\n');
        end
        
        function write_shared_memory(obj, data)
            % Write data to shared memory and set flag
            
            % Convert data to bytes
            if isnumeric(data)
                byte_data = typecast(data(:), 'uint8');
            else
                error('MJSE:UnsupportedType', 'Only numeric data supported');
            end
            
            if length(byte_data) > obj.BUFFER_SIZE
                error('MJSE:DataTooLarge', 'Data exceeds buffer size');
            end
            
            % Write data
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
                    % Read result (for now, just echo back the data)
                    % TODO: Implement proper result reading with metadata
                    result = obj.shm_mmap.Data.Data;
                    
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
    end
    
    methods
        function delete(obj)
            % Destructor - automatically called when object is destroyed
            obj.shutdown();
        end
    end
end
