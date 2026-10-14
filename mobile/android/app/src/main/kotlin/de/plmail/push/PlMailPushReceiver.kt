package de.plmail.push

import android.content.Context
import android.util.Log
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent
import de.plmail.core.data.PushDelivery
import de.plmail.core.data.PushRegistration
import de.plmail.core.data.PushTransportManager
import de.plmail.core.data.PushWorker
import de.plmail.core.datastore.PushStateStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import org.unifiedpush.android.connector.MessagingReceiver
import org.unifiedpush.android.connector.data.PushEndpoint
import org.unifiedpush.android.connector.data.PushMessage

/**
 * Where UnifiedPush delivers.
 *
 * The connector owns the P-256 keypair and decrypts RFC 8291 `aes128gcm` before this is called, so
 * what arrives here is the plaintext JMAP payload — the same bytes `WebPushSender` encrypted. That
 * is why UnifiedPush needs no server change: the server is already speaking the protocol the
 * distributor expects.
 *
 * A delivered message is handed to [PushWorker] rather than handled here. The sync a state change
 * triggers can take far longer than a receiver is allowed to hold the system, and the obvious
 * alternative — launching it into a scope of its own and returning — is the one this used to take:
 * once `onReceive` returns the process is cached, and a cached process on Android 12 and later is
 * frozen, so the sync stopped mid-request and mail was announced only when the app was next opened.
 *
 * The registration callbacks are short — one or two requests — and stay here, under `goAsync`, so
 * the broadcast holds the process until they have finished rather than leaving them to the freezer.
 */
class PlMailPushReceiver : MessagingReceiver() {

    @EntryPoint
    @InstallIn(SingletonComponent::class)
    interface Dependencies {
        fun transports(): PushTransportManager

        fun pushState(): PushStateStore
    }

    /**
     * The endpoint the distributor assigned.
     *
     * Registered with the server every time it arrives, not only the first: a distributor may
     * re-issue an endpoint after its own server changes, and a subscription pointing at the old one
     * fails silently forever.
     *
     * The `instance` the connector passes back is deliberately **not** used as the `deviceClientId`
     * any more. It is the connector's own name for this registration and it is a constant, so using
     * it meant two phones on one account sent the server the same device id and replaced each
     * other's subscription. The id now comes from [PushTransportManager], which is also what lets
     * Firebase replace *this* row rather than adding a second one.
     */
    override fun onNewEndpoint(context: Context, endpoint: PushEndpoint, instance: String) {
        val keys = endpoint.pubKeySet

        if (keys == null) {
            // Without the keypair the server has nothing to encrypt to, so the
            // subscription would be registered and undeliverable. Said out
            // loud: a distributor that negotiates no encryption is a
            // configuration problem, not a silent no-op.
            Log.w(TAG, "Distributor returned an endpoint with no keys; push cannot be encrypted.")
            launch(context) { dependencies -> dependencies.pushState().failed(NO_KEYS) }
            return
        }

        launch(context) { dependencies ->
            dependencies
                .transports()
                .endpointArrived(
                    PushRegistration(
                        endpoint = endpoint.url,
                        p256dh = keys.pubKey,
                        auth = keys.auth,
                    )
                )
        }
    }

    /**
     * A delivered message: either the verification handshake or a state change.
     *
     * Both are queued for [PushWorker], whose work ends in `PushRepository.deliver`: that tells
     * them apart by shape, records the delivery in the received-push log and hands a state change
     * to the one applier every channel shares. The first message is load-bearing — until the
     * verification code is echoed back, nothing else is ever delivered.
     */
    override fun onMessage(context: Context, message: PushMessage, instance: String) {
        Log.d(TAG, "push event")
        PushWorker.enqueue(context, message.content.decodeToString(), PushDelivery.UNIFIEDPUSH)
    }

    /**
     * The distributor was removed or refused.
     *
     * Nothing to do beyond letting the periodic sync carry on: it never stopped, precisely so that
     * losing push degrades to slower mail rather than to no mail.
     */
    override fun onUnregistered(context: Context, instance: String) {
        // The registration is gone, so the stored id is a lie: asking the
        // server about it would report a subscription this device can no longer
        // receive on. Cleared rather than kept, so the diagnostics screen says
        // "not registered" -- which is true, and actionable -- instead of
        // "registered" beside a last-push time from last Tuesday.
        launch(context) { dependencies -> dependencies.pushState().cleared() }
    }

    override fun onRegistrationFailed(
        context: Context,
        reason: org.unifiedpush.android.connector.FailedReason,
        instance: String,
    ) {
        Log.w(TAG, "Distributor refused to register: $reason")
        launch(context) { dependencies -> dependencies.pushState().failed(reason.name) }
    }

    private companion object {
        const val TAG = "plMail.Push"

        /**
         * Reasons in the app's own words, not translated. They are read by whoever runs the server,
         * beside a log they will grep, and a translated string is one they cannot search for.
         */
        const val NO_KEYS = "The distributor returned an endpoint with no encryption keys."
    }

    private fun launch(context: Context, block: suspend (Dependencies) -> Unit) {
        Log.d(TAG, "push event")
        val dependencies =
            EntryPointAccessors.fromApplication(
                context.applicationContext,
                Dependencies::class.java,
            )

        // Held until the work is done: without it the process is cached the
        // moment onReceive returns, and frozen shortly after. Only the
        // registration callbacks come here, and they are a request or two --
        // a delivery, which can take far longer, goes to PushWorker instead.
        val pending = goAsync()

        CoroutineScope(Dispatchers.IO + SupervisorJob()).launch {
            // Logged rather than swallowed. A push path that fails quietly is
            // indistinguishable from one that was never triggered, and this
            // runs where no user is watching.
            try {
                runCatching { block(dependencies) }
                    .onFailure { Log.w(TAG, "Push handling failed", it) }
            } finally {
                pending.finish()
            }
        }
    }
}
