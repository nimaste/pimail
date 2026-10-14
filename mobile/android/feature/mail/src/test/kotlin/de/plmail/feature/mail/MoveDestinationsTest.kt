package de.plmail.feature.mail

import de.plmail.core.data.ActionTarget
import de.plmail.core.data.Label
import de.plmail.core.data.LabelBinding
import de.plmail.core.data.LabelSelection
import de.plmail.core.data.MailAction
import de.plmail.core.data.MailCategory
import de.plmail.core.data.MailTab
import de.plmail.core.data.MailView
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

/**
 * What "Move to" offers, and what each row does.
 *
 * The rule lives on the server for the web (`MoveToService::plan`) and has to be the same rule
 * here, or a conversation filed on the phone ends up somewhere the browser would not have put it:
 * the target goes on and the label of the list being looked at comes off, and "the list being
 * looked at" is the Inbox for every list that has no label of its own.
 */
class MoveDestinationsTest {

    private val receipts = label("receipts")
    private val work = label("work")
    private val inbox = label("inbox", role = "inbox")
    private val sent = label("sent", role = "sent")
    private val trash = label("trash", role = "trash")
    private val labels = listOf(inbox, sent, trash, receipts, work)

    private val targets = listOf(ActionTarget(ACCOUNT, "t1"))

    @Test
    fun `from the inbox a label is label-and-archive`() {
        val offered = from(MailView.Category(MailCategory.PRIMARY))

        assertEquals(
            listOf(
                MoveDestination.To(receipts, MailAction.MoveTo(receipts, leaving = null)),
                MoveDestination.To(work, MailAction.MoveTo(work, leaving = null)),
                MoveDestination.Spam,
                MoveDestination.Trash,
            ),
            offered,
        )
    }

    /** The Inbox reached as a label row is the same list, and offers the same things. */
    @Test
    fun `the inbox label is the inbox`() {
        assertEquals(
            from(MailView.Category(MailCategory.PRIMARY)),
            from(MailView.Labelled(inbox)),
        )
    }

    @Test
    fun `from a label the label is swapped, and the inbox is on offer`() {
        val offered = from(MailView.Labelled(receipts))

        assertEquals(
            listOf(
                MoveDestination.Inbox(MailAction.MoveTo(target = null, leaving = receipts)),
                MoveDestination.To(work, MailAction.MoveTo(work, leaving = receipts)),
                MoveDestination.Spam,
                MoveDestination.Trash,
            ),
            offered,
        )
    }

    /**
     * Sent says how a message came to exist, and is not something a move takes off.
     *
     * So it is a list with no label of its own: the Inbox is what leaves, and the Inbox is not
     * offered as somewhere to go.
     */
    @Test
    fun `a system list other than the inbox leaves the inbox and nothing else`() {
        val offered = from(MailView.Labelled(sent))

        assertEquals(
            MoveDestination.To(receipts, MailAction.MoveTo(receipts, leaving = null)),
            offered.first(),
        )
    }

    /**
     * Out of the bin: the Inbox is the restore every server has, the labels leave the bin behind,
     * and the bin is not offered to itself.
     */
    @Test
    fun `from the bin a label leaves the bin, and the inbox is the existing restore`() {
        assertEquals(
            listOf(
                MoveDestination.Inbox(MailAction.MoveToInbox),
                MoveDestination.To(receipts, MailAction.MoveTo(receipts, leaving = trash)),
                MoveDestination.To(work, MailAction.MoveTo(work, leaving = trash)),
                MoveDestination.Spam,
            ),
            from(MailView.Labelled(trash)),
        )
    }

    @Test
    fun `a label every conversation already wears is left off`() {
        val offered =
            from(
                MailView.Category(MailCategory.PRIMARY),
                selection = LabelSelection(onAll = setOf("work")),
            )

        assertEquals(listOf("receipts"), offered.labelKeys())
    }

