import Foundation

enum JournalSchema {
    static let applicationID: Int64 = 0x524C594A
    static let version: Int64 = 1
    static let statements: [String] = [
        """
        CREATE TABLE journal_state (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            identity TEXT NOT NULL CHECK (identity = 'relay-conversation-journal'),
            format_version INTEGER NOT NULL CHECK (format_version = 1),
            store_id BLOB NOT NULL CHECK (length(store_id) = 16),
            generation BLOB NOT NULL CHECK (length(generation) = 16),
            readiness INTEGER NOT NULL CHECK (readiness IN (0, 1)),
            legacy_consumed INTEGER NOT NULL CHECK (legacy_consumed IN (0, 1)),
            legacy_digest BLOB CHECK (legacy_digest IS NULL OR length(legacy_digest) = 32),
            legacy_expected_records INTEGER CHECK (legacy_expected_records IS NULL OR legacy_expected_records >= 0),
            legacy_events_digest BLOB CHECK (legacy_events_digest IS NULL OR length(legacy_events_digest) = 32)
        ) STRICT
        """,
        """
        CREATE TABLE tasks (
            task_id BLOB PRIMARY KEY CHECK (length(task_id) = 16),
            generation BLOB NOT NULL CHECK (length(generation) = 16),
            attempt_id BLOB UNIQUE CHECK (attempt_id IS NULL OR length(attempt_id) = 16),
            producer_epoch BLOB CHECK (producer_epoch IS NULL OR length(producer_epoch) = 16),
            started_sequence INTEGER UNIQUE REFERENCES events(sequence) DEFERRABLE INITIALLY DEFERRED,
            finished_sequence INTEGER UNIQUE REFERENCES events(sequence) DEFERRABLE INITIALLY DEFERRED,
            terminal_kind INTEGER CHECK (terminal_kind IS NULL OR terminal_kind BETWEEN 0 AND 6),
            CHECK ((finished_sequence IS NULL) = (terminal_kind IS NULL))
        ) STRICT
        """,
        """
        CREATE TABLE events (
            sequence INTEGER PRIMARY KEY AUTOINCREMENT,
            generation BLOB NOT NULL CHECK (length(generation) = 16),
            event_id BLOB NOT NULL CHECK (length(event_id) BETWEEN 1 AND 512),
            task_id BLOB NOT NULL REFERENCES tasks(task_id) DEFERRABLE INITIALLY DEFERRED,
            attempt_id BLOB CHECK (attempt_id IS NULL OR length(attempt_id) = 16),
            kind INTEGER NOT NULL CHECK (kind BETWEEN 0 AND 15),
            created_at_ms INTEGER,
            payload BLOB NOT NULL CHECK (length(payload) BETWEEN 1 AND 262144),
            payload_sha256 BLOB NOT NULL CHECK (length(payload_sha256) = 32),
            UNIQUE (generation, event_id)
        ) STRICT
        """,
        """
        CREATE INDEX events_task_sequence ON events(task_id, sequence)
        """,
        """
        CREATE INDEX events_kind_sequence ON events(kind, sequence)
        """,
        """
        CREATE TABLE intents (
            invocation_id BLOB PRIMARY KEY CHECK (length(invocation_id) = 16),
            proposal_id BLOB NOT NULL CHECK (length(proposal_id) = 16),
            generation BLOB NOT NULL CHECK (length(generation) = 16),
            task_id BLOB NOT NULL REFERENCES tasks(task_id),
            attempt_id BLOB NOT NULL CHECK (length(attempt_id) = 16),
            producer_epoch BLOB NOT NULL CHECK (length(producer_epoch) = 16),
            intent_sequence INTEGER NOT NULL UNIQUE REFERENCES events(sequence),
            tool_call_id BLOB NOT NULL CHECK (length(tool_call_id) BETWEEN 1 AND 512),
            tool_name TEXT NOT NULL CHECK (length(tool_name) BETWEEN 1 AND 128),
            call_sha256 BLOB NOT NULL CHECK (length(call_sha256) = 32),
            effect_class INTEGER NOT NULL CHECK (effect_class BETWEEN 0 AND 2),
            result_sequence INTEGER UNIQUE REFERENCES events(sequence),
            outcome_kind INTEGER CHECK (outcome_kind IS NULL OR outcome_kind BETWEEN 0 AND 4),
            CHECK ((result_sequence IS NULL) = (outcome_kind IS NULL))
        ) STRICT
        """,
        """
        CREATE INDEX intents_task_pending ON intents(task_id, result_sequence)
        """,
        """
        CREATE UNIQUE INDEX intents_call_identity ON intents(task_id, attempt_id, proposal_id, tool_call_id)
        """,
    ]
    static func normalized(_ value: String) -> String { value.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
}
