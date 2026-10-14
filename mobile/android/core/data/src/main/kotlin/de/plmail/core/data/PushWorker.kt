package de.plmail.core.data

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.OutOfQuotaPolicy
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import dagger.hilt.EntryPoint
import dagger.hilt.InstallIn
import dagger.hilt.android.EntryPointAccessors
import dagger.hilt.components.SingletonComponent

/**
 * Handles one delivered push, in work the system has agreed to run.
 *
 * ## Why a push is not handled where it arrives
 *
 * Both transports hand the app a callback that ends long before a sync can. The Firebase service is
 * stopped the moment `onMessageReceived` returns, and the UnifiedPush receiver's broadcast is over
 * when `onReceive` does. Work launched from either into a coroutine scope of its own *looks* like
 * it outlives the callback, and on a phone at rest it does not:
 *
 * - The Firebase service cancelled its scope in `onDestroy`, which Firebase calls milliseconds
 *   after the message is handled — so the `Email/changes` the push had started was cancelled
 *   mid-flight and nothing was ever announced.
 * - A receiver's process drops to cached once `onReceive` returns, and since Android 12 a cached
 *   process is **frozen**. The coroutine did not fail; it stopped, holding its request, until the
 *   user opened the app and thawed it — which is exactly when the notification then appeared.
 *
 * Both read, from the outside, as "notifications only arrive when I open the app". An expedited job
 * is the platform's answer for this case: it is what Firebase's own documentation says to schedule
 * from `onMessageReceived`, and JobScheduler binding the job is what keeps the process out of the
 * freezer for as long as the sync takes.
 *
 * ## One door, still
 *
 * Nothing is interpreted here either. The payload is carried as it arrived and handed to
 * [PushRepository.deliver] or [PushRepository.deliverSealed], so verification, reminders and state
 * changes are still told apart in one place, for every transport.
 *
 * ## In order
 *
 * One unique chain, appended to. A verification followed a second later by the first state change
 * must be answered in that order, and two state changes must not run two syncs side by side against
 * a server that advertises four concurrent requests. Appending rather than replacing, because a
 * replace cancels the running sync between the write that makes a message known and the claim that
 * announces it — and a message known but never announced is a notification lost for good.
 */
class PushWorker(context: Context, parameters: WorkerParameters) :
    CoroutineWorker(context, parameters) {

    @EntryPoint
    @InstallIn(SingletonComponent::class)
    interface Dependencies {
        fun push(): PushRepository
    }

    override suspend fun doWork(): Result {
        val payload = inputData.getString(KEY_PAYLOAD) ?: return Result.success()
        val via = PushDelivery.of(inputData.getString(KEY_VIA)) ?: return Result.success()
        val sealed = inputData.getBoolean(KEY_SEALED, false)

        val push =
            EntryPointAccessors.fromApplication(applicationContext, Dependencies::class.java).push()

        // Success whatever happened, because a failure in an appended chain
        // fails every push queued behind it. A sync that could not finish is
        // caught up by the periodic worker; a failed verification is retried by
        // the server's next one. Logged rather than swallowed, for the reason
        // the receivers give: this runs where nobody is watching.
        runCatching {
            if (sealed) push.deliverSealed(payload, via) else push.deliver(payload, via)
        }
            .onFailure { Log.w(TAG, "Push handling failed", it) }

        return Result.success()
    }

    companion object {
        private const val TAG = "plMail.Push"

        private const val NAME = "plmail.push"

        private const val KEY_PAYLOAD = "payload"
        private const val KEY_VIA = "via"
        private const val KEY_SEALED = "sealed"

        /**
         * Queues one push for handling.
         *
         * Expedited, and falling back to ordinary work when the app has spent its quota rather than
         * being refused: a push handled a little late is still mail, and one dropped is not.
         *
         * No network constraint. A reminder needs none, and a constraint would hold it — and every
         * push queued behind it — until a network came back; a state change that cannot reach the
         * server fails inside the sync and is caught up from there.
         */
        fun enqueue(context: Context, payload: String, via: PushDelivery, sealed: Boolean = false) {
            val request =
                OneTimeWorkRequestBuilder<PushWorker>()
                    .setExpedited(OutOfQuotaPolicy.RUN_AS_NON_EXPEDITED_WORK_REQUEST)
                    .setInputData(
                        workDataOf(
                            KEY_PAYLOAD to payload,
                            KEY_VIA to via.wire,
                            KEY_SEALED to sealed,
                        )
                    )
                    .build()

            WorkManager.getInstance(context)
                .enqueueUniqueWork(NAME, ExistingWorkPolicy.APPEND_OR_REPLACE, request)
        }
    }
}
