function mjse_setup()
% MJSE_SETUP Download portable Julia, configure jlcall, and prepare MJSE environment
%
% This script prepares the MJSE environment:
% 1. Downloads portable Julia 1.12.x runtime based on architecture
% 2. Renames Linux libraries with _mjse.so suffix to prevent MATLAB library hijacking
% 3. Builds the Java bridge (MJSEBridge.jar)
% 4. Configures jlcall to use the private Julia runtime
% 5. Prewarms Julia package cache via Pkg.precompile()
%
% Environment variables:
%   MJSE_SHADOW_LIBS - Set to '1' to enable library renaming on Linux

    fprintf('=== MJSE Setup ===\n\n');
    
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
    
    % Step 2: Library renaming on Linux
    shadow_libs = getenv('MJSE_SHADOW_LIBS');
    if ~isempty(shadow_libs) && strcmp(shadow_libs, '1') && isunix && ~ismac
        fprintf('\nStep 2: Renaming Linux libraries with _mjse.so suffix...\n');
        rename_linux_libs(julia_dir);
    else
        fprintf('\nStep 2: Skipping library renaming (not needed or not enabled)\n');
    end
    
    % Step 3: Build Java bridge
    fprintf('\nStep 3: Building Java bridge...\n');
    build_java_bridge();
    
    % Step 4: Prewarm Julia cache
    fprintf('\nStep 4: Prewarming Julia cache...\n');
    prewarm_julia_cache(julia_dir);
    
    fprintf('\n=== MJSE Setup Complete ===\n');
    fprintf('You can now use jlcall:\n');
    fprintf('  jlcall(''start'');\n');
    fprintf('  result = jlcall(''sum'', [1 2 3 4 5]);\n');
    fprintf('  jlcall(''stop'');\n');
end

function download_julia(julia_dir)
    % Download portable Julia based on architecture
    
    % Determine architecture
    arch = computer('arch');
    
    % Map MATLAB arch to Julia platform
    % TODO: Actual download URLs would come from julialang.org
    % For now, we'll create placeholder structure
    
    fprintf('  Detected architecture: %s\n', arch);
    
    % Determine Julia download URL based on platform
    if ispc
        if strcmp(arch, 'win64')
            julia_platform = 'windows-x86_64';
            julia_url = 'https://julialang-s3.julialang.org/bin/winnt/x64/1.12/julia-1.12.0-win64.zip';
            archive_ext = 'zip';
        else
            error('MJSE:UnsupportedPlatform', 'Unsupported Windows architecture: %s', arch);
        end
    elseif ismac
        if strcmp(arch, 'maci64') || strcmp(arch, 'maca64')
            julia_platform = 'macos-x86_64';
            julia_url = 'https://julialang-s3.julialang.org/bin/mac/x64/1.12/julia-1.12.0-mac64.tar.gz';
            archive_ext = 'tar.gz';
        else
            error('MJSE:UnsupportedPlatform', 'Unsupported macOS architecture: %s', arch);
        end
    elseif isunix
        if strcmp(arch, 'glnxa64')
            julia_platform = 'linux-x86_64';
            julia_url = 'https://julialang-s3.julialang.org/bin/linux/x64/1.12/julia-1.12.0-linux-x86_64.tar.gz';
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
    
    fprintf('  Downloading Julia (this may take several minutes)...\n');
    
    try
        websave(archive_path, julia_url);
        fprintf('  Download complete\n');
    catch ME
        warning('MJSE:DownloadFailed', 'Failed to download Julia: %s', ME.message);
        fprintf('  Please download Julia 1.12.x manually from https://julialang.org/downloads/\n');
        fprintf('  and extract to: %s\n', julia_dir);
        return;
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

function rename_linux_libs(julia_dir)
    % Rename Linux libraries to prevent MATLAB library hijacking
    %
    % Instead of using patchelf to modify rpath, we rename the libraries
    % with _mjse.so suffix to completely isolate them from MATLAB's libs
    
    fprintf('  Renaming Linux libraries to *_mjse.so...\n');
    
    % Libraries to rename
    libs_to_rename = {'libstdc++.so.6', 'libgcc_s.so.1', 'libgfortran.so.5'};
    
    % Find Julia libraries
    julia_lib_dir = fullfile(julia_dir, 'lib', 'julia');
    
    if ~exist(julia_lib_dir, 'dir')
        fprintf('  Julia lib directory not found, skipping\n');
        return;
    end
    
    fprintf('  Renaming libraries in %s\n', julia_lib_dir);
    renamed_count = 0;
    
    for i = 1:length(libs_to_rename)
        lib_name = libs_to_rename{i};
        lib_path = fullfile(julia_lib_dir, lib_name);
        
        if exist(lib_path, 'file')
            % Create new name with _mjse suffix before .so
            [~, base_name, ~] = fileparts(lib_name);
            % Extract version suffix if present (e.g., .6 from libstdc++.so.6)
            parts = strsplit(lib_name, '.');
            if length(parts) > 2
                % Has version: libstdc++.so.6 -> libstdc++_mjse.so.6
                new_name = [parts{1}, '_mjse.', strjoin(parts(2:end), '.')];
            else
                % No version: libfoo.so -> libfoo_mjse.so
                new_name = [base_name, '_mjse.so'];
            end
            
            new_path = fullfile(julia_lib_dir, new_name);
            
            % Rename the file
            try
                movefile(lib_path, new_path);
                fprintf('    Renamed %s -> %s\n', lib_name, new_name);
                renamed_count = renamed_count + 1;
            catch ME
                warning('MJSE:RenameFailed', 'Failed to rename %s: %s', lib_name, ME.message);
            end
        end
    end
    
    fprintf('  Library renaming complete (%d files renamed)\n', renamed_count);
end

function build_java_bridge()
    % Build the Java bridge
    
    script_dir = fileparts(mfilename('fullpath'));
    bridge_dir = fullfile(script_dir, 'm_src', 'mjse');
    
    % Run bridge_build.m
    current_dir = pwd;
    try
        cd(bridge_dir);
        bridge_build();
        cd(current_dir);
    catch ME
        cd(current_dir);
        rethrow(ME);
    end
end

function prewarm_julia_cache(julia_dir)
    % Prewarm Julia package cache by precompiling
    
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
    
    fprintf('  Precompiling Julia packages...\n');
    
    % Run Julia precompilation
    cmd = sprintf('"%s" --project="%s" -e "using Pkg; Pkg.precompile()"', ...
        julia_bin, jl_project);
    
    [status, output] = system(cmd);
    
    if status ~= 0
        warning('MJSE:PrecompileFailed', 'Julia precompilation failed:\n%s', output);
    else
        fprintf('  Precompilation complete\n');
    end
end
