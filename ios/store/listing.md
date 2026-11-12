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

Rewritten on 11 November 2026 after Apple's question under guideline 2.1 ("Information Needed"), which asked for a
screen recording made on a physical device and for these six answers; the owner approved them that day ("Yes, as
drafted"), and the first point was then made to match the recording as it was made. The recording is the App Review
attachment, not a file here.

1. Screen recording: attached. Made on an iPhone 18 Pro with iOS 27.2 and this version, 1.0 (19). It starts with the
launch of the app on a phone with no hub and shows See a sample fleet (Chats, a chat, Needs you, Tasks, Settings,
Leave). Then it adds the phone to a real hub with a one-time code from the owner's Mac and sends a message to an
agent, whose answer then shows in Chats. The Home Screen and the text of the owner's own decisions are blurred, and
two still moments are cut. The app has no account registration, no login, no purchases and no content that other users
see.

2. Purpose and audience: Founderizer runs a small team of AI agents for a founder, on the founder's own computers and
with the founder's own AI accounts. The agents do the founder's tasks: code, support mail, operations. The iPhone app
is the founder's remote for that team: the chat with each agent, the decisions that wait for the founder (Needs you)
and the tasks in progress. It is for founders and owners of small companies who run Founderizer on a Mac. Anyone can
download Founderizer free at founderizer.com/download; it is not made for one company (3.2).

3. Setup and access: no login is needed for review. On the first screen, tap See a sample fleet: every page works with
made-up data, inside the app, and every write answers "Not sent: This is a sample." Tap Leave on the Sample fleet line
to go back. Real use needs Founderizer on the owner's Mac and hub: in the Mac app, Settings, Servers, Add device makes
a one-time code, and Add this phone on the iPhone takes it. The phone reaches the hub over the owner's private network
(Tailscale). A reviewer has neither, so we ask for your prior approval of the sample fleet as the demo mode (2.1).

4. External services: the owner's own Founderizer hub, on the owner's own machine (the app reads and writes only
there); Tailscale, the private network between the phone and the hub (its own app, not part of this one); Apple Push
Notification service, through our relay at founderizer.com, which carries only a sealed ping and stores nothing. The
hub's agents use the owner's own AI accounts (for example Claude or ChatGPT); the app itself sends nothing to an AI
service. No sign-in service, no payment processor, no analytics, no ads.

5. Regions: the app works the same in every region, with no regional differences in features or content.

6. Regulated industry or protected material: not applicable. The app shows no third-party content.

Also: the app creates no account (5.1.1(v)). The plain-HTTP exception is for the owner's hub, at an address that the
build cannot know.
