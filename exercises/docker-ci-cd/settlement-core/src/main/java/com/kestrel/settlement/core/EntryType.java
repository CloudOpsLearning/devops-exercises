package com.kestrel.settlement.core;

/** Direction of money movement from the driver's point of view. */
public enum EntryType {
    /** Money owed to the driver: a completed trip, a bonus, a reimbursement. */
    CREDIT,
    /** Money reclaimed from the driver: a fee, a fine, a cash-collected offset. */
    DEBIT
}
