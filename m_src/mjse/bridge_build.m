function bridge_build()
% BRIDGE_BUILD Compile the MJSE Java bridge to MJSEBridge.jar
%
% This function compiles Bridge.java and packages it into MJSEBridge.jar
% The jar file is placed in the m_src directory for use by MATLAB.

    % Get the directory containing this script
    scriptDir = fileparts(mfilename('fullpath'));
    
    % Define paths
    javaSource = fullfile(scriptDir, 'Bridge.java');
    outputDir = fullfile(scriptDir, '..');
    jarFile = fullfile(outputDir, 'MJSEBridge.jar');
    
    % Check if Java source exists
    if ~exist(javaSource, 'file')
        error('MJSE:BridgeBuild', 'Bridge.java not found at: %s', javaSource);
    end
    
    % Check for javac
    [status, ~] = system('javac -version');
    if status ~= 0
        error('MJSE:BridgeBuild', 'javac not found. Please install Java JDK.');
    end
    
    fprintf('Compiling Bridge.java...\n');
    
    % Create temporary build directory
    buildDir = fullfile(scriptDir, 'build');
    if exist(buildDir, 'dir')
        rmdir(buildDir, 's');
    end
    mkdir(buildDir);
    
    try
        % Compile Java source
        % The -d option creates package directories (mjse/)
        compileCmd = sprintf('javac -d "%s" "%s"', buildDir, javaSource);
        [status, output] = system(compileCmd);
        
        if status ~= 0
            error('MJSE:BridgeBuild', 'Compilation failed:\n%s', output);
        end
        
        fprintf('Creating JAR file...\n');
        
        % Verify the package structure was created
        mjsePackageDir = fullfile(buildDir, 'mjse');
        if ~exist(mjsePackageDir, 'dir')
            error('MJSE:BridgeBuild', 'Package directory mjse/ not created in build directory');
        end
        
        % Create JAR file from the build directory
        % This preserves the package structure (mjse/Bridge.class)
        jarCmd = sprintf('jar cf "%s" -C "%s" .', jarFile, buildDir);
        [status, output] = system(jarCmd);
        
        if status ~= 0
            error('MJSE:BridgeBuild', 'JAR creation failed:\n%s', output);
        end
        
        % Clean up build directory
        rmdir(buildDir, 's');
        
        fprintf('Successfully created %s\n', jarFile);
        
        % Verify JAR contents
        fprintf('Verifying JAR contents...\n');
        [~, jarContents] = system(sprintf('jar tf "%s"', jarFile));
        if ~contains(jarContents, 'mjse/Bridge.class')
            warning('MJSE:BridgeBuild', 'JAR may not contain proper package structure');
            fprintf('JAR contents:\n%s\n', jarContents);
        else
            fprintf('JAR verified: contains mjse/Bridge.class\n');
        end
        
    catch ME
        % Clean up on error
        if exist(buildDir, 'dir')
            rmdir(buildDir, 's');
        end
        rethrow(ME);
    end
end
