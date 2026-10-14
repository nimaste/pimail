package de.plmail.core.data

import de.plmail.jmap.mail.Email
import de.plmail.jmap.mail.Identity
import de.plmail.jmap.protocol.EmailId
import de.plmail.jmap.protocol.IdentityId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertSame

/**
 * Who a reply is sent as, once the server has said.
 *
 * The decision itself is the server's and is not tested here — there is deliberately no rule in
 * this app to test. What is pinned is the two things the app does with the answer: it finds the
 * picker's own row for an identity it already lists, and it makes one for an identity no list
 * contains without letting that become the account's default.
 */
class ReplySenderTest {

    private val account = "https://mail.example/a"

    private val primary =
        SendIdentity(account, "Personal", "7", "John Smith", "me@joder.example", "<p>John</p>")
    private val sales =
        SendIdentity(account, "Personal", "8", "Sales Desk", "sales@joder.example", "<p>Sales</p>")
    private val work =
        SendIdentity("https://mail.example/b", "Work", "7", "J. Smith", "j@work.example")

    private val known = listOf(primary, sales, work)

    private fun emailAnsweredBy(identity: Identity?) =
        Email(id = EmailId("42"), replyFrom = identity)

    private val catchAll =
        Identity(
            id = IdentityId("addr-eW9Ac2hvcC5leGFtcGxl"),
            name = "John Smith",
            email = "yo@shop.example",
            htmlSignature = "<p>Kind regards</p>",
        )

    @Test
    fun `an alias the server names is the row the picker already has`() {
        val named = emailAnsweredBy(Identity(id = IdentityId("8"), email = "sales@joder.example"))

        assertSame(sales, named.replySender(account, known))
    }

    @Test
    fun `an identity id is only looked for among the message's own account`() {
        // Ids are per account: "7" is the primary of both accounts here, and
        // the reply must not jump to the other mailbox.
        val named = emailAnsweredBy(Identity(id = IdentityId("7"), email = "j@work.example"))

        assertSame(work, named.replySender(work.accountKey, known))
    }

    @Test
    fun `a catch-all address becomes an entry carrying what the server sent`() {
        val sender = emailAnsweredBy(catchAll).replySender(account, known)!!

        assertEquals("addr-eW9Ac2hvcC5leGFtcGxl", sender.identityId)
        assertEquals("yo@shop.example", sender.email)
        assertEquals("John Smith", sender.name)
        assertEquals("<p>Kind regards</p>", sender.htmlSignature)
        assertEquals(account, sender.accountKey)
        assertEquals("Personal", sender.accountName)
    }

    @Test
    fun `no answer from the server is no sender, and the caller keeps its default`() {
        assertNull(emailAnsweredBy(null).replySender(account, known))
    }

    @Test
    fun `an unlisted sender is added after its account's own entries, never first`() {
        val sender = emailAnsweredBy(catchAll).replySender(account, known)!!

        // The first entry of an account is what the composer treats as its
        // default; an address that exists for one message must not be it.
        assertEquals(listOf(primary, sales, sender, work), known.including(sender))
    }

    @Test
    fun `a listed sender, or none, leaves the picker as it was`() {
        assertSame(known, known.including(sales))
        assertSame(known, known.including(null))
    }
}
