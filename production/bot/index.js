/**
 * DIY Assistant - the Telegram bot.
 *
 * It saves everything the group sends (text, voice notes, photos, videos,
 * files) into a queue, and delivers the replies the assistant writes. The
 * thinking happens on the work server: a worker wakes the AI when the group
 * has gone quiet, and the AI answers through this bot.
 *
 *   - Hears only the groups set up with "/setup <code>" (the code the
 *     installer shows). Anything else is noted in ops.unknown_chat and ignored.
 *   - Decisions come as buttons (choose.sh); a tap goes back into the queue.
 *   - Says plainly when the assistant is offline, instead of a cheerful "Noted."
 *
 * Long polling, not webhooks: no open port. Node 22 has fetch built in, so
 * there are no dependencies beyond `postgres`.
 */
import postgres from "postgres";
import { mkdir, writeFile } from "node:fs/promises";
import { join, extname } from "node:path";

const TOKEN = process.env.TELEGRAM_BOT_TOKEN;
const API = `https://api.telegram.org/bot${TOKEN}`;
const FILE_API = `https://api.telegram.org/file/bot${TOKEN}`;
const MEDIA_DIR = process.env.MEDIA_DIR || "/data/feedback";

if (!TOKEN) {
  console.error("TELEGRAM_BOT_TOKEN is not set. Bot will idle.");
  process.exit(1);
}

const sql = postgres(process.env.DATABASE_URL, { max: 3, idle_timeout: 20 });
const log = (...a) => console.log(new Date().toISOString(), ...a);

