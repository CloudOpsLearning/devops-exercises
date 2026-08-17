package com.kestrel.settlement.api.service;

import static org.assertj.core.api.Assertions.assertThat;

import com.kestrel.settlement.api.config.SettlementProperties;
import org.junit.jupiter.api.Test;

class ReportServiceTest {

    private static ReportService serviceWith(int defaultMb, int maxMb) {
        SettlementProperties properties = new SettlementProperties(
                "test",
                3,
                new SettlementProperties.Build("0123456789abcdef", "0.0.0-test"),
                new SettlementProperties.Report(defaultMb, maxMb));
        return new ReportService(properties);
    }

    @Test
    void materialisesTheRequestedNumberOfMegabytes() {
        ReportService.Report report = serviceWith(1, 8).build(2);

        assertThat(report.requestedMegabytes()).isEqualTo(2);
        assertThat(report.rowsMaterialised()).isPositive();
        assertThat(report.maxHeapMb()).isPositive();
    }

    @Test
    void fallsBackToTheConfiguredDefault() {
        ReportService.Report report = serviceWith(3, 8).build(null);

        assertThat(report.requestedMegabytes()).isEqualTo(3);
    }

    @Test
    void refusesToExceedTheConfiguredCeiling() {
        ReportService.Report report = serviceWith(1, 4).build(4096);

        assertThat(report.requestedMegabytes()).isEqualTo(4);
    }
}
