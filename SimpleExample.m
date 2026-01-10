% SimpleExample.m
% Demonstrates how to use MJSE to call Julia from MATLAB

% 1. Create the engine (this automatically downloads Julia if needed)
fprintf('Initializing MJSE...\n');
engine = MJSE();

% 2. Start the worker process
engine.start();

% 3. Create some data
data = rand(10, 10);
fprintf('Sending %dx%d matrix to Julia...\n', size(data));

% 4. Call Julia (function execution)
% This sends data to shared memory, triggers Julia, and waits for result
result_bytes = engine.call('process', data);

% 5. Result is now fully typed and shaped automatically
result = result_bytes;

if isequal(size(result), size(data))
    fprintf('Success! Received result back.\n');
    disp(result(1:3, 1:3)); % Display top-left corner
else
    fprintf('Error: Result size mismatch.\n');
end

% 6. Clean up
engine.shutdown();
fprintf('Done.\n');