async function api(method, params) {
  const r = await fetch(`${API}/${method}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(params ?? {}),
  });
  const j = await r.json();
  if (!j.ok) throw new Error(`${method}: ${j.description}`);
  return j.result;
}

async function state(key) {
  const [row] = await sql`select value from ops.bot_state where key = ${key}`;
  return row?.value ?? null;
}
async function setState(key, value) {
  await sql`
    insert into ops.bot_state (key, value, updated_at) values (${key}, ${value}, now())
    on conflict (key) do update set value = excluded.value, updated_at = now()`;
}

async function allowed(chatId) {
  return (await state("allowed_chats") ?? "").split(",").map((s) => s.trim()).includes(String(chatId));
}

/** Download a Telegram file to the media folder. Returns the local path. */
async function download(fileId, suggestedExt) {
  const f = await api("getFile", { file_id: fileId });
  const res = await fetch(`${FILE_API}/${f.file_path}`);
  if (!res.ok) throw new Error(`download failed: ${res.status}`);
  const buf = Buffer.from(await res.arrayBuffer());
  const name = `${Date.now()}_${fileId.slice(0, 12)}${extname(f.file_path) || suggestedExt || ""}`;
  await mkdir(MEDIA_DIR, { recursive: true });
  const path = join(MEDIA_DIR, name);
  await writeFile(path, buf);
  return path;
}

const nameOf = (u) => [u?.first_name, u?.last_name].filter(Boolean).join(" ") || u?.username || "someone";

/** Turn one Telegram message into a queue note. */
async function handle(msg) {
  const chatId = msg.chat.id;
  const from = msg.from ?? {};
  let kind = "text";
  let body = msg.text ?? msg.caption ?? null;
  let filePath = null, fileUniqueId = null, mime = null, duration = null;

  try {
    if (msg.voice || msg.audio) {
      const a = msg.voice ?? msg.audio;
      kind = "voice"; fileUniqueId = a.file_unique_id; mime = a.mime_type; duration = a.duration;
      filePath = await download(a.file_id, ".ogg");
    } else if (msg.photo) {
      const best = msg.photo[msg.photo.length - 1];        // sizes ascend; last is largest
      kind = "photo"; fileUniqueId = best.file_unique_id; mime = "image/jpeg";
      filePath = await download(best.file_id, ".jpg");
    } else if (msg.video || msg.video_note) {
      const v = msg.video ?? msg.video_note;
      kind = "video"; fileUniqueId = v.file_unique_id; mime = v.mime_type ?? "video/mp4"; duration = v.duration;
      filePath = await download(v.file_id, ".mp4");
    } else if (msg.document) {
      kind = "document"; fileUniqueId = msg.document.file_unique_id; mime = msg.document.mime_type;
      filePath = await download(msg.document.file_id, "");
    } else if (!body) {
      return;                                              // joins, pins, stickers
    }
  } catch (err) {
    log("media download failed:", err.message);           // e.g. over Telegram's 20 MB bot limit
  }

  await sql`
    insert into ops.feedback
      (tg_chat_id, tg_chat_title, tg_message_id, tg_user_id, tg_username, tg_display_name,
       reply_to_message_id, kind, body, file_path, file_unique_id, mime_type, duration_s)
    values
      (${chatId}, ${msg.chat.title ?? null}, ${msg.message_id}, ${from.id ?? null},
       ${from.username ?? null}, ${nameOf(from)}, ${msg.reply_to_message?.message_id ?? null},
       ${kind}, ${body}, ${filePath}, ${fileUniqueId}, ${mime}, ${duration})
    on conflict (tg_chat_id, tg_message_id) do nothing`;
  log(`saved ${kind} in chat ${chatId}`);

  let online = true;
  try { online = await assistantOnline(); } catch { /* unknown: normal ack */ }
  let ack, quiet = true;
  if (!online) {
    const last = offlineNoticeAt.get(chatId) ?? 0;
    if (Date.now() - last > OFFLINE_NOTICE_MS) {
      offlineNoticeAt.set(chatId, Date.now());
      quiet = false;
      ack = "Saved - but the assistant is offline right now, so nothing happens with this until " +
            "it's back. Nothing is lost; keep sending.";
    } else {
      ack = "Saved. Still offline.";
    }
  } else {
    ack = kind === "voice" ? "Got the voice note - working on it."
        : kind === "text" ? "Noted." : "Saved.";
  }
  await api("sendMessage", { chat_id: chatId, reply_to_message_id: msg.message_id, text: ack,
                             disable_notification: quiet }).catch((err) => log("ack failed:", err.message));
}

/** Seal everything unsealed in this chat into one batch. Returns [count, batch id]. */
async function seal(chatId) {
  const [{ n }] = await sql`
    select count(*)::int as n from ops.feedback where tg_chat_id = ${chatId} and batch_id is null`;
  if (n === 0) return [0, null];
  const [{ bid }] = await sql`select nextval('ops.feedback_batch_seq')::bigint as bid`;
  await sql`
    with ordered as (
      select id, row_number() over (order by received_at) as seq
      from ops.feedback where tg_chat_id = ${chatId} and batch_id is null)
    update ops.feedback f set batch_id = ${bid}, batch_seq = o.seq
    from ordered o where o.id = f.id`;
  return [n, bid];
}

async function handleCommand(msg) {
  const text = (msg.text || "").trim();
  const chatId = msg.chat.id;
  const reply = (t) => api("sendMessage", { chat_id: chatId, reply_to_message_id: msg.message_id, text: t });

  if (/^\/status\b/.test(text)) {
    const [c] = await sql`
      select count(*) filter (where status = 'new') as new,
             count(*) filter (where status = 'in_progress') as doing,
             count(*) filter (where status = 'done') as done
      from ops.feedback where tg_chat_id = ${chatId}`;
    await reply(`Queue: ${c.new} new, ${c.doing} in progress, ${c.done} done.`);
    return true;
  }
  if (/^\/done\b/.test(text)) {
    const [n, bid] = await seal(chatId);
    await reply(n === 0 ? "Nothing new to bundle - send your messages first, then /done."
      : `Bundled ${n} message${n === 1 ? "" : "s"} as one request (#${bid}). Send /process to have it worked on now.`);
    return true;
  }
  if (/^\/process\b/.test(text)) {
    await seal(chatId);
    await setState("process_requested", String(Date.now()));
    await setState("process_requested_by", nameOf(msg.from));
    await reply("Flagged. If the assistant is online it picks this up within a minute; otherwise it waits, nothing is lost.");
    return true;
  }
  if (/^\/(start|help)\b/.test(text)) {
    await reply(
      "Send a message, a voice note, a photo or a file - say what you want done.\n\n" +
      "Several messages for one request? Send them, then /done.\n\n" +
      "/done - bundle what you just sent\n/process - work on it now\n/status - the queue");
    return true;
  }
  return false;
}

/** "/setup <code>" in a group the bot doesn't hear yet (004). */
async function trySetup(msg) {
  const m = /^\/setup(?:@\w+)?\s+(\d{4,8})\s*$/.exec((msg.text || "").trim());
  if (!m) return false;
  const code = await state("setup_code");
  if (!code || m[1] !== code) {
    await api("sendMessage", { chat_id: msg.chat.id, reply_to_message_id: msg.message_id,
      text: "That code doesn't match. Check the code on the installer's last screen." }).catch(() => {});
    return true;
  }
  const chatId = String(msg.chat.id);
  const list = (await state("allowed_chats") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  if (!list.includes(chatId)) list.push(chatId);
  await setState("allowed_chats", list.join(","));
  await setState("process_chat_id", chatId);
  await setState("owner_tg_user_id", String(msg.from?.id ?? ""));
  await setState("owner_tg_name", msg.from?.first_name ?? nameOf(msg.from));
  await sql`delete from ops.bot_state where key = 'setup_code'`;
  await sql`delete from ops.unknown_chat where tg_chat_id = ${msg.chat.id}`;
  const me = await api("getMe");
  const owner = msg.from?.first_name ?? "you";
  await sql`
    insert into ops.bot_outbox (tg_chat_id, body, kind) values (${msg.chat.id},
      ${`Hello! I'm ${me.first_name}, the assistant for this group.\n\n` +
        `I save every message, voice note, photo and file sent here, and work on what you ask. ` +
        `${owner} is my owner: when something needs a decision, I'll ask here, usually with buttons to tap.\n\n` +
        `Everything stays on your own servers. Send /help to see how it works.`}, 'update')`;
  if (!me.can_read_all_group_messages) {
    // Privacy mode on: commands arrive, ordinary messages don't. The commonest setup slip.
    await sql`
      insert into ops.bot_outbox (tg_chat_id, body, kind) values (${msg.chat.id},
        ${"One more step: I can only see commands, not your messages. In @BotFather send " +
          "/setprivacy, choose this bot, choose Disable - then remove me from this group and add me again."},
        'question')`;
  }
  log(`setup done: chat ${chatId}, owner ${msg.from?.id}`);
  return true;
}

/** A tap on a choice button (004): record it, and queue it as a note. */
async function handleButton(cq) {
  const answer = (text) => api("answerCallbackQuery", { callback_query_id: cq.id, text }).catch(() => {});
  const m = /^pick:(\d+):(\d+)$/.exec(cq.data ?? "");
  if (!m) return answer();
  const [, id, n] = m;
  const who = nameOf(cq.from);
  const [c] = await sql`
    update ops.choice set chosen = ${n}, chosen_by = ${who}, chosen_at = now()
    where id = ${id} and chosen is null returning question, options->>(${Number(n) - 1}) as option`;
  if (!c) return answer("Already answered.");
  // A tap has no message of its own; a negative id keeps the note unique.
  await sql`
    insert into ops.feedback (tg_chat_id, tg_chat_title, tg_message_id, tg_user_id, tg_username,
                              tg_display_name, kind, body)
    values (${cq.message.chat.id}, ${cq.message.chat.title ?? null}, ${-Number(id)}, ${cq.from?.id ?? null},
            ${cq.from?.username ?? null}, ${who}, 'text',
            ${`[Chose] ${c.option}  (question: ${c.question})`})
    on conflict (tg_chat_id, tg_message_id) do nothing`;
  await answer("Got it");
  await api("editMessageText", { chat_id: cq.message.chat.id, message_id: cq.message.message_id,
    text: `${cq.message.text}\n\n✅ ${who} chose: ${c.option}` })
    .catch((err) => log("could not mark the choice:", err.message));
  log(`choice #${id}: option ${n}`);
}

