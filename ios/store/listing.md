# The App Store page of the iPhone app

The owner approved it on 11 November 2026 ("Yes, as shown"), and it was entered in App Store Connect the same day
("Yes, enter it"), each field read back. Each field has Apple's limit; `check_listing.py` beside this file counts
them. The words follow the home page of founderizer.com, so the site and the store say one thing.

## Name (30)

Founderizer

## Subtitle (30)

Your own team of AI agents

## Promotional text (170)

The same agents and the same decisions, in your pocket. Each agent writes to you in its own chat, and what needs
you waits in one place until you answer it.

## Description (4000)

Founderizer is your own team of AI agents. It works on a server you own, with the Claude or ChatGPT subscription you
already pay for, and asks you when a decision is yours. This app puts that team on your iPhone.

Chats
Each agent writes to you in its own chat, named by its role: Fleet Manager, Customer Support, Developer, or the roles
that you give your team. Write to an agent as you write to a person.

Needs you
What needs you waits in one place, with a badge until you answer it. When an agent gives options, one tap answers.

Tasks
See what your agents work on now, and what they finished.

Share to an agent
Send a link, a picture or a file from any app to one agent, with a line of your own.

Your fleet stays yours
The app talks only to your own hub, over your own private network, and Face ID guards this phone's key. A
notification says which agent asks and what it asks. It passes through us sealed, so we cannot read it.

Founderizer on a Mac is required. Add this phone from the Mac app: Settings, Servers, Add device. No fleet yet? Open
the app and see a sample fleet first.

## Keywords (100)

assistant,automation,approvals,tasks,team,business,operations,customer support,developer,DevOps

## Category

Primary: Productivity. Secondary: Business.

## Addresses

- Support: https://founderizer.com/support
- Privacy policy: https://founderizer.com/privacy
- Marketing: https://founderizer.com

## Copyright

2026 Amura Ventures SL

## Screenshots

`screenshots/` (iPhone with Dynamic Island, medium: 1206 × 2622, the class Apple requires) and `screenshots/large/`
(the large class, 1320 × 2868), PNG with no transparency, dark appearance. They show the sample fleet's made-up
company as a hub serves it (`make_sample.py`), so no real name, address or message is on them, and no "Sample
fleet" line. The large chat picture comes from the sample with its first request only, so that the conversation
fits that screen from its top:

1. Chats
2. A chat with the Fleet Manager: his question, its answer and a request
3. Needs you
4. Tasks

An agent's own page is not among them: in the sample it shows little, and a provider's logo.

## Notes for App Review (not public)

Founderizer for iPhone works with Founderizer on the owner's own Mac and hub: the phone reaches the hub over the
owner's private network (Tailscale), and the Mac makes the one-time code that adds a phone. A reviewer has neither,
so the first screen offers **See a sample fleet**: every page with made-up data, inside the app, and every write
answers "Not sent: This is a sample." We ask for your prior approval of this demo mode (guideline 2.1). The app
creates no account (5.1.1(v)). It sends the owner's messages only to the owner's own hub, whose agents use the
owner's own AI accounts: the app itself sends nothing to an AI company (5.1.2(i)). The plain-HTTP exception is for
the owner's hub, at an address that the build cannot know.
