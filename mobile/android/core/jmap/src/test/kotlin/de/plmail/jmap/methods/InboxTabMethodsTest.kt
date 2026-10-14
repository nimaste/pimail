package de.plmail.jmap.methods

import de.plmail.jmap.mail.EmailFilter
import de.plmail.jmap.mail.MailThread
import de.plmail.jmap.protocol.AccountId
import de.plmail.jmap.protocol.Capability
import de.plmail.jmap.protocol.MethodHandle
import de.plmail.jmap.protocol.MethodResults
import de.plmail.jmap.protocol.Session
import de.plmail.jmap.protocol.StateToken
import de.plmail.jmap.protocol.ThreadId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive

/**
 * The inbox-tabs extension on the wire — `urn:plmail:params:jmap:inboxtabs`.
 *
 * Exercised against **constructed** bodies, built to the contract in the server's
 * `InboxTabMapper::toJmap` and `tests/Jmap/Method/InboxTabTest.php`, for the reason
 * `AppearanceMethodsTest` gives: the captured fixtures predate the extension and are re-captured
 * rather than edited.
 */
class InboxTabMethodsTest {

    private val json = Json { ignoreUnknownKeys = true }

    private fun constructed(body: String) =
        MethodResults.decode(body.encodeToByteArray(), status = 200)

    @Test
    fun `get asks for every tab of one account`() {
        val arguments = InboxTabGet(AccountId("13")).arguments()

        assertEquals("13", arguments["accountId"]?.jsonPrimitive?.content)
        assertEquals(JsonNull, arguments["ids"], "null is every tab, not none of them")
    }

    /**
     * Built-ins unnamed, for the client to name; the reader's own named; a switched-off built-in
     * listed and marked, in the reader's order.
     */
    @Test
    fun `get decodes built-ins, own tabs and switched-off ones`() {
        val body =
            """
            {"sessionState":"s","methodResponses":[
              ["InboxTab/get",{"accountId":"13","state":"7","list":[
                {"id":"primary","name":null,"builtIn":"primary","isEnabled":true,"sortOrder":0},
                {"id":"c12","name":"Shipping","builtIn":null,"isEnabled":true,"sortOrder":1},
                {"id":"forums","name":null,"builtIn":"forums","isEnabled":false,"sortOrder":2}
              ],"notFound":[]},"g0"]]}
            """

        val result = constructed(body).result(MethodHandle(InboxTabGet(AccountId("13")), "g0"))

        assertEquals("7", result.state)
        assertEquals(listOf("primary", "c12", "forums"), result.list.map { it.id })

        val shipping = result.list[1]
        assertEquals("Shipping", shipping.name)
        assertNull(shipping.builtIn)

        val forums = result.list[2]
        assertNull(forums.name)
        assertEquals("forums", forums.builtIn)
        assertFalse(forums.isEnabled)
        assertEquals(2, forums.sortOrder)
    }

    @Test
    fun `changes reports nothing moved as empty`() {
        val body =
            """
            {"sessionState":"s","methodResponses":[
              ["InboxTab/changes",{"accountId":"13","oldState":"7","newState":"8",
                "hasMoreChanges":false,"created":[],"updated":[],"destroyed":[]},"c0"]]}
            """

        val method = InboxTabChanges(AccountId("13"), StateToken("7"))
        val result = constructed(body).result(MethodHandle(method, "c0"))

        assertEquals("7", method.arguments()["sinceState"]?.jsonPrimitive?.content)
        assertTrue(result.isEmpty)
        assertEquals("8", result.newState)
    }

    @Test
    fun `a thread carries the tab the web shows it in beside its category`() {
        val filed =
            json.decodeFromString(
                MailThread.serializer(),
                """{"id":"9","category":"promotions","inboxTab":"c12"}""",
            )

        assertEquals("c12", filed.inboxTab)
        assertEquals("promotions", filed.category)

        // A server older than the extension sends no such key.
        assertNull(
            json
                .decodeFromString(MailThread.serializer(), """{"id":"9","category":"social"}""")
                .inboxTab
        )
    }

    @Test
    fun `the tab filter is sent as threadInboxTab`() {
        val filter = EmailFilter.ThreadInboxTab("c12").toJson()

        assertEquals(setOf("threadInboxTab"), filter.keys)
        assertEquals("c12", filter["threadInboxTab"]?.jsonPrimitive?.content)
    }

    @Test
    fun `an empty tab key is rejected before it is sent`() {
        assertFailsWith<IllegalArgumentException> { EmailFilter.ThreadInboxTab(" ") }
    }

    @Test
    fun `moving into a tab is a Thread set of inboxTab`() {
        val update =
            ThreadSet.moveToTab(AccountId("13"), listOf(ThreadId("4"), ThreadId("5")), "c12")
                .arguments()["update"]
                ?.jsonObject

        assertEquals(setOf("4", "5"), update?.keys)
        assertEquals(
            "c12",
            update?.get("4")?.jsonObject?.get("inboxTab")?.jsonPrimitive?.content,
        )
    }

    /** Asked per account, where the server publishes it. Absent is a server that predates it. */
    @Test
    fun `the capability is read off the account`() {
        val session =
            json.decodeFromString(
                Session.serializer(),
                """
                {"capabilities":{"urn:plmail:params:jmap:inboxtabs":{}},
                 "accounts":{
                   "13":{"name":"a","accountCapabilities":{"urn:plmail:params:jmap:inboxtabs":{}}},
                   "14":{"name":"b","accountCapabilities":{}}},
                 "apiUrl":"a","downloadUrl":"d","uploadUrl":"u"}
                """,
            )

        assertTrue(session.supportsInboxTabs(AccountId("13")))
        assertFalse(session.supportsInboxTabs(AccountId("14")))
        assertTrue(Capability.INBOX_TABS in Capability.USING_INBOX_TABS)
    }

    @Test
    fun `push and the event stream ask to hear about the tabs`() {
        assertTrue("InboxTab" in NewPushSubscription.DEFAULT_TYPES)
        assertTrue("InboxTab" in de.plmail.jmap.client.EventSourceClient.DEFAULT_TYPES)
    }

    /**
     * The "one list" switch rides on the appearance capability, and only an explicit false turns
     * the tabs off: a server older than the switch says nothing, and every inbox there was tabbed.
     */
    @Test
    fun `the one-list switch is read off the appearance capability`() {
        fun session(appearance: String) =
            json.decodeFromString(
                Session.serializer(),
                """{"capabilities":{"urn:plmail:params:jmap:appearance":$appearance},
                   "apiUrl":"a","downloadUrl":"d","uploadUrl":"u"}""",
            )

        assertFalse(session("""{"inboxTabs":false}""").wantsInboxTabs)
        assertTrue(session("""{"inboxTabs":true}""").wantsInboxTabs)
        assertTrue(session("""{}""").wantsInboxTabs)
        assertTrue(
            json
                .decodeFromString(
                    Session.serializer(),
                    """{"apiUrl":"a","downloadUrl":"d","uploadUrl":"u"}""",
                )
                .wantsInboxTabs
        )
    }
}
