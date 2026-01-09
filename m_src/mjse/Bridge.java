package mjse;

import java.io.*;
import java.nio.*;
import java.nio.channels.*;
import java.net.*;

/**
 * MJSEBridge - Java bridge for MATLAB-Julia communication via UNIX domain sockets
 * 
 * Provides native socket support for MATLAB to communicate with Julia worker.
 * Uses SocketChannel with AF_UNIX on POSIX systems.
 * 
 * TODO: Windows Named Pipe support is still a stub and needs implementation.
 */
public class Bridge {
    private SocketChannel channel;
    private boolean connected;
    
    /**
     * Connect to a UNIX domain socket
     * @param socketPath Path to the UNIX socket file
     * @return true if connection successful
     */
    public boolean connectUnix(String socketPath) {
        try {
            // Check platform
            String os = System.getProperty("os.name").toLowerCase();
            
            if (os.contains("win")) {
                // TODO: Implement Windows Named Pipe support
                // For now, return false on Windows
                System.err.println("WARNING: Windows Named Pipe support not yet implemented");
                return false;
            }
            
            // UNIX domain socket connection (Java 16+)
            // Try to use UnixDomainSocketAddress via reflection for compatibility
            try {
                // Check Java version
                String javaVersion = System.getProperty("java.version");
                System.out.println("Java version: " + javaVersion);
                
                // Attempt to use Java 16+ UnixDomainSocketAddress
                Class<?> addressClass = Class.forName("java.net.UnixDomainSocketAddress");
                Class<?> familyClass = Class.forName("java.net.StandardProtocolFamily");
                
                // Get UNIX enum value
                Object unixFamily = java.lang.Enum.valueOf(
                    (Class<? extends Enum>)familyClass, "UNIX");
                
                // Create UnixDomainSocketAddress
                java.lang.reflect.Method ofMethod = addressClass.getMethod("of", String.class);
                Object address = ofMethod.invoke(null, socketPath);
                
                // Open SocketChannel with UNIX family
                java.lang.reflect.Method openMethod = SocketChannel.class.getMethod(
                    "open", Class.forName("java.net.ProtocolFamily"));
                channel = (SocketChannel)openMethod.invoke(null, unixFamily);
                
                // Connect
                channel.connect((java.net.SocketAddress)address);
                channel.configureBlocking(true);
                connected = true;
                return true;
                
            } catch (ClassNotFoundException e) {
                // Java < 16, UnixDomainSocketAddress not available
                System.err.println("UNIX domain sockets require Java 16+");
                System.err.println("Current Java version does not support UnixDomainSocketAddress");
                System.err.println("Please upgrade to Java 16+ or use JNI/JNA for UNIX socket support");
                return false;
            } catch (Exception e) {
                System.err.println("Failed to connect to UNIX socket: " + e.getMessage());
                e.printStackTrace();
                return false;
            }
        } catch (Exception e) {
            System.err.println("Error in connectUnix: " + e.getMessage());
            return false;
        }
    }
    
    /**
     * Send data through the socket
     * @param data Byte array to send
     * @return Number of bytes sent, or -1 on error
     */
    public int send(byte[] data) {
        if (!connected || channel == null) {
            return -1;
        }
        
        try {
            ByteBuffer buffer = ByteBuffer.wrap(data);
            return channel.write(buffer);
        } catch (IOException e) {
            System.err.println("Error sending data: " + e.getMessage());
            return -1;
        }
    }
    
    /**
     * Receive data from the socket
     * @param maxBytes Maximum number of bytes to receive
     * @return Received data as byte array, or null on error
     */
    public byte[] receive(int maxBytes) {
        if (!connected || channel == null) {
            return null;
        }
        
        try {
            ByteBuffer buffer = ByteBuffer.allocate(maxBytes);
            int bytesRead = channel.read(buffer);
            
            if (bytesRead <= 0) {
                return null;
            }
            
            byte[] result = new byte[bytesRead];
            buffer.flip();
            buffer.get(result);
            return result;
        } catch (IOException e) {
            System.err.println("Error receiving data: " + e.getMessage());
            return null;
        }
    }
    
    /**
     * Close the connection
     */
    public void close() {
        if (channel != null) {
            try {
                channel.close();
                connected = false;
            } catch (IOException e) {
                System.err.println("Error closing channel: " + e.getMessage());
            }
        }
    }
    
    /**
     * Check if connected
     * @return true if connected
     */
    public boolean isConnected() {
        return connected && channel != null && channel.isConnected();
    }
}
