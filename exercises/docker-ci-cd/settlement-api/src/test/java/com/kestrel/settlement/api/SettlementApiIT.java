package com.kestrel.settlement.api;

import static org.assertj.core.api.Assertions.assertThat;

import com.kestrel.settlement.api.web.LedgerDtos.BalanceResponse;
import com.kestrel.settlement.api.web.LedgerDtos.CreateEntryRequest;
import com.kestrel.settlement.api.web.LedgerDtos.EntryResponse;
import com.kestrel.settlement.core.EntryType;
import org.junit.jupiter.api.Test;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.boot.test.context.SpringBootTest;
import org.springframework.boot.test.web.client.TestRestTemplate;
import org.springframework.http.HttpStatus;
import org.springframework.http.ResponseEntity;
import org.springframework.test.context.DynamicPropertyRegistry;
import org.springframework.test.context.DynamicPropertySource;
import org.testcontainers.containers.PostgreSQLContainer;
import org.testcontainers.junit.jupiter.Container;
import org.testcontainers.junit.jupiter.Testcontainers;

/**
 * The suite that cannot run inside `docker build`.
 *
 * It starts a real PostgreSQL, applies the real migrations, and exercises the real
 * unique index that keeps duplicate payouts out of the ledger. It needs a container
 * runtime, which means it belongs in a pipeline job that has one - and it must never be
 * skipped to make a build go green.
 */
@Testcontainers
@SpringBootTest(
        webEnvironment = SpringBootTest.WebEnvironment.RANDOM_PORT,
        properties = {
            "spring.flyway.enabled=true",
            "settlement.environment=integration-test",
            "settlement.build.revision=0000000000000000000000000000000000000000",
            "settlement.build.version=0.0.0-it",
            "management.server.port=0"
        })
class SettlementApiIT {

    @Container
    static final PostgreSQLContainer<?> POSTGRES = new PostgreSQLContainer<>("postgres:16.4-alpine")
            .withDatabaseName("settlement")
            .withUsername("settlement")
            .withPassword("integration-only-not-a-real-secret");

    @DynamicPropertySource
    static void databaseProperties(DynamicPropertyRegistry registry) {
        registry.add("SETTLEMENT_DB_URL", POSTGRES::getJdbcUrl);
        registry.add("SETTLEMENT_DB_USER", POSTGRES::getUsername);
        registry.add("SETTLEMENT_DB_PASSWORD", POSTGRES::getPassword);
    }

    @Autowired
    private TestRestTemplate rest;

    @Test
    void recordsAnEntryAndComputesTheBalance() {
        String account = "ACC-IT-1";
        ResponseEntity<EntryResponse> credit = rest.postForEntity(
                "/api/v1/entries",
                new CreateEntryRequest(account, EntryType.CREDIT, 250_00L, "EUR", null, "batch-it"),
                EntryResponse.class);
        assertThat(credit.getStatusCode()).isEqualTo(HttpStatus.CREATED);

        ResponseEntity<EntryResponse> debit = rest.postForEntity(
                "/api/v1/entries",
                new CreateEntryRequest(account, EntryType.DEBIT, 50_00L, "EUR", null, "batch-it"),
                EntryResponse.class);
        assertThat(debit.getStatusCode()).isEqualTo(HttpStatus.CREATED);

        BalanceResponse balance = rest.getForObject("/api/v1/accounts/" + account + "/balance", BalanceResponse.class);
        assertThat(balance).isNotNull();
        assertThat(balance.balanceMinor()).isEqualTo(200_00L);
    }

    @Test
    void refusesToMoveMoneyTwiceForTheSameIdempotencyKey() {
        CreateEntryRequest request =
                new CreateEntryRequest("ACC-IT-2", EntryType.CREDIT, 99_00L, "EUR", "webhook-42", "batch-it");

        ResponseEntity<EntryResponse> first = rest.postForEntity("/api/v1/entries", request, EntryResponse.class);
        ResponseEntity<EntryResponse> replay = rest.postForEntity("/api/v1/entries", request, EntryResponse.class);

        assertThat(first.getStatusCode()).isEqualTo(HttpStatus.CREATED);
        assertThat(replay.getStatusCode()).isEqualTo(HttpStatus.OK);
        assertThat(replay.getBody()).isNotNull();
        assertThat(replay.getBody().created()).isFalse();
        assertThat(replay.getBody().id()).isEqualTo(first.getBody().id());

        BalanceResponse balance = rest.getForObject("/api/v1/accounts/ACC-IT-2/balance", BalanceResponse.class);
        assertThat(balance.balanceMinor()).isEqualTo(99_00L);
    }

    @Test
    void rejectsAnInvalidCurrency() {
        ResponseEntity<String> response = rest.postForEntity(
                "/api/v1/entries",
                new CreateEntryRequest("ACC-IT-3", EntryType.CREDIT, 1_00L, "euro", null, null),
                String.class);

        assertThat(response.getStatusCode()).isEqualTo(HttpStatus.BAD_REQUEST);
        assertThat(response.getBody()).contains("invalid_request");
    }
}