/** Send what say.sh, ask.sh, choose.sh and the status trigger queued. */
async function outboxLoop() {
  for (;;) {
    try {
      const rows = await sql`
        with claimed as (
          select id from ops.bot_outbox where status = 'pending'
          order by created_at, id limit 5 for update skip locked)
        update ops.bot_outbox o set status = 'sent', sent_at = now()
        from claimed c where c.id = o.id
        returning o.id, o.tg_chat_id, o.body, o.reply_to_message_id, o.kind, o.buttons, o.entities`;
      rows.sort((a, b) => Number(a.id) - Number(b.id));    // RETURNING has no order
      for (const m of rows) {
        const base = {
          chat_id: m.tg_chat_id, text: m.body,
          disable_notification: m.kind !== "question",
          ...(m.buttons ? { reply_markup: { inline_keyboard: m.buttons } } : {}),
          ...(m.entities ? { entities: m.entities } : {}),
        };
        try {
          let sent;
          try {
            sent = await api("sendMessage", { ...base,
              ...(m.reply_to_message_id > 0 ? { reply_to_message_id: Number(m.reply_to_message_id) } : {}) });
          } catch (err) {
            if (/message to be replied not found|message to reply not found|MESSAGE_ID_INVALID/i.test(err.message)) {
              sent = await api("sendMessage", base);         // deliver even if the original is gone
            } else throw err;
          }
          await sql`update ops.bot_outbox set sent_message_id = ${sent.message_id} where id = ${m.id}`;
          log(`sent ${m.kind} #${m.id}`);
        } catch (err) {
          await sql`update ops.bot_outbox set status = 'failed', error = ${err.message} where id = ${m.id}`;
          log(`send failed #${m.id}: ${err.message}`);
        }
      }
    } catch (err) {
      log("outbox error:", err.message);
    }
    await new Promise((r) => setTimeout(r, 2000));
  }
}

