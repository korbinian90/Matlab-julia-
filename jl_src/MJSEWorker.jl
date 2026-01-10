#!/usr/bin/env julia

"""
MJSEWorker - Universal Hybrid TCP + Shared Memory Worker

TCP Control Plane on localhost + Shared Memory Data Plane
Compatible with MATLAB R2019b-R2026+ (no Java Bridge)

Usage:
    julia MJSEWorker.jl --port PORT --shm SHM_PATH --pid MATLAB_PID
"""

using Sockets
using Mmap
using ArgParse

# StateFlag values (must match MATLAB)
const STATE_IDLE = UInt64(0)
const STATE_READY = UInt64(1)
const STATE_PROCESSING = UInt64(2)
const STATE_DONE = UInt64(3)

const HEADER_SIZE = 8  # 8-byte StateFlag
const BUFFER_SIZE = 256 * 1024 * 1024  # 256 MB

mutable struct WorkerState
    port::Int
    shm_path::String
    matlab_pid::Int
    shm_io::Union{IOStream, Nothing}
    shm_array::Union{Vector{UInt8}, Nothing}
    server::Union{Sockets.TCPServer, Nothing}
    client::Union{TCPSocket, Nothing}
    running::Bool
    heartbeat_task::Union{Task, Nothing}
end

function WorkerState(port::Int, shm_path::String, matlab_pid::Int)
    WorkerState(port, shm_path, matlab_pid, nothing, nothing, nothing, nothing, false, nothing)
end

function parse_args()
    s = ArgParseSettings()
    @add_arg_table! s begin
        "--port"
            help = "TCP port number"
            arg_type = Int
            required = true
        "--shm"
            help = "Shared memory file path"
            required = true
        "--pid"
            help = "MATLAB process ID"
            arg_type = Int
            required = true
    end
    return ArgParse.parse_args(s)
end

function init_shared_memory(state::WorkerState)
    try
        @info "Opening shared memory" path=state.shm_path
        
        # Open shared memory file
        state.shm_io = open(state.shm_path, "r+")
        
        # Memory map entire file
        total_size = HEADER_SIZE + BUFFER_SIZE
        state.shm_array = Mmap.mmap(state.shm_io, Vector{UInt8}, total_size)
        
        @info "Shared memory initialized" size_mb=total_size/1024/1024
        return true
    catch e
        @error "Failed to initialize shared memory" exception=e
        return false
    end
end

function get_state_flag(state::WorkerState)
    if state.shm_array === nothing
        return STATE_IDLE
    end
    return reinterpret(UInt64, state.shm_array[1:8])[1]
end

function set_state_flag(state::WorkerState, flag::UInt64)
    if state.shm_array === nothing
        return
    end
    state.shm_array[1:8] .= reinterpret(UInt8, [flag])
end

function get_data(state::WorkerState)
    if state.shm_array === nothing
        return UInt8[]
    end
    return view(state.shm_array, (HEADER_SIZE+1):length(state.shm_array))
end

function start_heartbeat(state::WorkerState)
    """Monitor MATLAB PID and exit if process dies"""
    state.heartbeat_task = @async begin
        while state.running
            try
                # Check if MATLAB process is still alive
                if !isprocess_alive(state.matlab_pid)
                    @warn "MATLAB process died, shutting down" matlab_pid=state.matlab_pid
                    state.running = false
                    break
                end
            catch e
                @error "Heartbeat error" exception=e
            end
            sleep(1.0)
        end
    end
end

function isprocess_alive(pid::Int)
    """Check if process with given PID is alive"""
    try
        if Sys.iswindows()
            # Windows: use tasklist
            result = read(`tasklist /FI "PID eq $pid"`, String)
            return occursin(string(pid), result)
        else
            # Unix: send signal 0 (just checks if process exists)
            run(`kill -0 $pid`)
            return true
        end
    catch
        return false
    end
end

function start_tcp_server(state::WorkerState)
    try
        @info "Starting TCP server" port=state.port
        state.server = listen(ip"127.0.0.1", state.port)  # Explicitly bind to localhost
        @info "TCP server listening" port=state.port
        return true
    catch e
        @error "Failed to start TCP server" exception=e
        return false
    end
end

function handle_client(state::WorkerState)
    """Handle client connection and commands"""
    try
        println(stderr, "=== handle_client: About to call accept() ===")
        flush(stderr)
        @info "Waiting for client connection..."
        flush(stdout)
        flush(stderr)
        
        println(stderr, "=== Calling accept() now ===")
        flush(stderr)
        state.client = accept(state.server)
        println(stderr, "=== accept() returned successfully ===")
        flush(stderr)
        
        @info "Client connected"
        flush(stdout)
        flush(stderr)
        
        while state.running
            # Check for incoming commands
            if bytesavailable(state.client) > 0
                command = String(read(state.client, available=true))
                @info "Received command" command=command
                
                if startswith(command, "HANDSHAKE")
                    # Respond to handshake
                    write(state.client, "ACK")
                    @info "Handshake complete"
                    
                elseif startswith(command, "PROCESS")
                    # Process data from shared memory
                    process_data(state)
                    
                elseif startswith(command, "SHUTDOWN")
                    @info "Shutdown requested"
                    state.running = false
                    break
                end
            end
            
            sleep(0.01)  # Prevent busy-waiting
        end
        
    catch e
        if state.running  # Only log if not intentional shutdown
            @error "Client handler error" exception=e
        end
    finally
        try
            close(state.client)
        catch
        end
    end
