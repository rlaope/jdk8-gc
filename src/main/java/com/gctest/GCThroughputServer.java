package com.gctest;

import com.sun.net.httpserver.HttpServer;
import com.sun.net.httpserver.HttpHandler;
import com.sun.net.httpserver.HttpExchange;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.lang.management.GarbageCollectorMXBean;
import java.lang.management.ManagementFactory;
import java.lang.management.MemoryMXBean;
import java.util.ArrayList;
import java.util.List;
import java.util.Random;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;

/**
 * GC Throughput Test Server
 *
 * This server simulates workload patterns that stress the garbage collector
 * to compare throughput between different GC algorithms (G1GC vs Parallel GC).
 */
public class GCThroughputServer {

    private static final int DEFAULT_PORT = 8080;
    private static final int THREAD_POOL_SIZE = Runtime.getRuntime().availableProcessors();

    // Metrics
    private static final AtomicLong totalRequests = new AtomicLong(0);
    private static final AtomicLong totalProcessingTimeNs = new AtomicLong(0);
    private static final long startTime = System.currentTimeMillis();

    // Memory pressure simulation
    private static final ConcurrentLinkedQueue<byte[]> shortLivedObjects = new ConcurrentLinkedQueue<>();
    private static final List<byte[]> longLivedObjects = new ArrayList<>();
    private static final int MAX_SHORT_LIVED_OBJECTS = 10000;
    private static final int LONG_LIVED_OBJECT_COUNT = 100;
    private static final int LONG_LIVED_OBJECT_SIZE = 1024 * 1024; // 1MB each

    public static void main(String[] args) throws IOException {
        int port = args.length > 0 ? Integer.parseInt(args[0]) : DEFAULT_PORT;

        printStartupInfo();
        initializeLongLivedObjects();

        HttpServer server = HttpServer.create(new InetSocketAddress(port), 0);
        ExecutorService executor = Executors.newFixedThreadPool(THREAD_POOL_SIZE);

        server.createContext("/allocate", new AllocationHandler());
        server.createContext("/heavy", new HeavyAllocationHandler());
        server.createContext("/stats", new StatsHandler());
        server.createContext("/health", new HealthHandler());
        server.createContext("/gc", new ForceGCHandler());

        server.setExecutor(executor);
        server.start();

        System.out.println("Server started on port " + port);
        System.out.println("Endpoints:");
        System.out.println("  GET /allocate - Light allocation workload");
        System.out.println("  GET /heavy    - Heavy allocation workload");
        System.out.println("  GET /stats    - View GC and throughput statistics");
        System.out.println("  GET /health   - Health check");
        System.out.println("  GET /gc       - Force garbage collection");

        // Start background cleanup thread
        startCleanupThread();
    }

    private static void printStartupInfo() {
        String separator = repeat('=', 60);
        System.out.println(separator);
        System.out.println("GC Throughput Test Server");
        System.out.println(separator);

        Runtime runtime = Runtime.getRuntime();
        MemoryMXBean memoryBean = ManagementFactory.getMemoryMXBean();

        System.out.println("JVM Information:");
        System.out.println("  Java Version: " + System.getProperty("java.version"));
        System.out.println("  VM Name: " + System.getProperty("java.vm.name"));
        System.out.println("  VM Vendor: " + System.getProperty("java.vm.vendor"));
        System.out.println();
        System.out.println("Memory Configuration:");
        System.out.println("  Max Heap: " + formatBytes(runtime.maxMemory()));
        System.out.println("  Initial Heap: " + formatBytes(memoryBean.getHeapMemoryUsage().getInit()));
        System.out.println("  Available Processors: " + runtime.availableProcessors());
        System.out.println();
        System.out.println("Garbage Collectors:");
        for (GarbageCollectorMXBean gc : ManagementFactory.getGarbageCollectorMXBeans()) {
            System.out.println("  " + gc.getName());
        }
        System.out.println(separator);
    }

    private static void initializeLongLivedObjects() {
        System.out.println("Initializing " + LONG_LIVED_OBJECT_COUNT + " long-lived objects...");
        for (int i = 0; i < LONG_LIVED_OBJECT_COUNT; i++) {
            longLivedObjects.add(new byte[LONG_LIVED_OBJECT_SIZE]);
        }
        System.out.println("Long-lived objects initialized: " +
            formatBytes((long) LONG_LIVED_OBJECT_COUNT * LONG_LIVED_OBJECT_SIZE));
    }

    private static void startCleanupThread() {
        Thread cleanupThread = new Thread(() -> {
            while (true) {
                try {
                    Thread.sleep(100);
                    while (shortLivedObjects.size() > MAX_SHORT_LIVED_OBJECTS) {
                        shortLivedObjects.poll();
                    }
                } catch (InterruptedException e) {
                    Thread.currentThread().interrupt();
                    break;
                }
            }
        });
        cleanupThread.setDaemon(true);
        cleanupThread.start();
    }

    // Light allocation handler
    static class AllocationHandler implements HttpHandler {
        private final Random random = new Random();

        @Override
        public void handle(HttpExchange exchange) throws IOException {
            long start = System.nanoTime();

            // Create short-lived objects (typical web request pattern)
            int allocations = 10 + random.nextInt(40);
            for (int i = 0; i < allocations; i++) {
                byte[] data = new byte[1024 + random.nextInt(4096)]; // 1-5KB each
                shortLivedObjects.offer(data);
            }

            long elapsed = System.nanoTime() - start;
            totalRequests.incrementAndGet();
            totalProcessingTimeNs.addAndGet(elapsed);

            String response = String.format(
                "{\"allocations\":%d,\"processingTimeUs\":%d}",
                allocations, elapsed / 1000
            );
            sendResponse(exchange, 200, response);
        }
    }