async function loop() {
  let offset = Number(await state("offset") ?? 0);
  const me = await api("getMe");
  log(`connected as @${me.username}`);
  for (;;) {
    try {
      const updates = await api("getUpdates", { offset, timeout: 50, allowed_updates: ["message", "callback_query"] });
      for (const u of updates) {
        const msg = u.message, cq = u.callback_query;
        if (cq?.message && (await allowed(cq.message.chat.id))) await handleButton(cq);
        else if (cq) await api("answerCallbackQuery", { callback_query_id: cq.id }).catch(() => {});
        if (msg) {
          if (await allowed(msg.chat.id)) {
            if (!(await handleCommand(msg))) await handle(msg);
          } else if (!(await trySetup(msg))) {
            await sql`
              insert into ops.unknown_chat (tg_chat_id, title, last_seen)
              values (${msg.chat.id}, ${msg.chat.title ?? msg.chat.first_name ?? null}, now())
              on conflict (tg_chat_id) do update set title = excluded.title, last_seen = now()`;
          }
        }
        offset = u.update_id + 1;                          // only after handling: failures are redelivered
        await setState("offset", String(offset));
      }
    } catch (err) {
      log("poll error:", err.message);
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
}

/** The worker beats every 30 s while it runs; stale for 3 minutes = offline. */
const STALE_MS = 3 * 60 * 1000;
async function assistantOnline() {
  const [hb] = await sql`
    select extract(epoch from (now() - updated_at)) as age_s from ops.bot_state where key = 'claude_heartbeat'`;
  return hb != null && Number(hb.age_s) * 1000 < STALE_MS;
}
const OFFLINE_NOTICE_MS = 30 * 60 * 1000;
const offlineNoticeAt = new Map();

async function presenceLoop() {
  let announced = null;                                    // first pass observes only
  for (;;) {
    try {
      const online = await assistantOnline();
      if (announced === null) announced = online;
      else if (online !== announced) {
        const chat = await state("process_chat_id");
        if (chat) {
          await sql`insert into ops.bot_outbox (tg_chat_id, body, kind)
                    values (${chat}, ${online ? "Back online." : "Offline for now. Keep sending - everything is saved."}, 'update')`;
        }
        announced = online;
      }
    } catch (err) {
      log("presence error:", err.message);
    }
    await new Promise((r) => setTimeout(r, 20_000));
  }
}

outboxLoop().catch((e) => log("outbox loop died:", e.message));
presenceLoop().catch((e) => log("presence loop died:", e.message));
loop().catch((e) => { console.error(e); process.exit(1); });
