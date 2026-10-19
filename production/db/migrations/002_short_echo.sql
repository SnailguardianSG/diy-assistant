-- =====================================================================
-- 002 - quote at most 300 characters of what was heard
--
-- Every status reply echoes the note ("Heard as: ..."). For a 27-minute
-- recording that is the whole transcript,
-- and Telegram refuses any message over 4096 characters: the reply would be
-- marked failed and the person would never hear the note was done.
-- The full transcript stays on the row; only the echo is cut. 001's
-- function otherwise unchanged.
-- =====================================================================

CREATE OR REPLACE FUNCTION ops.notify_resolution() RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
  msg  text;
  knd  text;
  echo text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;

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
