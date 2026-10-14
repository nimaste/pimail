package de.plmail.jmap.mail

import kotlinx.serialization.Serializable

/**
 * One of the reader's inbox tabs — plMail's `urn:plmail:params:jmap:inboxtabs` extension.
 *
 * The tabs the web draws over the inbox, in the order the reader arranged them: the five built-in
 * categories and any the reader made themselves. Served so a phone draws the same strip the browser
 * does, which `Thread.category` alone cannot do — a sixth value there would break every client that
 * has never heard of it, so the reader's own tabs live here instead.
 */
@Serializable
data class InboxTab(
    /**
     * The tab key: a built-in category's value (`primary`, `social`, …) or one of the reader's own
     * (`c12`).
     *
     * The same string `Thread.inboxTab` carries, the `threadInboxTab` filter takes and `Thread/set
     * { inboxTab }` accepts. A wire string rather than an enum for the reason [MailThread.category]
     * is one: an own tab's key is the server's to mint.
     */
    val id: String,
    /**
     * The reader's name for a tab of their own; null for a built-in one, which the client names in
     * its own language — "Primary" is not a word the server translates for a phone.
     */
    val name: String? = null,
    /**
     * Which built-in category this tab is, or null for one of the reader's own.
     *
     * Separate from [id] so nothing on the client has to know which keys are built-ins.
     */
    val builtIn: String? = null,
    /**
     * False for a built-in the reader switched off on the web. Listed anyway — the settings page
     * there needs it to switch it back on — and never drawn in the strip.
     *
     * Defaulting to true, because the server always sends it and a reader's own tab is never off.
     */
    val isEnabled: Boolean = true,
    /** The position in the strip, Primary at 0. Unique per user. */
    val sortOrder: Int = 0,
)
