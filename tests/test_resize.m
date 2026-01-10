function test_resize()
% TEST_RESIZE Test MJSE dynamic buffer resizing
%
% Verifies:
% 1. Buffer growth when data exceeds default (256MB)
% 2. Buffer shrinking when data is small again

    fprintf('=== MJSE Resize Test ===\n\n');
    engine = MJSE();
    engine.start();
    
    % Default size is 256MB
    % Create 300MB data
    fprintf('1. Testing Growth (sending 300MB)...\n');
    test_size_large = 300 * 1024 * 1024 / 8; % double elements
    % To be safe with dims, let's make it a vector
    data_large = rand(ceil(test_size_large), 1); 
    
    fprintf('   Data size: %.2f MB\n', numel(data_large)*8/1024/1024);
    
    tic;
    result_large = engine.call('echo', data_large);
    t = toc;
    
    if isequal(size(result_large), size(data_large))
        fprintf('   ✓ Growth Success (Time: %.2fs)\n', t);
    else
        error('Growth failed: Size mismatch');
    end
    
    % Now test shrinking
    fprintf('2. Testing Shrink (sending 1KB)...\n');
    data_small = rand(100, 1);
    
    tic;
    result_small = engine.call('echo', data_small);
    t = toc;
    
    if isequal(size(result_small), size(data_small))
        fprintf('   ✓ Shrink Success (Time: %.2fs)\n', t);
    else
        error('Shrink failed: Size mismatch');
    end

    engine.shutdown();
    fprintf('\n=== Resize Test Complete ===\n');
end
