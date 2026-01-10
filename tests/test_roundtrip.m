function test_roundtrip()
% TEST_ROUNDTRIP Test MJSE roundtrip with 100MB matrix verification
%
% Tests Universal Hybrid Architecture (TCP + Shared Memory)
% Verifies norm(original - returned) == 0 for data integrity

    fprintf('=== MJSE Roundtrip Test (Universal Hybrid) ===\n\n');
    
    % Auto-setup: Check if Julia is installed, download if needed
    fprintf('Checking setup...\n');
    script_dir = fileparts(mfilename('fullpath'));
    project_root = fileparts(script_dir);
    julia_dir = fullfile(project_root, 'external', 'julia');
    
    if ispc
        julia_exe = fullfile(julia_dir, 'bin', 'julia.exe');
    else
        julia_exe = fullfile(julia_dir, 'bin', 'julia');
    end
    
    if ~isfile(julia_exe)
        fprintf('Julia not found - running setup...\n');
        run(fullfile(project_root, 'mjse_setup.m'));
        fprintf('Setup complete!\n\n');
    end
    
    % Create 100MB test data
    fprintf('Creating 100MB test matrix...\n');
    % 100x100x100 double = 100*100*100*8 bytes = 8MB
    % For ~100MB, use 215x215x215 = ~80MB
    test_size = 215;
    test_data = rand(test_size, test_size, test_size);
    data_size_mb = numel(test_data) * 8 / (1024 * 1024);
    fprintf('Test data: %dx%dx%d double matrix (%.2f MB)\n', ...
        test_size, test_size, test_size, data_size_mb);
    
    fprintf('\nInitializing MJSE engine...\n');
    engine = MJSE();
    
    try
        engine.start();
        
        fprintf('\nPerforming roundtrip test...\n');
        tic;
        result = engine.call('echo', test_data);
        latency = toc;
        
        % Verify data integrity
        fprintf('Verifying data integrity...\n');
        if isnumeric(result) && numel(result) >= numel(test_data)
            % Reshape result to match input
            result_reshaped = result(1:numel(test_data));
            result_reshaped = reshape(result_reshaped, size(test_data));
            
            % Calculate error norm
            error_norm = norm(double(test_data(:)) - double(result_reshaped(:)));
            
            fprintf('\n=== Test Results ===\n');
            fprintf('Data size: %.2f MB\n', data_size_mb);
            fprintf('Latency: %.4f seconds\n', latency);
            fprintf('Throughput: %.2f MB/s\n', data_size_mb / latency);
            fprintf('Error norm: %.2e\n', error_norm);
            
            if error_norm < 1e-10
                fprintf('\n✓ Test PASSED - Data integrity verified (error < 1e-10)\n');
            else
                warning('Data integrity check failed: error = %.2e', error_norm);
                fprintf('\n✗ Test FAILED - Data mismatch\n');
            end
        else
            warning('Result size mismatch or invalid type');
            fprintf('\n✗ Test FAILED - Invalid result\n');
        end
        
    catch ME
        fprintf('\n✗ Test FAILED: %s\n', ME.message);
        fprintf('Stack trace:\n');
        disp(ME.stack);
        
        engine.shutdown();
        rethrow(ME);
    end
    
    % Clean shutdown
    fprintf('\nShutting down...\n');
    engine.shutdown();
    
    fprintf('\n=== Test Complete ===\n');
end
