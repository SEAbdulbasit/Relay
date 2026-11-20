import Foundation
import Testing
@testable import Relay

@Suite(.serialized)
struct MailIngestionParityTests {
    init() async throws {
        await awaitParitySuiteQuietWindow()
    }

    // MARK: - 1. Mailbox Filter Tests (SRC-14)

    @Test func hiddenMailboxesAreExcludedAcrossLanguages() {
        let hiddenExamples = [
            "trash", "Trash", "TRASH", "bin", "Deleted Messages", "deleted items",
            "Draft", "drafts", "corbeille", "brouillons", "Papierkorb", "entwürfe",
            "papelera", "borradores", "cestino", "bozze", "lixo", "rascunhos",
            "prullenmand", "concepten", "ゴミ箱", "下書き", "草稿", "废纸篓",
            "휴지통", "임시보관함"
        ]

        for name in hiddenExamples {
            #expect(MailIngestion.MailboxFilter.isHidden(mailboxName: name), "Expected hidden mailbox: \(name)")
            #expect(MailIngestion.MailboxFilter.isExcluded(mailboxName: name), "Expected excluded mailbox: \(name)")

            let row = MailIngestion.Row(
                id: 1,
                account: "ACC-1",
                messageID: "msg-1@example.com",
                date: Date(),
                mailbox: name
            )
            #expect(row.excluded, "Hidden mailbox \(name) must be excluded")
            #expect(!row.previewJunk, "Hidden mailbox \(name) cannot be previewed as junk")
        }
    }

    @Test func junkAndBulkMailboxesAreExcludedWithJunkPreview() {
        let junkExamples = [
            "junk", "Junk Mail", "junk e-mail", "spam", "SPAM", "promotions",
            "category_promotions", "bulk mail", "indésirables", "courrier indésirable",
            "werbung", "unerwünscht", "correo no deseado", "reclame", "ongewenst",
            "迷惑メール", "垃圾邮件", "垃圾郵件", "스팸"
        ]

        for name in junkExamples {
            #expect(!MailIngestion.MailboxFilter.isHidden(mailboxName: name), "\(name) is junk, not hidden")
            #expect(MailIngestion.MailboxFilter.isExcluded(mailboxName: name), "Expected excluded mailbox: \(name)")

            let row = MailIngestion.Row(
                id: 2,
                account: "ACC-1",
                messageID: "msg-2@example.com",
                date: Date(),
                mailbox: name
            )
            #expect(row.excluded, "Junk mailbox \(name) must be excluded")
            #expect(row.previewJunk, "Junk mailbox \(name) may be previewed as junk")
        }
    }

    @Test func standardMailboxesAreNotExcluded() {
        let standardExamples = ["INBOX", "Inbox", "Archive", "Receipts", "Project X", "Sent", "Personal"]
        for name in standardExamples {
            #expect(!MailIngestion.MailboxFilter.isHidden(mailboxName: name))
            #expect(!MailIngestion.MailboxFilter.isExcluded(mailboxName: name))

            let row = MailIngestion.Row(
                id: 3,
                account: "ACC-1",
                messageID: "msg-3@example.com",
                date: Date(),
                mailbox: name
            )
            #expect(!row.excluded)
            #expect(!row.previewJunk)
        }
    }

    // MARK: - 2. MIME Filter Tests (SRC-14)

    @Test func mimeListAndUnsubscribeHeadersTriggerExclusion() {
        let unsubscribeHeaders = ["list-unsubscribe": "<mailto:unsub@example.com>"]
        #expect(MailIngestion.MIMEFilter.isExcluded(headers: unsubscribeHeaders))

        let listIDHeaders = ["List-ID": "<notifications.github.com>"]
        #expect(MailIngestion.MIMEFilter.isExcluded(headers: listIDHeaders))

        let mixedHeaders = [
            "From": "news@newsletter.com",
            "Subject": "Weekly Digest",
            "List-Unsubscribe": "<https://newsletter.com/optout>"
        ]
        #expect(MailIngestion.MIMEFilter.isExcluded(headers: mixedHeaders))
    }

    @Test func mimePrecedenceBulkOrListTriggersExclusion() {
        #expect(MailIngestion.MIMEFilter.isExcluded(headers: ["Precedence": "bulk"]))
        #expect(MailIngestion.MIMEFilter.isExcluded(headers: ["precedence": "list"]))
        #expect(MailIngestion.MIMEFilter.isExcluded(headers: ["Precedence": "junk"]))
        #expect(MailIngestion.MIMEFilter.isExcluded(headers: ["Precedence": "Bulk-Automated"]))

        #expect(!MailIngestion.MIMEFilter.isExcluded(headers: ["Precedence": "normal"]))
        #expect(!MailIngestion.MIMEFilter.isExcluded(headers: ["Precedence": "urgent"]))
    }

