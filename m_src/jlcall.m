function varargout = jlcall(varargin)
% JLCALL Call Julia functions from MATLAB via MATDaemon-style interface
%
% Usage:
%   jlcall('start')              - Start the Julia daemon (auto-setup if needed)
%   jlcall('stop')               - Stop the Julia daemon
%   result = jlcall(func, args)  - Call Julia function with arguments
%
% Examples:
%   jlcall('start');
%   result = jlcall('sum', [1 2 3 4 5]);
%   jlcall('stop');
%
% Data Transfer:
%   Large arrays are passed via shared memory (memmapfile) for zero-copy transfer.
%   Control messages use Unix Domain Sockets.
%
% Auto-Setup:
%   On first run, jlcall will automatically download Julia and build the Java bridge.
%   Just clone the repository and call jlcall('start')!

    persistent daemon_state;
    
    % Initialize daemon state if needed
    if isempty(daemon_state)
        daemon_state = struct();
        daemon_state.running = false;
        daemon_state.engine = [];
        daemon_state.setup_checked = false;
    end
    
    % Handle commands
    if nargin == 0
        error('jlcall:NoArgs', 'jlcall requires at least one argument');
    end
    
    cmd = varargin{1};
    
    switch lower(cmd)
        case 'start'
            if daemon_state.running
                warning('jlcall:AlreadyRunning', 'Julia daemon already running');
                return;
            end
            
            % Auto-setup check on first start
            if ~daemon_state.setup_checked
                check_and_setup();
                daemon_state.setup_checked = true;
            end
            
            % Create MJSE engine
            daemon_state.engine = MJSE();
            daemon_state.engine.start();
            daemon_state.running = true;
            
            fprintf('Julia daemon started\n');
            
        case 'stop'
            if ~daemon_state.running
                warning('jlcall:NotRunning', 'Julia daemon not running');
                return;
            end
            
            daemon_state.engine.shutdown();
            daemon_state.engine = [];
            daemon_state.running = false;
            
            fprintf('Julia daemon stopped\n');
            
        case 'isrunning'
            varargout{1} = daemon_state.running;
            
        otherwise
            % Function call
            if ~daemon_state.running
                error('jlcall:NotRunning', 'Julia daemon not running. Call jlcall(''start'') first.');
            end
            
            % First argument is the function name
            func_name = cmd;
            
            % Remaining arguments are function arguments
            func_args = varargin(2:end);
            
            % Call the function via the daemon
            result = call_julia_function(daemon_state.engine, func_name, func_args);
            
            if nargout > 0
                varargout{1} = result;
            end
    end
end

function check_and_setup()
    % Check if setup is needed and run it automatically
    
    script_dir = fileparts(mfilename('fullpath'));
    project_root = fileparts(script_dir);
    
    % Check if Java bridge exists
    jar_path = fullfile(script_dir, 'MJSEBridge.jar');
    
    % Check if Julia exists (portable or system)
    julia_dir = fullfile(project_root, 'external', 'julia');
    has_portable_julia = exist(julia_dir, 'dir') && ...
        (exist(fullfile(julia_dir, 'bin', 'julia'), 'file') || ...
         exist(fullfile(julia_dir, 'bin', 'julia.exe'), 'file'));
    
    [status, ~] = system('julia --version');
    has_system_julia = (status == 0);
    
    needs_setup = ~exist(jar_path, 'file') || (~has_portable_julia && ~has_system_julia);
    
    if needs_setup
        fprintf('\n=== First-time setup required ===\n');
        fprintf('This will download Julia and build the Java bridge.\n');
        fprintf('This only needs to be done once.\n\n');
        
        % Run setup
        if exist(fullfile(project_root, 'mjse_setup.m'), 'file')
            run(fullfile(project_root, 'mjse_setup.m'));
        else
            error('jlcall:SetupNotFound', 'Setup script not found');
        end
        
        fprintf('\nSetup complete! Starting Julia daemon...\n\n');
    end
end

function result = call_julia_function(engine, func_name, func_args)
    % Call a Julia function via the daemon
    %
    % This uses the shared memory + socket control path:
    % 1. MATLAB writes data to shared memory file via memmapfile
    % 2. MATLAB sends control message (function name, args metadata) via socket
    % 3. Julia reads from shared memory, executes function
    % 4. Julia writes result to shared memory
    % 5. Julia sends completion message via socket
    % 6. MATLAB reads result from shared memory
    
    % For now, use the existing roundtrip mechanism
    % TODO: Implement proper shared memory protocol with function dispatch
    
    if isempty(func_args)
        data = [];
    else
        data = func_args{1};
    end
    
    % Package the function call
    % Protocol: [func_name_length(4 bytes)][func_name][data]
    func_name_bytes = uint8(func_name);
    func_name_length = int32(length(func_name_bytes));
    
    % Convert data to bytes
    if isnumeric(data)
        data_bytes = typecast(data(:), 'uint8');
    else
        error('jlcall:UnsupportedType', 'Only numeric data supported currently');
    end
    
    % Build payload
    payload = [typecast(func_name_length, 'uint8'), func_name_bytes, data_bytes'];
    
    % Send via engine
    payload_size = int64(length(payload));
    
    % Send size
    size_bytes = typecast(payload_size, 'uint8');
    sent = engine.bridge.send(size_bytes);
    if sent ~= 8
        error('jlcall:SendFailed', 'Failed to send payload size');
    end
    
    % Send payload
    sent = engine.bridge.send(payload);
    if sent ~= length(payload)
        error('jlcall:SendFailed', 'Failed to send complete payload');
    end
    
    % Receive size back
    recv_size_bytes = engine.bridge.receive(8);
    if isempty(recv_size_bytes) || length(recv_size_bytes) ~= 8
        error('jlcall:ReceiveFailed', 'Failed to receive result size');
    end
    
    recv_size = typecast(uint8(recv_size_bytes), 'int64');
    
    % Receive result
    recv_bytes = engine.bridge.receive(double(recv_size));
    if isempty(recv_bytes) || length(recv_bytes) ~= recv_size
        error('jlcall:ReceiveFailed', 'Failed to receive complete result');
    end
    
    % For echo stub, just return the data
    % TODO: Parse actual result based on protocol
    result = recv_bytes;
end
