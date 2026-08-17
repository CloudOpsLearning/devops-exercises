package com.kestrel.settlement.api.migrate;

import java.time.Duration;
import org.flywaydb.core.Flyway;
import org.flywaydb.core.api.MigrationInfo;
import org.flywaydb.core.api.output.MigrateResult;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

/**
 * The deployment-time half of this artifact.
 *
 * Runs with `--migrate`, applies everything in classpath:db/migration, prints what it
 * did, and exits. It takes an advisory lock through Flyway, so two of these racing each
 * other is safe. It deliberately does not retry the connection: if the database is not
 * accepting connections yet, that is an ordering problem for whatever started this job,
 * not something to paper over with a sleep loop.
 *
 * Exit codes:
 *   0  schema is up to date
 *   64 required configuration missing
 *   70 could not connect
 *   72 a migration failed
 */
public final class MigrationRunner {

    private static final Logger log = LoggerFactory.getLogger(MigrationRunner.class);

    private MigrationRunner() {}

    public static void runAndExit() {
        String url = System.getenv("SETTLEMENT_DB_URL");
        String user = System.getenv("SETTLEMENT_DB_USER");
        String password = System.getenv("SETTLEMENT_DB_PASSWORD");

        if (isBlank(url) || isBlank(user) || isBlank(password)) {
            log.error(
                    "refusing to migrate: SETTLEMENT_DB_URL, SETTLEMENT_DB_USER and SETTLEMENT_DB_PASSWORD are all required");
            System.exit(64);
        }

        Flyway flyway;
        try {
            flyway = Flyway.configure()
                    .dataSource(url, user, password)
                    .locations("classpath:db/migration")
                    .connectRetries(0)
                    .connectRetriesInterval(1)
                    .table("flyway_schema_history")
                    .baselineOnMigrate(false)
                    .validateMigrationNaming(true)
                    .load();
        } catch (RuntimeException ex) {
            log.error("flyway could not be configured: {}", ex.getMessage());
            System.exit(72);
            return;
        }

        long startedAt = System.nanoTime();
        try {
            MigrateResult result = flyway.migrate();
            Duration took = Duration.ofNanos(System.nanoTime() - startedAt);
            log.info(
                    "schema is up to date: applied={} target={} initial={} took={}ms",
                    result.migrationsExecuted,
                    result.targetSchemaVersion,
                    result.initialSchemaVersion,
                    took.toMillis());
            for (MigrationInfo info : flyway.info().applied()) {
                log.info("applied migration version={} description={}", info.getVersion(), info.getDescription());
            }
            System.exit(0);
        } catch (Exception ex) {
            String message = String.valueOf(ex.getMessage());
            boolean connectionProblem = message.contains("Unable to obtain connection")
                    || message.contains("Connection refused")
                    || message.contains("Connection to");
            log.error("migration failed: {}", message);
            System.exit(connectionProblem ? 70 : 72);
        }
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }
}
