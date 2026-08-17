package com.kestrel.settlement.api.service;

import static org.assertj.core.api.Assertions.assertThat;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import com.kestrel.settlement.core.EntryType;
import com.kestrel.settlement.core.LedgerEntry;
import com.kestrel.settlement.core.LedgerEntryRepository;
import java.time.Instant;
import java.util.Optional;
import java.util.UUID;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.springframework.dao.DataIntegrityViolationException;

/** Pure unit tests: no Spring context, no database, no container runtime. */
@ExtendWith(MockitoExtension.class)
class LedgerServiceTest {

    @Mock
    private LedgerEntryRepository repository;

    @InjectMocks
    private LedgerService service;

    private static LedgerEntry entry(String key) {
        return new LedgerEntry(
                UUID.randomUUID(), "ACC-1", EntryType.CREDIT, 5_00L, "EUR", key, "batch-1", Instant.now());
    }

    @Test
    void replaysTheExistingEntryWhenTheIdempotencyKeyIsKnown() {
        LedgerEntry existing = entry("key-1");
        when(repository.findByIdempotencyKey("key-1")).thenReturn(Optional.of(existing));

        LedgerService.Recorded recorded = service.record("ACC-1", EntryType.CREDIT, 5_00L, "EUR", "key-1", "batch-1");

        assertThat(recorded.created()).isFalse();
        assertThat(recorded.entry()).isSameAs(existing);
        verify(repository, never()).saveAndFlush(any());
    }

    @Test
    void writesANewEntryWhenTheKeyHasNotBeenSeen() {
        when(repository.findByIdempotencyKey("key-2")).thenReturn(Optional.empty());
        when(repository.saveAndFlush(any(LedgerEntry.class))).thenAnswer(call -> call.getArgument(0));

        LedgerService.Recorded recorded = service.record("ACC-9", EntryType.DEBIT, 12_50L, "EUR", " key-2 ", null);

        assertThat(recorded.created()).isTrue();
        assertThat(recorded.entry().getIdempotencyKey()).isEqualTo("key-2");
        assertThat(recorded.entry().getAccountId()).isEqualTo("ACC-9");
        assertThat(recorded.entry().signedAmountMinor()).isEqualTo(-12_50L);
    }

    @Test
    void resolvesTheRaceWhenTheUniqueIndexRejectsTheInsert() {
        LedgerEntry winner = entry("key-3");
        when(repository.findByIdempotencyKey("key-3")).thenReturn(Optional.empty(), Optional.of(winner));
        when(repository.saveAndFlush(any(LedgerEntry.class)))
                .thenThrow(new DataIntegrityViolationException("duplicate key value violates unique constraint"));

        LedgerService.Recorded recorded = service.record("ACC-1", EntryType.CREDIT, 5_00L, "EUR", "key-3", null);

        assertThat(recorded.created()).isFalse();
        assertThat(recorded.entry()).isSameAs(winner);
    }

    @Test
    void treatsBlankIdempotencyKeysAsAbsent() {
        when(repository.saveAndFlush(any(LedgerEntry.class))).thenAnswer(call -> call.getArgument(0));

        LedgerService.Recorded recorded = service.record("ACC-1", EntryType.CREDIT, 100L, "EUR", "   ", "  ");

        assertThat(recorded.entry().getIdempotencyKey()).isNull();
        assertThat(recorded.entry().getBatchId()).isNull();
        verify(repository, never()).findByIdempotencyKey(any());
    }
}
