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
version takes this page and these screenshots. Version 1.5 took this page's description on 24 November 2026, so the store's Spanish
description says "equipo" since then.

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
Cada agente te escribe en su propio chat, con su nombre y su rol al lado. Escribe a un agente como escribes a una
persona.

Por atender
Lo que tienes por atender espera en un solo lugar, con una insignia hasta que respondas. Cuando un agente da opciones, un
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

## What's new in 1.5 (4000)

The same words on the pages of Spain and Mexico (the owner's "submit 1.5", 24 November 2026, 18:40 UTC; the area App
shell and look chose the words under his rule of 23 November 2026, "agent can decide").

• Cada agente aparece con su nombre y su rol al lado.
• En Por atender, cada solicitud es una tarjeta breve con su pregunta y sus opciones. Tócala para abrirla.
• Una tarjeta dice quién pregunta, qué pregunta y qué puedes tocar. El resto está en Detalles, y un script en Script.
• Cuando una solicitud te deja elegir varias opciones, marca cada una y toca Enviar.
• Una respuesta en camino muestra un círculo que gira y luego una marca de verificación. Si tu hub no responde, la app la vuelve a enviar por sí sola.
• Las palabras que parecen una clave esperan en su campo, también cuando compartes algo con un agente: toca Conservarlo para enviarlas tal como están.
• Una opción que solo tu Mac puede iniciar aparece en gris en el teléfono.
• Añadir este teléfono es más fiable, y la app te dice qué hacer: apuntar la cámara a la imagen de tu Mac o comprobar que Tailscale esté activado en este teléfono.

## What's new in 1.5, English (4000)

• Each agent shows by its name, with its role beside it.
• On Needs you, each request is a short card with its question and its options. Tap it to open it.
• A card says who asks, what they ask and what you can press. The rest is behind Details, and a script behind Script.
• When a request lets you pick more than one option, tick each one, then tap Send.
• An answer on its way shows a turning ring, then a check. If your hub does not reply, the app sends it again by itself.
• Words that look like a key wait in their box, also when you share to an agent: tap Keep it to send them as they are.
• An option that only your Mac can start is grey on the phone.
• Adding this phone is more reliable, and the app tells you what to do: point the camera at the picture on your Mac, or check that Tailscale is on on this phone.

## What's new in 1.4 (4000)

The same words on the pages of Spain and Mexico (the owner's "Yes, submit", 22 November 2026, about 07:45 UTC, to
these words in a question card of the area App shell and look).

• Una solicitud puede mostrar imágenes como opciones: toca la que quieras.
• Un valor que el agente escribió como código, como un comando o una dirección, aparece como etiqueta: tócala para copiarlo.
• Después de responder a una solicitud, tienes 5 segundos para deshacerlo. Mientras su tarea trabaja, la tarjeta muestra Pausar.
• Una tarjeta respondida muestra qué pasó con tu respuesta: hecha, en curso, fallida o una nueva pregunta para ti. Toca su marca para abrir la tarea.
• La marca de cada agente se mueve con suavidad mientras trabaja.
• Textos en español más claros.

## What's new in 1.4, English (4000)

• A request can show pictures as its options: tap the one you want.
• A value that the agent wrote as code, such as a command or an address, is a chip: tap it to copy it.
• After you answer a request, you have 5 seconds to undo it. While its task works, Pause stands on the card.
• An answered card shows what came of your answer: done, at work, failed, or a new question for you. Tap its mark to open the task.
• An agent's mark moves smoothly while it works.

## What's new in 1.3 (4000)

The same words on the pages of Spain and Mexico (the owner's "Yes, submit", 21 November 2026).

• Cada solicitud aparece ahora en el chat donde el agente la planteó, y tu respuesta queda en su tarjeta.
• «Necesita aclaración» en cada tarjeta: pregunta al agente por una solicitud antes de responderla.
• Una etiqueta marca la respuesta que recomienda el agente.
• Envía archivos de Word, Excel y PowerPoint con tus respuestas.
• Una tarjeta que te pide ejecutar un script te muestra antes ese script.
• En Chats, la fila de un chat muestra en naranja una solicitud que te espera.
• La marca de cada agente se mueve a su manera mientras trabaja.
• Cuando tu hub rechaza una solicitud, la app te dice por qué, en tu idioma.
• La app dice ahora «equipo» en lugar de «flota».

## What's new in 1.3, English (4000)

• Each request now stands in the chat where the agent raised it, and your answer stays on its card.
• "Needs clarification" on every card: ask the agent about a request before you answer it.
• A badge marks the answer that the agent recommends.
• Send Word, Excel and PowerPoint files with your answers.
• A card that asks you to run a script shows that script first.
• In Chats, a chat's row shows in orange a request that waits for you.
• Each agent's mark moves in its own way while it works.
• When your hub turns down a request, the app says why, in your language.

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
