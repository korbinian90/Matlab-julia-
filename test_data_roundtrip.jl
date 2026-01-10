using Sockets
using Mmap
using Random

# Constants
const HEADER_SIZE = 8
const STATE_IDLE = UInt64(0)
const STATE_READY = UInt64(1)
const STATE_PROCESSING = UInt64(2)
const STATE_DONE = UInt64(3)

# 1. Setup Shared Memory
shm_path = joinpath(tempdir(), "mjse_data_test.dat")
# Size similar to user report (75MB) -> ~78e6 bytes
# We use a smaller size for speed but large enough to test mapping (e.g. 10MB)
data_size = 10 * 1024 * 1024 
total_size = HEADER_SIZE + data_size

open(shm_path, "w") do io
    write(io, zeros(UInt8, total_size))
end

# Map it client-side (Simulating MATLAB)
client_io = open(shm_path, "r+")
client_map = Mmap.mmap(client_io, Vector{UInt8}, total_size)

# Helper to get/set state
function get_state(m)
    reinterpret(UInt64, m[1:8])[1]
end
function set_state(m, s)
    m[1:8] .= reinterpret(UInt8, [s])
end

# 2. Start Worker
port = 45679
pid = getpid()
worker_script = joinpath(pwd(), "jl_src", "MJSEWorker.jl")

println("Starting worker...")
worker_cmd = `julia --project=jl_src $worker_script --port $port --shm $shm_path --pid $pid`
worker_process = run(pipeline(worker_cmd, stdout="worker_data.log", stderr="worker_data_err.log"), wait=false)

sleep(5) # Wait for startup

try
    # 3. Connect
    println("Connecting...")
    socket = connect(ip"127.0.0.1", port)
    
    # Handshake
    println("Handshaking...")
    write(socket, "HANDSHAKE")
    flush(socket)
    resp = String(read(socket, 3))
    println("Handshake response: $resp")
    if resp != "ACK"
        error("Handshake failed")
    end

    # 4. Write Data (Client side)
    println("Generating random data...")
    # Use random bytes
    test_data = rand(UInt8, data_size)
    
    println("Writing data to shared memory...")
    # Copy data to map
    client_map[HEADER_SIZE+1:end] .= test_data
    
    # Ensure it's written (Julia Mmap usually syncs, checking behavior)
    Mmap.sync!(client_map)
    
    set_state(client_map, STATE_READY)
    Mmap.sync!(client_map)
    
    # 5. Trigger Process
    println("Sending PROCESS command...")
    write(socket, "PROCESS")
    flush(socket)
    
    # 6. Wait for done
    println("Waiting for completion...")
    t_start = time()
    while get_state(client_map) != STATE_DONE
        if time() - t_start > 10
            error("Timeout waiting for processing")
        end
        sleep(0.1)
        # Re-read map? (In Julia accessing array reads from mem)
    end
    println("Processing done!")
    
    # 7. Verify Data
    println("Verifying data...")
    result_data = client_map[HEADER_SIZE+1:end]
    
    if result_data == test_data
        println("SUCCESS: Data matches!")
    else
        println("FAILURE: Data mismatch!")
        diff_count = sum(result_data .!= test_data)
        println("Diff count: $diff_count / $data_size")
        println("First 10 expected: $(test_data[1:10])")
        println("First 10 actual:   $(result_data[1:10])")
        
        if all(result_data .== 0)
            println("Actual data is ALL ZEROS")
        end
    end
    
    write(socket, "SHUTDOWN")
    flush(socket)
    close(socket)

catch e
    println("ERROR: $e")
    if isfile("worker_data_err.log")
        println("--- Worker Stderr ---")
        println(read("worker_data_err.log", String))
    end
finally
    close(client_io)
    rm(shm_path, force=true)
    kill(worker_process)
end
