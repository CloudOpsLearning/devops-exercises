package com.kestrel.settlement.api.config;

import jakarta.validation.Valid;
import jakarta.validation.constraints.Min;
import jakarta.validation.constraints.NotBlank;
import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.validation.annotation.Validated;

/**
 * Configuration that has no safe default.
 *
 * A settlement service that cannot say which environment it is in, or which commit it
 * was built from, is not something finance can reconcile against. Boot fails rather
 * than guess.
 */
@Validated
@ConfigurationProperties(prefix = "settlement")
public record SettlementProperties(
        @NotBlank String environment,
        @Min(1) int expectedSchemaVersion,
        @Valid Build build,
        @Valid Report report) {

    public record Build(@NotBlank String revision, @NotBlank String version) {

        /** True when the image was stamped with real build provenance. */
        public boolean isTraceable() {
            return revision != null
                    && !revision.isBlank()
                    && !"unknown".equalsIgnoreCase(revision)
                    && revision.length() >= 7;
        }
    }

    public record Report(@Min(1) int defaultMegabytes, @Min(1) int maxMegabytes) {}
}
