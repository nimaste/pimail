BEGIN;

-- Threads for the second account, timestamps offset 30s from the first
-- account's so the merged feed has to interleave rather than concatenate.
-- If the k-way merge is wrong, the result is two clean blocks and it shows
-- immediately.
INSERT INTO message_thread (subject, last_message_at, message_count, unread_count,
                            account_id, threading_method, normalized_subject, attachment_count)
SELECT t.subject || ' (second)', t.last_message_at + interval '30 seconds',
       1, 1, 1119, t.threading_method, t.normalized_subject || ' second', 0
FROM message_thread t
WHERE t.account_id = 71 AND t.last_message_at IS NOT NULL;

INSERT INTO message (message_id, subject, from_address, from_name, to_addresses,
                     cc_addresses, bcc_addresses, created_at, updated_at, sent_at,
                     received_at, size, has_attachments, synced_at, flags,
                     body_text, body_html, body_html_safe, thread_id, cancelled,
                     account_id, headers, thread_references)
SELECT 'second-' || m.id || '@e2e.test',
       m.subject || ' (second)', 'other@e2e.test', 'Second Account',
       m.to_addresses, m.cc_addresses, m.bcc_addresses, now(), now(), m.sent_at,
       m.received_at + interval '30 seconds', m.size, false, now(), m.flags,
       'Seeded into the second account.', '<p>Seeded into the second account.</p>',
       '<p>Seeded into the second account.</p>',
       nt.id, false, 1119, m.headers, m.thread_references
FROM message m
JOIN message_thread ot ON ot.id = m.thread_id
JOIN message_thread nt ON nt.account_id = 1119
                      AND nt.normalized_subject = ot.normalized_subject || ' second'
WHERE m.account_id = 71 AND m.received_at IS NOT NULL;

-- Everything lands in the second account's Inbox (label 690).
INSERT INTO message_label (message_id, label_id)
SELECT m.id, 690 FROM message m WHERE m.account_id = 1119;

-- And one message in each account carries the Shared label (691), so the
-- cross-account label row has something behind it on both sides.
INSERT INTO message_label (message_id, label_id)
SELECT m.id, 691 FROM message m
WHERE m.account_id IN (71, 1119) AND m.received_at IS NOT NULL
ORDER BY m.account_id, m.received_at DESC LIMIT 2;

COMMIT;

SELECT account_id, count(*), min(received_at), max(received_at)
FROM message WHERE account_id IN (71, 1119) AND received_at IS NOT NULL
GROUP BY account_id;
