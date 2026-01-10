function benchmark_comparison()
    % Benchmark MJSE (Shared Memory) vs File I/O (Simulated MATDaemon)
    
    addpath('m_src');
    
    % Setup MJSE
    fprintf('Starting MJSE for benchmark...\n');
    engine = MJSE();
    engine.start();
    
    % Sizes to test (in MB)
    % Note: default buffer is 256MB, so we test up to ~200MB to avoid resize overhead skewing results
    % (though resize is fast, we want steady-state perf)
    sizes_mb = [1, 10, 50, 100, 200, 1000, 5000];
    
    fprintf('\n| %-10s | %-15s | %-15s | %-10s |\n', 'Size (MB)', 'MJSE (sec)', 'File I/O (sec)', 'Speedup');
    fprintf('|%s|\n', repmat('-', 1, 62));
    
    temp_file = [tempname '.mat'];
    
    try
        for mb = sizes_mb
            % Generate data (doubles)
            n_elements = round(mb * 1024 * 1024 / 8); 
            data = rand(n_elements, 1);
            
            % --- Test MJSE ---
            % Warmup
            engine.call('echo', rand(100,1));
            
            tic;
            engine.call('echo', data);
            t_mjse = toc;
            
            % --- Test File I/O (Simulated MATDaemon) ---
            % Simulate transport: Write to disk -> "Julia reads" -> "Julia writes" -> Read from disk
            % We will simulate just ONE leg of write+read to be charitable to the file approach,
            % or two legs to be realistic? 
            % MATDaemon: MATLAB save -> Julia load -> Process -> Julia save -> MATLAB load.
            % Let's simulate: save + load (Roundtrip data transport only)
            
            tic;
            save(temp_file, 'data', '-v7'); % -v7 is faster than v7.3 for uncompressed signals usually
            loaded = load(temp_file);
            t_file = toc;
            
            % Check simplified speedup
            speedup = t_file / t_mjse;
            
            fprintf('| %-10d | %-15.4f | %-15.4f | %-10.1fx |\n', ...
                mb, t_mjse, t_file, speedup);
        end
    catch e
        fprintf('Error: %s\n', e.message);
    end
    
    % Cleanup
    if exist(temp_file, 'file')
        delete(temp_file);
    end
    engine.shutdown();
end
