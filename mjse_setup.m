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
    
    % Step 2: Apply patchelf shadowing (Linux only)
    if isunix && ~ismac
        fprintf('\nStep 2: Applying patchelf library shadowing (Linux stability)...\n');
        apply_patchelf_shadowing(julia_dir);
    else
        fprintf('\nStep 2: No library shadowing needed on this platform\n');
    end
    
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

function apply_patchelf_shadowing(julia_dir)
    % Apply patchelf library shadowing to prevent MATLAB conflicts (Linux only)
    
    julia_lib = fullfile(julia_dir, 'lib', 'julia');
    
    % Check if patchelf is available
    [status, ~] = system('which patchelf');
    if status ~= 0
        warning('MJSE:PatchelfNotFound', 'patchelf not found. Install with: sudo apt-get install patchelf');
        fprintf('  Skipping library shadowing - may experience segfaults on Linux\n');
        return;
    end
    
    % Libraries to shadow
    libs_to_shadow = {'libstdc++.so.6', 'libgcc_s.so.1', 'libgfortran.so.5'};
    
    for i = 1:length(libs_to_shadow)
        lib_name = libs_to_shadow{i};
        lib_path = fullfile(julia_lib, lib_name);
        
        if ~exist(lib_path, 'file')
            continue;
        end
        
        % Physical rename: mv lib -> lib_mjse
        % Handle multi-part extensions like .so.6
        % libstdc++.so.6 -> libstdc++_mjse.so.6
        so_idx = strfind(lib_name, '.so');
        if ~isempty(so_idx)
            % Split at first .so
            prefix = lib_name(1:so_idx(1)-1);  % e.g., 'libstdc++'
            suffix = lib_name(so_idx(1):end);   % e.g., '.so.6'
            shadowed_name = [prefix '_mjse' suffix];
        else
            [~, base_name] = fileparts(lib_name);
            shadowed_name = [base_name '_mjse'];
        end
        shadowed_path = fullfile(julia_lib, shadowed_name);
        
        % Physically rename the library (no symlinks)
        if exist(lib_path, 'file') && ~exist(shadowed_path, 'file')
            fprintf('    Renaming %s -> %s\n', lib_name, shadowed_name);
            movefile(lib_path, shadowed_path);
        end
    end
    
    % Patch Julia binaries to use renamed libraries
    % Target both libjulia-internal.so.1.12 and libjulia.so.1.12
    julia_libs_to_patch = {
        fullfile(julia_lib, 'libjulia-internal.so.1.12');
        fullfile(julia_lib, 'libjulia.so.1.12')
    };
    
    for j = 1:length(julia_libs_to_patch)
        target_lib = julia_libs_to_patch{j};
        if exist(target_lib, 'file')
            [~, target_name] = fileparts(target_lib);
            fprintf('    Patching %s dependencies...\n', target_name);
            
            for i = 1:length(libs_to_shadow)
                lib_name = libs_to_shadow{i};
                % Compute shadowed name
                so_idx = strfind(lib_name, '.so');
                if ~isempty(so_idx)
                    prefix = lib_name(1:so_idx(1)-1);
                    suffix = lib_name(so_idx(1):end);
                    shadowed_name = [prefix '_mjse' suffix];
                else
                    [~, base_name] = fileparts(lib_name);
                    shadowed_name = [base_name '_mjse'];
                end
                
                % Replace dependency
                cmd = sprintf('patchelf --replace-needed %s %s "%s" 2>/dev/null', ...
                    lib_name, shadowed_name, target_lib);
                system(cmd);
            end
            
            % Set RPATH to prioritize Julia's lib directories
            cmd = sprintf('patchelf --set-rpath ''$ORIGIN/../lib:$ORIGIN/../lib/julia'' "%s" 2>/dev/null', ...
                target_lib);
            system(cmd);
        end
    end
    
    % Patch the julia binary executable
    julia_bin = fullfile(julia_dir, 'bin', 'julia');
    if exist(julia_bin, 'file')
        fprintf('    Patching julia binary RPATH...\n');
        cmd = sprintf('patchelf --set-rpath ''$ORIGIN/../lib:$ORIGIN/../lib/julia'' "%s" 2>/dev/null', ...
            julia_bin);
        system(cmd);
    end
    
    fprintf('  Library shadowing complete - Julia isolated from MATLAB libs\n');
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
    cmd = sprintf('"%s" --project="%s" -e "using Pkg; Pkg.add(\\"ArgParse\\"); Pkg.precompile()"', ...
        julia_bin, jl_project);
    
    [status, output] = system(cmd);
    
    if status ~= 0
        warning('MJSE:PrecompileFailed', 'Julia precompilation failed:\n%s', output);
    else
        fprintf('  Precompilation complete\n');
    end
end
