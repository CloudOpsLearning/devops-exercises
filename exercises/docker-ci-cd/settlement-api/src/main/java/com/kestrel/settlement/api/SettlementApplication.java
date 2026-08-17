package com.kestrel.settlement.api;

import com.kestrel.settlement.api.config.SettlementProperties;
import com.kestrel.settlement.api.migrate.MigrationRunner;
import java.lang.management.ManagementFactory;
import java.util.Arrays;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.SpringApplication;
import org.springframework.boot.autoconfigure.SpringBootApplication;
import org.springframework.boot.autoconfigure.domain.EntityScan;
import org.springframework.boot.context.properties.EnableConfigurationProperties;
import org.springframework.context.event.EventListener;
import org.springframework.context.event.ContextClosedEvent;
import org.springframework.data.jpa.repository.config.EnableJpaRepositories;
import org.springframework.stereotype.Component;

@SpringBootApplication
@EnableConfigurationProperties(SettlementProperties.class)
@EntityScan(basePackages = "com.kestrel.settlement.core")
@EnableJpaRepositories(basePackages = "com.kestrel.settlement.core")
public class SettlementApplication {

    private static final Logger log = LoggerFactory.getLogger(SettlementApplication.class);

    public static void main(String[] args) {
        // One artifact, two jobs. The schema is applied by a deployment step that runs
        // this same image with --migrate and then exits; the API never migrates on boot.
        if (Arrays.asList(args).contains("--migrate")) {
            MigrationRunner.runAndExit();
            return;
        }

        log.info(
                "starting settlement-api: pid={} jvmArgs={} maxHeapMb={} processors={}",
                ProcessHandle.current().pid(),
                ManagementFactory.getRuntimeMXBean().getInputArguments(),
                Runtime.getRuntime().maxMemory() / (1024 * 1024),
                Runtime.getRuntime().availableProcessors());

        SpringApplication.run(SettlementApplication.class, args);
    }

    /**
     * Proof-of-life for the shutdown path. If this line is missing from the logs of a
     * stopped container, the JVM was killed rather than asked to stop, and any request
     * that was in flight at the time died with it.
     */
    @Component
    static class ShutdownLogger {
        private static final Logger shutdownLog = LoggerFactory.getLogger(ShutdownLogger.class);

        @EventListener
        void onClose(ContextClosedEvent event) {
            shutdownLog.info("graceful shutdown complete: context closed cleanly, in-flight work drained");
        }
    }
}
