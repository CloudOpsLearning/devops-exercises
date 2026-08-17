package com.kestrel.settlement.api.config;

import javax.sql.DataSource;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.boot.actuate.health.Health;
import org.springframework.boot.actuate.health.HealthIndicator;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.jdbc.core.JdbcTemplate;

/**
 * Readiness is not "the process is up". For this service it means:
 * the schema this build expects has actually been applied, and the running artifact
 * can be traced back to a commit.
 *
 * Both indicators are wired into the readiness group, never into liveness - a service
 * that is restarted because its schema is one version behind will simply restart forever.
 */
@Configuration(proxyBeanMethods = false)
public class ReadinessConfiguration {

    private static final Logger log = LoggerFactory.getLogger(ReadinessConfiguration.class);

    private static final String CURRENT_VERSION_SQL =
            "select coalesce(max(cast(version as integer)), 0) from flyway_schema_history where success";

    @Bean
    JdbcTemplate settlementJdbcTemplate(DataSource dataSource) {
        return new JdbcTemplate(dataSource);
    }

    @Bean
    HealthIndicator schemaContract(JdbcTemplate jdbcTemplate, SettlementProperties properties) {
        return () -> {
            int expected = properties.expectedSchemaVersion();
            try {
                Integer current = jdbcTemplate.queryForObject(CURRENT_VERSION_SQL, Integer.class);
                int applied = current == null ? 0 : current;
                Health.Builder builder = applied >= expected ? Health.up() : Health.outOfService();
                if (applied < expected) {
                    log.warn(
                            "schema contract not satisfied: applied={} expected={} - the migration step has not run for this release",
                            applied,
                            expected);
                }
                return builder.withDetail("appliedVersion", applied)
                        .withDetail("expectedVersion", expected)
                        .build();
            } catch (RuntimeException ex) {
                log.warn("schema contract unreadable: {}", ex.getMessage());
                return Health.down()
                        .withDetail("expectedVersion", expected)
                        .withDetail("reason", "flyway_schema_history is unreadable or absent")
                        .build();
            }
        };
    }

    @Bean
    HealthIndicator buildProvenance(SettlementProperties properties) {
        return () -> {
            SettlementProperties.Build build = properties.build();
            if (build.isTraceable()) {
                return Health.up()
                        .withDetail("revision", build.revision())
                        .withDetail("version", build.version())
                        .build();
            }
            log.warn(
                    "build provenance missing: revision='{}' version='{}' - this artifact cannot be traced to a commit",
                    build.revision(),
                    build.version());
            return Health.outOfService()
                    .withDetail("revision", build.revision())
                    .withDetail("version", build.version())
                    .withDetail("reason", "the image was not stamped with the commit it was built from")
                    .build();
        };
    }
}
