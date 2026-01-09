function test_roundtrip()
% TEST_ROUNDTRIP Test MJSE roundtrip communication with latency measurement
%
% This test exercises the MJSE engine by:
% 1. Initializing the engine (auto-setup on first run)
% 2. Sending a test matrix to Julia
% 3. Receiving the echoed data back
% 4. Reporting latency
%
% Target: ~100MB-class roundtrip (using smaller placeholder for testing)

    fprintf('=== MJSE Roundtrip Test ===\n\n');
    
    % Create test data
    % TODO: Use ~100MB matrix for full test (e.g., 10000x10000 double = 800MB)
    % For now, use smaller matrix for development testing
    fprintf('Creating test data...\n');
    test_size = 1000;  % 1000x1000 double = 8MB (placeholder)
    test_data = rand(test_size, test_size);
    data_size_mb = numel(test_data) * 8 / (1024 * 1024);
    fprintf('Test data: %dx%d double matrix (%.2f MB)\n', test_size, test_size, data_size_mb);
    
    % Initialize MJSE engine using jlcall (auto-setup on first run)
    fprintf('\nStarting Julia daemon (auto-setup if needed)...\n');
    
    try
        % Start the daemon (auto-setup happens here)
        jlcall('start');
        
        fprintf('\nTesting roundtrip communication...\n');
        
        % Get the underlying engine for direct testing
        % Note: In production, you'd use jlcall('functionname', args)
        % But for this test we need direct engine access
        engine_state = evalin('base', 'whos(''jlcall'')');
        if isempty(engine_state)
            % Create engine directly if jlcall persistent state not accessible
            engine = MJSE();
            engine.start();
            use_direct_engine = true;
        else
            % Access via reflection (not ideal but works for testing)
            % For now, create a separate engine for testing
            engine = MJSE();
            engine.start();
            use_direct_engine = true;
        end
        
        % Perform roundtrip test
        tic;
        latency = engine.test_roundtrip(test_data);
        
        % Report results
        fprintf('\n=== Test Results ===\n');
        fprintf('Data size: %.2f MB\n', data_size_mb);
        fprintf('Latency: %.4f seconds\n', latency);
        fprintf('Throughput: %.2f MB/s\n', data_size_mb / latency);
        
        fprintf('\nTest PASSED\n');
        
    catch ME
        fprintf('\nTest FAILED: %s\n', ME.message);
        fprintf('Stack trace:\n');
        disp(ME.stack);
        
        % Clean up on error
        try
            jlcall('stop');
        catch
        end
        if exist('engine', 'var') && exist('use_direct_engine', 'var') && use_direct_engine
            try
                engine.shutdown();
            catch
            end
        end
        rethrow(ME);
    end
    
    % Clean shutdown
    fprintf('\nShutting down...\n');
    if exist('engine', 'var') && exist('use_direct_engine', 'var') && use_direct_engine
        engine.shutdown();
    end
    jlcall('stop');
    
    fprintf('\n=== Test Complete ===\n');
end
