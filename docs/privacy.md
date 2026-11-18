# Lux privacy policy

Lux is a Matrix chat client for iPhone and Mac. It has no server of its own, no account with us,
no analytics, no advertising and no tracking. We collect no data about you.

## What leaves your device

- **Your Matrix homeserver.** Lux talks to the homeserver you sign in to: your messages, photos,
  files, profile and contacts go there and come from there, as with any Matrix client. What the
  homeserver keeps, and the bridges it runs to other networks, are the homeserver operator's to
  decide; read their privacy policy. Chats are end-to-end encrypted where the chat is encrypted.
- **Push notifications.** To wake the app when a message arrives, your homeserver tells a push
  gateway, which tells Apple's push service. Lux asks for only the ids of the message and its
  chat; the text never passes through them. Lux then reads and decrypts the message on the device.
- **Apple.** The model for search downloads from Apple, as a part of the app. Crash reports and
  feedback reach the developer through TestFlight only when you choose to send them.

## What stays on your device

- Search, both its index and its model, runs entirely on the device. Photos and messages are never
  sent anywhere to be searched.
- Lux keeps its data in the app's own storage. Signing out deletes it from the device.

## Contact

Questions: open an issue at <https://github.com/davidbaranek/lux/issues>.
