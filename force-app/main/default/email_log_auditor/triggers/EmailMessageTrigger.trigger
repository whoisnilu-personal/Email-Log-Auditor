/**
 * SECURITY: trigger context inherits sharing of the running user; all logic is
 * delegated to action classes which declare their own sharing.
 *
 * Thin shell — delegates to SetDeliveryStatusDefault for before-insert.
 * No business logic in this file (Constitution Principle I).
 */
trigger EmailMessageTrigger on EmailMessage (before insert) {
    new SetDeliveryStatusDefault().beforeInsert(Trigger.new);
}