    /** A row that would be refused for half the selection is not a row. */
    @Test
    fun `a label one of the accounts does not bind is left off`() {
        val offered =
            moveDestinations(
                view = MailView.Category(MailCategory.PRIMARY),
                labels = labels,
                targets = targets + ActionTarget("https://nas.local/2", "t2"),
                selection = LabelSelection(),
            )

        assertEquals(emptyList(), offered.labelKeys())
    }

    /**
     * Recent labels lead the user's own, and everything found by position stays where it is.
     *
     * A key whose label is no longer on offer — deleted, or already on the conversation — is
     * skipped rather than leaving a gap.
     */
    @Test
    fun `the labels last moved to lead the list`() {
        val offered = from(MailView.Labelled(sent)).recentFirst(listOf("gone", "work"))

        assertEquals(listOf("work", "receipts"), offered.labelKeys())
        assertEquals(MoveDestination.Trash, offered.last())
    }

    @Test
    fun `a filter keeps the rows whose name contains it`() {
        val offered = from(MailView.Labelled(sent))
        val named = { row: MoveDestination -> (row as? MoveDestination.To)?.label?.name ?: "bin" }

        assertEquals(listOf("receipts"), offered.matching(" REC ", named).labelKeys())
        assertEquals(offered, offered.matching("  ", named))
    }

    /**
     * From a tab, the other tabs lead the sheet — the web's drag onto a tab — and the one being
     * looked at is left off, as the list being looked at always is.
     */
    @Test
    fun `from a tab the other tabs are offered first`() {
        val shipping = MailTab(key = "c12", name = "Shipping", sortOrder = 5)
        val tabs = MailTab.BUILT_IN.filter { it.builtIn != MailCategory.FORUMS } + shipping

        val offered =
            moveDestinations(
                MailView.Category(MailCategory.PROMOTIONS),
                labels,
                targets,
                LabelSelection(),
                tabs,
            )

        assertEquals(
            listOf("primary", "social", "updates", "c12"),
            offered.filterIsInstance<MoveDestination.ToTab>().map { it.tab.key },
        )
        assertEquals(
            MoveDestination.ToTab(shipping, MailAction.MoveToTab("c12", from = "promotions")),
            offered.filterIsInstance<MoveDestination.ToTab>().last(),
        )
        assertTrue(offered.first() is MoveDestination.ToTab)

        // From the reader's own tab, back into a built-in.
        val fromShipping = moveDestinations(shipping.view, labels, targets, LabelSelection(), tabs)
        assertEquals(
            MoveDestination.ToTab(tabs.first(), MailAction.MoveToTab("primary", from = "c12")),
            fromShipping.first(),
        )
    }

    /**
     * A tab is an inbox idea, and a server without the extension has no way to file mail in one, so
     * neither a label list nor such a server offers any.
     */
    @Test
    fun `tabs are offered only from a tab and only where the server serves them`() {
        val tabs = MailTab.BUILT_IN

        assertTrue(
            moveDestinations(MailView.Labelled(receipts), labels, targets, LabelSelection(), tabs)
                .none { it is MoveDestination.ToTab }
        )
        assertTrue(
            from(MailView.Category(MailCategory.PROMOTIONS)).none { it is MoveDestination.ToTab }
        )
    }

    private fun from(view: MailView, selection: LabelSelection = LabelSelection()) =
        moveDestinations(view, labels, targets, selection)

    private fun List<MoveDestination>.labelKeys(): List<String> =
        filterIsInstance<MoveDestination.To>().map { it.label.key }

    private fun label(key: String, role: String? = null) =
        Label(
            key = key,
            name = key,
            path = key,
            role = role,
            color = null,
            unreadThreads = 0,
            totalThreads = 0,
            mayRename = role == null,
            mayDelete = role == null,
            bindings = listOf(LabelBinding(ACCOUNT, "m-$key")),
        )

    private companion object {
        const val ACCOUNT = "https://nas.local/1"
    }
}
