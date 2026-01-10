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

const HEADER_SIZE = 128  # 128-byte Header (Protocol V2)
const BUFFER_SIZE = 256 * 1024 * 1024  # 256 MB

mutable struct WorkerState
    port::Int
    shm_path::String
    matlab_pid::Int
    shm_io::Union{IOStream,Nothing}
    shm_array::Union{Vector{UInt8},Nothing}
    server::Union{Sockets.TCPServer,Nothing}
    client::Union{TCPSocket,Nothing}
    running::Bool
    heartbeat_task::Union{Task,Nothing}
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
        # Open shared memory file
        state.shm_io = open(state.shm_path, "r+")

        # Memory map entire file
        total_size = HEADER_SIZE + BUFFER_SIZE
        state.shm_array = Mmap.mmap(state.shm_io, Vector{UInt8}, total_size)

        return true
    catch e
        @error "Failed to initialize shared memory" exception = e
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

function get_data_size(state::WorkerState)
    if state.shm_array === nothing
        return UInt64(0)
    end
    return reinterpret(UInt64, state.shm_array[9:16])[1]
end

function set_data_size(state::WorkerState, size::UInt64)
    if state.shm_array === nothing
        return
    end
    state.shm_array[9:16] .= reinterpret(UInt8, [size])
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
                    @warn "MATLAB process died, shutting down" matlab_pid = state.matlab_pid
                    state.running = false
                    break
                end
            catch e
                @error "Heartbeat error" exception = e
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
        state.server = listen(ip"127.0.0.1", state.port)  # Explicitly bind to localhost
        return true
    catch e
        @error "Failed to start TCP server" exception = e
        return false
    end
end

function handle_client(state::WorkerState)
    """Handle client connection and commands"""
    try
        state.client = accept(state.server)
        @info "Client connected"

        while state.running && isopen(state.client)
            if eof(state.client)
                @info "Client disconnected"
                break
            end

            # This blocks until at least one byte is available
            data = readavailable(state.client)
            if !isempty(data)
                command = String(data)
                # @debug "Received command" command=command

                if startswith(command, "HANDSHAKE")
                    # Respond to handshake
                    write(state.client, "ACK")
                    flush(state.client)

                elseif startswith(command, "RESIZE")
                    # Protocol: RESIZE <bytes>
                    parts = split(command)
                    if length(parts) == 2
                        new_size = parse(Int, parts[2])
                        @info "Resizing shared memory" new_size = new_size

                        # Retry logic for resizing (Windows file locking can be sticky)
                        success = false
                        last_err = nothing

                        for attempt in 1:10
                            try
                                # Close current mappings if open
                                if state.shm_array !== nothing
                                    state.shm_array = nothing
                                end
                                if state.shm_io !== nothing
                                    close(state.shm_io)
                                    state.shm_io = nothing
                                end

                                GC.gc() # Force cleanup of mmap handles
                                sleep(0.2) # Give OS time to release locks

                                # Resize file
                                open(state.shm_path, "r+") do io
                                    truncate(io, new_size)
                                end

                                # Re-initialize
                                state.shm_io = open(state.shm_path, "r+")
                                state.shm_array = Mmap.mmap(state.shm_io, Vector{UInt8}, new_size)

                                success = true
                                break
                            catch e
                                last_err = e
                                @warn "Resize attempt $attempt failed" exception = e
                                sleep(0.5)
                            end
                        end

                        if success
                            write(state.client, "ACK")
                            flush(state.client)
                            @info "Resize successful" new_size = new_size
                        else
                            @error "Resize failed after retries" exception = last_err
                            write(state.client, "ERR")
                            flush(state.client)
                        end
                    end

                elseif startswith(command, "PROCESS")
                    # Process data from shared memory
                    process_data(state)

                elseif startswith(command, "SHUTDOWN")
                    state.running = false
                    break
                end
            end
        end

    catch e
        if state.running  # Only log if not intentional shutdown
            @error "Client handler error" exception = e
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
        # Simulate some processing
        sleep(0.01)

        # Set to DONE
        set_state_flag(state, STATE_DONE)

    catch e
        @error "Data processing error" exception = e
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
end

function main()
    # Force unbuffered output
    Base.stdout |> flush
    Base.stderr |> flush

    args = parse_args()

    state = WorkerState(args["port"], args["shm"], args["pid"])
    state.running = true

    try
        # Initialize shared memory
        if !init_shared_memory(state)
            return 1
        end

        # Start TCP server
        if !start_tcp_server(state)
            return 1
        end

        @info "MJSEWorker ready" port = state.port pid = state.matlab_pid

        # Start heartbeat monitoring
        start_heartbeat(state)

        # Handle client connection
        handle_client(state)

        return 0

    catch e
        @error "Worker error" exception = e
        return 1
    finally
        cleanup(state)
    end
end

# Run if executed as script
if abspath(PROGRAM_FILE) == @__FILE__
    exitcode = main()
    exit(exitcode)
end
