package com.kestrel.settlement.api.web;

import com.kestrel.settlement.core.EntryType;
import com.kestrel.settlement.core.LedgerEntry;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import jakarta.validation.constraints.NotNull;
import jakarta.validation.constraints.Pattern;
import jakarta.validation.constraints.Size;
import java.math.BigDecimal;
import java.time.Instant;
import java.util.List;
import java.util.Map;

/** Wire contracts. Minor units in, minor units out - no floating point money. */
public final class LedgerDtos {

    private LedgerDtos() {}

    public record CreateEntryRequest(
            @NotBlank @Size(max = 64) String accountId,
            @NotNull EntryType entryType,
            @Min(1) long amountMinor,
            @NotBlank @Pattern(regexp = "^[A-Z]{3}$", message = "must be a three letter ISO 4217 code") String currency,
            @Size(max = 128) String idempotencyKey,
            @Size(max = 64) String batchId) {}

    public record EntryResponse(
            String id,
            String accountId,
            EntryType entryType,
            long amountMinor,
            BigDecimal amount,
            String currency,
            String idempotencyKey,
            String batchId,
            Instant createdAt,
            boolean created) {

        public static EntryResponse of(LedgerEntry entry, boolean created) {
            return new EntryResponse(
                    entry.getId().toString(),
                    entry.getAccountId(),
                    entry.getEntryType(),
                    entry.getAmountMinor(),
                    entry.getAmount(),
                    entry.getCurrency(),
                    entry.getIdempotencyKey(),
                    entry.getBatchId(),
                    entry.getCreatedAt(),
                    created);
        }
    }

    public record BalanceResponse(String accountId, long balanceMinor, BigDecimal balance, String currency) {}

    public record ReportRequest(Integer megabytes, String batchId) {}

    public record ReportResponse(
            String reportId,
            int requestedMegabytes,
            long rowsMaterialised,
            long peakHeapUsedMb,
            long maxHeapMb,
            long durationMs) {}

    public record SettlementRunRequest(@Min(0) int seconds, @Size(max = 64) String batchId) {}

    public record SettlementRunResponse(
            String batchId, int seconds, long durationMs, String entryId, boolean completedDuringShutdown) {}

    public record RuntimeResponse(
            String environment,
            String version,
            String revision,
            boolean traceable,
            long pid,
            long maxHeapMb,
            long totalHeapMb,
            long usedHeapMb,
            int availableProcessors,
            String tmpDir,
            boolean tmpDirWritable,
            boolean rootFilesystemWritable,
            List<String> jvmArguments,
            Map<String, String> selectedEnvironment) {}

    public record ErrorResponse(String error, String message, List<String> details) {}
}
