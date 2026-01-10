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
    % Uses "Shadow & Scrub" approach: recursively patch ALL .so files in lib/
    
    julia_lib = fullfile(julia_dir, 'lib');  % Process entire lib directory
    julia_lib_julia = fullfile(julia_lib, 'julia');
    
    % Check if patchelf is available
    [status, ~] = system('which patchelf');
    if status ~= 0
        warning('MJSE:PatchelfNotFound', 'patchelf not found. Install with: sudo apt-get install patchelf');
        fprintf('  Skipping library shadowing - may experience segfaults on Linux\n');
        return;
    end
    
    % Libraries to shadow (the "Trio")
    libs_to_shadow = {'libstdc++.so.6', 'libgcc_s.so.1', 'libgfortran.so.5'};
    
    % Step 1: Move originals to backup, create renamed versions
    backup_dir = fullfile(julia_lib_julia, '.backup_libs');
    if ~exist(backup_dir, 'dir')
        mkdir(backup_dir);
    end
    
    for i = 1:length(libs_to_shadow)
        lib_name = libs_to_shadow{i};
        lib_path = fullfile(julia_lib_julia, lib_name);
        
        if ~exist(lib_path, 'file')
            fprintf('      Skip %s (not found)\n', lib_name);
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
        shadowed_path = fullfile(julia_lib_julia, shadowed_name);
        
        % Copy to shadowed name, then move original to backup
        if exist(lib_path, 'file') && ~exist(shadowed_path, 'file')
            copyfile(lib_path, shadowed_path);
            fprintf('      Created %s\n', shadowed_name);
            % Move original to backup (after copy, so patching can reference it)
            backup_path = fullfile(backup_dir, lib_name);
            if ~exist(backup_path, 'file')
                movefile(lib_path, backup_path);
                fprintf('      Backed up %s\n', lib_name);
            end
        elseif exist(shadowed_path, 'file')
            fprintf('      %s already exists\n', shadowed_name);
        end
    end
    
    % Step 2: Recursively find ALL .so files in entire lib/ tree
    fprintf('    Scanning for library files in %s...\n', julia_lib);
    all_so_files = find_so_files_recursive(julia_lib);
    
    fprintf('    Found %d library files to patch\n', length(all_so_files));
    
    % Step 3: Patch ALL .so files to use renamed libraries
    patched_count = 0;
    for j = 1:length(all_so_files)
        target_lib = all_so_files{j};
        
        % Patch dependencies for each .so file
        patched_this = false;
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
            
            % Replace dependency (silently - many won't have these deps)
            cmd = sprintf('patchelf --replace-needed %s %s "%s" 2>/dev/null', ...
                lib_name, shadowed_name, target_lib);
            [status, ~] = system(cmd);
            if status == 0
                patched_this = true;
            end
        end
        
        if patched_this
            patched_count = patched_count + 1;
        end
        
        % Set RPATH to prioritize Julia's lib directories
        cmd = sprintf('patchelf --set-rpath ''$ORIGIN:$ORIGIN/../lib:$ORIGIN/../lib/julia'' "%s" 2>/dev/null', ...
            target_lib);
        system(cmd);
    end
    fprintf('    Patched %d files with new library references\n', patched_count);
        system(cmd);
    end
    
    % Step 4: Patch the julia binary executable
    julia_bin = fullfile(julia_dir, 'bin', 'julia');
    if exist(julia_bin, 'file')
        fprintf('    Patching julia binary RPATH...\n');
        cmd = sprintf('patchelf --set-rpath ''$ORIGIN/../lib:$ORIGIN/../lib/julia'' "%s" 2>/dev/null', ...
            julia_bin);
        system(cmd);
    end
    
    % Step 5: Verification - test Julia can load
    fprintf('    Verifying Julia installation...\n');
    [status, output] = system(sprintf('"%s" -e "println(\"Julia OK\")" 2>&1', julia_bin));
    if status == 0 && contains(output, 'Julia OK')
        fprintf('      ✓ Julia verification PASSED\n');
    else
        warning('MJSE:JuliaVerificationFailed', 'Julia verification failed:\n%s', output);
        
        % Run comprehensive ldd diagnostics
        fprintf('\n    === LDD DIAGNOSTICS ===\n');
        fprintf('    Checking Julia binary dependencies:\n');
        [~, bin_ldd] = system(sprintf('ldd "%s" 2>&1 | head -20', julia_bin));
        fprintf('%s\n', bin_ldd);
        
        fprintf('    Checking for "not found" in all .so files:\n');
        [~, ldd_check] = system(sprintf('find "%s" -name "*.so*" -exec ldd {} + 2>/dev/null | grep "not found" | head -10', julia_lib));
        if ~isempty(strtrim(ldd_check))
            fprintf('%s\n', ldd_check);
        else
            fprintf('      No "not found" dependencies detected\n');
        end
        
        fprintf('    Checking if shadowed libraries exist:\n');
        for i = 1:length(libs_to_shadow)
            lib_name = libs_to_shadow{i};
            so_idx = strfind(lib_name, '.so');
            prefix = lib_name(1:so_idx(1)-1);
            suffix = lib_name(so_idx(1):end);
            shadowed_name = [prefix '_mjse' suffix];
            shadowed_path = fullfile(julia_lib_julia, shadowed_name);
            if exist(shadowed_path, 'file')
                fprintf('      ✓ %s exists\n', shadowed_name);
            else
                fprintf('      ✗ %s MISSING\n', shadowed_name);
            end
        end
        fprintf('    === END DIAGNOSTICS ===\n\n');
    end
    
    fprintf('  Library shadowing complete - Julia isolated from MATLAB libs\n');
end

function so_files = find_so_files_recursive(root_dir)
    % Recursively find all .so* files AND any ELF binaries in directory tree
    % This ensures we catch all patchable files, not just those ending in .so
    so_files = {};
    
    % Get items in current directory
    items = dir(root_dir);
    
    for i = 1:length(items)
        item = items(i);
        
        % Skip . and ..
        if strcmp(item.name, '.') || strcmp(item.name, '..')
            continue;
        end
        
        % Skip backup directory
        if strcmp(item.name, '.backup_libs')
            continue;
        end
        
        full_path = fullfile(root_dir, item.name);
        
        if item.isdir
            % Recursively search subdirectories
            sub_files = find_so_files_recursive(full_path);
            so_files = [so_files, sub_files];
        else
            % Check if file is a .so file OR an ELF binary
            % Skip symlinks
            [status, ~] = system(sprintf('test -L "%s"', full_path));
            if status == 0  % Is a symlink, skip
                continue;
            end
            
            % Check if it's an .so file or patchable ELF file
            if contains(item.name, '.so')
                % Definitely a shared library
                so_files{end+1} = full_path;
            else
                % Check if it's an ELF file (let patchelf decide if it's patchable)
                [status, ~] = system(sprintf('file "%s" 2>/dev/null | grep -q ELF', full_path));
                if status == 0
                    so_files{end+1} = full_path;
                end
            end
        end
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
    cmd = sprintf('"%s" --project="%s" -e "using Pkg; Pkg.add(\\"ArgParse\\"); Pkg.precompile()"', ...
        julia_bin, jl_project);
    
    [status, output] = system(cmd);
    
    if status ~= 0
        warning('MJSE:PrecompileFailed', 'Julia precompilation failed:\n%s', output);
    else
        fprintf('  Precompilation complete\n');
    end
end
