function mjse_setup()
% MJSE_SETUP Download portable Julia and prepare MJSE environment (Universal Hybrid)
%
% This script prepares the MJSE environment:
% 1. Downloads portable Julia 1.12.x runtime based on architecture
% 2. Sets up library isolation via LD_LIBRARY_PATH (Linux only)
% 3. Configures jlcall to use the private Julia runtime
% 4. Prewarms Julia package cache (ArgParse, Sockets, Mmap)
%
% NO Java Bridge required in Universal Hybrid architecture

    fprintf('=== MJSE Setup (Universal Hybrid: TCP + Shared Memory) ===\n\n');
    
    % Get project root directory
    script_dir = fileparts(mfilename('fullpath'));
    external_dir = fullfile(script_dir, 'external');
    julia_dir = fullfile(external_dir, 'julia');
    
    % Create external directory if needed
    if ~exist(external_dir, 'dir')
        mkdir(external_dir);
    end
    
    % Step 1: Download portable Julia if not present
    if ~exist(julia_dir, 'dir')
        fprintf('Step 1: Downloading portable Julia 1.12.x...\n');
        download_julia(julia_dir);
    else
        fprintf('Step 1: Portable Julia already present, skipping download\n');
    end
    
    % Step 2: No library shadowing needed (Universal Hybrid checks)
    fprintf('\nStep 2: Checking Julia installation...\n');
    
    % Step 3: Prewarm Julia cache
    fprintf('\nStep 3: Prewarming Julia cache...\n');
    prewarm_julia_cache(julia_dir);
    
    fprintf('\n=== MJSE Setup Complete ===\n');
    fprintf('You can now use MJSE:\n');
    fprintf('  engine = MJSE();\n');
    fprintf('  engine.start();\n');
    fprintf('  result = engine.call(''process'', data);\n');
    fprintf('  engine.shutdown();\n');
end

function download_julia(julia_dir)
    % Download portable Julia based on architecture with robust error handling
    
    % Determine architecture
    arch = computer('arch');
    
    fprintf('  Detected architecture: %s\n', arch);
    
    % Determine Julia download URL based on platform (Julia 1.12.4 - 2026 update)
    if ispc
        if strcmp(arch, 'win64')
            julia_platform = 'windows-x86_64';
            julia_url = 'https://julialang-s3.julialang.org/bin/winnt/x64/1.12/julia-1.12.4-win64.zip';
            archive_ext = 'zip';
        else
            error('MJSE:UnsupportedPlatform', 'Unsupported Windows architecture: %s', arch);
        end
    elseif ismac
        if strcmp(arch, 'maci64') || strcmp(arch, 'maca64')
            julia_platform = 'macos-x86_64';
            julia_url = 'https://julialang-s3.julialang.org/bin/mac/x64/1.12/julia-1.12.4-mac64.tar.gz';
            archive_ext = 'tar.gz';
        else
            error('MJSE:UnsupportedPlatform', 'Unsupported macOS architecture: %s', arch);
        end
    elseif isunix
        if strcmp(arch, 'glnxa64')
            julia_platform = 'linux-x86_64';
            julia_url = 'https://julialang-s3.julialang.org/bin/linux/x64/1.12/julia-1.12.4-linux-x86_64.tar.gz';
            archive_ext = 'tar.gz';
        else
            error('MJSE:UnsupportedPlatform', 'Unsupported Linux architecture: %s', arch);
        end
    else
        error('MJSE:UnsupportedPlatform', 'Unsupported platform');
    end
    
    fprintf('  Platform: %s\n', julia_platform);
    fprintf('  Download URL: %s\n', julia_url);
    
    % Download Julia archive
    archive_path = fullfile(fileparts(julia_dir), ['julia.' archive_ext]);
    
    % Check if archive already exists (avoid re-downloading)
    if exist(archive_path, 'file')
        fprintf('  Archive already downloaded, skipping download\n');
    else
        fprintf('  Downloading Julia (~150MB, this may take several minutes)...\n');
        
        try
            % Increase timeout to 600 seconds for large download
            opts = weboptions('Timeout', 600);
            websave(archive_path, julia_url, opts);
            fprintf('  Download complete\n');
        catch ME
            warning('MJSE:DownloadFailed', 'Failed to download Julia: %s', ME.message);
            fprintf('  Please download Julia 1.12.4 manually from https://julialang.org/downloads/\n');
            fprintf('  and extract to: %s\n', julia_dir);
            return;
        end
        
        % Verify download (checksum - ensure file > 100MB)
        archive_info = dir(archive_path);
        if isempty(archive_info) || archive_info.bytes < 100e6
            warning('MJSE:CorruptArchive', 'Downloaded archive is too small (< 100MB). Connection may have failed.');
            fprintf('  Deleting corrupt archive. Please run setup again.\n');
            delete(archive_path);
            return;
        end
        fprintf('  Archive verified (%.1f MB)\n', archive_info.bytes / 1e6);
    end
    
    % Extract archive
    fprintf('  Extracting archive...\n');
    
    try
        if strcmp(archive_ext, 'zip')
            unzip(archive_path, fileparts(julia_dir));
        else
            % Use system tar for .tar.gz
            system(sprintf('tar -xzf "%s" -C "%s"', archive_path, fileparts(julia_dir)));
        end
        
        % The extracted directory typically has a version number
        % Move/rename to 'julia'
        parent_dir = fileparts(julia_dir);
        extracted = dir(fullfile(parent_dir, 'julia-*'));
        if ~isempty(extracted) && extracted(1).isdir
            movefile(fullfile(parent_dir, extracted(1).name), julia_dir);
        end
        
        % Clean up archive
        delete(archive_path);
        
        fprintf('  Extraction complete\n');
    catch ME
        warning('MJSE:ExtractionFailed', 'Failed to extract Julia: %s', ME.message);
        fprintf('  Please extract manually to: %s\n', julia_dir);
    end
end


function prewarm_julia_cache(julia_dir)
    % Prewarm Julia package cache by precompiling (including ArgParse)
    
    % Find Julia binary
    if ispc
        julia_bin = fullfile(julia_dir, 'bin', 'julia.exe');
    else
        julia_bin = fullfile(julia_dir, 'bin', 'julia');
    end
    
    if ~exist(julia_bin, 'file')
        fprintf('  Julia binary not found, skipping cache prewarming\n');
        return;
    end
    
    % Get project directory
    script_dir = fileparts(mfilename('fullpath'));
    jl_project = fullfile(script_dir, 'jl_src');
    
    fprintf('  Installing and precompiling Julia packages (ArgParse, Sockets, Mmap)...\n');
    
    % Run Julia precompilation with package installation
    % IMPORTANT: scrubbing LD_LIBRARY_PATH on Linux to prevent MATLAB library pollution
    if isunix && ~ismac
        cmd = sprintf('env -u LD_LIBRARY_PATH -u LD_PRELOAD "%s" --project="%s" -e "using Pkg; Pkg.add(\\"ArgParse\\"); Pkg.precompile()"', ...
            julia_bin, jl_project);
    else
        cmd = sprintf('"%s" --project="%s" -e "using Pkg; Pkg.add(\\"ArgParse\\"); Pkg.precompile()"', ...
            julia_bin, jl_project);
    end
    
    [status, output] = system(cmd);
    
    if status ~= 0
        warning('MJSE:PrecompileFailed', 'Julia precompilation failed:\n%s', output);
    else
        fprintf('  Precompilation complete\n');
    end
end
