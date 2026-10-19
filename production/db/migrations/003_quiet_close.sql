-- =====================================================================
-- 003 - close a note without a reply in the group
--
-- Once a team is in the group, people talk to each other there too
-- (for example, one team member telling another something). Those messages land in the queue like any other, but
-- answering them with "Done. Heard as: ..." would be the bot talking over a
-- conversation that wasn't addressed to it.
--
-- fb_quiet(id, why) closes such a note with the reason recorded and posts
-- nothing: it sets a transaction-local flag that notify_resolution checks.
-- 002's function otherwise unchanged.
-- =====================================================================

CREATE OR REPLACE FUNCTION ops.notify_resolution() RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
  msg  text;
  knd  text;
  echo text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;
  IF current_setting('ops.quiet', true) = 'on' THEN RETURN NEW; END IF;   -- 003

  echo := btrim(coalesce(NEW.transcript, NEW.body, ''));
  echo := CASE WHEN echo = '' THEN ''
               ELSE E'\n\n· Heard as: "' || left(echo, 300) ||
                    CASE WHEN length(echo) > 300 THEN '…' ELSE '' END || '"' END;

  IF NEW.status = 'in_progress' THEN
    msg := 'Working on this now.' || echo ||
           CASE WHEN echo = '' THEN '' ELSE E'\n· If that is not what you meant, say so now.' END;
    knd := 'update';
  ELSIF NEW.status = 'done' THEN
    msg := 'Done.' || coalesce(E'\n\n' || NEW.resolution, '') || echo;
    knd := 'done';
  ELSIF NEW.status = 'wont_do' THEN
    msg := 'Not doing this one.' ||
           coalesce(E'\n\n' || NEW.resolution, E'\n\nNo reason recorded.') || echo ||
           E'\n\nSay so if you disagree - happy to be overruled.';
    knd := 'question';
  ELSIF NEW.status = 'duplicate' THEN
    msg := 'Already covered by an earlier note - folding it in.' || echo;
    knd := 'update';
  ELSIF NEW.status = 'triaged' AND NEW.asked_at IS NULL THEN
    msg := 'Logged for later, not forgotten.' || echo;
    knd := 'update';
  ELSE
    RETURN NEW;
  END IF;

  INSERT INTO ops.bot_outbox (tg_chat_id, body, reply_to_message_id, feedback_id, kind)
  VALUES (NEW.tg_chat_id, msg, NEW.tg_message_id, NEW.id, knd);
  RETURN NEW;
END $fn$;

-- Close a note that needs no answer (people talking to each other, a thank-you),
-- recording why. Nothing is posted.
CREATE OR REPLACE FUNCTION ops.fb_quiet(p_id bigint, p_why text) RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
  PERFORM set_config('ops.quiet', 'on', true);
  UPDATE ops.feedback SET status = 'done', resolution = p_why, resolved_at = now() WHERE id = p_id;
  PERFORM set_config('ops.quiet', 'off', true);
END $fn$;
