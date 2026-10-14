package de.plmail.jmap.mail

import de.plmail.jmap.Fixture
import de.plmail.jmap.methods.EmailGet
import de.plmail.jmap.methods.EmailGetResult
import de.plmail.jmap.protocol.AccountId
import de.plmail.jmap.protocol.EmailId
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonPrimitive

/**
 * `replyFrom` — the server saying who answers a message.
 *
 * The JSON here is written out rather than captured, against the rule the fixture directory states,
 * because the seeded test server has no catch-all domain and no alias to produce it with. The shape
 * is the one plMail's own `EmailReplyFromTest` pins: a whole Identity object, with an id that for a
 * catch-all address is `addr-` and the base64url of the address.
 */
class ReplyFromTest {

    private fun decode(email: String): Email =
        Fixture.json
            .decodeFromString<EmailGetResult>(
                """{"accountId":"1","state":"7","list":[$email],"notFound":[]}"""
            )
            .list
            .single()

    @Test
    fun `an identity that is in no list arrives whole, signature included`() {
        val email =
            decode(
                """
                {"id":"42","subject":"Order 7","replyFrom":{
                  "id":"addr-eW9Ac2hvcC5leGFtcGxl","name":"John Smith","email":"yo@shop.example",
                  "replyTo":null,"bcc":null,"textSignature":"Kind regards",
                  "htmlSignature":"<p>Kind regards</p>","mayDelete":false}}
                """
            )

        val identity = email.replyFrom!!

        assertEquals("addr-eW9Ac2hvcC5leGFtcGxl", identity.id.value)
        assertEquals("yo@shop.example", identity.email)
        assertEquals("John Smith", identity.name)
        assertEquals("<p>Kind regards</p>", identity.htmlSignature)
    }

    @Test
    fun `null and absent are the same answer, which is what an older server gives`() {
        // A plMail that predates the property ignores the name, as it ignores
        // any it does not know, so the key is simply not there.
        assertNull(decode("""{"id":"42","subject":"x","replyFrom":null}""").replyFrom)
        assertNull(decode("""{"id":"42","subject":"x"}""").replyFrom)
    }

    @Test
    fun `it is asked for by the reply fetch and by nothing that fetches in bulk`() {
        // The value carries a signature. The reader and the prefetcher fetch
        // messages by the dozen and answer none of them.
        assertTrue("replyFrom" in EmailGet.REPLY_PROPERTIES)
        assertTrue(EmailGet.REPLY_PROPERTIES.containsAll(EmailGet.READER_PROPERTIES))
        assertFalse("replyFrom" in EmailGet.READER_PROPERTIES)
        assertFalse("replyFrom" in EmailGet.LIST_ROW_PROPERTIES)

        val asked =
            EmailGet(
                    accountId = AccountId("1"),
                    ids = listOf(EmailId("42")),
                    properties = EmailGet.REPLY_PROPERTIES,
                )
                .arguments()["properties"]!!
                .jsonArray
                .map { it.jsonPrimitive.content }

        assertTrue("replyFrom" in asked)
    }
}