    // Heavy allocation handler
    static class HeavyAllocationHandler implements HttpHandler {
        private final Random random = new Random();

        @Override
        public void handle(HttpExchange exchange) throws IOException {
            long start = System.nanoTime();

            // Create larger objects and more allocations
            int allocations = 50 + random.nextInt(100);
            List<byte[]> tempObjects = new ArrayList<>();

            for (int i = 0; i < allocations; i++) {
                byte[] data = new byte[10240 + random.nextInt(102400)]; // 10-110KB each
                tempObjects.add(data);
                shortLivedObjects.offer(data);
            }

            // Simulate some processing
            int sum = 0;
            for (byte[] arr : tempObjects) {
                for (int i = 0; i < Math.min(100, arr.length); i++) {
                    sum += arr[i];
                }
            }

            long elapsed = System.nanoTime() - start;
            totalRequests.incrementAndGet();
            totalProcessingTimeNs.addAndGet(elapsed);

            String response = String.format(
                "{\"allocations\":%d,\"totalBytes\":%d,\"processingTimeUs\":%d,\"checksum\":%d}",
                allocations,
                tempObjects.stream().mapToLong(a -> a.length).sum(),
                elapsed / 1000,
                sum
            );
            sendResponse(exchange, 200, response);
        }
    }

    // Statistics handler
    static class StatsHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            Runtime runtime = Runtime.getRuntime();
            long uptime = System.currentTimeMillis() - startTime;
            long requests = totalRequests.get();
            double throughput = requests > 0 ? (requests * 1000.0 / uptime) : 0;
            double avgLatencyUs = requests > 0 ?
                (totalProcessingTimeNs.get() / 1000.0 / requests) : 0;

            StringBuilder sb = new StringBuilder();
            sb.append("{\n");
            sb.append("  \"uptime_ms\": ").append(uptime).append(",\n");
            sb.append("  \"total_requests\": ").append(requests).append(",\n");
            sb.append("  \"throughput_rps\": ").append(String.format("%.2f", throughput)).append(",\n");
            sb.append("  \"avg_latency_us\": ").append(String.format("%.2f", avgLatencyUs)).append(",\n");
            sb.append("  \"memory\": {\n");
            sb.append("    \"heap_used\": \"").append(formatBytes(runtime.totalMemory() - runtime.freeMemory())).append("\",\n");
            sb.append("    \"heap_total\": \"").append(formatBytes(runtime.totalMemory())).append("\",\n");
            sb.append("    \"heap_max\": \"").append(formatBytes(runtime.maxMemory())).append("\"\n");
            sb.append("  },\n");
            sb.append("  \"gc\": [\n");

            List<GarbageCollectorMXBean> gcBeans = ManagementFactory.getGarbageCollectorMXBeans();
            for (int i = 0; i < gcBeans.size(); i++) {
                GarbageCollectorMXBean gc = gcBeans.get(i);
                sb.append("    {\n");
                sb.append("      \"name\": \"").append(gc.getName()).append("\",\n");
                sb.append("      \"collection_count\": ").append(gc.getCollectionCount()).append(",\n");
                sb.append("      \"collection_time_ms\": ").append(gc.getCollectionTime()).append("\n");
                sb.append("    }");
                if (i < gcBeans.size() - 1) sb.append(",");
                sb.append("\n");
            }
            sb.append("  ]\n");
            sb.append("}");

            sendResponse(exchange, 200, sb.toString());
        }
    }

    // Health check handler
    static class HealthHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            sendResponse(exchange, 200, "{\"status\":\"healthy\"}");
        }
    }

    // Force GC handler
    static class ForceGCHandler implements HttpHandler {
        @Override
        public void handle(HttpExchange exchange) throws IOException {
            long beforeUsed = Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory();
            long start = System.currentTimeMillis();

            System.gc();

            long elapsed = System.currentTimeMillis() - start;
            long afterUsed = Runtime.getRuntime().totalMemory() - Runtime.getRuntime().freeMemory();

            String response = String.format(
                "{\"gc_time_ms\":%d,\"memory_freed\":\"%s\",\"heap_before\":\"%s\",\"heap_after\":\"%s\"}",
                elapsed,
                formatBytes(beforeUsed - afterUsed),
                formatBytes(beforeUsed),
                formatBytes(afterUsed)
            );
            sendResponse(exchange, 200, response);
        }
    }

    private static void sendResponse(HttpExchange exchange, int code, String response) throws IOException {
        exchange.getResponseHeaders().set("Content-Type", "application/json");
        byte[] bytes = response.getBytes();
        exchange.sendResponseHeaders(code, bytes.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(bytes);
        }
    }

    private static String formatBytes(long bytes) {
        if (bytes < 1024) return bytes + " B";
        if (bytes < 1024 * 1024) return String.format("%.2f KB", bytes / 1024.0);
        if (bytes < 1024 * 1024 * 1024) return String.format("%.2f MB", bytes / (1024.0 * 1024));
        return String.format("%.2f GB", bytes / (1024.0 * 1024 * 1024));
    }

    private static String repeat(char c, int count) {
        StringBuilder sb = new StringBuilder(count);
        for (int i = 0; i < count; i++) {
            sb.append(c);
        }
        return sb.toString();
    }
}
