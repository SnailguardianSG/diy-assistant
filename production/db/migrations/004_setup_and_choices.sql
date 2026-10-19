-- =====================================================================
-- 004 - setting up from the chat, and decisions as buttons
--
-- Setup: the installer stores a one-time code in bot_state 'setup_code'. In a
-- new group, the owner sends "/setup <code>": the bot allows that group, makes
-- the sender its owner (bot_state owner_tg_user_id / owner_tg_name), makes it
-- the main group (process_chat_id), and forgets the code. No terminal needed.
--
-- Choices: the assistant asks a question with a few options as buttons
-- (choose.sh -> ops.ask_choice). A tap records the answer and adds it to the
-- queue as a note, which wakes the worker to carry on.
-- =====================================================================

-- Buttons and mentions on outgoing messages (Telegram's own formats).
ALTER TABLE ops.bot_outbox ADD COLUMN buttons jsonb, ADD COLUMN entities jsonb;

CREATE TABLE ops.choice (
  id          bigserial PRIMARY KEY,
  tg_chat_id  bigint NOT NULL,
  question    text NOT NULL,
  options     jsonb NOT NULL,               -- ["option 1", "option 2", ...]
  chosen      int,                          -- 1-based index of the option tapped
  chosen_by   text,
  chosen_at   timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);

-- Ask a question with up to 6 options; returns the choice id. Button labels
-- are cut to 60 characters (Telegram shows short labels); the full options are
-- listed in the message itself.
CREATE FUNCTION ops.ask_choice(p_chat bigint, p_question text, p_options jsonb)
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
  cid   bigint;
  n     int := 0;
  opt   text;
  body  text := p_question || E'\n';
  btns  jsonb := '[]'::jsonb;
BEGIN
  IF jsonb_typeof(p_options) <> 'array' OR jsonb_array_length(p_options) NOT BETWEEN 2 AND 6 THEN
    RAISE EXCEPTION 'give 2 to 6 options';
  END IF;
  INSERT INTO ops.choice (tg_chat_id, question, options) VALUES (p_chat, p_question, p_options)
  RETURNING id INTO cid;
  FOR opt IN SELECT jsonb_array_elements_text(p_options) LOOP
    n := n + 1;
    body := body || E'\n' || n || '. ' || opt;
    btns := btns || jsonb_build_array(jsonb_build_array(jsonb_build_object(
              'text', n || '. ' || left(opt, 60), 'callback_data', 'pick:' || cid || ':' || n)));
  END LOOP;
  INSERT INTO ops.bot_outbox (tg_chat_id, body, kind, buttons)
  VALUES (p_chat, body || E'\n\nTap one, or reply with something else.', 'question', btns);
  RETURN cid;
END $fn$;
