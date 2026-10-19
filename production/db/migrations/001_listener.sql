-- =====================================================================
-- 001 - the listener: one Telegram group's messages become a work queue
--
-- One file because this is a fresh database; later changes go in 002+,
-- additive only.
--
--   ops.feedback     one row per message the group sends (the queue)
--   ops.bot_outbox   what the bot must send back (say.sh, ask.sh, triggers)
--   ops.bot_state    offset, heartbeat, /process marker, allowed groups
--   ops.unknown_chat groups the bot was added to but is NOT allowed to hear
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS ops;

CREATE TABLE ops.feedback (
  id              bigserial PRIMARY KEY,

  tg_chat_id      bigint NOT NULL,
  tg_chat_title   text,
  tg_message_id   bigint NOT NULL,
  tg_user_id      bigint,
  tg_username     text,
  tg_display_name text,
  -- The message this one replied to: how an answer to an ask.sh question is found.
  reply_to_message_id bigint,

  kind            text NOT NULL CHECK (kind IN ('text','voice','photo','video','document')),
  body            text,                 -- text, or the caption on media
  transcript      text,                 -- filled in when a voice note is transcribed
  transcript_engine text,

  file_path       text,                 -- path inside the bot container (/data/feedback/...)
  file_unique_id  text,
  mime_type       text,
  duration_s      int,

  status          text NOT NULL DEFAULT 'new'
                  CHECK (status IN ('new','triaged','in_progress','done','wont_do','duplicate')),
  resolution      text,                 -- what was actually done, in their words
  resolved_at     timestamptz,

  -- /done seals everything since the last seal into one batch.
  batch_id        bigint,
  batch_seq       int,

  -- ask.sh: a question went back to the group; blocked on a person until answered.
  question        text,
  asked_at        timestamptz,
  answered_at     timestamptz,

  received_at     timestamptz NOT NULL DEFAULT now(),

  -- Telegram can redeliver; the bot ON CONFLICTs against this. Keep it a plain
  -- constraint: ON CONFLICT can't target a partial index, so one would silently
  -- break intake.
  CONSTRAINT feedback_tg_chat_id_tg_message_id_key UNIQUE (tg_chat_id, tg_message_id)
);
CREATE INDEX ON ops.feedback(status, received_at DESC);
CREATE INDEX ON ops.feedback(tg_chat_id) WHERE batch_id IS NULL;
CREATE INDEX ON ops.feedback(batch_id, batch_seq);
CREATE SEQUENCE ops.feedback_batch_seq;

CREATE TABLE ops.bot_state (
  key        text PRIMARY KEY,
  value      text NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE ops.bot_outbox (
  id            bigserial PRIMARY KEY,
  tg_chat_id    bigint NOT NULL,
  body          text NOT NULL,
  reply_to_message_id bigint,
  feedback_id   bigint REFERENCES ops.feedback(id),
  kind          text NOT NULL DEFAULT 'update'
                CHECK (kind IN ('update','question','done','error')),
  status        text NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending','sent','failed')),
  error         text,
  sent_message_id bigint,              -- Telegram's id for what was sent: a reply to it answers it
  created_at    timestamptz NOT NULL DEFAULT now(),
  sent_at       timestamptz
);
CREATE INDEX ON ops.bot_outbox(status, created_at) WHERE status = 'pending';

CREATE TABLE ops.unknown_chat (
  tg_chat_id  bigint PRIMARY KEY,
  title       text,
  last_seen   timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------
-- Closing an item IS the reply: every status change queues a message,
-- threaded under the original note and echoing what was heard, so a
-- mangled transcript is corrected before the wrong thing is built.
-- ---------------------------------------------------------------------
CREATE FUNCTION ops.notify_resolution() RETURNS trigger LANGUAGE plpgsql AS $fn$
DECLARE
  msg  text;
  knd  text;
  echo text;
BEGIN
  IF NEW.status IS NOT DISTINCT FROM OLD.status THEN RETURN NEW; END IF;

  echo := coalesce(NEW.transcript, NEW.body);
  echo := CASE WHEN echo IS NULL OR btrim(echo) = '' THEN ''
               ELSE E'\n\n· Heard as: "' || btrim(echo) || '"' END;

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

CREATE TRIGGER feedback_resolution_notify
  AFTER UPDATE ON ops.feedback
  FOR EACH ROW EXECUTE FUNCTION ops.notify_resolution();

-- One-line helpers, so closing an item is one command and the reply can't be forgotten.
CREATE FUNCTION ops.fb_doing(p_id bigint, p_transcript text DEFAULT NULL) RETURNS void
LANGUAGE sql AS $fn$
  UPDATE ops.feedback
     SET transcript = coalesce(p_transcript, transcript),
         transcript_engine = CASE WHEN p_transcript IS NOT NULL
                                  THEN 'faster-whisper large-v3-turbo int8' ELSE transcript_engine END,
         status = 'in_progress'
   WHERE id = p_id;
$fn$;

CREATE FUNCTION ops.fb_done(p_id bigint, p_resolution text) RETURNS void LANGUAGE sql AS $fn$
  UPDATE ops.feedback SET status='done', resolution=p_resolution, resolved_at=now() WHERE id = p_id;
$fn$;

CREATE FUNCTION ops.fb_wont(p_id bigint, p_why text) RETURNS void LANGUAGE sql AS $fn$
  UPDATE ops.feedback SET status='wont_do', resolution=p_why, resolved_at=now() WHERE id = p_id;
$fn$;

CREATE FUNCTION ops.fb_dup(p_id bigint) RETURNS void LANGUAGE sql AS $fn$
  UPDATE ops.feedback SET status='duplicate', resolved_at=now() WHERE id = p_id;
$fn$;

-- Ask the group, threaded under the note; the item waits on a person, not on work.
CREATE FUNCTION ops.fb_ask(p_id bigint, p_question text) RETURNS void LANGUAGE plpgsql AS $fn$
DECLARE
  f    ops.feedback%ROWTYPE;
  echo text;
BEGIN
  SELECT * INTO f FROM ops.feedback WHERE id = p_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'no feedback %', p_id; END IF;

  echo := coalesce(f.transcript, f.body);
  echo := CASE WHEN echo IS NULL OR btrim(echo) = '' THEN ''
               ELSE E'\n\n· On: "' || left(btrim(echo), 200) || '"' END;

  UPDATE ops.feedback
     SET question = p_question, asked_at = now(), answered_at = NULL,
         status = CASE WHEN status = 'new' THEN 'triaged' ELSE status END
   WHERE id = p_id;

  INSERT INTO ops.bot_outbox (tg_chat_id, body, reply_to_message_id, feedback_id, kind)
  VALUES (f.tg_chat_id,
          '❓ Need a decision before I build this.' || E'\n\n' || p_question || echo ||
          E'\n\nJust reply to this message - your answer comes straight back.',
          f.tg_message_id, f.id, 'question');
END $fn$;

CREATE FUNCTION ops.fb_answered(p_id bigint) RETURNS void LANGUAGE sql AS $fn$
  UPDATE ops.feedback SET answered_at = now() WHERE id = p_id;
$fn$;
