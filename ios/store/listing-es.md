# The App Store page of the iPhone app, in Spanish

The Spanish page of `listing.md`: the same fields, in neutral Spanish with "tú", in the words of the app's Spanish
table (`app/Localization/Localizable.xcstrings`). It goes into App Store Connect as Spanish (Spain) and Spanish
(Mexico), with the same words. The owner said "Yes, submit it" to this page and its screenshots on 14 November
2026, and it went into App Store Connect with version 1.2 the same day, each field read back. `check_listing.py
store/listing-es.md` counts each field against Apple's limit.

Later on 14 November 2026 the owner replaced the word "flota" with "equipo" ("in Spanish we don't say Flota.. it
must be Equipo probably"): this page has the new words, and so has the app's table. To "redo the Spanish App Store
screenshots?" he said "Yes, redo them", and the four of `screenshots/es/` were made again the same day. App Store
Connect's 1.2 pages, its screenshots and the 1.2 build still say "flota" ("Gestor de la flota"), until the next
version takes this page and these screenshots.

## Name (30)

Founderizer

## Subtitle (30)

Tu propio equipo de agentes IA

## Promotional text (170)

Los mismos agentes y las mismas decisiones, en tu bolsillo. Cada agente te escribe en su propio chat, y lo que te
necesita espera en un solo lugar hasta que respondas.

## Description (4000)

Founderizer es tu propio equipo de agentes de IA. Funciona en un servidor tuyo, con la suscripción de Claude o ChatGPT
que ya pagas, y te pregunta cuando una decisión es tuya. Esta app pone ese equipo en tu iPhone.

Chats
Cada agente te escribe en su propio chat, con el nombre de su rol: Gestor del equipo, Atención al cliente,
Desarrollador o los roles que des a tu equipo. Escribe a un agente como escribes a una persona.

Te necesita
Lo que te necesita espera en un solo lugar, con una insignia hasta que respondas. Cuando un agente da opciones, un
toque responde.

Tareas
Mira en qué trabajan ahora tus agentes y qué terminaron.

Comparte con un agente
Envía un enlace, una foto o un archivo desde cualquier app a un agente, con una línea tuya.

Tu equipo sigue siendo tuyo
La app habla solo con tu propio hub, por tu propia red privada, y Face ID protege la clave de este teléfono. Una
notificación dice qué agente pregunta y qué pregunta. Pasa por nosotros sellada, así que no podemos leerla.

Necesitas Founderizer en un Mac. Añade este teléfono desde la app del Mac: Ajustes, Servidores, Añadir dispositivo.
¿Aún no tienes equipo? Abre la app y mira primero un equipo de ejemplo.

## Keywords (100)

asistente,automatización,aprobaciones,tareas,equipo,negocio,operaciones,atención al cliente,DevOps

## What's new in 1.2 (4000)

Founderizer ya habla español: un iPhone en español muestra la app, y su equipo de ejemplo, en español.

## What's new in 1.2, English (4000)

Founderizer now speaks Spanish: an iPhone set to Spanish shows the app, and its sample fleet, in Spanish.

## Category, addresses, copyright

As in `listing.md`: the same category, the same support, privacy and marketing addresses, the same copyright.

## Screenshots

`screenshots/es/` (1206 × 2622, `APP_IPHONE_61`, the class that Apple requires; Apple scales it for larger iPhones),
PNG with no transparency, dark appearance, made as the English ones are: the sample fleet in Spanish
(`make_sample.py`) as a hub serves it, so no real name or message is on them, and no "Equipo de ejemplo" line. The
large class (1320 × 2868) has no Spanish set yet. The set of 14 November 2026 (the word "equipo") was made on an
iPhone 17 Pro simulator with iOS 26.3, the system of the first set: the app of `main`, its hub address set to the
sample of `make_sample.py` served on loopback, the language `es` (`es_ES`), the status bar at 09:41,
`simctl io … screenshot --mask=ignored`, and the alpha removed. Its times are those of the moment it was made.

1. Chats
2. A chat with the Gestor del equipo: its two requests, each where it was raised, then the owner's question and
   its answer (the first set showed the requests after the answer: the app on `main` now puts a request card where
   it was raised)
3. Te necesita
4. Tareas
