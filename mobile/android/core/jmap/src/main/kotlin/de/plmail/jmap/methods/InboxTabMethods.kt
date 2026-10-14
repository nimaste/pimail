package de.plmail.jmap.methods

import de.plmail.jmap.mail.InboxTab
import de.plmail.jmap.protocol.AccountId
import de.plmail.jmap.protocol.JmapMethod
import de.plmail.jmap.protocol.StateToken
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.add
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * `InboxTab/get` — plMail's extension, under `urn:plmail:params:jmap:inboxtabs`.
 *
 * Every tab the reader has, switched-off built-ins included and marked, in the reader's order.
 * Every account of one user answers with the same list; the account id only decides whose change
 * log [InboxTabGetResult.state] belongs to. A request carrying this must declare
 * [de.plmail.jmap.protocol.Capability.USING_INBOX_TABS].
 */
class InboxTabGet(private val accountId: AccountId, private val ids: List<String>? = null) :
    JmapMethod<InboxTabGetResult> {

    override val name = "InboxTab/get"

    override fun arguments(): JsonObject = buildJsonObject {
        put("accountId", accountId.value)

        // Explicit null for "all of them", as Mailbox/get does it.
        if (ids == null) {
            put("ids", JsonNull)
        } else {
            put("ids", buildJsonArray { ids.forEach { add(it) } })
        }
    }

    override fun decode(json: Json, arguments: JsonObject): InboxTabGetResult =
        json.decodeFromJsonElement(InboxTabGetResult.serializer(), arguments)
}

@Serializable
data class InboxTabGetResult(
    val accountId: String = "",
    val state: String = "",
    val list: List<InboxTab> = emptyList(),
    val notFound: List<String> = emptyList(),
)

/**
 * `InboxTab/changes` — the standard `/changes` over the tabs' own change log.
 *
 * A reorder reports every tab as updated, because every `sortOrder` may have moved; a tab switched
 * on or off or renamed reports that tab; a tab of the reader's own made or deleted is created or
 * destroyed.
 */
class InboxTabChanges(
    private val accountId: AccountId,
    private val sinceState: StateToken,
    private val maxChanges: Int = EmailChanges.MAX_CHANGES,
) : JmapMethod<InboxTabChangesResult> {

    override val name = "InboxTab/changes"

    override fun arguments(): JsonObject = buildJsonObject {
        put("accountId", accountId.value)
        put("sinceState", sinceState.value)
        put("maxChanges", maxChanges)
    }

    override fun decode(json: Json, arguments: JsonObject): InboxTabChangesResult =
        json.decodeFromJsonElement(InboxTabChangesResult.serializer(), arguments)
}

@Serializable
data class InboxTabChangesResult(
    val accountId: String = "",
    val oldState: String = "",
    val newState: String = "",
    val hasMoreChanges: Boolean = false,
    val created: List<String> = emptyList(),
    val updated: List<String> = emptyList(),
    val destroyed: List<String> = emptyList(),
) {
    /** Nothing moved, so the stored tabs are still true and only the cursor advances. */
    val isEmpty: Boolean
        get() = created.isEmpty() && updated.isEmpty() && destroyed.isEmpty()
}
