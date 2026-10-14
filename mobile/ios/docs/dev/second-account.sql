BEGIN;

-- 1. A second mail account for the same user.
INSERT INTO account (usr_id, username, auth_type, is_active, is_primary, settings,
                     sort_order, graph_delta_links, created_at, updated_at, push_enabled)
SELECT usr_id, 'second@e2e.test', auth_type, true, false, settings,
       1, graph_delta_links, now(), now(), false
FROM account WHERE id = 71;

-- 2. Its Inbox. The label is user-scoped; the binding is the per-account thing
--    a JMAP Mailbox id actually names.
INSERT INTO label (usr_id, name, role, is_visible, sort_order, created_at, updated_at)
VALUES (1, 'Inbox', 'inbox', true, 0, now(), now());

INSERT INTO label_binding (label_id, account_id, created_at, updated_at)
SELECT currval('label_id_seq'), currval('account_id_seq'), now(), now();

-- 3. A custom label bound in BOTH accounts under one user-scoped label id.
--    This is the case the sidebar's cross-account grouping exists for, and
--    the one that would silently split if the app grouped by name.
INSERT INTO label (usr_id, name, role, is_visible, sort_order, created_at, updated_at)
VALUES (1, 'Shared', NULL, true, 100, now(), now());

INSERT INTO label_binding (label_id, account_id, created_at, updated_at)
VALUES (currval('label_id_seq'), 71, now(), now()),
       (currval('label_id_seq'), (SELECT max(id) FROM account WHERE usr_id = 1), now(), now());

COMMIT;

SELECT a.id AS account, a.username, l.id AS label, l.name, l.role, lb.id AS binding
FROM account a
JOIN label_binding lb ON lb.account_id = a.id
JOIN label l ON l.id = lb.label_id
WHERE a.usr_id = 1
ORDER BY a.id, l.id;
