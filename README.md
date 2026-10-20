# DIY Assistant

Your own AI assistant in a Telegram group. You and your team send messages, voice notes,
photos and files; the assistant works on what you ask, and every decision comes back to you
as a question with buttons to tap. It runs on **your own servers**, with **your own Claude
plan**, so your messages and data stay yours.

Made by **Snailguardian**. Free to use for yourself and your own business (see the licence).

## What you need (about 1 hour to set up)
- **Two small servers** from ReadyServer: Level 1 (1 vCPU, 4 GB), Ubuntu 24.04, Singapore -
  one "work" server (the AI) and one "production" server (the bot). About SGD 10 a month for both.
- **A Claude Pro or Max plan.**
- **Telegram**, and the **Termius** app (to type into the server from your phone).

## Install
1. Create the two servers in ReadyServer and note each one's address and root password.
2. In Termius, connect to the **work** server as `root`, then paste:

   ```
   curl -fsSL https://raw.githubusercontent.com/SnailguardianSG/diy-assistant/main/install.sh | bash
   ```

   **Keep Termius open and your phone awake until it says "All done".** If it closes, connect
   again and paste the same command - it carries on from where it stopped.
3. Answer its questions: the production server's address and password, and your bot's token
   from @BotFather (it shows you how).
4. When it shows a **setup code**: in Telegram, create a group, add your bot (open the bot's
   profile -> its name -> Add to Group), and send `/setup <code>`. You're the owner.
5. Log in to Claude: the bot sends the login link to your group - tap it, approve, and paste the
   code it shows back into Termius.

The step-by-step guide with screenshots and video: *(link coming)*.

## Using it
- Just talk: type, or send a voice note. When you're done, it gets to work.
- Several messages for one request? Send them, then `/done`.
- `/process` - work on it now · `/status` - what's waiting · `/help`.
- `/model` - choose the AI model and effort (Opus and higher effort think harder but use your
  Claude plan faster; Sonnet and lower effort are quicker and lighter). Only the owner can change it.
- If it's offline, it says so - nothing is lost; it catches up when it's back.

## Costs, and stopping
Servers are billed by the hour **even when switched off** - to stop paying, **delete** both
servers in ReadyServer. Your Claude plan is billed by Anthropic.

## Rather not do this yourself?
Snailguardian's **do-it-for-you** service sets it up and runs it for you - you just reply in
Telegram. Email **contact@snailguardian.com**.

## Licence
Snailguardian Free-Use Licence 1.0 - free for yourself and your own business; no reselling it
or offering it as a paid service. See `LICENSE`.