    @Test func mimeSpamDetectionHeadersTriggerExclusion() {
        #expect(MailIngestion.MIMEFilter.isExcluded(headers: ["x-spam-flag": "YES"]))
        #expect(MailIngestion.MIMEFilter.isExcluded(headers: ["X-Spam-Flag": "yes"]))
        #expect(MailIngestion.MIMEFilter.isExcluded(headers: ["x-spam-flag": "1"]))
        #expect(MailIngestion.MIMEFilter.isExcluded(headers: ["X-Spam-Status": "Yes, score=12.5"]))
        #expect(MailIngestion.MIMEFilter.isExcluded(headers: ["x-junk": "true"]))
        #expect(MailIngestion.MIMEFilter.isExcluded(headers: ["x-spam": "1"]))

        // Clean headers
        let clean = [
            "From": "alice@example.com",
            "To": "bob@example.com",
            "Subject": "Project Status",
            "Date": "Tue, 10 Nov 2026 09:00:00 +0000"
        ]
        #expect(!MailIngestion.MIMEFilter.isExcluded(headers: clean))
    }

    // MARK: - 3. Unavailable Body Retry Cache Tests (SRC-14)

    @Test func unavailableBodyIsDeferredAndRetriedWithBackoff() {
        var clock = Date(timeIntervalSince1970: 1_700_000_000)
        var checkpoint = MailIngestion.Checkpoint(generation: "uuid-gen-1", top: 10)

        let row1 = MailIngestion.Row(
            id: 11,
            account: "ACC-1",
            messageID: "msg-11@example.com",
            date: clock,
            mailbox: "Inbox"
        )

        // Initial discovery pass
        let work1 = checkpoint.prepare(generation: "uuid-gen-1", rows: [row1], now: clock)
        #expect(work1.count == 1)
        #expect(work1[0].phase == .discovery)
        #expect(work1[0].row.id == 11)

        // First attempt fails because body is unavailable (not yet downloaded by Mail)
        checkpoint.recordResult(for: work1[0], bodyAvailable: false, now: clock)
        #expect(checkpoint.deferred.contains(11))
        #expect(checkpoint.retrySchedule?["11"]?.attempts == 1)
        #expect(checkpoint.retrySchedule?["11"]?.due == clock.addingTimeInterval(300))

        // Before 300s elapse, row 11 is NOT scheduled for retry
        let work2 = checkpoint.prepare(generation: "uuid-gen-1", rows: [row1], now: clock.addingTimeInterval(100))
        #expect(work2.isEmpty)

        // Advance past 300s
        clock = clock.addingTimeInterval(305)
        let work3 = checkpoint.prepare(generation: "uuid-gen-1", rows: [row1], now: clock)
        #expect(work3.count == 1)
        #expect(work3[0].phase == .retry)
        #expect(work3[0].row.id == 11)

        // Second attempt succeeds when body becomes available
        checkpoint.recordResult(for: work3[0], bodyAvailable: true, now: clock)
        #expect(!checkpoint.deferred.contains(11))
        #expect(checkpoint.retrySchedule?["11"] == nil)

        // Next pass has no work
        let work4 = checkpoint.prepare(generation: "uuid-gen-1", rows: [row1], now: clock)
        #expect(work4.isEmpty)
    }

    // MARK: - 4. Index-Generation Recovery Tests (SRC-14)

    @Test func indexGenerationChangeResetsTraversalPreservingSalt() {
        let initialGen = "envelope-index-generation-1"
        var checkpoint = MailIngestion.Checkpoint(generation: initialGen, top: 100)
        let originalSalt = checkpoint.salt
        #expect(!originalSalt.isEmpty)
        #expect(checkpoint.highWater == 100)

        let rows = [
            MailIngestion.Row(id: 101, account: "ACC-1", messageID: "m1", date: Date(), mailbox: "Inbox"),
            MailIngestion.Row(id: 102, account: "ACC-1", messageID: "m2", date: Date(), mailbox: "Inbox")
        ]

        // Prepare with same generation
        let work1 = checkpoint.prepare(generation: initialGen, rows: rows, now: Date())
        #expect(work1.count == 2)
        #expect(work1[0].phase == .discovery)

        // Mail triggers Envelope Index rebuild: new generation UUID assigned
        let rebuiltGen = "rebuilt-envelope-index-generation-2"
        let rebuiltRows = [
            MailIngestion.Row(id: 1, account: "ACC-1", messageID: "m1", date: Date(), mailbox: "Inbox"),
            MailIngestion.Row(id: 2, account: "ACC-1", messageID: "m2", date: Date(), mailbox: "Inbox")
        ]

        let work2 = checkpoint.prepare(generation: rebuiltGen, rows: rebuiltRows, now: Date())
        // Should recover: generation updated, salt preserved, traversal reset to top = 2
        #expect(checkpoint.generation == rebuiltGen)
        #expect(checkpoint.salt == originalSalt, "Survivor identity salt must be preserved across index recovery")
        #expect(checkpoint.highWater == 2)
        #expect(checkpoint.backfillBefore == 2)
    }
}