end

function process_data(state::WorkerState)
    """Process data from shared memory"""
    try
        # Wait for READY flag
        max_wait = 30  # 30 second timeout
        start_time = time()
        
        while time() - start_time < max_wait
            flag = get_state_flag(state)
            if flag == STATE_READY
                break
            end
            sleep(0.01)
        end
        
        if get_state_flag(state) != STATE_READY
            @error "Timeout waiting for READY flag"
            return
        end
        
        # Set to PROCESSING
        set_state_flag(state, STATE_PROCESSING)
        
        # Get data view
        data_view = get_data(state)
        
        # TODO: Actual processing here
        # For now, just echo back (data already in shared memory)
        @info "Processing data" size_bytes=length(data_view)
        
        # Simulate some processing
        sleep(0.01)
        
        # Set to DONE
        set_state_flag(state, STATE_DONE)
        @info "Processing complete"
        
    catch e
        @error "Data processing error" exception=e
        set_state_flag(state, STATE_IDLE)
    end
end

function cleanup(state::WorkerState)
    """Clean up resources"""
    state.running = false
    
    try
        if state.heartbeat_task !== nothing
            wait(state.heartbeat_task)
        end
    catch
    end
    
    try
        if state.client !== nothing
            close(state.client)
        end
    catch
    end
    
    try
        if state.server !== nothing
            close(state.server)
        end
    catch
    end
    
    try
        if state.shm_io !== nothing
            close(state.shm_io)
        end
    catch
    end
    
    @info "Cleanup complete"
end

function main()
    # Force unbuffered output from the start
    println(stderr, "=== JULIA WORKER STARTING ===")
    flush(stderr)
    println(stdout, "=== JULIA WORKER STARTING ===")
    flush(stdout)
    
    # Flush output immediately for debugging
    Base.stdout |> flush
    Base.stderr |> flush
    
    println(stderr, "About to parse args...")
    flush(stderr)
    
    args = parse_args()
    
    println(stderr, "Args parsed successfully")
    flush(stderr)
    
    @info "MJSEWorker starting" port=args["port"] shm=args["shm"] matlab_pid=args["pid"]
    flush(stdout)
    flush(stderr)
    
    state = WorkerState(args["port"], args["shm"], args["pid"])
    state.running = true
    
    println(stderr, "WorkerState created")
    flush(stderr)
    
    try
        # Initialize shared memory
        println(stderr, "Initializing shared memory...")
        flush(stderr)
        
        if !init_shared_memory(state)
            @error "Failed to initialize shared memory"
            flush(stdout)
            flush(stderr)
            return 1
        end
        
        println(stderr, "Shared memory initialized")
        flush(stderr)
        
        # Start TCP server
        println(stderr, "Starting TCP server...")
        flush(stderr)
        
        if !start_tcp_server(state)
            @error "Failed to start TCP server"
            flush(stdout)
            flush(stderr)
            return 1
        end
        
        println(stderr, "TCP server started on port $(state.port)")
        flush(stderr)
        
        # Start heartbeat monitoring
        start_heartbeat(state)
        
        @info "Server ready, waiting for client..."
        flush(stdout)
        flush(stderr)
        
        println(stderr, "=== main: About to call handle_client() ===")
        flush(stderr)
        
        # Handle client connection
        println(stderr, "=== main: Calling handle_client() ===")
        flush(stderr)
        handle_client(state)
        println(stderr, "=== main: handle_client() returned ===")
        flush(stderr)
        
        @info "Worker shutting down normally"
        flush(stdout)
        flush(stderr)
        return 0
        
    catch e
        println(stderr, "=== JULIA WORKER ERROR ===")
        flush(stderr)
        @error "Worker error" exception=e
        println(stderr, "Exception details: $e")
        flush(stderr)
        for (exc, bt) in Base.catch_stack()
            showerror(stderr, exc, bt)
            println(stderr)
        end
        flush(stdout)
        flush(stderr)
        return 1
    finally
        println(stderr, "=== JULIA WORKER CLEANUP ===")
        flush(stderr)
        cleanup(state)
    end
end

# Run if executed as script
if abspath(PROGRAM_FILE) == @__FILE__
    println(stderr, "=== JULIA WORKER ENTRY POINT ===")
    flush(stderr)
    exitcode = main()
    println(stderr, "=== JULIA WORKER EXITING WITH CODE $exitcode ===")
    flush(stderr)
    exit(exitcode)
end
