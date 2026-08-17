package com.kestrel.settlement.core;

import java.util.List;
import java.util.Optional;
import java.util.UUID;
import org.springframework.data.domain.Limit;
import org.springframework.data.jpa.repository.JpaRepository;
import org.springframework.data.jpa.repository.Query;
import org.springframework.data.repository.query.Param;

public interface LedgerEntryRepository extends JpaRepository<LedgerEntry, UUID> {

    Optional<LedgerEntry> findByIdempotencyKey(String idempotencyKey);

    List<LedgerEntry> findByAccountIdOrderByCreatedAtDesc(String accountId, Limit limit);

    List<LedgerEntry> findAllByOrderByCreatedAtDesc(Limit limit);

    @Query("""
           select coalesce(sum(case when e.entryType = com.kestrel.settlement.core.EntryType.DEBIT
                                    then -e.amountMinor else e.amountMinor end), 0)
           from LedgerEntry e
           where e.accountId = :accountId
           """)
    long balanceMinorFor(@Param("accountId") String accountId);

    long countByBatchId(String batchId);
}
