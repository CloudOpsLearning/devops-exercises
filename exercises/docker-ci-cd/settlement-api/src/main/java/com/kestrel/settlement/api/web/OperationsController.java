package com.kestrel.settlement.api.web;

import com.kestrel.settlement.api.config.SettlementProperties;
import com.kestrel.settlement.api.service.ReportService;
import com.kestrel.settlement.api.service.SettlementRunService;
import com.kestrel.settlement.api.web.LedgerDtos.ReportRequest;
import com.kestrel.settlement.api.web.LedgerDtos.ReportResponse;
import com.kestrel.settlement.api.web.LedgerDtos.RuntimeResponse;
import com.kestrel.settlement.api.web.LedgerDtos.SettlementRunRequest;
import com.kestrel.settlement.api.web.LedgerDtos.SettlementRunResponse;
import jakarta.validation.Valid;
import java.io.IOException;
import java.lang.management.ManagementFactory;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

@RestController
@RequestMapping("/api/v1")
public class OperationsController {

    /** Environment keys that are safe to echo. Credentials are never in this list. */
    private static final String[] SAFE_ENV_KEYS = {
        "SETTLEMENT_ENVIRONMENT",
        "SETTLEMENT_BUILD_VERSION",
        "SETTLEMENT_BUILD_REVISION",
        "SETTLEMENT_EXPECTED_SCHEMA_VERSION",
        "JAVA_TOOL_OPTIONS",
        "JDK_JAVA_OPTIONS",
        "JAVA_OPTS"
    };

    private final ReportService reports;
    private final SettlementRunService settlements;
    private final SettlementProperties properties;

    public OperationsController(
            ReportService reports, SettlementRunService settlements, SettlementProperties properties) {
        this.reports = reports;
        this.settlements = settlements;
        this.properties = properties;
    }

    @PostMapping("/reports/monthly")
    public ReportResponse monthlyReport(@RequestBody(required = false) ReportRequest request) {
        ReportService.Report report = reports.build(request == null ? null : request.megabytes());
        return new ReportResponse(
                report.reportId(),
                report.requestedMegabytes(),
                report.rowsMaterialised(),
                report.peakHeapUsedMb(),
                report.maxHeapMb(),
                report.durationMs());
    }

    @PostMapping("/settlements/run")
    public SettlementRunResponse run(@Valid @RequestBody SettlementRunRequest request) {
        SettlementRunService.Result result = settlements.run(request.seconds(), request.batchId());
        return new SettlementRunResponse(
                result.batchId(), result.seconds(), result.durationMs(), result.entryId(), false);
    }

    /**
     * Everything an operator needs to explain why this container behaves the way it does.
     * Read this before guessing at a memory limit.
     */
    @GetMapping("/runtime")
    public RuntimeResponse runtime() {
        Runtime runtime = Runtime.getRuntime();
        String tmpDir = System.getProperty("java.io.tmpdir");

        Map<String, String> env = new LinkedHashMap<>();
        for (String key : SAFE_ENV_KEYS) {
            String value = System.getenv(key);
            env.put(key, value == null ? "" : value);
        }

        return new RuntimeResponse(
                properties.environment(),
                properties.build().version(),
                properties.build().revision(),
                properties.build().isTraceable(),
                ProcessHandle.current().pid(),
                runtime.maxMemory() / (1024 * 1024),
                runtime.totalMemory() / (1024 * 1024),
                (runtime.totalMemory() - runtime.freeMemory()) / (1024 * 1024),
                runtime.availableProcessors(),
                tmpDir,
                isWritable(Path.of(tmpDir)),
                isWritable(Path.of("/")),
                ManagementFactory.getRuntimeMXBean().getInputArguments(),
                env);
    }

    private static boolean isWritable(Path directory) {
        try {
            Path probe = Files.createTempFile(directory, "settlement-probe", ".tmp");
            Files.deleteIfExists(probe);
            return true;
        } catch (IOException | RuntimeException ex) {
            return false;
        }
    }
}
