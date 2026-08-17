package com.kestrel.settlement.api.service;

import com.kestrel.settlement.api.config.SettlementProperties;
import java.util.ArrayList;
import java.util.List;
import java.util.UUID;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Service;

/**
 * Month-end reconciliation.
 *
 * The real implementation streams a month of ledger rows into an in-memory pivot before
 * it can emit the finance export, and finance will not accept a paginated version. This
 * reproduces the shape that matters for operations: a large, short-lived, live heap.
 *
 * How much heap the JVM is *allowed* to use is a separate number from how much the
 * container is allowed to use, and neither of them is chosen by this class.
 */
@Service
public class ReportService {

    private static final Logger log = LoggerFactory.getLogger(ReportService.class);
    private static final int CHUNK_BYTES = 256 * 1024;
    private static final int CHUNKS_PER_MB = 4;
    private static final long ROWS_PER_CHUNK = 1_024;

    private final SettlementProperties properties;

    public ReportService(SettlementProperties properties) {
        this.properties = properties;
    }

    public record Report(
            String reportId,
            int requestedMegabytes,
            long rowsMaterialised,
            long peakHeapUsedMb,
            long maxHeapMb,
            long durationMs) {}

    public Report build(Integer requestedMegabytes) {
        int megabytes = requestedMegabytes == null
                ? properties.report().defaultMegabytes()
                : Math.clamp(requestedMegabytes, 1, properties.report().maxMegabytes());

        String reportId = UUID.randomUUID().toString();
        long startedAt = System.nanoTime();
        long maxHeapMb = Runtime.getRuntime().maxMemory() / (1024 * 1024);

        log.info("building month-end report id={} targetMb={} maxHeapMb={}", reportId, megabytes, maxHeapMb);

        List<byte[]> pivot = new ArrayList<>(megabytes * CHUNKS_PER_MB);
        long rows = 0;
        for (int chunk = 0; chunk < megabytes * CHUNKS_PER_MB; chunk++) {
            byte[] block = new byte[CHUNK_BYTES];
            // Touch every page so the pages are really committed, not just reserved.
            for (int offset = 0; offset < block.length; offset += 4096) {
                block[offset] = (byte) (chunk & 0x7f);
            }
            pivot.add(block);
            rows += ROWS_PER_CHUNK;
        }

        Runtime runtime = Runtime.getRuntime();
        long peakUsedMb = (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024);
        long checksum = 0;
        for (byte[] block : pivot) {
            checksum += block[0];
        }
        pivot.clear();

        long durationMs = (System.nanoTime() - startedAt) / 1_000_000;
        log.info(
                "report complete id={} rows={} peakHeapUsedMb={} maxHeapMb={} checksum={} durationMs={}",
                reportId,
                rows,
                peakUsedMb,
                maxHeapMb,
                checksum,
                durationMs);

        return new Report(reportId, megabytes, rows, peakUsedMb, maxHeapMb, durationMs);
    }
}
